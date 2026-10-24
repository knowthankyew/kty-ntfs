#import <Cocoa/Cocoa.h>
#import "KTYDaemonProtocol.h"

@interface KTYMenuAppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSArray<NSDictionary *> *disks;
@property (nonatomic, strong) NSDictionary *daemonStatus;
@property (nonatomic, strong) NSDictionary *daemonConfig;
@property (nonatomic, assign) BOOL isDaemonReachable;

@end

@implementation KTYMenuAppDelegate

- (NSXPCConnection *)getDaemonConnection {
    NSXPCConnection *conn = [[NSXPCConnection alloc] initWithMachServiceName:KTY_NTFSD_MACH_SERVICE options:0];
    conn.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(KTYDaemonProtocol)];
    [conn resume];
    return conn;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    if (self.statusItem.button) {
        self.statusItem.button.title = @"⏏ KTY NTFS";
        self.statusItem.button.toolTip = @"kty-ntfs Companion (knowthankyew)";
    }

    self.menu = [[NSMenu alloc] initWithTitle:@"kty-ntfs"];
    self.statusItem.menu = self.menu;

    [self refreshState];

    /* Poll every 3 seconds for disk and mount updates */
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                         target:self
                                                       selector:@selector(refreshState)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)refreshState {
    NSXPCConnection *conn = [self getDaemonConnection];
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        (void)error;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isDaemonReachable = NO;
            [self rebuildMenu];
            [conn invalidate];
        });
    }];

    [proxy getStatusWithReply:^(NSDictionary * _Nullable status, NSError * _Nullable error) {
        if (!error && status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.daemonStatus = status;
                self.isDaemonReachable = YES;
            });
        }
    }];

    [proxy getConfigWithReply:^(NSDictionary * _Nullable config, NSError * _Nullable error) {
        if (!error && config) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.daemonConfig = config;
            });
        }
    }];

    [proxy listDisksWithReply:^(NSArray<NSDictionary *> * _Nullable disks, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && disks) {
                self.disks = disks;
                self.isDaemonReachable = YES;
            }
            [self rebuildMenu];
            [conn invalidate];
        });
    }];
}

- (void)rebuildMenu {
    [self.menu removeAllItems];

    /* Header */
    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"kty-ntfs Volume Manager" action:nil keyEquivalent:@""];
    header.enabled = NO;
    [self.menu addItem:header];

    /* Daemon status badge */
    NSString *statusStr = self.isDaemonReachable ?
        [NSString stringWithFormat:@"🟢 Daemon Active (PID: %d)", [self.daemonStatus[@"pid"] intValue]] :
        @"🔴 Daemon Offline (Start with sudo launchctl)";
    NSMenuItem *statusItem = [[NSMenuItem alloc] initWithTitle:statusStr action:nil keyEquivalent:@""];
    statusItem.enabled = NO;
    [self.menu addItem:statusItem];

    [self.menu addItem:[NSMenuItem separatorItem]];

    /* Volume list section */
    NSMenuItem *volHeader = [[NSMenuItem alloc] initWithTitle:@"Detected Partitions:" action:nil keyEquivalent:@""];
    volHeader.enabled = NO;
    [self.menu addItem:volHeader];

    NSArray<NSDictionary *> *currentDisks = self.disks;
    if (!currentDisks || currentDisks.count == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"  No Storage Devices Detected" action:nil keyEquivalent:@""];
        none.enabled = NO;
        [self.menu addItem:none];
    } else {
        for (NSDictionary *disk in currentDisks) {
            NSString *bsd = disk[@"bsd_name"] ?: @"-";
            NSString *name = disk[@"volume_name"];
            if (!name || name.length == 0) name = bsd;
            NSString *fsType = disk[@"fs_type"] ?: @"";
            uint64_t size = [disk[@"media_size"] unsignedLongLongValue];
            NSString *sizeStr = (size > 0) ? [NSString stringWithFormat:@"%.1f GB", (double)size / (1024.0 * 1024.0 * 1024.0)] : @"";
            BOOL isMounted = [disk[@"is_mounted"] boolValue];
            BOOL isKtyManaged = [disk[@"kty_managed"] boolValue];

            NSString *displayTitle = [NSString stringWithFormat:@"%@ (%@, %@%@)",
                                      name, bsd, fsType, (sizeStr.length > 0 ? [@", " stringByAppendingString:sizeStr] : @"")];

            NSMenuItem *diskItem = [[NSMenuItem alloc] initWithTitle:displayTitle action:nil keyEquivalent:@""];
            NSMenu *diskSubmenu = [[NSMenu alloc] initWithTitle:name];

            /* Volume details */
            NSString *mountStatus = isMounted ? (isKtyManaged ? @"Status: Mounted (kty-ntfs Read/Write)" : @"Status: Mounted (Apple Read-Only)") : @"Status: Unmounted";
            NSMenuItem *subStatus = [[NSMenuItem alloc] initWithTitle:mountStatus action:nil keyEquivalent:@""];
            subStatus.enabled = NO;
            [diskSubmenu addItem:subStatus];

            [diskSubmenu addItem:[NSMenuItem separatorItem]];

            /* Auto-mount toggle */
            BOOL autoMountOn = NO;
            NSDictionary *rules = self.daemonConfig[@"auto_mount_targets"];
            if (rules && (rules[name] || rules[bsd])) {
                NSDictionary *r = rules[name] ?: rules[bsd];
                autoMountOn = [r[@"enabled"] boolValue];
            }
            NSMenuItem *autoMountItem = [[NSMenuItem alloc] initWithTitle:@"Auto-Mount on Connect"
                                                                   action:@selector(toggleAutoMountForDisk:)
                                                            keyEquivalent:@""];
            autoMountItem.state = autoMountOn ? NSControlStateValueOn : NSControlStateValueOff;
            autoMountItem.representedObject = disk;
            autoMountItem.target = self;
            [diskSubmenu addItem:autoMountItem];

            [diskSubmenu addItem:[NSMenuItem separatorItem]];

            /* Action: Mount Read/Write */
            NSMenuItem *mountRW = [[NSMenuItem alloc] initWithTitle:@"Mount with Write Support (kty-ntfs)"
                                                             action:@selector(mountDiskRW:)
                                                      keyEquivalent:@""];
            mountRW.representedObject = disk;
            mountRW.target = self;
            [diskSubmenu addItem:mountRW];

            /* Action: Mount Read-Only */
            NSMenuItem *mountRO = [[NSMenuItem alloc] initWithTitle:@"Mount Read-Only (Safe Mode)"
                                                             action:@selector(mountDiskRO:)
                                                      keyEquivalent:@""];
            mountRO.representedObject = disk;
            mountRO.target = self;
            [diskSubmenu addItem:mountRO];

            /* Action: Unmount */
            if (isMounted) {
                NSMenuItem *unmount = [[NSMenuItem alloc] initWithTitle:@"Unmount Volume"
                                                                 action:@selector(unmountDisk:)
                                                          keyEquivalent:@""];
                unmount.representedObject = disk;
                unmount.target = self;
                [diskSubmenu addItem:unmount];
            }

            [diskSubmenu addItem:[NSMenuItem separatorItem]];

            /* Action: Direct File Transfer */
            NSMenuItem *transfer = [[NSMenuItem alloc] initWithTitle:@"Transfer File to this Volume..."
                                                              action:@selector(transferFileToDisk:)
                                                       keyEquivalent:@""];
            transfer.representedObject = disk;
            transfer.target = self;
            [diskSubmenu addItem:transfer];

            /* Safety Preflight Check */
            NSMenuItem *safety = [[NSMenuItem alloc] initWithTitle:@"Check Windows Fast Startup Safety..."
                                                            action:@selector(checkSafetyForDisk:)
                                                     keyEquivalent:@""];
            safety.representedObject = disk;
            safety.target = self;
            [diskSubmenu addItem:safety];

            diskItem.submenu = diskSubmenu;
            [self.menu addItem:diskItem];
        }
    }

    [self.menu addItem:[NSMenuItem separatorItem]];

    /* Global Preferences & Actions */
    BOOL globalAutoMount = [self.daemonConfig[@"auto_mount_enabled"] boolValue];
    NSMenuItem *globalAuto = [[NSMenuItem alloc] initWithTitle:@"Global Auto-Mount Arbitration"
                                                        action:@selector(toggleGlobalAutoMount:)
                                                 keyEquivalent:@""];
    globalAuto.state = globalAutoMount ? NSControlStateValueOn : NSControlStateValueOff;
    globalAuto.target = self;
    [self.menu addItem:globalAuto];

    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"Refresh Storage Devices"
                                                     action:@selector(refreshState)
                                              keyEquivalent:@"r"];
    refresh.target = self;
    [self.menu addItem:refresh];

    [self.menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit kty-ntfs Manager"
                                                  action:@selector(quitApp)
                                           keyEquivalent:@"q"];
    quit.target = self;
    [self.menu addItem:quit];
}

#pragma mark - Actions

- (void)mountDiskRW:(NSMenuItem *)sender {
    NSDictionary *disk = sender.representedObject;
    NSString *bsd = disk[@"bsd_name"];
    if (!bsd) return;

    NSXPCConnection *conn = [self getDaemonConnection];
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        [self showAlertWithTitle:@"Connection Error" message:error.localizedDescription];
        [conn invalidate];
    }];

    [proxy mountDevice:bsd targetPath:nil readOnly:NO allowSystemMetadata:NO withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
        (void)result;
        dispatch_async(dispatch_get_main_queue(), ^{
            [conn invalidate];
            if (error) {
                if (error.userInfo[@"KTYGuidance"]) {
                    [self showFastStartupAlertForVolume:disk[@"volume_name"] ?: bsd guidance:error.userInfo[@"KTYGuidance"]];
                } else {
                    [self showAlertWithTitle:@"Mount Failed" message:error.localizedDescription];
                }
            } else {
                [self refreshState];
            }
        });
    }];
}

- (void)mountDiskRO:(NSMenuItem *)sender {
    NSDictionary *disk = sender.representedObject;
    NSString *bsd = disk[@"bsd_name"];
    if (!bsd) return;

    NSXPCConnection *conn = [self getDaemonConnection];
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        [self showAlertWithTitle:@"Connection Error" message:error.localizedDescription];
        [conn invalidate];
    }];

    [proxy mountDevice:bsd targetPath:nil readOnly:YES allowSystemMetadata:NO withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
        (void)result;
        dispatch_async(dispatch_get_main_queue(), ^{
            [conn invalidate];
            if (error) {
                [self showAlertWithTitle:@"Read-Only Mount Failed" message:error.localizedDescription];
            } else {
                [self refreshState];
            }
        });
    }];
}

- (void)unmountDisk:(NSMenuItem *)sender {
    NSDictionary *disk = sender.representedObject;
    NSString *target = disk[@"mount_point"];
    if (!target || target.length == 0) target = disk[@"bsd_name"];
    if (!target) return;

    NSXPCConnection *conn = [self getDaemonConnection];
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        [self showAlertWithTitle:@"Connection Error" message:error.localizedDescription];
        [conn invalidate];
    }];

    [proxy unmountTarget:target withReply:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [conn invalidate];
            if (!success || error) {
                [self showAlertWithTitle:@"Unmount Failed" message:error ? error.localizedDescription : @"Unknown error"];
            } else {
                [self refreshState];
            }
        });
    }];
}

- (void)toggleAutoMountForDisk:(NSMenuItem *)sender {
    NSDictionary *disk = sender.representedObject;
    NSString *target = disk[@"volume_name"];
    if (!target || target.length == 0) target = disk[@"bsd_name"];
    if (!target) return;

    BOOL newState = (sender.state == NSControlStateValueOff);

    NSXPCConnection *conn = [self getDaemonConnection];
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        [self showAlertWithTitle:@"Connection Error" message:error.localizedDescription];
        [conn invalidate];
    }];

    [proxy setAutoMountTarget:target enabled:newState readOnly:NO withReply:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [conn invalidate];
            if (!success || error) {
                [self showAlertWithTitle:@"Configuration Error" message:error ? error.localizedDescription : @"Failed to update rule"];
            } else {
                [self refreshState];
            }
        });
    }];
}

- (void)toggleGlobalAutoMount:(NSMenuItem *)sender {
    BOOL newState = (sender.state == NSControlStateValueOff);

    NSXPCConnection *conn = [self getDaemonConnection];
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        [self showAlertWithTitle:@"Connection Error" message:error.localizedDescription];
        [conn invalidate];
    }];

    [proxy setGlobalAutoMountEnabled:newState withReply:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [conn invalidate];
            if (!success || error) {
                [self showAlertWithTitle:@"Configuration Error" message:error ? error.localizedDescription : @"Failed to update global auto-mount"];
            } else {
                [self refreshState];
            }
        });
    }];
}

- (void)checkSafetyForDisk:(NSMenuItem *)sender {
    NSDictionary *disk = sender.representedObject;
    NSString *bsd = disk[@"bsd_name"];
    if (!bsd) return;

    NSXPCConnection *conn = [self getDaemonConnection];
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        [self showAlertWithTitle:@"Connection Error" message:error.localizedDescription];
        [conn invalidate];
    }];

    [proxy checkSafetyForTarget:bsd withReply:^(NSDictionary * _Nullable report, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [conn invalidate];
            if (error || !report) {
                [self showAlertWithTitle:@"Safety Check Failed" message:error ? error.localizedDescription : @"No response from daemon"];
            } else {
                BOOL isSafe = [report[@"safe_for_write"] boolValue];
                NSString *summary = report[@"status_summary"] ?: @"";
                if (isSafe) {
                    [self showAlertWithTitle:@"🟢 Partition is Safe for Read/Write"
                                     message:[NSString stringWithFormat:@"Target: %@\nStatus: %@\n\nWindows Fast Startup is inactive and filesystem transactions are clean. You can safely mount this partition with write support.", bsd, summary]];
                } else {
                    [self showFastStartupAlertForVolume:report[@"volume_name"] ?: bsd guidance:report[@"guidance"] ?: summary];
                }
            }
        });
    }];
}

- (void)transferFileToDisk:(NSMenuItem *)sender {
    NSDictionary *disk = sender.representedObject;
    NSString *bsd = disk[@"bsd_name"];
    if (!bsd) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Transfer to NTFS";
    panel.message = [NSString stringWithFormat:@"Select a file to transfer directly to %@", disk[@"volume_name"] ?: bsd];

    [NSApp activateIgnoringOtherApps:YES];
    if ([panel runModal] == NSModalResponseOK) {
        NSURL *selectedURL = panel.URL;
        if (!selectedURL) return;

        NSString *hostPath = selectedURL.path;
        NSString *destPath = [NSString stringWithFormat:@"/%@", selectedURL.lastPathComponent];

        NSXPCConnection *conn = [self getDaemonConnection];
        id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
            [self showAlertWithTitle:@"Connection Error" message:error.localizedDescription];
            [conn invalidate];
        }];

        [proxy copyFileToNTFS:bsd
                   sourcePath:hostPath
              destinationPath:destPath
          allowSystemMetadata:NO
                    withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [conn invalidate];
                if (error || !result) {
                    if (error.userInfo[@"KTYGuidance"]) {
                        [self showFastStartupAlertForVolume:disk[@"volume_name"] ?: bsd guidance:error.userInfo[@"KTYGuidance"]];
                    } else {
                        [self showAlertWithTitle:@"Transfer Failed" message:error ? error.localizedDescription : @"Unknown error"];
                    }
                } else {
                    NSString *msg = [NSString stringWithFormat:@"Transferred '%@' to %@:%@\n\nSHA-256: %@\nBLAKE3:  %@\n\nAlternate Data Streams verified and written cleanly.",
                                     selectedURL.lastPathComponent, bsd, result[@"destination"], result[@"sha256"], result[@"blake3"]];
                    [self showAlertWithTitle:@"Transfer Complete" message:msg];
                }
            });
        }];
    }
}

#pragma mark - Alert Helpers

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlertWithTitle:title message:message];
        });
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)showFastStartupAlertForVolume:(NSString *)volume guidance:(NSString *)guidance {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showFastStartupAlertForVolume:volume guidance:guidance];
        });
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"⚠️ Windows Fast Startup Active on '%@'", volume];
    alert.informativeText = guidance;
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Copy 'powercfg /h off' to Clipboard"];

    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertSecondButtonReturn) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:@"powercfg /h off" forType:NSPasteboardTypeString];
    }
}

- (void)quitApp {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char * argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        KTYMenuAppDelegate *delegate = [[KTYMenuAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
