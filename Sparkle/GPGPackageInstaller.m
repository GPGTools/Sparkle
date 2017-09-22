//
//  GPGPackageInstaller.m
//  Sparkle
//
//  Created by Mento on 28.04.16.
//  Copyright (c) 2016 GPGTools. All rights reserved.
//

#import "GPGPackageInstaller.h"

#import <Security/Security.h>
#import <SecurityFoundation/SFAuthorization.h>
#import <openssl/x509.h>
#import <xar/xar.h>



@implementation GPGPackageInstaller


+ (void)performInstallationToPath:(NSString *)destinationPath
                         fromPath:(NSString *)packagePath
                             host:(SUHost *)__unused host
                versionComparator:(id<SUVersionComparison>)__unused comparator
                completionHandler:(void (^)(NSError *))completionHandler {
    
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        
        void (^manualInstallation)() = ^() {
            BOOL validInstallation = NO;
            NSString *command = @"/usr/bin/open";
            // -W = wait until the app has quit.
            // -n = Open another instance if already open.
            // -b = app bundle identifier
            NSArray *args = @[@"-W", @"-n", @"-b", @"com.apple.installer", packagePath];
            
            
            @try {
                NSTask *installer = [NSTask launchedTaskWithLaunchPath:command arguments:args];
                [installer waitUntilExit];
                validInstallation = installer.terminationStatus == 0;
            }
            @catch (NSException *exception) {
                NSLog(@"Installation failed with exception: '%@'", exception);
            }

            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishInstallationToPath:destinationPath
                                    withResult:validInstallation
                                         error:nil
                             completionHandler:completionHandler];
                
            });
        };
        
        
#ifdef CODE_SIGN_CHECK
        /* Check the validity of the code signature. */
        if (![self isBundleValidSigned:[NSBundle mainBundle]]) {
            NSLog(@"bundle isn't signed correctly!");
            manualInstallation();
            return;
        }
#endif

        if (![[packagePath substringFromIndex:packagePath.length - 4] isEqualToString:@".pkg"]) {
            NSLog(@"Not a pkg-file: '%@'!", packagePath);
            manualInstallation();
            return;
        }
        
        BOOL isDir;
        if (![[NSFileManager defaultManager] fileExistsAtPath:packagePath isDirectory:&isDir] || isDir) {
            NSLog(@"No such file: '%@'!", packagePath);
            manualInstallation();
            return;
        }
        
        NSString *xmlPath = [packagePath stringByAppendingString:@".xml"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:xmlPath isDirectory:&isDir] || isDir) {
            xmlPath = nil;
        } else {
            NSLog(@"Use xml.");
        }
        
        if (![self checkPackage:packagePath]) {
            NSLog(@"The pkg-file '%@' isn't signed correctly!", packagePath);
            manualInstallation();
            return;
        }
        
        NSInteger result = [self installPackage:packagePath xml:xmlPath];
        if (result == 1) {
            manualInstallation();
            return;
        }
        
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishInstallationToPath:destinationPath
                                withResult:YES
                                     error:nil
                         completionHandler:completionHandler];
        });
    });
}




+ (BOOL)isBundleValidSigned:(NSBundle *)bundle {
    SecRequirementRef requirement = nil;
    SecStaticCodeRef staticCode = nil;
    
    SecStaticCodeCreateWithPath((__bridge CFURLRef)[bundle bundleURL], 0, &staticCode);
    SecRequirementCreateWithString(CFSTR("anchor apple generic and ( cert leaf = H\"C21964B138DE0094F42CEDE7078C6F800BA5838B\" or cert leaf = H\"233B4E43187B51BF7D6711053DD652DDF54B43BE\" ) "), 0, &requirement);
    
    OSStatus result = SecStaticCodeCheckValidity(staticCode, 0, requirement);
    
    if (staticCode) CFRelease(staticCode);
    if (requirement) CFRelease(requirement);
    return result == noErr;
}



+ (BOOL)checkPackage:(NSString *)pkgPath {
    xar_t pkg = NULL;
    xar_signature_t signature = NULL;
    const char *signatureType = NULL;
    const uint8_t *data = NULL;
    uint32_t length = 0, plainLength = 0, signLength = 0;
    X509 *certificate = NULL;
    uint8_t *plainData = NULL, *signData = NULL;
    EVP_PKEY *pubkey = NULL;
    RSA *rsa = NULL;
    uint8_t hash[20];
    int verificiationSuccess = 0;
    // This is the hash of the GPGTools installer certificate.
    const uint8_t goodHash[] = {0x56, 0x16, 0x98, 0xDA, 0x21, 0xAF, 0xA4, 0xFB, 0x04, 0xDF, 0x54, 0x17, 0x01, 0x0B, 0x59, 0x00, 0x5D, 0x5B, 0x3A, 0xDF};
    
    
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
    
    return [self installerCertificateIsTrustworthy:pkgPath];
}



+ (BOOL)installerCertificateIsTrustworthy:(NSString *)pkgPath {
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
            xar_close(pkg);
            return NO;
        }
        const CSSM_DATA cert = { (CSSM_SIZE) certificateLength, (uint8_t *) certificateData };
        error = SecCertificateCreateFromData(&cert, CSSM_CERT_X_509v3, CSSM_CERT_ENCODING_DER, &currentCertificateRef);
        if(error != errSecSuccess) {
            xar_close(pkg);
            return NO;
        }
        [certificates addObject:(__bridge id)currentCertificateRef];
    }
    
    policy = SecPolicyCreateBasicX509();
    error = SecTrustCreateWithCertificates((__bridge CFArrayRef)certificates, policy, &trust);
    if(error != noErr) {
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
        if(policy)
            CFRelease(policy);
        if(trust)
            CFRelease(trust);
        xar_close(pkg);
        return YES;
    }
    
    return NO;
}


+ (NSInteger)installPackage:(NSString *)pkgPath xml:(NSString *)xmlPath {
    // Run the installer command.
    NSArray *arguments;
    if (xmlPath) {
        arguments = @[@"-applyChoiceChangesXML", xmlPath, @"-pkg", pkgPath, @"-target", @"/"];
    } else {
        arguments = @[@"-pkg", pkgPath, @"-target", @"/"];
    }
    
    NSInteger result = [self executeWithPrivilegesAndWait:@"/usr/sbin/installer" arguments:arguments];
    
    return result;
}



+ (NSInteger)executeWithPrivilegesAndWait:(NSString *)executable arguments:(NSArray *)arguments {
    const char *path = executable.UTF8String;
    
    NSUInteger i = 0;
    NSUInteger count = arguments.count;
    const char *args[count + 1];
    
    for (; i < count; i++) {
        args[i] = [[arguments objectAtIndex:i]  UTF8String];
    }
    args[i] = nil;
    
    
    AuthorizationItem items[1];
    items[0].name = kAuthorizationRightExecute;
    items[0].value = (void *)path;
    items[0].valueLength = strlen(path);
    items[0].flags = 0;
    
    AuthorizationRights rights;
    rights.count = 1;
    rights.items = items;
    
    SFAuthorization *sfAuth = [SFAuthorization authorizationWithFlags:kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights
                                                               rights:&rights
                                                          environment:nil];
    AuthorizationRef authRef = [sfAuth authorizationRef];
    
    if(!authRef) {
        return -1;
    }
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus result = AuthorizationExecuteWithPrivileges(authRef, path, 0, (char* const*)args, nil);
#pragma clang diagnostic pop
    
    if (result == errAuthorizationSuccess) {
        int status;
        pid_t pid = wait(&status);
        if (pid != -1 && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
            return 0;
        }
    }
    
    return 1;
}



@end
