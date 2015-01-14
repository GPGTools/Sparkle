//
//  SUCodeSigningVerifier.m
//  Sparkle
//
//  Created by Andy Matuschak on 7/5/12.
//
//

#import <Security/CodeSigning.h>
#import "SUCodeSigningVerifier.h"
#import "SULog.h"
#import <openssl/x509.h>
#import <xar/xar.h>


@implementation SUCodeSigningVerifier

extern OSStatus SecCodeCopySelf(SecCSFlags flags, SecCodeRef *self)  __attribute__((weak_import));

extern OSStatus SecCodeCopyDesignatedRequirement(SecStaticCodeRef code, SecCSFlags flags, SecRequirementRef *requirement) __attribute__((weak_import));

extern OSStatus SecStaticCodeCreateWithPath(CFURLRef path, SecCSFlags flags, SecStaticCodeRef *staticCode) __attribute__((weak_import));

extern OSStatus SecStaticCodeCheckValidityWithErrors(SecStaticCodeRef staticCode, SecCSFlags flags, SecRequirementRef requirement, CFErrorRef *errors) __attribute__((weak_import));


+ (BOOL)codeSignatureIsValidAtPath:(NSString *)destinationPath error:(NSError **)error {
    // This API didn't exist prior to 10.6.
    if (SecCodeCopySelf == NULL) return NO;
    
    OSStatus result;
    SecRequirementRef requirement = NULL;
    SecStaticCodeRef staticCode = NULL;
    SecCodeRef hostCode = NULL;
    
    result = SecCodeCopySelf(kSecCSDefaultFlags, &hostCode);
    if (result != 0) {
        SULog(@"Failed to copy host code %d", result);
        goto finally;
    }
    
    result = SecCodeCopyDesignatedRequirement(hostCode, kSecCSDefaultFlags, &requirement);
    if (result != 0) {
        SULog(@"Failed to copy designated requirement %d", result);
        goto finally;
    }
    
    NSBundle *newBundle = [NSBundle bundleWithPath:destinationPath];
    if (!newBundle) {
        SULog(@"Failed to load NSBundle for update");
        result = -1;
        goto finally;
    }
    
    result = SecStaticCodeCreateWithPath((CFURLRef)[newBundle executableURL], kSecCSDefaultFlags, &staticCode);
    if (result != 0) {
        SULog(@"Failed to get static code %d", result);
        goto finally;
    }
    
    result = SecStaticCodeCheckValidityWithErrors(staticCode, kSecCSDefaultFlags | kSecCSCheckAllArchitectures, requirement, (CFErrorRef *)error);
    if (result != 0 && error) [*error autorelease];
    
finally:
    if (hostCode) CFRelease(hostCode);
    if (staticCode) CFRelease(staticCode);
    if (requirement) CFRelease(requirement);
    return (result == 0);
}

+ (BOOL)pkgSignatureIsValidAtPath:(NSString *)pkgPath error:(NSError **)error {
	xar_t pkg;
	xar_signature_t signature;
	const char *signatureType;
	const uint8_t *data;
	uint32_t length, plainLength, signLength;
	X509 *certificate;
	uint8_t *plainData, *signData;
	EVP_PKEY *pubkey;
	RSA *rsa = NULL;
    uint8_t hash[20];
    int verificiationSuccess = 0;
	// This is the hash of the GPGTools installer certificate.
	uint8_t goodHash[] = {0x56, 0x16, 0x98, 0xDA, 0x21, 0xAF, 0xA4, 0xFB, 0x04, 0xDF, 0x54, 0x17, 0x01, 0x0B, 0x59, 0x00, 0x5D, 0x5B, 0x3A, 0xDF};
	
    if ((pkg = xar_open([pkgPath UTF8String], READ)) == nil) {
        return NO; // Unable to open the pkg.
    }
    
    signature = xar_signature_first(pkg);
    // No signature, bail out.
    if(signature == NULL) {
        xar_close(pkg);
        return NO;
    }
    
    signatureType = xar_signature_type(signature);
    // No signature type available, bail out.
    if(signatureType == NULL) {
        xar_close(pkg);
        return NO;
    }
    
    // Signature type has to be RSA.
    if(strlen(signatureType) != 3) {
        xar_close(pkg);
        return NO;
    }
    if(strncmp(signatureType, "RSA", 3)) {
        xar_close(pkg);
        return NO;
    }
    
    if (xar_signature_get_x509certificate_count(signature) < 1) {
        xar_close(pkg);
        return NO; // No certificate found.
    }
    
    if (xar_signature_get_x509certificate_data(signature, 0, &data, &length) != 0) {
        xar_close(pkg);
        return NO; // Unable to extract the certificate data.
    }
    
    SHA1(data, length, (uint8_t *)&hash);
    
    if (memcmp(hash, goodHash, 20) != 0) {
        xar_close(pkg);
        return NO; // Not the GPGTools certificate!
    }
    
    certificate = d2i_X509(nil, &data, length);
    if(certificate == NULL) {
        xar_close(pkg);
        return NO;
    }
    if (xar_signature_copy_signed_data(signature, &plainData, &plainLength, &signData, &signLength, nil) != 0) {
        X509_free(certificate);
        xar_close(pkg);
        return NO; // Unable to copy signed data || not SHA1.
    }
    // Not SHA-1
    if(plainLength != 20) {
        X509_free(certificate);
        free(plainData);
        free(signData);
        xar_close(pkg);
        return NO;
    }
    
    pubkey = X509_get_pubkey(certificate);
    // No public key available.
    if(!pubkey) {
        X509_free(certificate);
        free(plainData);
        free(signData);
        xar_close(pkg);
        return NO;
    }
    // The public key is not RSA.
    if(pubkey->type != EVP_PKEY_RSA) {
        X509_free(certificate);
        free(plainData);
        free(signData);
        xar_close(pkg);
        return NO;
    }
    // RSA is not set.
    rsa = pubkey->pkey.rsa;
    if(!rsa) {
        X509_free(certificate);
        free(plainData);
        free(signData);
        xar_close(pkg);
        return NO;
    }
    
    // The verfication.
    verificiationSuccess = RSA_verify(NID_sha1, plainData, plainLength, signData, signLength, rsa);
    if (verificiationSuccess != 1) {
        X509_free(certificate);
        free(plainData);
        free(signData);
        xar_close(pkg);
        return NO; // Verification failed!
    }
    
    // Cleanup.
    X509_free(certificate);
    free(plainData);
    free(signData);
    xar_close(pkg);
    
    return [self installerCertificateIsTrustworthyWithPackage:pkgPath];
}

+ (BOOL)installerCertificateIsTrustworthyWithPackage:(NSString *)pkgPath {
    OSStatus error = noErr;
    NSMutableArray *certificates = nil;
    SecPolicyRef policy = NULL;
    SecTrustRef trust = NULL;
    SecTrustResultType trustResult;
    
    xar_t pkg = NULL;
    xar_signature_t signature = NULL;
    const uint8_t *certificateData = NULL;
    uint32_t certificateLength = 0;
    SecCertificateRef currentCertificateRef = NULL;
    
    // Open the pkg.
    if ((pkg = xar_open([pkgPath UTF8String], READ)) == nil) {
        return NO; // Unable to open the pkg.
    }
    
    // Retrieve the first signature.
    signature = xar_signature_first(pkg);
    if(signature == NULL) {
        xar_close(pkg);
        return NO;
    }
    
    int32_t nrOfCerts = xar_signature_get_x509certificate_count(signature);
    certificates = [[NSMutableArray alloc] init];
    for(int32_t i = 0; i < nrOfCerts; i++) {
        if(xar_signature_get_x509certificate_data(signature, i, &certificateData, &certificateLength) != 0) {
            [certificates release];
            xar_close(pkg);
            return NO;
        }
        const CSSM_DATA cert = { (CSSM_SIZE) certificateLength, (uint8_t *) certificateData };
        error = SecCertificateCreateFromData(&cert, CSSM_CERT_X_509v3, CSSM_CERT_ENCODING_DER, &currentCertificateRef);
        if(error != errSecSuccess) {
            [certificates release];
            xar_close(pkg);
            return NO;
        }
        [certificates addObject:(id)currentCertificateRef];
    }
    
    policy = SecPolicyCreateBasicX509();
    error = SecTrustCreateWithCertificates((CFArrayRef)certificates, policy, &trust);
    if(error != noErr) {
        [certificates release];
        if(policy)
            CFRelease(policy);
        if(trust)
            CFRelease(trust);
        xar_close(pkg);
        return NO;
    }
    
    // Check if the certificate can be trusted.
    error = SecTrustEvaluate(trust, &trustResult);
    if(error != noErr) {
        [certificates release];
        if(policy)
            CFRelease(policy);
        if(trust)
            CFRelease(trust);
        xar_close(pkg);
        return NO;
    }
    
    if(trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultConfirm ||
       trustResult == kSecTrustResultUnspecified) {
        // Clean up and return that the certificate can be trusted.
        [certificates release];
        if(policy)
            CFRelease(policy);
        if(trust)
            CFRelease(trust);
        xar_close(pkg);
        return YES;
    }
    
    return NO;
}

+ (BOOL)hostApplicationIsCodeSigned
{
    // This API didn't exist prior to 10.6.
    if (SecCodeCopySelf == NULL) return NO;
    
    OSStatus result;
    SecCodeRef hostCode = NULL;
    result = SecCodeCopySelf(kSecCSDefaultFlags, &hostCode);
    if (result != 0) return NO;
    
    SecRequirementRef requirement = NULL;
    result = SecCodeCopyDesignatedRequirement(hostCode, kSecCSDefaultFlags, &requirement);
    if (hostCode) CFRelease(hostCode);
    if (requirement) CFRelease(requirement);
    return (result == 0);
}

@end
