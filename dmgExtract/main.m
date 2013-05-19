#import <Cocoa/Cocoa.h>

BOOL extractDMG(NSString *dmgPath) {
	BOOL success = NO;
	BOOL needUnmount = NO;
	NSFileManager *fileManager = [NSFileManager defaultManager];
	
	// get a unique mount point path
	NSString *mountPoint = [dmgPath stringByAppendingPathExtension:@"mount"];
	int i = 0;
	while ([fileManager fileExistsAtPath:mountPoint]) {
		mountPoint = [dmgPath stringByAppendingPathExtension:[NSString stringWithFormat:@"mount%i", i]];
		i++;
	}
	
	{
		NSTask *task = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/hdiutil" arguments:@[@"attach", dmgPath, @"-mountpoint", mountPoint, @"-nobrowse", @"-noautoopen", @"-quiet"]];
		[task waitUntilExit];
		
		
		if ([task terminationStatus] != 0) {
			NSLog(@"hdiutil failed!");
			goto finally;
		}
		needUnmount = YES;
		
		
		NSError *error = nil;
		NSArray *contents = [fileManager contentsOfDirectoryAtPath:mountPoint error:&error];
		if (error) {
			NSLog(@"Couldn't enumerate contents of dmg mounted at %@: %@", mountPoint, error);
			goto finally;
		}
		
		NSEnumerator *contentsEnumerator = [contents objectEnumerator];
		NSString *item;
		while ((item = [contentsEnumerator nextObject])) {
			NSString *fromPath = [mountPoint stringByAppendingPathComponent:item];
			
			// We skip any files in the DMG which are not readable.
			if (![fileManager isReadableFileAtPath:fromPath]) {
				continue;
			}
			
			NSString *toPath = [[dmgPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:item];
			
			NSLog(@"copyItemAtPath:'%@' toPath:'%@'", fromPath, toPath);
			
			if (![fileManager copyItemAtPath:fromPath toPath:toPath error:&error]) {
				NSLog(@"Couldn't copy item: %@ : %@", error, error.userInfo ? error.userInfo : @"");
				goto finally;
			}
		}
	}
	
	success = YES;
	
finally:
	if (needUnmount) {
		NSTask *task = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/hdiutil" arguments:[NSArray arrayWithObjects:@"detach", mountPoint, @"-force", @"-quiet", nil]];
		[task waitUntilExit];
	}
	
	return success;
}

int main(int argc, char *argv[]) {
	if (argc != 2) {
		NSLog(@"Exact one argument 'dmgPath' is required!");
		return 1;
	}
	
	return extractDMG(@(argv[1])) ? 0 : 1;
}

