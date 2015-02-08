//
//  SUBasicUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 4/23/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUBasicUpdateDriver.h"

#import "SUHost.h"
#import "SUDSAVerifier.h"
#import "SUInstaller.h"
#import "SUStandardVersionComparator.h"
#import "SUUnarchiver.h"
#import "SUConstants.h"
#import "SULog.h"
#import "SUPlainInstaller.h"
#import "SUPlainInstallerInternals.h"
#import "SUBinaryDeltaCommon.h"
#import "SUCodeSigningVerifier.h"
#import "SUUpdater_Private.h"

@interface SUBasicUpdateDriver () <NSURLDownloadDelegate>; @end


@implementation SUBasicUpdateDriver

- (NSString *)userAgentString {
	// Build the user agent string, from the installed Tool, Libmacgpg and OS version.
	
	NSMutableDictionary *simpleProfile = [NSMutableDictionary dictionary];
	NSArray *profile = [host systemProfile];
	for (NSDictionary *item in profile) {
		[simpleProfile setObject:[item objectForKey:@"value"] forKey:[item objectForKey:@"key"]];
	}
	
	NSMutableString *string = [NSMutableString string];
	[string appendFormat:@"%@/%@-%@ ", [simpleProfile objectForKey:@"appName"], [simpleProfile objectForKey:@"appBuild"], [simpleProfile objectForKey:@"appVersion"]];
	[string appendFormat:@"Libmacgpg/%@-%@ ", [simpleProfile objectForKey:@"lmBuild"], [simpleProfile objectForKey:@"lmVersion"]];
	[string appendFormat:@"osx/%@ ", [simpleProfile objectForKey:@"osVersion"]];

	
	// Let's only send the system profiling information once per week at most, so we normalize daily-checkers vs. biweekly-checkers and the such.
	NSDate *lastSubmitDate = [host objectForUserDefaultsKey:SULastProfileSubmitDateKey];
	if(!lastSubmitDate)
		lastSubmitDate = [NSDate distantPast];
	const NSTimeInterval oneWeek = 60 * 60 * 24 * 7;
	BOOL sendingSystemProfile = (-[lastSubmitDate timeIntervalSinceNow] >= oneWeek);
	
	if (sendingSystemProfile) {
		[string appendString:@"profile "];
		
		if ([updater sendsSystemProfile]) {
			// Send more detailed profile, if any.
			[simpleProfile removeObjectsForKeys:[NSArray arrayWithObjects:@"appName", @"appBuild", @"appVersion", @"lmBuild", @"lmVersion", @"osVersion", nil]];
			
			for (NSString *key in simpleProfile) {
				NSString *value = [simpleProfile objectForKey:key];
				[string appendFormat:@"%@/%@ ", key, value];
			}
		}
		
		[host setObject:[NSDate date] forUserDefaultsKey:SULastProfileSubmitDateKey];
	}
	
	return string;
}


- (void)checkForUpdatesAtURL:(NSURL *)URL host:(SUHost *)aHost
{	
	[super checkForUpdatesAtURL:URL host:aHost];
	if ([aHost isRunningOnReadOnlyVolume])
	{
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURunningFromDiskImageError userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:SULocalizedString(@"%1$@ can't be updated when it's running from a read-only volume like a disk image or an optical drive. Move %1$@ to your Applications folder, relaunch it from there, and try again.", nil), [aHost name]] forKey:NSLocalizedDescriptionKey]]];
		return;
	}	
	
	SUAppcast *appcast = [[SUAppcast alloc] init];
	CFRetain(appcast); // We'll manage the appcast's memory ourselves so we don't have to make it an IV to support GC.
	[appcast release];
	
	[appcast setDelegate:self];
	[appcast setUserAgentString:[self userAgentString]];
	[appcast fetchAppcastFromURL:URL];
}

- (id <SUVersionComparison>)versionComparator
{
	id <SUVersionComparison> comparator = nil;
	
	// Give the delegate a chance to provide a custom version comparator
	if ([[updater delegate] respondsToSelector:@selector(versionComparatorForUpdater:)])
		comparator = [[updater delegate] versionComparatorForUpdater:updater];
	
	// If we don't get a comparator from the delegate, use the default comparator
	if (!comparator) {
		SUHost *aHost = self.host;
		if (!aHost) {
			aHost = [[[SUHost alloc] initWithBundle:updater.hostBundle] autorelease];
		}
		comparator = [SUGPGVersionComperator comperatorForHost:aHost];
	}
	
	return comparator;	
}

- (BOOL)isItemNewer:(SUAppcastItem *)ui
{
	return [[self versionComparator] compareVersion:[host version] toVersion:[ui versionString]] == NSOrderedAscending;
}

- (BOOL)hostSupportsItem:(SUAppcastItem *)ui
{
	if (([ui minimumSystemVersion] == nil || [[ui minimumSystemVersion] isEqualToString:@""]) && 
        ([ui maximumSystemVersion] == nil || [[ui maximumSystemVersion] isEqualToString:@""])) { return YES; }
    
    BOOL minimumVersionOK = TRUE;
    BOOL maximumVersionOK = TRUE;
    
    // Check minimum and maximum System Version
    if ([ui minimumSystemVersion] != nil && ![[ui minimumSystemVersion] isEqualToString:@""]) {
        minimumVersionOK = [[SUStandardVersionComparator defaultComparator] compareVersion:[ui minimumSystemVersion] toVersion:[SUHost systemVersionString]] != NSOrderedDescending;
    }
    if ([ui maximumSystemVersion] != nil && ![[ui maximumSystemVersion] isEqualToString:@""]) {
        maximumVersionOK = [[SUStandardVersionComparator defaultComparator] compareVersion:[ui maximumSystemVersion] toVersion:[SUHost systemVersionString]] != NSOrderedAscending;
    }
    
    return minimumVersionOK && maximumVersionOK;
}

- (BOOL)itemContainsSkippedVersion:(SUAppcastItem *)ui
{
	NSString *skippedVersion = [host objectForUserDefaultsKey:SUSkippedVersionKey];
	if (skippedVersion == nil) { return NO; }
	return [[self versionComparator] compareVersion:[ui versionString] toVersion:skippedVersion] != NSOrderedDescending;
}

- (BOOL)itemContainsValidUpdate:(SUAppcastItem *)ui
{
	return [self hostSupportsItem:ui] && [self isItemNewer:ui] && ![self itemContainsSkippedVersion:ui];
}

- (void)appcastDidFinishLoading:(SUAppcast *)ac
{
	SULog(@"appcastDidFinishLoading %@", ac);
	if ([[updater delegate] respondsToSelector:@selector(updater:didFinishLoadingAppcast:)])
		[[updater delegate] updater:updater didFinishLoadingAppcast:ac];
    
    SUAppcastItem *item = nil;
    
	// Now we have to find the best valid update in the appcast.
	if ([[updater delegate] respondsToSelector:@selector(bestValidUpdateInAppcast:forUpdater:)]) // Does the delegate want to handle it?
	{
		item = [[updater delegate] bestValidUpdateInAppcast:ac forUpdater:updater];
	}
	else // If not, we'll take care of it ourselves.
	{
		// Find the first update we can actually use.
		NSEnumerator *updateEnumerator = [[ac items] objectEnumerator];
		do {
			item = [updateEnumerator nextObject];
		} while (item && ![self hostSupportsItem:item]);

		if (binaryDeltaSupported()) {        
			SUAppcastItem *deltaUpdateItem = [[item deltaUpdates] objectForKey:[host version]];
			if (deltaUpdateItem && [self hostSupportsItem:deltaUpdateItem]) {
				nonDeltaUpdateItem = [item retain];
				item = deltaUpdateItem;
			}
		}
	}
    
    updateItem = [item retain];
	if (ac) { CFRelease(ac); } // Remember that we're explicitly managing the memory of the appcast.
	if (updateItem == nil) { [self didNotFindUpdate]; return; }
	
	if ([self itemContainsValidUpdate:updateItem])
		[self didFindValidUpdate];
	else
		[self didNotFindUpdate];
}

- (void)appcast:(SUAppcast *)ac failedToLoadWithError:(NSError *)error
{
	SULog(@"appcast: %@ failedToLoadWithError: %@", ac, error);
	if (ac) { CFRelease(ac); } // Remember that we're explicitly managing the memory of the appcast.
	[self abortUpdateWithError:error];
}

- (void)didFindValidUpdate
{
	SULog(@"didFindValidUpdate");
	if ([[updater delegate] respondsToSelector:@selector(updater:didFindValidUpdate:)])
		[[updater delegate] updater:updater didFindValidUpdate:updateItem];
	[self downloadUpdate];
}

- (void)didNotFindUpdate
{
	SULog(@"didNotFindUpdate");
	if ([[updater delegate] respondsToSelector:@selector(updaterDidNotFindUpdate:)])
		[[updater delegate] updaterDidNotFindUpdate:updater];
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUNoUpdateError userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:SULocalizedString(@"You already have the newest version of %@.", nil), [host name]] forKey:NSLocalizedDescriptionKey]]];
}

- (void)downloadUpdate
{
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[updateItem fileURL]];
	[request setValue:[updater userAgentString] forHTTPHeaderField:@"User-Agent"];
	download = [[NSURLDownload alloc] initWithRequest:request delegate:self];
}

- (void)download:(NSURLDownload *)d decideDestinationWithSuggestedFilename:(NSString *)name
{
	// If name ends in .txt, the server probably has a stupid MIME configuration. We'll give the developer the benefit of the doubt and chop that off.
	if ([[name pathExtension] isEqualToString:@"txt"])
		name = [name stringByDeletingPathExtension];
	
	NSString *downloadFileName = [NSString stringWithFormat:@"%@ %@", [host name], [updateItem versionString]];
    
    
	[tempDir release];
	tempDir = [[[host appSupportPath] stringByAppendingPathComponent:downloadFileName] retain];
	int cnt=1;
	while ([[NSFileManager defaultManager] fileExistsAtPath:tempDir] && cnt <= 999)
	{
		[tempDir release];
		tempDir = [[[host appSupportPath] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d", downloadFileName, cnt++]] retain];
	}
	
    // Create the temporary directory if necessary.
#if MAC_OS_X_VERSION_MIN_REQUIRED <= MAC_OS_X_VERSION_10_4
	BOOL success = YES;
    NSEnumerator *pathComponentEnumerator = [[tempDir pathComponents] objectEnumerator];
    NSString *pathComponentAccumulator = @"";
    NSString *currentPathComponent;
    while ((currentPathComponent = [pathComponentEnumerator nextObject])) {
        pathComponentAccumulator = [pathComponentAccumulator stringByAppendingPathComponent:currentPathComponent];
        if ([[NSFileManager defaultManager] fileExistsAtPath:pathComponentAccumulator]) continue;
        success &= [[NSFileManager defaultManager] createDirectoryAtPath:pathComponentAccumulator attributes:nil];
    }
#else
	BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:NULL];
#endif
	if (!success)
	{
		// Okay, something's really broken with this user's file structure.
		[download cancel];
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUTemporaryDirectoryError userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Can't make a temporary directory for the update download at %@.",tempDir] forKey:NSLocalizedDescriptionKey]]];
	}
	
	downloadPath = [[tempDir stringByAppendingPathComponent:name] retain];
	[download setDestination:downloadPath allowOverwrite:YES];
}

- (BOOL)validateUpdateDownloadedToPath:(NSString *)downloadedPath extractedToPath:(NSString *)extractedPath DSASignature:(NSString *)DSASignature publicDSAKey:(NSString *)publicDSAKey
{
    NSString *newBundlePath = [SUInstaller appPathInUpdateFolder:extractedPath forHost:host];
    if (newBundlePath)
    {
        NSError *error = nil;
        if ([SUCodeSigningVerifier codeSignatureIsValidAtPath:newBundlePath error:&error]) {
            return YES;
        } else {
            SULog(@"Code signature check on update failed: %@", error);
        }
    }
	else if ((newBundlePath = [SUInstaller pkgPathInUpdateFolder:extractedPath forHost:host]) != nil){
        NSError *error = nil;
        if ([SUCodeSigningVerifier pkgSignatureIsValidAtPath:newBundlePath error:&error]) {
            return YES;
        } else {
            SULog(@"Package signature check on update failed: %@", error);
        }
	}
    SULog(@"Verifying DSA signature of %@", downloadedPath);
	SULog(@"DSA Signature: %@", DSASignature);
	SULog(@"DSA Key: %@", publicDSAKey);
	BOOL valid = [SUDSAVerifier validatePath:downloadedPath withEncodedDSASignature:DSASignature withPublicDSAKey:publicDSAKey];
	SULog(@"Now let's see if this is valid: %@", valid ? @"YES" : @"NO");
	return valid;
}

- (void)downloadDidFinish:(NSURLDownload *)d
{	
	[self extractUpdate];
}

- (void)download:(NSURLDownload *)download didFailWithError:(NSError *)error
{
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while downloading the update. Please try again later.", nil), NSLocalizedDescriptionKey, [error localizedDescription], NSLocalizedFailureReasonErrorKey, nil]]];
}

- (BOOL)download:(NSURLDownload *)download shouldDecodeSourceDataOfMIMEType:(NSString *)encodingType
{
	// We don't want the download system to extract our gzips.
	// Note that we use a substring matching here instead of direct comparison because the docs say "application/gzip" but the system *uses* "application/x-gzip". This is a documentation bug.
	return ([encodingType rangeOfString:@"gzip"].location == NSNotFound);
}

- (void)extractUpdate
{	
	SUUnarchiver *unarchiver = [SUUnarchiver unarchiverForPath:downloadPath updatingHost:host];
	if (!unarchiver)
	{
		SULog(@"Sparkle Error: No valid unarchiver for %@!", downloadPath);
		[self unarchiverDidFail:nil];
		return;
	}
	CFRetain(unarchiver); // Manage this memory manually so we don't have to make it an IV.
	[unarchiver setDelegate:self];
	[unarchiver start];
}

- (void)failedToApplyDeltaUpdate
{
	// When a delta update fails to apply we fall back on updating via a full install.
	[updateItem release];
	updateItem = nonDeltaUpdateItem;
	nonDeltaUpdateItem = nil;

	[self downloadUpdate];
}

- (void)unarchiverDidFinish:(SUUnarchiver *)ua
{
	if (ua) { CFRelease(ua); }
	[self installWithToolAndRelaunch:YES];
}

- (void)unarchiverDidFail:(SUUnarchiver *)ua
{
	if (ua) { CFRelease(ua); }

	if ([updateItem isDeltaUpdate]) {
		[self failedToApplyDeltaUpdate];
		return;
	}

	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUUnarchivingError userInfo:[NSDictionary dictionaryWithObject:SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil) forKey:NSLocalizedDescriptionKey]]];
}

- (BOOL)shouldInstallSynchronously { return NO; }

- (void)installWithToolAndRelaunch:(BOOL)relaunch
{
#if !ENDANGER_USERS_WITH_INSECURE_UPDATES
    if (![self validateUpdateDownloadedToPath:downloadPath extractedToPath:tempDir DSASignature:[updateItem DSASignature] publicDSAKey:[host publicDSAKey]])
    {
        [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUSignatureError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil), NSLocalizedDescriptionKey, @"The update is improperly signed.", NSLocalizedFailureReasonErrorKey, nil]]];
        return;
	}
#endif
    
    if (![updater mayUpdateAndRestart])
    {
        [self abortUpdate];
        return;
    }
    
    // Give the host app an opportunity to postpone the install and relaunch.
    static BOOL postponedOnce = NO;
    if (!postponedOnce && [[updater delegate] respondsToSelector:@selector(updater:shouldPostponeRelaunchForUpdate:untilInvoking:)])
    {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[[self class] instanceMethodSignatureForSelector:@selector(installWithToolAndRelaunch:)]];
        [invocation setSelector:@selector(installWithToolAndRelaunch:)];
        [invocation setArgument:&relaunch atIndex:2];
        [invocation setTarget:self];
        postponedOnce = YES;
        if ([[updater delegate] updater:updater shouldPostponeRelaunchForUpdate:updateItem untilInvoking:invocation])
            return;
    }

    
	if ([[updater delegate] respondsToSelector:@selector(updater:willInstallUpdate:)])
		[[updater delegate] updater:updater willInstallUpdate:updateItem];
	
	// Copy the relauncher into a temporary directory so we can get to it after the new version's installed.
	NSString *relaunchPathToCopy = [SPARKLE_BUNDLE pathForResource:@"finish_installation" ofType:@"app"];
    NSString *targetPath = [[host appSupportPath] stringByAppendingPathComponent:[relaunchPathToCopy lastPathComponent]];
	// Only the paranoid survive: if there's already a stray copy of relaunch there, we would have problems.
	NSError *error = nil;
#if MAC_OS_X_VERSION_MIN_REQUIRED <= MAC_OS_X_VERSION_10_4
	[[NSFileManager defaultManager] createDirectoryAtPath: [targetPath stringByDeletingLastPathComponent] attributes: [NSDictionary dictionary]];
#else
	[[NSFileManager defaultManager] createDirectoryAtPath: [targetPath stringByDeletingLastPathComponent] withIntermediateDirectories: YES attributes: [NSDictionary dictionary] error: &error];
#endif

	// Only the paranoid survive: if there's already a stray copy of relaunch there, we would have problems.
	if( [SUPlainInstaller copyPathWithAuthentication: relaunchPathToCopy overPath: targetPath temporaryName: nil error: &error] )
		relaunchPath = [targetPath retain];
	else
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil), NSLocalizedDescriptionKey, [NSString stringWithFormat:@"Couldn't copy relauncher (%@) to temporary path (%@)! %@", relaunchPathToCopy, targetPath, (error ? [error localizedDescription] : @"")], NSLocalizedFailureReasonErrorKey, nil]]];
	
    [[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterWillRestartNotification object:self];
    if ([[updater delegate] respondsToSelector:@selector(updaterWillRelaunchApplication:)])
        [[updater delegate] updaterWillRelaunchApplication:updater];

    if(!relaunchPath || ![[NSFileManager defaultManager] fileExistsAtPath:relaunchPath])
    {
        // Note that we explicitly use the host app's name here, since updating plugin for Mail relaunches Mail, not just the plugin.
        [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:SULocalizedString(@"An error occurred while relaunching %1$@, but the new version will be available next time you run %1$@.", nil), [host name]], NSLocalizedDescriptionKey, [NSString stringWithFormat:@"Couldn't find the relauncher (expected to find it at %@)", relaunchPath], NSLocalizedFailureReasonErrorKey, nil]]];
        // We intentionally don't abandon the update here so that the host won't initiate another.
        return;
    }		
    
    NSString *pathToRelaunch = [host bundlePath];
    if ([[updater delegate] respondsToSelector:@selector(pathToRelaunchForUpdater:)])
        pathToRelaunch = [[updater delegate] pathToRelaunchForUpdater:updater];
    NSString *relaunchToolPath = [relaunchPath stringByAppendingPathComponent: @"/Contents/MacOS/finish_installation"];
    NSArray *arguments = @[[host bundlePath], pathToRelaunch, [NSString stringWithFormat:@"%d", [[NSProcessInfo processInfo] processIdentifier]], tempDir, relaunch ? @"1" : @"0"];
	
	if ([[updater delegate] respondsToSelector:@selector(updater:relaunchUsingPath:arguments:)]) {
		// let the delegate relaunch the app.
		if ([[updater delegate] updater:updater relaunchUsingPath:relaunchToolPath arguments:arguments]) {
			[NSApp terminate:self];
		}
	}
	[NSTask launchedTaskWithLaunchPath: relaunchToolPath arguments:arguments];
	
	[NSApp terminate:self];
}

- (void)cleanUpDownload
{
    if (tempDir != nil)	// tempDir contains downloadPath, so we implicitly delete both here.
	{
		BOOL		success = NO;
#if MAC_OS_X_VERSION_MIN_REQUIRED <= MAC_OS_X_VERSION_10_4
        success = [[NSFileManager defaultManager] removeFileAtPath: tempDir handler: nil]; // Clean up the copied relauncher
#else
        NSError	*	error = nil;
        success = [[NSFileManager defaultManager] removeItemAtPath: tempDir error: &error]; // Clean up the copied relauncher
#endif
		if( !success )
			[[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation source:[tempDir stringByDeletingLastPathComponent] destination:@"" files:[NSArray arrayWithObject:[tempDir lastPathComponent]] tag:NULL];
	}
}

- (void)installerForHost:(SUHost *)aHost failedWithError:(NSError *)error
{
	if (aHost != host) { return; }
#if MAC_OS_X_VERSION_MIN_REQUIRED <= MAC_OS_X_VERSION_10_4
    [[NSFileManager defaultManager] removeFileAtPath: relaunchPath handler: nil]; // Clean up the copied relauncher
#else
	NSError	*	dontThrow = nil;
	[[NSFileManager defaultManager] removeItemAtPath: relaunchPath error: &dontThrow]; // Clean up the copied relauncher
#endif
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while installing the update. Please try again later.", nil), NSLocalizedDescriptionKey, [error localizedDescription], NSLocalizedFailureReasonErrorKey, nil]]];
}

- (void)abortUpdate
{
	[[self retain] autorelease];	// In case the notification center was the last one holding on to us.
    [self cleanUpDownload];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[super abortUpdate];
}

- (void)abortUpdateWithError:(NSError *)error
{
	SULog(@"Sparkle Error: %@", [error localizedDescription]);
	if ([error localizedFailureReason])
		SULog(@"Sparkle Error (continued): %@", [error localizedFailureReason]);
	if (download)
		[download cancel];
	[self abortUpdate];
}

- (void)dealloc
{
	[updateItem release];
	[nonDeltaUpdateItem release];
	[download release];
	[downloadPath release];
	[tempDir release];
	[relaunchPath release];
	[super dealloc];
}

@end
