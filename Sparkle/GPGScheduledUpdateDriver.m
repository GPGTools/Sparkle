//
//  GPGScheduledUpdateDriver.m
//  GPGTools Sparkle extension
//
//  Created by Mento on 09.02.18.
//

#import "GPGScheduledUpdateDriver.h"
#import "SUAppcastItem.h"
#import "SUUpdaterPrivate.h"
#import "SUUpdaterDelegate.h"

@protocol GPGUpdaterDelegate <NSObject>
- (void)updater:(SUUpdater *)updater didFindValidUpdateInBackground:(SUAppcastItem *)item;
@end

@interface GPGScheduledUpdateDriver () <NSUserNotificationCenterDelegate>
@property (nonatomic) BOOL shouldDisableKeyboardShortcutForInstallButton;
@end


@implementation GPGScheduledUpdateDriver
@synthesize shouldDisableKeyboardShortcutForInstallButton;

- (void)didFindValidUpdate {
    id<SUUpdaterPrivate> updater = self.updater;
    id<GPGUpdaterDelegate> delegate = (id)updater.delegate;

    if (!self.updateItem.isCriticalUpdate && [delegate respondsToSelector:@selector(updater:didFindValidUpdateInBackground:)]) {
        // Notify the delegate and stop now.
        // The delegate is responsilbe to trigger the installation or a foreground update check.
        [delegate updater:self.updater didFindValidUpdateInBackground:self.updateItem];
        [self abortUpdate];
    } else {
        // For critical updates, the update dialog is displayed immediately.
        // Also display the dialog immediately when the delegate does not implement -updater:didFindValidUpdate:
        
        // Disable the default shortcut, because this was a background check.
        self.shouldDisableKeyboardShortcutForInstallButton = YES;
        [super didFindValidUpdate];
        return;
    }
}

@end
