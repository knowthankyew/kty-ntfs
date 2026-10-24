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
    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        if (jsonOutput) {
            printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error.localizedDescription.UTF8String);
        } else {
            fprintf(stderr, "Error connecting to kty-ntfsd daemon: %s\n", error.localizedDescription.UTF8String);
            fprintf(stderr, "Ensure kty-ntfsd is running (launchctl load /Library/LaunchDaemons/com.knowthankyew.ntfsd.plist).\n");
        }
        exitCode = 1;
        dispatch_semaphore_signal(sem);
    }];

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

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        if (!jsonOutput) {
            fprintf(stderr, "Error: Timeout waiting for kty-ntfsd daemon response.\n");
        }
        exitCode = 1;
    }
    [conn invalidate];
    return exitCode;
}

static NSString *KTYExtractFSTypeFromDiskDesc(NSDictionary *desc) {
    if (!desc) return @"-";

    NSString *vType = desc[(NSString *)kDADiskDescriptionVolumeTypeKey];
    if (vType && vType.length > 0) {
        return [vType uppercaseString];
    }

    NSString *vKind = desc[(NSString *)kDADiskDescriptionVolumeKindKey];
    if (vKind && vKind.length > 0) {
        if ([vKind.lowercaseString isEqualToString:@"ntfs"]) return @"NTFS";
        if ([vKind.lowercaseString isEqualToString:@"apfs"]) return @"APFS";
        if ([vKind.lowercaseString isEqualToString:@"hfs"] || [vKind.lowercaseString isEqualToString:@"hfsplus"]) return @"HFS+";
        if ([vKind.lowercaseString isEqualToString:@"msdos"] || [vKind.lowercaseString isEqualToString:@"fat32"]) return @"FAT32";
        if ([vKind.lowercaseString isEqualToString:@"exfat"]) return @"ExFAT";
        return [vKind uppercaseString];
    }

    NSString *content = desc[(NSString *)kDADiskDescriptionMediaContentKey];
    if (content && content.length > 0) {
        NSString *uContent = [content uppercaseString];
        if ([uContent isEqualToString:@"EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"] ||
            [uContent containsString:@"NTFS"] ||
            [uContent isEqualToString:@"MICROSOFT BASIC DATA"]) {
            return @"NTFS";
        }
        if ([uContent isEqualToString:@"41504653-0000-11AA-AA11-00306543ECAC"] ||
            [uContent isEqualToString:@"7C3457EF-0000-11AA-AA11-00306543ECAC"] ||
            [uContent isEqualToString:@"EF57347C-0000-11AA-AA11-00306543ECAC"] ||
            [uContent containsString:@"APFS"]) {
            return @"APFS";
        }
        if ([uContent isEqualToString:@"APPLE_HFS"] || [uContent containsString:@"HFS"]) {
            return @"HFS+";
        }
        if ([uContent isEqualToString:@"C12A7328-F81F-11D2-BA4B-00A0C93EC93B"] ||
            [uContent containsString:@"EFI"]) {
            return @"FAT32";
        }
        if ([uContent isEqualToString:@"DE94BBA4-06D1-4D40-A16A-BFD50179D6AC"] ||
            [uContent containsString:@"RECOVERY"]) {
            return @"Recovery";
        }
        if ([uContent isEqualToString:@"E3C9E316-0B5C-4DB8-817D-F92DF00215AE"] ||
            [uContent isEqualToString:@"E3C9E310-0B5E-4965-97B1-3D21465175A6"] ||
            [uContent containsString:@"MICROSOFT RESERVED"]) {
            return @"MSR";
        }
        if ([uContent isEqualToString:@"GUID_PARTITION_SCHEME"]) {
            return @"Partition";
        }
        if (content.length > 12) {
            return @"Other";
        }
        return content;
    }

    return @"-";
}

static int CommandList(BOOL jsonOutput) {
    NSXPCConnection *conn = GetDaemonConnection();
    __block int exitCode = 0;
    __block BOOL receivedReply = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        if (jsonOutput) {
            printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error.localizedDescription.UTF8String);
        } else {
            fprintf(stderr, "Notice: Daemon not reachable (%s); scanning local system disks...\n", error.localizedDescription.UTF8String);
            printf("No response from daemon. Run 'kty-ntfsd' to start autonomous management.\n");
        }
        exitCode = 1;
        dispatch_semaphore_signal(sem);
    }];

    [proxy listDisksWithReply:^(NSArray<NSDictionary *> * _Nullable disks, NSError * _Nullable error) {
        if (!error && disks) {
            receivedReply = YES;
            NSArray<NSDictionary *> *sortedDisks = [disks sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                NSString *bsdA = a[@"bsd_name"] ?: @"";
                NSString *bsdB = b[@"bsd_name"] ?: @"";
                return [bsdA localizedStandardCompare:bsdB];
            }];

            NSMutableArray<NSDictionary *> *enrichedDisks = [NSMutableArray array];
            DASessionRef fallbackSession = NULL;
            for (NSDictionary *d in sortedDisks) {
                NSMutableDictionary *mut = [d mutableCopy];
                NSString *fsType = mut[@"fs_type"] ?: mut[@"volume_type"];
                if (!fsType || [fsType isEqualToString:@"-"] || [fsType isEqualToString:@"Unknown"]) {
                    NSString *bsd = mut[@"bsd_name"];
                    if (bsd && bsd.length > 0) {
                        if (!fallbackSession) {
                            fallbackSession = DASessionCreate(kCFAllocatorDefault);
                        }
                        if (fallbackSession) {
                            NSString *devPath = [NSString stringWithFormat:@"/dev/%@", bsd];
                            DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, fallbackSession, devPath.UTF8String);
                            if (disk) {
                                CFDictionaryRef desc = DADiskCopyDescription(disk);
                                if (desc) {
                                    fsType = KTYExtractFSTypeFromDiskDesc((__bridge NSDictionary *)desc);
                                    CFRelease(desc);
                                }
                                CFRelease(disk);
                            }
                        }
                    }
                }
                if (!fsType || fsType.length == 0) {
                    fsType = @"-";
                }
                mut[@"fs_type"] = fsType;
                mut[@"volume_type"] = fsType;
                [enrichedDisks addObject:mut];
            }
            if (fallbackSession) {
                CFRelease(fallbackSession);
            }

            if (jsonOutput) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:enrichedDisks options:NSJSONWritingPrettyPrinted error:nil];
                printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            } else {
                printf("%-12s %-20s %-12s %-10s %-12s %-20s\n", "IDENTIFIER", "VOLUME NAME", "FS TYPE", "CAPACITY", "STATUS", "HYGIENE MODE");
                printf("----------------------------------------------------------------------------------------------------\n");
                if (enrichedDisks.count == 0) {
                    printf("No storage devices detected.\n");
                }
                for (NSDictionary *d in enrichedDisks) {
                    NSString *bsd = d[@"bsd_name"] ?: @"-";
                    NSString *name = d[@"volume_name"];
                    if (!name || name.length == 0) name = @"-";
                    NSString *fsType = d[@"fs_type"] ?: @"-";
                    uint64_t size = [d[@"media_size"] unsignedLongLongValue];
                    NSString *sizeStr = (size > 0) ? [NSString stringWithFormat:@"%.1f GB", (double)size / (1024.0 * 1024.0 * 1024.0)] : @"-";
                    BOOL mounted = [d[@"is_mounted"] boolValue];
                    BOOL ktyManaged = [d[@"kty_managed"] boolValue];
                    NSString *status = mounted ? @"Mounted" : @"Unmounted";
                    BOOL allowMeta = [d[@"allow_system_metadata"] boolValue];
                    NSString *hygiene = mounted ? (ktyManaged ? (allowMeta ? @"DIRTY (--allow)" : @"STRICT (Clean)") : @"OS Default") : @"-";

                    printf("%-12s %-20s %-12s %-10s %-12s %-20s\n",
                           bsd.UTF8String,
                           name.UTF8String,
                           fsType.UTF8String,
                           sizeStr.UTF8String,
                           status.UTF8String,
                           hygiene.UTF8String);
                }
            }
        } else {
            if (jsonOutput) {
                printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error ? error.localizedDescription.UTF8String : "unknown error");
            } else {
                fprintf(stderr, "Error listing disks: %s\n", error ? error.localizedDescription.UTF8String : "unknown error");
            }
            exitCode = 1;
        }
        dispatch_semaphore_signal(sem);
    }];

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
        if (!receivedReply) {
            if (!jsonOutput) {
                printf("No response from daemon. Run 'kty-ntfsd' to start autonomous management.\n");
            }
            exitCode = 1;
        }
    }
    [conn invalidate];

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
    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        fprintf(stderr, "Error connecting to daemon: %s\n", error.localizedDescription.UTF8String);
        exitCode = 1;
        dispatch_semaphore_signal(sem);
    }];

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

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        fprintf(stderr, "Error: Timeout waiting for daemon response\n");
        exitCode = 1;
    }
    [conn invalidate];
    return exitCode;
}

static int CommandUnmount(NSString *target) {
    if (!target || target.length == 0) {
        fprintf(stderr, "Error: Mount point or BSD device required to unmount\n");
        return 1;
    }

    NSXPCConnection *conn = GetDaemonConnection();
    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        fprintf(stderr, "Error connecting to daemon: %s\n", error.localizedDescription.UTF8String);
        exitCode = 1;
        dispatch_semaphore_signal(sem);
    }];

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

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        fprintf(stderr, "Error: Timeout waiting for daemon response\n");
        exitCode = 1;
    }
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
