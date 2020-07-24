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

typedef NS_ENUM(NSInteger, GPGUserNotificationStyle) {
    GPGUserNotificationStyleNone = 0,
    GPGUserNotificationStyleBanner,
    GPGUserNotificationStyleAlert,
};



@interface GPGScheduledUpdateDriver () <NSUserNotificationCenterDelegate>
@property (nonatomic) BOOL notificationDismissed;
@property (nonatomic) BOOL shouldDisableKeyboardShortcutForInstallButton;
@property (nonatomic, strong) NSUserNotification *updateNotification;
@property (getter=isInterruptible) BOOL interruptible;
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
@synthesize updateNotification;
@synthesize interruptible;

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
        
        self.updateNotification = notification;
        
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

- (void)abortUpdate {
    [self dismissNotification:self.updateNotification];
    [super abortUpdate];
}

- (void)dismissNotification:(NSUserNotification *)notification {
    [[NSUserNotificationCenter defaultUserNotificationCenter] removeDeliveredNotification:notification];
    self.notificationDismissed = YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didDeliverNotification:(NSUserNotification *)notification {

    // In case the user has disabled notifications for GPGSuite_Updater,
    // show the traditional dialog.
    GPGUserNotificationStyle displayStyle;
    @try {
        NSNumber *displayStyleValue = [notification valueForKey:@"_displayStyle"]; // Private API. Better do this in @try @catch.
        displayStyle = displayStyleValue.integerValue;
    } @catch (__unused NSException *exception) {
        displayStyle = GPGUserNotificationStyleNone;
    }

    if (displayStyle == GPGUserNotificationStyleNone) {
        [self dismissNotification:notification];
        dispatch_async(dispatch_get_main_queue(), ^{
            [super didFindValidUpdate];
        });
    } else {
        // Set interruptible to YES, so a manual updated check if possible, even if a update notification is on screen.
        self.interruptible = YES;

        
        // TODO: Instead of waiting in a loop, close the updater and re-open it, when the user clicks on a notification.
        
        // Wait until the notification is gone, so the user has a chance to click on it, to trigger the update.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            NSString *identifier = notification.identifier;

            BOOL notificationStillPresent;
            do {
                // Check from time to time, if the notification is gone.
                [NSThread sleepForTimeInterval: 10];
                
                notificationStillPresent = NO;
                for (NSUserNotification *aNotification in center.deliveredNotifications) {
                    if ([aNotification.identifier isEqualToString:identifier]) {
                        // The notification is still there, so an user could click on it to trigger the update process.
                        notificationStillPresent = YES;
                        break;
                    }
                }
            } while (notificationStillPresent);
            
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.notificationDismissed) {
                    // The user did not click on the notificaiton.
                    // Cancel the update, because it can not be triggered anymore.
                    [self abortUpdate];
                }
            });
        });
    }
    
}

- (void)userNotificationCenter:(__unused NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification NS_AVAILABLE_MAC(10.10) {
    
    switch (notification.activationType) {
        case NSUserNotificationActivationTypeContentsClicked:
            // The user clicked on the notification.
            [self dismissNotification:notification];
            self.interruptible = NO;
            [super didFindValidUpdate];
            break;
        case NSUserNotificationActivationTypeActionButtonClicked:
            // The user clicked on the bottom button.
            [self dismissNotification:notification];
            if (!self.updateItem.isInformationOnlyUpdate && ![self.updateItem.propertiesDictionary[SUAppcastElementTags] containsObject:GPGAppcastElementInfoOnlyNotification]) {
                self.automaticallyInstallUpdates = YES;
            }
            self.interruptible = NO;
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
