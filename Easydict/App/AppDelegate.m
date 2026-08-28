//
//  AppDelegate.m
//  Easydict
//
//  Created by tisfeng on 2022/10/30.
//  Copyright © 2023 izual. All rights reserved.
//

#import "AppDelegate.h"
#import "AppDelegate+EZURLScheme.h"


@interface AppDelegate ()

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    MMLogInfo(@"程序启动");

    [ShortcutManager.shared setupShortcut];

    // Main window (input translate UI) removed from the product surface; the
    // app now lives in the menu bar and its four kept features.
    // [EZWindowManager.shared showMainWindowIfNeeded];

    [self registerRouters];

    [DarkModeManager.shared updateDarkMode:MyConfiguration.shared.appearance];
}

#pragma mark - NSApplicationDelegate

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    // Reopen used to bring back the main window; nothing to show anymore.
    return YES;
}

@end
