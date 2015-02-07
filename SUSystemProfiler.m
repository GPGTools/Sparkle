//
//  SUSystemProfiler.m
//  Sparkle
//
//  Created by Andy Matuschak on 12/22/07.
//  Copyright 2007 Andy Matuschak. All rights reserved.
//  Adapted from Sparkle+, by Tom Harrington.
//

#import "SUSystemProfiler.h"

#import "SUHost.h"
#import <sys/sysctl.h>

@implementation SUSystemProfiler
+ (SUSystemProfiler *)sharedSystemProfiler
{
	static SUSystemProfiler *sharedSystemProfiler = nil;
	if (!sharedSystemProfiler)
		sharedSystemProfiler = [[self alloc] init];
	return sharedSystemProfiler;
}

- (NSMutableArray *)systemProfileArrayForHost:(SUHost *)host
{
	// Gather profile information.
	NSMutableArray *profileArray = [NSMutableArray array];
	NSArray *profileDictKeys = [NSArray arrayWithObjects:@"key", @"displayKey", @"value", @"displayValue", nil];
	
	// OS version
	NSString *currentSystemVersion = [SUHost systemVersionString];
	if (currentSystemVersion != nil)
		[profileArray addObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:@"osVersion",@"OS Version",currentSystemVersion,currentSystemVersion,nil] forKeys:profileDictKeys]];
	
	
	// Application sending the request
	NSString *appName = [host name];
	if (appName)
		[profileArray addObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:@"appName",@"Application Name", appName, appName,nil] forKeys:profileDictKeys]];
	NSString *appBuild = [host version];
	if (appBuild)
		[profileArray addObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:@"appBuild",@"Application Version", appBuild, appBuild,nil] forKeys:profileDictKeys]];
	NSString *appVersion = [host displayVersion];
	if (appVersion)
		[profileArray addObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:@"appVersion",@"Application Display Version", appVersion, appVersion,nil] forKeys:profileDictKeys]];
	
	
	// Libmacgpg version
	Class lmclass = NSClassFromString(@"GPGOptions");
	if (lmclass) {
		NSBundle *libmacgpg = [NSBundle bundleForClass:lmclass];
		if (libmacgpg) {
			NSString *lmBuild = [libmacgpg objectForInfoDictionaryKey:@"CFBundleVersion"];
			if (lmBuild)
				[profileArray addObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:@"lmBuild",@"Libmacgpg Version", lmBuild, lmBuild,nil] forKeys:profileDictKeys]];
			NSString *lmVersion = [libmacgpg objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
			if (lmVersion)
				[profileArray addObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:@"lmVersion",@"Libmacgpg Display Version", lmVersion, lmVersion,nil] forKeys:profileDictKeys]];
		}
	}
	
	return profileArray;
}

@end
