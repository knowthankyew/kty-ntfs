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

        /* 2. Simulate disk appearance */
        {
            NSDictionary *desc = @{
                (NSString *)kDADiskDescriptionVolumeNameKey: @"EVIDENCE_PARTITION",
                (NSString *)kDADiskDescriptionMediaSizeKey: @(10737418240ULL)
            };
            [daemon registerDiskAppeared:@"disk7s1" description:desc];

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
            assert(resDisks.count == 1);
            NSDictionary *diskInfo = resDisks[0];
            assert([diskInfo[@"bsd_name"] isEqualToString:@"disk7s1"]);
            assert([diskInfo[@"volume_name"] isEqualToString:@"EVIDENCE_PARTITION"]);
            assert([diskInfo[@"is_mounted"] boolValue] == NO);
            assert([diskInfo[@"media_size"] unsignedLongLongValue] == 10737418240ULL);
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

        /* 9. Disk disappears */
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
