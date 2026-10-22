#import <Foundation/Foundation.h>
#import <DiskArbitration/DiskArbitration.h>
#import "KTYDaemonProtocol.h"

static void PrintHelp(void) {
    printf("kty-ntfs - Native NTFS Companion CLI (knowthankyew)\n\n");
    printf("Usage:\n");
    printf("  kty-ntfs list [--json]                     List detected and mounted NTFS partitions\n");
    printf("  kty-ntfs mount <device> [options]          Mount an NTFS partition\n");
    printf("  kty-ntfs unmount <target>                  Gracefully unmount a volume or device\n");
    printf("  kty-ntfs status [--json]                   Query kty-ntfsd daemon status & metrics\n");
    printf("  kty-ntfs help, --help, -h                  Show this help reference\n\n");
    printf("Mount Options:\n");
    printf("  -t, --target <path>          Custom mount directory (default: /Volumes/<VolumeName>)\n");
    printf("  -r, --readonly               Mount volume in read-only mode\n");
    printf("      --allow-system-metadata  WARNING: Allow Finder/Spotlight host metadata (.DS_Store,\n");
    printf("                               Spotlight-V100, Trashes) on the destination media.\n");
    printf("                               Default is STRICT HYGIENE (metadata suppressed in RAM).\n\n");
    printf("Portfolio Invariants:\n");
    printf("  Zero Network Egress | Zero Kernel Extensions | Bit-for-Bit Hash Integrity\n");
}

static NSXPCConnection *GetDaemonConnection(void) {
    NSXPCConnection *conn = [[NSXPCConnection alloc] initWithMachServiceName:KTY_NTFSD_MACH_SERVICE options:0];
    conn.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(KTYDaemonProtocol)];
    [conn resume];
    return conn;
}

static int CommandStatus(BOOL jsonOutput) {
    NSXPCConnection *conn = GetDaemonConnection();
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        if (jsonOutput) {
            printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error.localizedDescription.UTF8String);
        } else {
            fprintf(stderr, "Error connecting to kty-ntfsd daemon: %s\n", error.localizedDescription.UTF8String);
            fprintf(stderr, "Ensure kty-ntfsd is running (launchctl load /Library/LaunchDaemons/com.knowthankyew.ntfsd.plist).\n");
        }
    }];

    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [proxy getStatusWithReply:^(NSDictionary * _Nullable status, NSError * _Nullable error) {
        if (error || !status) {
            if (jsonOutput) {
                printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error ? error.localizedDescription.UTF8String : "unknown error");
            } else {
                fprintf(stderr, "Error querying status: %s\n", error ? error.localizedDescription.UTF8String : "No response");
            }
            exitCode = 1;
        } else {
            if (jsonOutput) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil];
                printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            } else {
                printf("kty-ntfsd Daemon Status:\n");
                printf("  Daemon Version:             %s\n", [status[@"daemon_version"] UTF8String]);
                printf("  PID:                        %d\n", [status[@"pid"] intValue]);
                printf("  Uptime:                     %llu seconds\n", [status[@"uptime_seconds"] unsignedLongLongValue]);
                printf("  Active Mounts:              %llu\n", [status[@"active_mounts_count"] unsignedLongLongValue]);
                printf("  Detected Disks:             %llu\n", [status[@"detected_disks_count"] unsignedLongLongValue]);
                printf("  Active Transactions:        %llu\n", [status[@"total_transactions"] unsignedLongLongValue]);
                printf("  Total Bytes Written:        %llu bytes\n", [status[@"total_bytes_written"] unsignedLongLongValue]);
                printf("  Suppressed Metadata Ops:    %llu (.DS_Store / Spotlight dropped)\n", [status[@"suppressed_metadata_operations"] unsignedLongLongValue]);
                printf("  Forensic Hygiene Mode:      %s\n", [status[@"forensic_hygiene_mode"] UTF8String]);
            }
        }
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    [conn invalidate];
    return exitCode;
}

static int CommandList(BOOL jsonOutput) {
    NSXPCConnection *conn = GetDaemonConnection();
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        if (!jsonOutput) {
            fprintf(stderr, "Notice: Daemon not reachable (%s); scanning local system disks...\n", error.localizedDescription.UTF8String);
        }
    }];

    __block int exitCode = 0;
    __block BOOL receivedReply = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [proxy listDisksWithReply:^(NSArray<NSDictionary *> * _Nullable disks, NSError * _Nullable error) {
        if (!error && disks) {
            receivedReply = YES;
            if (jsonOutput) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:disks options:NSJSONWritingPrettyPrinted error:nil];
                printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            } else {
                printf("%-14s %-20s %-12s %-12s %-20s\n", "IDENTIFIER", "VOLUME NAME", "CAPACITY", "STATUS", "HYGIENE MODE");
                printf("----------------------------------------------------------------------------------\n");
                if (disks.count == 0) {
                    printf("No NTFS storage devices attached.\n");
                }
                for (NSDictionary *d in disks) {
                    NSString *bsd = d[@"bsd_name"] ?: @"-";
                    NSString *name = d[@"volume_name"] ?: @"-";
                    uint64_t size = [d[@"media_size"] unsignedLongLongValue];
                    NSString *sizeStr = (size > 0) ? [NSString stringWithFormat:@"%.1f GB", (double)size / (1024.0 * 1024.0 * 1024.0)] : @"-";
                    BOOL mounted = [d[@"is_mounted"] boolValue];
                    NSString *status = mounted ? @"Mounted" : @"Unmounted";
                    BOOL allowMeta = [d[@"allow_system_metadata"] boolValue];
                    NSString *hygiene = mounted ? (allowMeta ? @"DIRTY (--allow)" : @"STRICT (Clean)") : @"-";

                    printf("%-14s %-20s %-12s %-12s %-20s\n",
                           bsd.UTF8String,
                           name.UTF8String,
                           sizeStr.UTF8String,
                           status.UTF8String,
                           hygiene.UTF8String);
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    [conn invalidate];

    if (!receivedReply && !jsonOutput) {
        printf("No response from daemon. Run 'kty-ntfsd' to start autonomous management.\n");
    }

    return exitCode;
}

static int CommandMount(NSString *device, NSString *target, BOOL readOnly, BOOL allowMetadata) {
    if (!device || device.length == 0) {
        fprintf(stderr, "Error: Device argument required (e.g. /dev/disk2s1 or disk2s1)\n");
        return 1;
    }

    if (allowMetadata) {
        printf("\n======================================================================\n");
        printf(" [!] FORENSIC HYGIENE WARNING: --allow-system-metadata IS ENABLED\n");
        printf(" Destination disk will receive host metadata (.DS_Store, Spotlight,\n");
        printf(" Trashes, AppleDouble sidecars). The media is NOT forensically clean.\n");
        printf("======================================================================\n\n");
    }

    NSXPCConnection *conn = GetDaemonConnection();
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        fprintf(stderr, "Error connecting to daemon: %s\n", error.localizedDescription.UTF8String);
    }];

    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [proxy mountDevice:device
            targetPath:target
              readOnly:readOnly
   allowSystemMetadata:allowMetadata
             withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
        if (error || !result) {
            fprintf(stderr, "Mount failed: %s\n", error ? error.localizedDescription.UTF8String : "Unknown error");
            exitCode = 1;
        } else {
            printf("==> Successfully claimed and mounted device: %s\n", [result[@"device_node"] UTF8String]);
            printf("    Mount point:     %s\n", [result[@"mount_point"] UTF8String]);
            printf("    Access mode:     %s\n", [result[@"read_only"] boolValue] ? "Read-Only" : "Read/Write");
            printf("    Forensic mode:   %s\n", [result[@"allow_system_metadata"] boolValue] ? "Permissive (Host Metadata Allowed)" : "STRICT (Host Metadata Suppressed)");
        }
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [conn invalidate];
    return exitCode;
}

static int CommandUnmount(NSString *target) {
    if (!target || target.length == 0) {
        fprintf(stderr, "Error: Mount point or BSD device required to unmount\n");
        return 1;
    }

    NSXPCConnection *conn = GetDaemonConnection();
    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        fprintf(stderr, "Error connecting to daemon: %s\n", error.localizedDescription.UTF8String);
    }];

    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [proxy unmountTarget:target withReply:^(BOOL success, NSError * _Nullable error) {
        if (!success || error) {
            fprintf(stderr, "Unmount failed: %s\n", error ? error.localizedDescription.UTF8String : "Unknown error");
            exitCode = 1;
        } else {
            printf("==> Flushed dirty clusters and updated transaction journals.\n");
            printf("==> Volume '%s' safely unmounted and detached.\n", target.UTF8String);
        }
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [conn invalidate];
    return exitCode;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            PrintHelp();
            return 1;
        }

        NSString *subcmd = [NSString stringWithUTF8String:argv[1]];
        if ([subcmd isEqualToString:@"help"] || [subcmd isEqualToString:@"--help"] || [subcmd isEqualToString:@"-h"]) {
            PrintHelp();
            return 0;
        }

        if ([subcmd isEqualToString:@"status"]) {
            BOOL json = NO;
            for (int i = 2; i < argc; i++) {
                if (strcmp(argv[i], "--json") == 0) json = YES;
            }
            return CommandStatus(json);
        }

        if ([subcmd isEqualToString:@"list"]) {
            BOOL json = NO;
            for (int i = 2; i < argc; i++) {
                if (strcmp(argv[i], "--json") == 0) json = YES;
            }
            return CommandList(json);
        }

        if ([subcmd isEqualToString:@"mount"]) {
            if (argc < 3) {
                fprintf(stderr, "Usage: kty-ntfs mount <device> [options]\n");
                return 1;
            }
            NSString *device = [NSString stringWithUTF8String:argv[2]];
            NSString *target = nil;
            BOOL readOnly = NO;
            BOOL allowMetadata = NO;

            for (int i = 3; i < argc; i++) {
                NSString *arg = [NSString stringWithUTF8String:argv[i]];
                if (([arg isEqualToString:@"--target"] || [arg isEqualToString:@"-t"]) && i + 1 < argc) {
                    target = [NSString stringWithUTF8String:argv[++i]];
                } else if ([arg isEqualToString:@"--readonly"] || [arg isEqualToString:@"-r"]) {
                    readOnly = YES;
                } else if ([arg isEqualToString:@"--allow-system-metadata"]) {
                    allowMetadata = YES;
                }
            }

            return CommandMount(device, target, readOnly, allowMetadata);
        }

        if ([subcmd isEqualToString:@"unmount"]) {
            if (argc < 3) {
                fprintf(stderr, "Usage: kty-ntfs unmount <target-or-device>\n");
                return 1;
            }
            NSString *target = [NSString stringWithUTF8String:argv[2]];
            return CommandUnmount(target);
        }

        fprintf(stderr, "Unknown command: %s\n", subcmd.UTF8String);
        PrintHelp();
        return 1;
    }
}
