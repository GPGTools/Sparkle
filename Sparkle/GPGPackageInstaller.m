//
//  GPGPackageInstaller.m
//  GPGTools Sparkle extension
//
//  Created by Mento on 09.02.18.
//

#import "GPGPackageInstaller.h"

#import <xar/xar.h>
#import <CommonCrypto/CommonDigest.h>
#import "SUErrors.h"
#import "SULog.h"


@interface SUGuidedPackageInstaller ()
// Make the property visible.
@property (nonatomic, readonly, copy) NSString *packagePath;
@end


static NSString *localized(NSString *key) {
    if (!key) {
        return nil;
    }
    static NSBundle *bundle = nil, *englishBundle = nil;
    if (!bundle) {
        bundle = [NSBundle mainBundle];
        englishBundle = [NSBundle bundleWithPath:(NSString * _Nonnull)[bundle pathForResource:@"en" ofType:@"lproj"]];
    }
    
    NSString *notFoundValue = @"~#*?*#~";
    NSString *localized = [bundle localizedStringForKey:key value:notFoundValue table:@"GPGSparkle"];
    if (localized == notFoundValue) {
        localized = [englishBundle localizedStringForKey:key value:nil table:@"GPGSparkle"];
    }
    
    return localized;
}




@implementation GPGPackageInstaller

/*
 * Checks if the main bundle and the pkg are valid signed and installs the pkg. 
*/
- (BOOL)performFinalInstallationProgressBlock:(nullable void(^)(double))progressBlock error:(NSError * __autoreleasing *)error {
    
#ifdef CODE_SIGN_CHECK
    /* Check the validity of the code signature. */
    if (![self isBundleValidSigned:[NSBundle mainBundle]]) {
        SULog(SULogLevelError, @"bundle isn't signed correctly!");
        if (error) {
            NSString *errorMessage = [NSString stringWithFormat:@"%@%@", localized(@"ErrorTampered"), localized(@"ErrorInstallOriginal")];
            *error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:@{NSLocalizedDescriptionKey: errorMessage}];
        }
        return NO;
    }
#endif
    
    if (![[self.packagePath substringFromIndex:self.packagePath.length - 4] isEqualToString:@".pkg"]) {
        SULog(SULogLevelError, @"Not a pkg-file: '%@'!", self.packagePath);
        if (error) {
            NSString *errorMessage = [NSString stringWithFormat:@"%@%@", localized(@"ErrorNotPkg"), localized(@"ErrorInstallOriginal")];
            *error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:@{NSLocalizedDescriptionKey: errorMessage}];
        }
        return NO;
    }
    
    BOOL isDir;
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.packagePath isDirectory:&isDir] || isDir) {
        SULog(SULogLevelError, @"No such file: '%@'!", self.packagePath);
        if (error) {
            NSString *errorMessage = [NSString stringWithFormat:@"%@%@", localized(@"ErrorExtraction"), localized(@"ErrorInstallOriginal")];
            *error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:@{NSLocalizedDescriptionKey: errorMessage}];
        }
        return NO;
    }
    
    if (![self checkPackage:self.packagePath error:error]) {
        SULog(SULogLevelError, @"The pkg-file '%@' isn't signed correctly!", self.packagePath);
        return NO;
    }
    
    
    return [super performFinalInstallationProgressBlock:progressBlock error:error];
}

/*
 * Checks if the main bundle is valid signed.
 */
- (BOOL)isBundleValidSigned:(NSBundle *)bundle {
    SecRequirementRef requirement = nil;
    SecStaticCodeRef staticCode = nil;
    
    SecStaticCodeCreateWithPath((__bridge CFURLRef)[bundle bundleURL], 0, &staticCode);
    SecRequirementCreateWithString(CFSTR("anchor apple generic and ( cert leaf = H\"C21964B138DE0094F42CEDE7078C6F800BA5838B\" or cert leaf = H\"233B4E43187B51BF7D6711053DD652DDF54B43BE\" ) "), 0, &requirement);
    
    OSStatus result = SecStaticCodeCheckValidity(staticCode, 0, requirement);
    
    if (staticCode) {
        CFRelease(staticCode);
    }
    if (requirement) {
        CFRelease(requirement);
    }
    return result == noErr;
}

/*
 * Checks if the pkg is valid signed.
 */
- (BOOL)checkPackage:(NSString *)pkgPath error:(NSError * __autoreleasing *)error {
    xar_t xarPkg = nil;
    xar_signature_t xarSignature = nil;
    const char *signatureType = nil;
    const uint8_t *certificateBytes = nil;
    uint32_t certificateLength = 0, plaintextLength = 0, signatureLength = 0;
    uint8_t *plaintextBytes = nil, *signatureBytes = nil;
    NSMutableData *calculatedHash = nil;
    BOOL isValid = NO;
    SecCertificateRef certificateRef = nil;
    NSData *certificateData = nil;
    SecKeyRef publicKeyRef = nil;
    NSData *signatureData = nil;
    NSData *signedData = nil;
    CFErrorRef errorRef = nil;
    SecTransformRef verifier = nil;
    CFBooleanRef result = nil;
    
    
    // This is the SHA512 hash of the GPGTools installer certificate.
    const uint8_t gpgtoolsCertHashBytes[] = {
        0xBD, 0xF0, 0xBD, 0xC6, 0xDC, 0x99, 0x03, 0x48, 0x72, 0xCA, 0x54, 0x71, 0xAD, 0x78, 0x1B, 0x0A,
        0x53, 0x0F, 0xEE, 0x0D, 0xC3, 0x74, 0x42, 0x0B, 0x98, 0x21, 0xFE, 0x97, 0x77, 0x2F, 0xA1, 0x3C,
        0x51, 0x9E, 0x4D, 0x1F, 0x1F, 0xB2, 0xE4, 0xA7, 0xAF, 0x4D, 0xA3, 0x42, 0xCF, 0xD8, 0x5F, 0xCF,
        0x82, 0xC3, 0xEF, 0xC5, 0x8B, 0x55, 0x14, 0x53, 0xFD, 0x03, 0x6E, 0x34, 0xD7, 0xAE, 0x68, 0x89
    };
    NSData *gpgtoolsCertHash = [NSData dataWithBytes:gpgtoolsCertHashBytes length:sizeof(gpgtoolsCertHashBytes)];
    
    
    do {
        xarPkg = xar_open(pkgPath.UTF8String, READ);
        if (xarPkg == nil) {
            SULog(SULogLevelError, @"Unable to open the pkg.");
            break; // Unable to open the pkg.
        }
        
        xarSignature = xar_signature_first(xarPkg);
        if (xarSignature == nil) {
            SULog(SULogLevelError, @"No signature.");
            break; // No signature.
        }
        
        signatureType = xar_signature_type(xarSignature);
        if (signatureType == nil) {
            SULog(SULogLevelError, @"No signature type available.");
            break; // No signature type available.
        }
        
        if (strlen(signatureType) != 3) {
            SULog(SULogLevelError, @"Signature type isn't RSA.");
            break; // Signature type isn't RSA.
        }
        if (strncmp(signatureType, "RSA", 3)) {
            SULog(SULogLevelError, @"Signature type isn't RSA.");
            break; // Signature type isn't RSA.
        }
        
        if (xar_signature_get_x509certificate_count(xarSignature) < 1) {
            SULog(SULogLevelError, @"No certificate found.");
            break; // No certificate found.
        }
        
        if (xar_signature_get_x509certificate_data(xarSignature, 0, &certificateBytes, &certificateLength) != 0) {
            SULog(SULogLevelError, @"Unable to extract certificate data.");
            break; // Unable to extract certificate data.
        }
        
        calculatedHash = [NSMutableData dataWithLength:CC_SHA512_DIGEST_LENGTH];
        CC_SHA512(certificateBytes, certificateLength, (uint8_t *)calculatedHash.mutableBytes);
        if (![gpgtoolsCertHash isEqualToData:calculatedHash]) {
            SULog(SULogLevelError, @"Not the GPGTools certificate.");
            break; // Not the GPGTools certificate!
        }
        
        if (xar_signature_copy_signed_data(xarSignature, &plaintextBytes, &plaintextLength, &signatureBytes, &signatureLength, nil) != 0) {
            SULog(SULogLevelError, @"Unable to copy signed data.");
            break; // Unable to copy signed data.
        }
        
        if (plaintextLength != CC_SHA1_DIGEST_LENGTH) {
            SULog(SULogLevelError, @"Not SHA-1.");
            break; // Not SHA-1.
        }
        
        certificateData = [[NSData alloc] initWithBytes:certificateBytes length:certificateLength];
        certificateRef = SecCertificateCreateWithData(nil, (CFDataRef)certificateData);
        if (!certificateRef) {
            SULog(SULogLevelError, @"Can't create certificate ref.");
            break; // Can't create certificate ref.
        }
        
        if (SecCertificateCopyPublicKey(certificateRef, &publicKeyRef) != 0) {
            SULog(SULogLevelError, @"No public key available.");
            break; // No public key available.
        }
        
        signatureData = [[NSData alloc] initWithBytes:signatureBytes length:signatureLength];
        signedData = [[NSData alloc] initWithBytes:plaintextBytes length:plaintextLength];
        
        
        verifier = SecVerifyTransformCreate(publicKeyRef, (CFDataRef)signatureData, &errorRef);
        if (errorRef) {
            SULog(SULogLevelError, @"Unable to create verify transform.");
            break; // Unable to create verify transform.
        }
        
        SecTransformSetAttribute(verifier, kSecTransformInputAttributeName, (CFDataRef)signedData, &errorRef);
        if (errorRef) {
            SULog(SULogLevelError, @"Unable to set signed data.");
            break; // Unable to set signed data.
        }
        
        SecTransformSetAttribute(verifier, kSecInputIsAttributeName, kSecInputIsDigest, &errorRef);
        if (errorRef) {
            SULog(SULogLevelError, @"Unable to set attribute.");
            break; // Unable to set attribute.
        }
        
        
        result = SecTransformExecute(verifier, &errorRef);
        if (errorRef) {
            SULog(SULogLevelError, @"Signature does not verify.");
            break; // Signature does not verify.
        }
        
        isValid = result == kCFBooleanTrue;
        
    } while (0);
    
    
    // Cleanup.
    if (verifier) {
        CFRelease(verifier);
    }
    if (certificateRef) {
        CFRelease(certificateRef);
    }
    if (plaintextBytes) {
        free(plaintextBytes);
    }
    if (signatureBytes) {
        free(signatureBytes);
    }
    if (xarPkg) {
        xar_close(xarPkg);
    }
    
    
    if (isValid) {
        if (![self installerCertificateIsTrustworthy:pkgPath]) {
            SULog(SULogLevelError, @"installer certificate isn't valid.");
            isValid = NO;
        }
    }
    if (isValid) {
        // Verify the content of the package using pkgutil;
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/sbin/pkgutil";
        task.arguments = @[@"--check-signature", pkgPath];
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        [task launch];
        [task waitUntilExit];
        if (task.terminationStatus != 0) {
            SULog(SULogLevelError, @"pkgutil did not verify.");
            isValid = NO;
        }
    }
    if (!isValid) {
        SULog(SULogLevelError, @"checkPackage failed.");
        if (error) {
            NSString *errorMessage = [NSString stringWithFormat:@"%@%@", localized(@"ErrorVerify"), localized(@"ErrorInstallOriginal")];
            *error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:@{NSLocalizedDescriptionKey: errorMessage}];
        }
        return NO;
    }
    
    
    return YES;
}

/*
 * Checks if the certificates in the pkg can be trusted.
 */
- (BOOL)installerCertificateIsTrustworthy:(NSString *)pkgPath {
    OSStatus error = noErr;
    NSMutableArray *certificates = nil;
    SecPolicyRef policy = nil;
    SecTrustRef trust = nil;
    SecTrustResultType trustResult;
    xar_t pkg = nil;
    xar_signature_t signature = nil;
    const uint8_t *certificateBytes = nil;
    uint32_t certificateLength = 0;
    NSData *certificateData = nil;
    SecCertificateRef certificateRef = nil;
    int32_t certificateCount = 0;
    
    // Open the pkg.
    pkg = xar_open(pkgPath.UTF8String, READ);
    if (pkg == nil) {
        SULog(SULogLevelError, @"Unable to open the pkg.");
        return NO; // Unable to open the pkg.
    }
    
    // Retrieve the first signature.
    signature = xar_signature_first(pkg);
    if (signature == nil) {
        SULog(SULogLevelError, @"No signature.");
        xar_close(pkg);
        return NO;
    }
    
    certificateCount = xar_signature_get_x509certificate_count(signature);
    certificates = [[NSMutableArray alloc] init];
    for (int32_t i = 0; i < certificateCount; i++) {
        if (xar_signature_get_x509certificate_data(signature, i, &certificateBytes, &certificateLength) != 0) {
            SULog(SULogLevelError, @"Unable to extract certificate data.");
            xar_close(pkg);
            return NO;
        }
        
        certificateData = [[NSData alloc] initWithBytes:certificateBytes length:certificateLength];
        certificateRef = SecCertificateCreateWithData(nil, (CFDataRef)certificateData);
        if (!certificateRef) {
            SULog(SULogLevelError, @"Can't create certificate ref.");
            xar_close(pkg);
            return NO;
        }
        
        [certificates addObject:(__bridge id)certificateRef];
    }
    
    policy = SecPolicyCreateBasicX509();
    error = SecTrustCreateWithCertificates((__bridge CFArrayRef)certificates, policy, &trust);
    if (error != noErr) {
        SULog(SULogLevelError, @"Can't create certificate trust.");
        if (policy) {
            CFRelease(policy);
        }
        if (trust) {
            CFRelease(trust);
        }
        xar_close(pkg);
        return NO;
    }
    
    // Check if the certificate can be trusted.
    error = SecTrustEvaluate(trust, &trustResult);
    
    
    // Clean up.
    if (policy) {
        CFRelease(policy);
    }
    if (trust) {
        CFRelease(trust);
    }
    xar_close(pkg);
    
    
    if (error != noErr) {
        SULog(SULogLevelError, @"Can't evaluate trust.");
        return NO;
    }
    
    if (trustResult != kSecTrustResultProceed &&
        trustResult != kSecTrustResultConfirm &&
        trustResult != kSecTrustResultUnspecified) {
        SULog(SULogLevelError, @"The certificate can't be trusted.");
        return NO;
    }

    return YES;
}


@end
