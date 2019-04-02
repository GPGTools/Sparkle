//
//  GPGScheduledUpdateDriver.m
//  GPGTools Sparkle extension
//
//  Created by Mento on 09.02.18.
//

#import "GPGScheduledUpdateDriver.h"

#import "SUAppcastItem.h"
#import "SUHost.h"
#import "SUUIBasedUpdateDriver.h"
#import "SUUpdateAlert.h"
#import "SUConstants.h"


static NSString *const GPGAppcastElementDisableNotification = @"sparkle:gpgtoolsDisableNotification";
static NSString *const GPGAppcastElementInfoOnlyNotification = @"sparkle:gpgtoolsInfoOnlyNotification";



@interface GPGScheduledUpdateDriver () <NSUserNotificationCenterDelegate>
@property (nonatomic) BOOL notificationDismissed;
@property (nonatomic) BOOL shouldDisableKeyboardShortcutForInstallButton;
@end

@interface SUUIBasedUpdateDriver (MakeVisiable)
@property (strong) SUUpdateAlert *updateAlert;
@end
@implementation SUUIBasedUpdateDriver (MakeVisiable)
@dynamic updateAlert;
@end



static NSString *localized(NSString *key) {
    if (!key) {
        return nil;
    }
    static NSBundle *bundle = nil, *englishBundle = nil;
    if (!bundle) {
        bundle = [NSBundle bundleWithIdentifier:SUBundleIdentifier];
        englishBundle = [NSBundle bundleWithPath:(NSString * _Nonnull)[bundle pathForResource:@"en" ofType:@"lproj"]];
    }
    
    NSString *notFoundValue = @"~#*?*#~";
    NSString *localized = [bundle localizedStringForKey:key value:notFoundValue table:@"GPGSparkle"];
    if (localized == notFoundValue) {
        localized = [englishBundle localizedStringForKey:key value:nil table:@"GPGSparkle"];
    }
    
    return localized;
}




@implementation GPGScheduledUpdateDriver
@synthesize notificationDismissed, shouldDisableKeyboardShortcutForInstallButton;

- (void)didFindValidUpdate {
    if (@available(macos 10.10, *)) {
        
        if (self.updateItem.isCriticalUpdate || [self.updateItem.propertiesDictionary[SUAppcastElementTags] containsObject:GPGAppcastElementDisableNotification]) {
            // For critical updates, the update dialog is displayed immediately.
            // Also show the update dialog, if the notification is disabled.
            self.shouldDisableKeyboardShortcutForInstallButton = YES;
            [super didFindValidUpdate];
            return;
        }
        
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.identifier = [NSUUID UUID].UUIDString;
        notification.title = self.host.name;
        notification.subtitle = [NSString stringWithFormat:localized(@"NotificationSubtitle"), self.host.name, self.updateItem.displayVersionString];
        notification.informativeText = localized(@"NotificationMsg");
        notification.hasActionButton = YES;
        
        if (self.updateItem.isInformationOnlyUpdate || [self.updateItem.propertiesDictionary[SUAppcastElementTags] containsObject:GPGAppcastElementInfoOnlyNotification]) {
            notification.actionButtonTitle = localized(@"NotificationDetails");
        } else {
            notification.actionButtonTitle = localized(@"NotificationInstall");
        }
        
        notification.otherButtonTitle = localized(@"NotificationHide");
        
//      NSUserNotificationAction *installAction = [NSUserNotificationAction actionWithIdentifier:@"install" title:localized(@"NotificationInstall")];
//      notification.additionalActions = @[installAction];
        
        NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];
        center.delegate = self;
        [center deliverNotification:notification];
        
    } else {
        // Do not use notifications on macOS < 10.10
        self.shouldDisableKeyboardShortcutForInstallButton = YES;
        [super didFindValidUpdate];
        return;
    }
}

- (void)dismissNotification:(NSUserNotification *)notification {
    [[NSUserNotificationCenter defaultUserNotificationCenter] removeDeliveredNotification:notification];
    self.notificationDismissed = YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didDeliverNotification:(NSUserNotification *)notification {
    NSString *identifier = notification.identifier;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL notificationBlocked = YES;
        BOOL notificationStillPresent;
        NSInteger isBlockedCounter = 10;
        
        // This loop waits, until the notificaion is dismissed.
        do {
            [NSThread sleepForTimeInterval:1];
            
            // Check if the notification is still on screen.
            notificationStillPresent = NO;
            for (NSUserNotification *aNotification in center.deliveredNotifications) {
                if ([aNotification.identifier isEqualToString:identifier]) {
                    notificationStillPresent = YES;
                    break;
                }
            }
            
            
            // This code checks if the user blocked notifications. In that case the normal update dialog is shown.
            if (isBlockedCounter >= 0 && !self.notificationDismissed && notificationStillPresent) {
                isBlockedCounter--;
                if (isBlockedCounter == 0) {
                    @try {
                        NSArray *presentedAlerts = [center valueForKey:@"_presentedAlerts"];
                        for (NSUserNotification *aNotification in presentedAlerts) {
                            if ([aNotification.identifier isEqualToString:identifier]) {
                                notificationBlocked = NO;
                                break;
                            }
                        }
                    } @catch (__unused NSException *exception) {
                    }
                }
                if (isBlockedCounter == -1 && notificationBlocked) {
                    // The user has blocked notifications from GPGSuite.
                    // Show the standard update dialog.
                    [self dismissNotification:notification];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [super didFindValidUpdate];
                    });
                }
            }
            
        } while (!self.notificationDismissed && notificationStillPresent);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.notificationDismissed) {
                [self abortUpdate];
            }
        });
    });
    
}

- (void)userNotificationCenter:(__unused NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification NS_AVAILABLE_MAC(10.10) {
    
    switch (notification.activationType) {
        case NSUserNotificationActivationTypeContentsClicked:
            // The user clicked on the notification.
            [self dismissNotification:notification];
            [super didFindValidUpdate];
            break;
        case NSUserNotificationActivationTypeActionButtonClicked:
            // The user clicked on the bottom button.
            [self dismissNotification:notification];
            if (!self.updateItem.isInformationOnlyUpdate && ![self.updateItem.propertiesDictionary[SUAppcastElementTags] containsObject:GPGAppcastElementInfoOnlyNotification]) {
                self.automaticallyInstallUpdates = YES;
            }
            [super didFindValidUpdate];
            break;
//      case NSUserNotificationActivationTypeAdditionalActionClicked: {
//          // The user clicked on one of the additional buttons.
//          [self dismissNotification:notification];
//
//          NSString *actionIdentifier = notification.additionalActivationAction.identifier;
//          if ([actionIdentifier isEqualToString:@"install"]) {
//              self.automaticallyInstallUpdates = YES;
//          }
//          [super didFindValidUpdate];
//          break;
//      }
        case NSUserNotificationActivationTypeNone:
            // Nothing happend. Is that even possible?
            break;
        default:
            // Something else happend.
            [self dismissNotification:notification];
            [self abortUpdate];
            break;
    }
}

- (BOOL)userNotificationCenter:(__unused NSUserNotificationCenter *)center shouldPresentNotification:(__unused NSUserNotification *)notification {
    return YES;
}


@end
