#import <Foundation/Foundation.h>
#import <DiskArbitration/DiskArbitration.h>
#import "KTYDaemon.h"
#import "KTYDaemonProtocol.h"
#import <assert.h>

static void test_mounted_volume_info(void) {
    printf("==> Running test_mounted_volume_info...\n");
    @autoreleasepool {
        KTYMountedVolumeInfo *info = [[KTYMountedVolumeInfo alloc] init];
        info.bsdName = @"disk5s2";
        info.devicePath = @"/dev/disk5s2";
        info.mountPoint = @"/Volumes/EVIDENCE_DATA";
        info.volumeName = @"EVIDENCE_DATA";
        info.volumeUUID = @"12345678-ABCD-EF01-2345-6789ABCDEF01";
        info.readOnly = NO;
        info.allowSystemMetadata = NO;
        info.mountTime = 1700000000;

        NSDictionary *d = [info toDictionary];
        assert([d[@"bsd_name"] isEqualToString:@"disk5s2"]);
        assert([d[@"device_node"] isEqualToString:@"/dev/disk5s2"]);
        assert([d[@"mount_point"] isEqualToString:@"/Volumes/EVIDENCE_DATA"]);
        assert([d[@"volume_name"] isEqualToString:@"EVIDENCE_DATA"]);
        assert([d[@"volume_uuid"] isEqualToString:@"12345678-ABCD-EF01-2345-6789ABCDEF01"]);
        assert([d[@"fs_type"] isEqualToString:@"NTFS"]);
        assert([d[@"read_only"] boolValue] == NO);
        assert([d[@"allow_system_metadata"] boolValue] == NO);
        assert([d[@"mount_time"] unsignedLongLongValue] == 1700000000);
    }
    printf("    PASSED: test_mounted_volume_info\n");
}

static void test_mount_approval_evaluation(void) {
    printf("==> Running test_mount_approval_evaluation...\n");
    @autoreleasepool {
        KTYDaemon *daemon = [[KTYDaemon alloc] initWithMachServiceName:nil];
        assert(daemon != nil);
        assert(daemon.autoMountEnabled == YES);

        /* 1. Test Windows_NTFS content string */
        NSDictionary *ntfsDesc1 = @{
            (NSString *)kDADiskDescriptionMediaContentKey: @"Windows_NTFS"
        };
        DADissenterRef d1 = [daemon evaluateMountApprovalForDiskDescription:ntfsDesc1];
        assert(d1 != NULL);
        assert(DADissenterGetStatus(d1) == kDAReturnBusy);
        CFStringRef msg1 = DADissenterGetStatusString(d1);
        assert(msg1 != NULL);
        assert(CFStringFind(msg1, CFSTR("knowthankyew"), 0).location != kCFNotFound);
        CFRelease(d1);

        /* 2. Test Microsoft Basic Data GUID string */
        NSDictionary *ntfsDesc2 = @{
            (NSString *)kDADiskDescriptionMediaContentKey: @"EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
        };
        DADissenterRef d2 = [daemon evaluateMountApprovalForDiskDescription:ntfsDesc2];
        assert(d2 != NULL);
        assert(DADissenterGetStatus(d2) == kDAReturnBusy);
        CFRelease(d2);

        /* 3. Test VolumeTypeKey == ntfs */
        NSDictionary *ntfsDesc3 = @{
            (NSString *)kDADiskDescriptionVolumeTypeKey: @"ntfs"
        };
        DADissenterRef d3 = [daemon evaluateMountApprovalForDiskDescription:ntfsDesc3];
        assert(d3 != NULL);
        assert(DADissenterGetStatus(d3) == kDAReturnBusy);
        CFRelease(d3);

        /* 4. Non-NTFS volume should return NULL (no dissent) */
        NSDictionary *apfsDesc = @{
            (NSString *)kDADiskDescriptionMediaContentKey: @"7C3457EF-0000-11AA-AA11-00306543ECAC",
            (NSString *)kDADiskDescriptionVolumeTypeKey: @"apfs"
        };
        DADissenterRef d4 = [daemon evaluateMountApprovalForDiskDescription:apfsDesc];
        assert(d4 == NULL);

        /* 5. With autoMountEnabled disabled, even NTFS returns NULL */
        daemon.autoMountEnabled = NO;
        DADissenterRef d5 = [daemon evaluateMountApprovalForDiskDescription:ntfsDesc1];
        assert(d5 == NULL);

        /* 6. Nil dictionary or nil disk returns NULL */
        assert([daemon evaluateMountApprovalForDiskDescription:nil] == NULL);

        /* 7. Specific target disabled via autoMountTargets */
        daemon.autoMountEnabled = YES;
        daemon.autoMountTargets[@"BOOTCAMP"] = @{
            @"target": @"BOOTCAMP",
            @"enabled": @NO,
            @"read_only": @NO
        };
        NSDictionary *bootcampDesc = @{
            (NSString *)kDADiskDescriptionMediaContentKey: @"Windows_NTFS",
            (NSString *)kDADiskDescriptionVolumeNameKey: @"BOOTCAMP"
        };
        DADissenterRef d6 = [daemon evaluateMountApprovalForDiskDescription:bootcampDesc];
        assert(d6 == NULL);
        assert([daemon evaluateMountApprovalForDisk:NULL] == NULL);

        [daemon stop];
    }
    printf("    PASSED: test_mount_approval_evaluation\n");
}

static void test_daemon_xpc_lifecycle_and_operations(void) {
    printf("==> Running test_daemon_xpc_lifecycle_and_operations...\n");
    @autoreleasepool {
        KTYDaemon *daemon = [[KTYDaemon alloc] initWithMachServiceName:nil];
        assert(daemon != nil);

        NSXPCListenerEndpoint *endpoint = nil;
        NSError *startErr = nil;
        BOOL started = [daemon startWithEndpoint:&endpoint error:&startErr];
        assert(started == YES);
        assert(startErr == nil);
        assert(endpoint != nil);

        NSXPCConnection *conn = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
        assert(conn != nil);
        conn.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(KTYDaemonProtocol)];
        [conn resume];

        id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
            fprintf(stderr, "XPC Proxy Error: %s\n", error.localizedDescription.UTF8String);
            assert(false);
        }];
        assert(proxy != nil);

        /* 1. Query status */
        {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSDictionary *resStatus = nil;
            __block NSError *resError = nil;
            [proxy getStatusWithReply:^(NSDictionary * _Nullable status, NSError * _Nullable error) {
                resStatus = status;
                resError = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(resError == nil);
            assert(resStatus != nil);
            assert([resStatus[@"daemon_version"] isEqualToString:@"0.1.0"]);
            assert([resStatus[@"pid"] intValue] == getpid());
            assert([resStatus[@"active_mounts_count"] unsignedLongLongValue] == 0);
            assert([resStatus[@"detected_disks_count"] unsignedLongLongValue] == 0);
            assert([resStatus[@"forensic_hygiene_mode"] containsString:@"STRICT"]);
            assert([resStatus[@"auto_mount_enabled"] boolValue] == YES);
        }

        /* 2. Simulate disk appearance (NTFS and APFS) */
        {
            NSDictionary *desc = @{
                (NSString *)kDADiskDescriptionVolumeNameKey: @"EVIDENCE_PARTITION",
                (NSString *)kDADiskDescriptionMediaSizeKey: @(10737418240ULL),
                (NSString *)kDADiskDescriptionVolumeKindKey: @"ntfs"
            };
            [daemon registerDiskAppeared:@"disk7s1" description:desc];

            NSDictionary *apfsDesc = @{
                (NSString *)kDADiskDescriptionVolumeNameKey: @"MAC_SYSTEM",
                (NSString *)kDADiskDescriptionMediaSizeKey: @(50000000000ULL),
                (NSString *)kDADiskDescriptionVolumeTypeKey: @"APFS"
            };
            [daemon registerDiskAppeared:@"disk8s1" description:apfsDesc];

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSArray<NSDictionary *> *resDisks = nil;
            __block NSError *resError = nil;
            [proxy listDisksWithReply:^(NSArray<NSDictionary *> * _Nullable disks, NSError * _Nullable error) {
                resDisks = disks;
                resError = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(resError == nil);
            assert(resDisks != nil);
            assert(resDisks.count == 2);
            NSDictionary *diskInfo = resDisks[0];
            assert([diskInfo[@"bsd_name"] isEqualToString:@"disk7s1"]);
            assert([diskInfo[@"volume_name"] isEqualToString:@"EVIDENCE_PARTITION"]);
            assert([diskInfo[@"fs_type"] isEqualToString:@"NTFS"]);
            assert([diskInfo[@"is_mounted"] boolValue] == NO);
            assert([diskInfo[@"media_size"] unsignedLongLongValue] == 10737418240ULL);

            NSDictionary *diskInfo2 = resDisks[1];
            assert([diskInfo2[@"bsd_name"] isEqualToString:@"disk8s1"]);
            assert([diskInfo2[@"volume_name"] isEqualToString:@"MAC_SYSTEM"]);
            assert([diskInfo2[@"fs_type"] isEqualToString:@"APFS"]);
            assert([diskInfo2[@"is_mounted"] boolValue] == NO);

            [daemon registerDiskDisappeared:@"disk8s1"];
        }

        /* 3. Mount device over XPC */
        {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSDictionary *mountRes = nil;
            __block NSError *mountErr = nil;
            [proxy mountDevice:@"/dev/disk7s1"
                    targetPath:@"/Volumes/EVIDENCE_MOUNT"
                      readOnly:NO
           allowSystemMetadata:NO
                     withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
                mountRes = result;
                mountErr = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(mountErr == nil);
            assert(mountRes != nil);
            assert([mountRes[@"bsd_name"] isEqualToString:@"disk7s1"]);
            assert([mountRes[@"mount_point"] isEqualToString:@"/Volumes/EVIDENCE_MOUNT"]);
            assert([mountRes[@"read_only"] boolValue] == NO);
            assert([mountRes[@"allow_system_metadata"] boolValue] == NO);
        }

        /* 4. Verify status and list reflect active mount */
        {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSDictionary *resStatus = nil;
            [proxy getStatusWithReply:^(NSDictionary * _Nullable status, NSError * _Nullable error) {
                (void)error;
                resStatus = status;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert([resStatus[@"active_mounts_count"] unsignedLongLongValue] == 1);
        }

        /* 5. Duplicate mount fails closed with EEXIST */
        {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSDictionary *mountRes = nil;
            __block NSError *mountErr = nil;
            [proxy mountDevice:@"disk7s1"
                    targetPath:@"/Volumes/OTHER"
                      readOnly:NO
           allowSystemMetadata:NO
                     withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
                mountRes = result;
                mountErr = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(mountRes == nil);
            assert(mountErr != nil);
            assert(mountErr.code == EEXIST);
        }

        /* 6. Invalid mount device fails with EINVAL */
        {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSDictionary *mountRes = nil;
            __block NSError *mountErr = nil;
            [proxy mountDevice:@""
                    targetPath:nil
                      readOnly:NO
           allowSystemMetadata:NO
                     withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
                mountRes = result;
                mountErr = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(mountRes == nil);
            assert(mountErr != nil);
            assert(mountErr.code == EINVAL);
        }

        /* 7. Unmount target via mount point */
        {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL unmountOk = NO;
            __block NSError *unmountErr = nil;
            [proxy unmountTarget:@"/Volumes/EVIDENCE_MOUNT" withReply:^(BOOL success, NSError * _Nullable error) {
                unmountOk = success;
                unmountErr = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(unmountErr == nil);
            assert(unmountOk == YES);
        }

        /* 8. Unmount non-existent target fails with ENOENT */
        {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL unmountOk = NO;
            __block NSError *unmountErr = nil;
            [proxy unmountTarget:@"disk_does_not_exist" withReply:^(BOOL success, NSError * _Nullable error) {
                unmountOk = success;
                unmountErr = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(unmountOk == NO);
            assert(unmountErr != nil);
            assert(unmountErr.code == ENOENT);
        }

        /* 9. Test Config API over XPC */
        {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSDictionary *cfg = nil;
            [proxy getConfigWithReply:^(NSDictionary * _Nullable config, NSError * _Nullable error) {
                (void)error;
                cfg = config;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(cfg != nil);
            assert(cfg[@"auto_mount_enabled"] != nil);

            /* Set target rule */
            sem = dispatch_semaphore_create(0);
            __block BOOL setOk = NO;
            [proxy setAutoMountTarget:@"BOOTCAMP" enabled:YES readOnly:NO withReply:^(BOOL success, NSError * _Nullable error) {
                (void)error;
                setOk = success;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(setOk == YES);

            /* Verify target in config */
            sem = dispatch_semaphore_create(0);
            [proxy getConfigWithReply:^(NSDictionary * _Nullable config, NSError * _Nullable error) {
                (void)error;
                cfg = config;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(cfg[@"auto_mount_targets"][@"BOOTCAMP"] != nil);
            assert([cfg[@"auto_mount_targets"][@"BOOTCAMP"][@"enabled"] boolValue] == YES);

            /* Toggle global auto-mount */
            sem = dispatch_semaphore_create(0);
            setOk = NO;
            [proxy setGlobalAutoMountEnabled:NO withReply:^(BOOL success, NSError * _Nullable error) {
                (void)error;
                setOk = success;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(setOk == YES);

            sem = dispatch_semaphore_create(0);
            [proxy getConfigWithReply:^(NSDictionary * _Nullable config, NSError * _Nullable error) {
                (void)error;
                cfg = config;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert([cfg[@"auto_mount_enabled"] boolValue] == NO);

            /* Re-enable global auto-mount */
            sem = dispatch_semaphore_create(0);
            [proxy setGlobalAutoMountEnabled:YES withReply:^(BOOL success, NSError * _Nullable error) {
                (void)success;
                (void)error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
        }

        /* 10. Test Safety check over XPC */
        {
            char tempVol[] = "/tmp/kty_xpc_test_XXXXXX";
            assert(mkdtemp(tempVol) != NULL);
            NSString *tempPath = [NSString stringWithUTF8String:tempVol];

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSDictionary *report = nil;
            [proxy checkSafetyForTarget:tempPath withReply:^(NSDictionary * _Nullable rep, NSError * _Nullable error) {
                (void)error;
                report = rep;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(report != nil);
            assert([report[@"safe_for_write"] boolValue] == YES);

            /* Add active hiberfil.sys */
            NSString *hPath = [tempPath stringByAppendingPathComponent:@"hiberfil.sys"];
            int fd = open(hPath.UTF8String, O_CREAT | O_WRONLY | O_TRUNC, 0644);
            assert(fd >= 0);
            uint8_t hibrData[4096] = {'H', 'I', 'B', 'R', 0};
            assert(write(fd, hibrData, sizeof(hibrData)) == sizeof(hibrData));
            close(fd);

            sem = dispatch_semaphore_create(0);
            report = nil;
            [proxy checkSafetyForTarget:tempPath withReply:^(NSDictionary * _Nullable rep, NSError * _Nullable error) {
                (void)error;
                report = rep;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(report != nil);
            assert([report[@"safe_for_write"] boolValue] == NO);
            assert([report[@"is_hibernated"] boolValue] == YES);
            assert(report[@"guidance"] != nil);
            assert([report[@"guidance"] containsString:@"Turn off Fastboot"] || [report[@"guidance"] containsString:@"disable fastboot"]);

            unlink(hPath.UTF8String);
            rmdir(tempVol);
        }

        /* 11. Direct Transfer XPC APIs */
        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
            /* 11a: listDirectoryOnDevice with nil arguments */
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSError *listErr = nil;
            [proxy listDirectoryOnDevice:nil path:nil withReply:^(NSArray<NSDictionary *> * _Nullable entries, NSError * _Nullable error) {
                (void)entries;
                listErr = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(listErr != nil);
            assert(listErr.code == EINVAL);

            /* 11b: copyFileToNTFS with nil arguments */
            sem = dispatch_semaphore_create(0);
            __block NSError *cpToErr = nil;
            [proxy copyFileToNTFS:nil sourcePath:nil destinationPath:nil allowSystemMetadata:NO withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
                (void)result;
                cpToErr = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(cpToErr != nil);
            assert(cpToErr.code == EINVAL);

            /* 11c: copyFileFromNTFS with nil arguments */
            sem = dispatch_semaphore_create(0);
            __block NSError *cpFromErr = nil;
            [proxy copyFileFromNTFS:nil sourcePath:nil destinationPath:nil withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
                (void)result;
                cpFromErr = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(cpFromErr != nil);
            assert(cpFromErr.code == EINVAL);
#pragma clang diagnostic pop

            /* 11d: copyFileToNTFS fails closed when Fast Startup / hibernation is active */
            char hibDir[] = "/tmp/kty_xpc_hib_test_XXXXXX";
            assert(mkdtemp(hibDir) != NULL);
            NSString *hibVolPath = [NSString stringWithUTF8String:hibDir];
            NSString *hibFilePath = [hibVolPath stringByAppendingPathComponent:@"hiberfil.sys"];
            int hfd2 = open(hibFilePath.UTF8String, O_CREAT | O_WRONLY | O_TRUNC, 0644);
            assert(hfd2 >= 0);
            uint8_t hibr_bytes[4096] = {'h', 'i', 'b', 'r', 0};
            assert(write(hfd2, hibr_bytes, sizeof(hibr_bytes)) == sizeof(hibr_bytes));
            close(hfd2);

            NSString *dummySrc = [hibVolPath stringByAppendingPathComponent:@"source.txt"];
            [@"Hello" writeToFile:dummySrc atomically:YES encoding:NSUTF8StringEncoding error:nil];

            sem = dispatch_semaphore_create(0);
            __block NSError *fastBootRejectErr = nil;
            [proxy copyFileToNTFS:hibVolPath sourcePath:dummySrc destinationPath:@"/destination.txt" allowSystemMetadata:NO withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
                (void)result;
                fastBootRejectErr = error;
                dispatch_semaphore_signal(sem);
            }];
            assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
            assert(fastBootRejectErr != nil);
            assert(fastBootRejectErr.code == EPERM);
            assert([fastBootRejectErr.userInfo[@"KTYFastStartupActive"] boolValue] == YES);
            assert([fastBootRejectErr.userInfo[@"KTYGuidance"] containsString:@"Turn off Fastboot"] || [fastBootRejectErr.userInfo[@"KTYGuidance"] containsString:@"disable fastboot"]);

            unlink(dummySrc.UTF8String);
            unlink(hibFilePath.UTF8String);
            rmdir(hibDir);
        }

        /* 12. Disk disappears */
        [daemon registerDiskDisappeared:@"disk7s1"];
        assert(daemon.detectedDisks[@"disk7s1"] == nil);

        [conn invalidate];
        [daemon stop];
    }
    printf("    PASSED: test_daemon_xpc_lifecycle_and_operations\n");
}

static void test_cli_subcommands(const char *cliPath) {
    printf("==> Running test_cli_subcommands using %s...\n", cliPath);
    @autoreleasepool {
        NSString *binary = [NSString stringWithUTF8String:cliPath];
        if (![[NSFileManager defaultManager] fileExistsAtPath:binary]) {
            printf("    CLI binary not yet built at %s (skipping execution test)\n", cliPath);
            return;
        }

        /* Helper to run CLI process and capture return code & output */
        int (^runCLI)(NSArray<NSString *> *args, NSString **outText) = ^int(NSArray<NSString *> *args, NSString **outText) {
            NSTask *task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:binary];
            task.arguments = args;
            NSPipe *pipe = [NSPipe pipe];
            task.standardOutput = pipe;
            task.standardError = pipe;

            NSError *err = nil;
            if (![task launchAndReturnError:&err]) {
                fprintf(stderr, "Failed to launch CLI: %s\n", err.localizedDescription.UTF8String);
                return -1;
            }
            [task waitUntilExit];
            NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
            if (outText) {
                *outText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            }
            return task.terminationStatus;
        };

        NSString *outStr = nil;

        /* Test help commands */
        assert(runCLI(@[@"help"], &outStr) == 0);
        assert([outStr containsString:@"kty-ntfs - Native NTFS Companion CLI"]);

        assert(runCLI(@[@"--help"], &outStr) == 0);
        assert([outStr containsString:@"Usage:"]);

        assert(runCLI(@[@"-h"], &outStr) == 0);
        assert([outStr containsString:@"Portfolio Invariants"]);

        /* Test no arguments (should exit 1 and show help) */
        assert(runCLI(@[], &outStr) == 1);
        assert([outStr containsString:@"Usage:"]);

        /* Test invalid argument */
        assert(runCLI(@[@"bogus_command"], &outStr) == 1);
        assert([outStr containsString:@"Unknown command"]);

        /* Test mount without device */
        assert(runCLI(@[@"mount"], &outStr) == 1);
        assert([outStr containsString:@"Usage: kty-ntfs mount"]);

        /* Test unmount without target */
        assert(runCLI(@[@"unmount"], &outStr) == 1);
        assert([outStr containsString:@"Usage: kty-ntfs unmount"]);

        /* Test daemon-backed commands (handles live daemon or offline fail-closed) */
        int statusRc = runCLI(@[@"status"], &outStr);
        if (statusRc == 0) {
            assert([outStr containsString:@"Daemon Status"] || [outStr containsString:@"PID"]);
        } else {
            assert(statusRc == 1);
            assert([outStr containsString:@"Error connecting to kty-ntfsd daemon"] || [outStr containsString:@"Error:"]);
        }

        int listRc = runCLI(@[@"list"], &outStr);
        if (listRc == 0) {
            assert([outStr containsString:@"IDENTIFIER"] && [outStr containsString:@"FS TYPE"]);
        } else {
            assert(listRc == 1);
            assert([outStr containsString:@"Notice: Daemon not reachable"] || [outStr containsString:@"No response from daemon"]);
        }

        /* Test check command on clean directory */
        char cliTempVol[] = "/tmp/kty_cli_test_XXXXXX";
        assert(mkdtemp(cliTempVol) != NULL);
        NSString *cliTempPath = [NSString stringWithUTF8String:cliTempVol];

        int checkCleanRc = runCLI(@[@"check", cliTempPath], &outStr);
        assert(checkCleanRc == 0);
        assert([outStr containsString:@"SAFE FOR READ/WRITE"]);

        /* Test check with active hibernation */
        NSString *cliHiber = [cliTempPath stringByAppendingPathComponent:@"hiberfil.sys"];
        int cfd = open(cliHiber.UTF8String, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        assert(cfd >= 0);
        uint8_t cHibr[4096] = {'h', 'i', 'b', 'r', 0};
        assert(write(cfd, cHibr, sizeof(cHibr)) == sizeof(cHibr));
        close(cfd);

        int checkHibRc = runCLI(@[@"check", cliTempPath], &outStr);
        assert(checkHibRc == 2);
        assert([outStr containsString:@"UNSAFE"]);
        assert([outStr containsString:@"Control Panel"] && [outStr containsString:@"powercfg /h off"]);

        /* Test check --json */
        int checkJsonRc = runCLI(@[@"check", cliTempPath, @"--json"], &outStr);
        assert(checkJsonRc == 2);
        assert([outStr containsString:@"\"safe_for_write\" : false"]);

        unlink(cliHiber.UTF8String);
        rmdir(cliTempVol);

        /* Test config command */
        int configRc = runCLI(@[@"config"], &outStr);
        if (configRc == 0) {
            assert([outStr containsString:@"Configuration"] || [outStr containsString:@"Auto-Mount"]);
        } else {
            assert(configRc == 1);
            assert([outStr containsString:@"Error connecting to daemon"] || [outStr containsString:@"Error:"]);
        }

        /* Test ls command validation */
        assert(runCLI(@[@"ls"], &outStr) == 1);
        assert([outStr containsString:@"Usage:"] || [outStr containsString:@"Target required"]);

        /* Test cp command validation */
        assert(runCLI(@[@"cp"], &outStr) == 1);
        assert([outStr containsString:@"Usage: kty-ntfs cp"]);

        assert(runCLI(@[@"cp", @"only_one_arg"], &outStr) == 1);
        assert([outStr containsString:@"Usage: kty-ntfs cp"]);

        /* Test cp with invalid arguments (missing colon or target syntax) */
        int cpInvalidRc = runCLI(@[@"cp", @"fileA.txt", @"fileB.txt"], &outStr);
        assert(cpInvalidRc == 1);
        assert([outStr containsString:@"must specify an NTFS device"]);

        /* Non-existent unmount target must always fail closed */
        int unmountRc = runCLI(@[@"unmount", @"non_existent_target_12345"], &outStr);
        assert(unmountRc == 1);
        assert([outStr containsString:@"Mount target not found"] || [outStr containsString:@"Error connecting to kty-ntfsd daemon"] || [outStr containsString:@"Error:"]);
    }
    printf("    PASSED: test_cli_subcommands\n");
}

int main(int argc, const char *argv[]) {
    printf("====================================================\n");
    printf(" KTY-NTFS Daemon & CLI Integration Test Suite\n");
    printf("====================================================\n");

    const char *cliPath = "build/bin/kty-ntfs";
    if (argc > 1) {
        cliPath = argv[1];
    }

    test_mounted_volume_info();
    test_mount_approval_evaluation();
    test_daemon_xpc_lifecycle_and_operations();
    test_cli_subcommands(cliPath);

    printf("====================================================\n");
    printf(" All Daemon & CLI Tests PASSED (0 failures)\n");
    printf("====================================================\n");
    return 0;
}
