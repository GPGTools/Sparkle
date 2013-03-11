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
	uint8_t hash[20];
	// This is the hash of the GPGTools installer certificate.
	uint8_t goodHash[] = {0xD9, 0xD5, 0xFD, 0x43, 0x9C, 0x95, 0x16, 0xEF, 0xC7, 0x3A, 0x0E, 0x4A, 0xD0, 0xF2, 0xC5, 0xDB, 0x9E, 0xA0, 0xE3, 0x10};

	
	if ((pkg = xar_open([pkgPath UTF8String], READ)) == nil) {
		return NO; // Unable to open the pkg.
	}
	
	signature = xar_signature_first(pkg);
	
	signatureType = xar_signature_type(signature);
	if (!signatureType || strncmp(signatureType, "RSA", 3)) {
		return NO; // Not a RSA signature.
	}

	if (xar_signature_get_x509certificate_count(signature) < 1) {
		return NO; // No certificate found.
	}

	if (xar_signature_get_x509certificate_data(signature, 0, &data, &length) == -1) {
		return NO; // Unable to extract the certificate data.
	}

	SHA1(data, length, (uint8_t *)&hash);
	
	if (memcmp(hash, goodHash, 20) != 0) {
		return NO; // Not the GPGTools certificate!
	}
	
	certificate = d2i_X509(nil, &data, length);
	if (xar_signature_copy_signed_data(signature, &plainData, &plainLength, &signData, &signLength, nil) != 0 || plainLength != 20) {
		return NO; // Unable to copy signed data || not SHA1.
	}
	
	pubkey = X509_get_pubkey(certificate);
	if (!pubkey || pubkey->type != EVP_PKEY_RSA || !pubkey->pkey.rsa) {
		return NO; // No pubkey || not RSA || no RSA.
	}

	// The verfication.
	if (RSA_verify(NID_sha1, plainData, plainLength, signData, signLength, pubkey->pkey.rsa) != 1) {
		return NO; // Verification failed!
	}

	return YES;
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
