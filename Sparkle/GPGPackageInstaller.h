//
//  GPGPackageInstaller.h
//  Sparkle
//
//  Created by Mento on 28.04.16.
//  Copyright (c) 2016 GPGTools. All rights reserved.
//

#import "SUInstaller.h"

@interface GPGPackageInstaller : SUInstaller

+ (void)performInstallationToPath:(NSString *)path fromPath:(NSString *)installerGuide host:(SUHost *)host versionComparator:(id<SUVersionComparison>)comparator completionHandler:(void (^)(NSError *))completionHandler;

@end
