#import <Foundation/Foundation.h>
#import <DiskArbitration/DiskArbitration.h>
#import "KTYDaemonProtocol.h"
#include "kty_safety.h"

static void PrintHelp(void) {
    printf("kty-ntfs - Native NTFS Companion CLI (knowthankyew)\n\n");
    printf("Usage:\n");
    printf("  kty-ntfs list [--json]                     List detected and mounted NTFS partitions\n");
    printf("  kty-ntfs mount <device> [options]          Mount an NTFS partition\n");
    printf("  kty-ntfs unmount <target>                  Gracefully unmount a volume or device\n");
    printf("  kty-ntfs check <device-or-path> [--json]   Inspect volume for Windows Fast Startup safety\n");
    printf("  kty-ntfs config [options]                  Query or update auto-mount volume rules\n");
    printf("  kty-ntfs ls <device>:[path] [--json]       List directory contents on an NTFS partition\n");
    printf("  kty-ntfs cp <src> <dest> [options]         Copy file to/from NTFS directly (e.g. file.txt disk0s4:/)\n");
    printf("  kty-ntfs status [--json]                   Query kty-ntfsd daemon status & metrics\n");
    printf("  kty-ntfs help, --help, -h                  Show this help reference\n\n");
    printf("Mount Options:\n");
    printf("  -t, --target <path>          Custom mount directory (default: /Volumes/<VolumeName>)\n");
    printf("  -r, --readonly               Mount volume in read-only mode\n");
    printf("      --allow-system-metadata  WARNING: Allow Finder/Spotlight host metadata (.DS_Store,\n");
    printf("                               Spotlight-V100, Trashes) on the destination media.\n");
    printf("                               Default is STRICT HYGIENE (metadata suppressed in RAM).\n\n");
    printf("Config Options:\n");
    printf("  --target <name/uuid>         Target volume for rule (e.g. BOOTCAMP)\n");
    printf("  --enable / --disable         Enable or disable auto-mount for targeted volume\n");
    printf("  --readonly                   Configure target to auto-mount read-only\n");
    printf("  --auto-mount <on|off>        Toggle global auto-mount daemon state\n\n");
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
        fprintf(stderr, "Error connecting to kty-ntfsd daemon: %s\n", error.localizedDescription.UTF8String);
        exitCode = 1;
        dispatch_semaphore_signal(sem);
    }];

    [proxy mountDevice:device
            targetPath:target
              readOnly:readOnly
   allowSystemMetadata:allowMetadata
             withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
        if (error || !result) {
            if (error.userInfo[@"KTYGuidance"]) {
                printf("\n%s\n", [error.userInfo[@"KTYGuidance"] UTF8String]);
            } else {
                fprintf(stderr, "Mount failed: %s\n", error ? error.localizedDescription.UTF8String : "Unknown error");
            }
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
        fprintf(stderr, "Error connecting to kty-ntfsd daemon: %s\n", error.localizedDescription.UTF8String);
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

static int CommandCheck(NSString *target, BOOL jsonOutput) {
    if (!target || target.length == 0) {
        fprintf(stderr, "Error: Target volume or device required for check (e.g. BOOTCAMP, disk0s4, or /Volumes/BOOTCAMP)\n");
        return 1;
    }

    NSXPCConnection *conn = GetDaemonConnection();
    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        (void)error;
        /* Direct in-process fallback if daemon is offline */
        kty_safety_report_t rep;
        int rc = kty_check_volume_safety(target.UTF8String, &rep);
        if (rc < 0) {
            if (jsonOutput) {
                printf("{\"status\": \"error\", \"message\": \"%s\"}\n", rep.status_summary[0] ? rep.status_summary : "Safety check failed");
            } else {
                fprintf(stderr, "Error inspecting target '%s': %s\n", target.UTF8String, rep.status_summary[0] ? rep.status_summary : "Safety check failed");
            }
            exitCode = 1;
        } else {
            char guidanceBuf[2048] = {0};
            kty_format_fast_startup_guidance(rep.volume_name, guidanceBuf, sizeof(guidanceBuf));
            if (jsonOutput) {
                NSDictionary *d = @{
                    @"target": target,
                    @"volume_name": [NSString stringWithUTF8String:rep.volume_name],
                    @"has_hiberfile": @(rep.has_hiberfile),
                    @"is_hibernated": @(rep.is_hibernated),
                    @"is_dirty": @(rep.is_dirty),
                    @"metadata_cached": @(rep.metadata_cached),
                    @"safe_for_write": @(rep.safe_for_write),
                    @"status_summary": [NSString stringWithUTF8String:rep.status_summary]
                };
                NSData *data = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];
                printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            } else {
                printf("\n--- NTFS Partition Safety & Fast Startup Inspection ---\n");
                printf("  Target:              %s\n", target.UTF8String);
                printf("  Volume Name:         %s\n", rep.volume_name);
                printf("  hiberfil.sys:        %s\n", rep.has_hiberfile ? "Present" : "Not Found (Disabled)");
                printf("  Fast Startup Magic:  %s\n", rep.is_hibernated ? "ACTIVE (hibr/HIBR detected)" : "Clean (Zeroed or Inactive)");
                printf("  Journal State:       %s\n", rep.is_dirty ? "Dirty" : "Clean");
                printf("  Write Safety:        %s\n", rep.safe_for_write ? "SAFE FOR READ/WRITE" : "UNSAFE (Fast Startup active)");
                printf("  Summary:             %s\n\n", rep.status_summary);
                if (!rep.safe_for_write) {
                    printf("%s\n", guidanceBuf);
                }
            }
            exitCode = rep.safe_for_write ? 0 : 2;
        }
        dispatch_semaphore_signal(sem);
    }];

    [proxy checkSafetyForTarget:target withReply:^(NSDictionary * _Nullable report, NSError * _Nullable error) {
        if (error || !report) {
            if (jsonOutput) {
                printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error ? error.localizedDescription.UTF8String : "Inspection failed");
            } else {
                fprintf(stderr, "Error checking safety for '%s': %s\n", target.UTF8String, error ? error.localizedDescription.UTF8String : "Unknown error");
            }
            exitCode = 1;
        } else {
            if (jsonOutput) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
                printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            } else {
                printf("\n--- NTFS Partition Safety & Fast Startup Inspection ---\n");
                printf("  Target:              %s\n", [report[@"target"] UTF8String]);
                printf("  Volume Name:         %s\n", [report[@"volume_name"] UTF8String]);
                printf("  hiberfil.sys:        %s\n", [report[@"has_hiberfile"] boolValue] ? "Present" : "Not Found (Disabled)");
                printf("  Fast Startup Magic:  %s\n", [report[@"is_hibernated"] boolValue] ? "ACTIVE (hibr/HIBR detected)" : "Clean (Zeroed or Inactive)");
                printf("  Journal State:       %s\n", [report[@"is_dirty"] boolValue] ? "Dirty" : "Clean");
                printf("  Write Safety:        %s\n", [report[@"safe_for_write"] boolValue] ? "SAFE FOR READ/WRITE" : "UNSAFE (Fast Startup active)");
                printf("  Summary:             %s\n\n", [report[@"status_summary"] UTF8String]);
                if (![report[@"safe_for_write"] boolValue] && report[@"guidance"]) {
                    printf("%s\n", [report[@"guidance"] UTF8String]);
                }
            }
            exitCode = [report[@"safe_for_write"] boolValue] ? 0 : 2;
        }
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [conn invalidate];
    return exitCode;
}

static int CommandConfig(BOOL jsonOutput, NSString *targetVolume, NSNumber *enableAutoMount, NSNumber *readOnly) {
    NSXPCConnection *conn = GetDaemonConnection();
    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        if (!targetVolume && enableAutoMount == nil) {
            /* Fallback to reading preferences plist directly if daemon is unreachable */
            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:@"/Library/Preferences/com.knowthankyew.ntfsd.plist"];
            BOOL autoMountEn = dict[@"auto_mount_enabled"] ? [dict[@"auto_mount_enabled"] boolValue] : YES;
            NSDictionary *targets = dict[@"auto_mount_targets"] ?: @{};
            NSDictionary *config = @{
                @"auto_mount_enabled": @(autoMountEn),
                @"auto_mount_targets": targets,
                @"preferences_path": @"/Library/Preferences/com.knowthankyew.ntfsd.plist"
            };
            if (jsonOutput) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
                printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            } else {
                fprintf(stderr, "Notice: Daemon not reachable (%s); reading configuration from preferences...\n", error.localizedDescription.UTF8String);
                printf("kty-ntfs Configuration:\n");
                printf("  Global Auto-Mount:       %s\n", autoMountEn ? "Enabled" : "Disabled");
                printf("  Preferences File:        %s\n", "/Library/Preferences/com.knowthankyew.ntfsd.plist");
                printf("  Target Volume Rules:\n");
                if (targets.count == 0) {
                    printf("    (No specific volume rules configured; all NTFS volumes claimable)\n");
                } else {
                    for (NSString *key in targets) {
                        NSDictionary *t = targets[key];
                        printf("    - %-20s [Auto-Mount: %s, Mode: %s]\n",
                               key.UTF8String,
                               [t[@"enabled"] boolValue] ? "ON" : "OFF",
                               [t[@"read_only"] boolValue] ? "Read-Only" : "Read/Write");
                    }
                }
            }
            exitCode = 0;
            dispatch_semaphore_signal(sem);
            return;
        }

        if (jsonOutput) {
            printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error.localizedDescription.UTF8String);
        } else {
            fprintf(stderr, "Error connecting to daemon: %s\n", error.localizedDescription.UTF8String);
        }
        exitCode = 1;
        dispatch_semaphore_signal(sem);
    }];

    if (targetVolume) {
        BOOL en = enableAutoMount ? [enableAutoMount boolValue] : YES;
        BOOL ro = readOnly ? [readOnly boolValue] : NO;
        [proxy setAutoMountTarget:targetVolume enabled:en readOnly:ro withReply:^(BOOL success, NSError * _Nullable error) {
            if (!success || error) {
                if (jsonOutput) {
                    printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error ? error.localizedDescription.UTF8String : "Configuration failed");
                } else {
                    fprintf(stderr, "Failed to update target config: %s\n", error ? error.localizedDescription.UTF8String : "Unknown error");
                }
                exitCode = 1;
            } else {
                if (jsonOutput) {
                    printf("{\"status\": \"success\", \"target\": \"%s\", \"enabled\": %s, \"read_only\": %s}\n",
                           targetVolume.UTF8String, en ? "true" : "false", ro ? "true" : "false");
                } else {
                    printf("==> Auto-mount configuration updated for '%s':\n", targetVolume.UTF8String);
                    printf("    Auto-Mount: %s\n", en ? "Enabled" : "Disabled");
                    printf("    Mode:       %s\n", ro ? "Read-Only" : "Read/Write");
                }
            }
            dispatch_semaphore_signal(sem);
        }];
    } else if (enableAutoMount != nil) {
        BOOL en = [enableAutoMount boolValue];
        [proxy setGlobalAutoMountEnabled:en withReply:^(BOOL success, NSError * _Nullable error) {
            if (!success || error) {
                if (jsonOutput) {
                    printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error ? error.localizedDescription.UTF8String : "Failed to update global auto-mount state");
                } else {
                    fprintf(stderr, "Failed to update global auto-mount state: %s\n", error ? error.localizedDescription.UTF8String : "Unknown error");
                }
                exitCode = 1;
            } else {
                if (jsonOutput) {
                    printf("{\"status\": \"success\", \"auto_mount_enabled\": %s}\n", en ? "true" : "false");
                } else {
                    printf("==> Global auto-mount daemon state updated: %s\n", en ? "Enabled" : "Disabled");
                }
            }
            dispatch_semaphore_signal(sem);
        }];
    } else {
        [proxy getConfigWithReply:^(NSDictionary * _Nullable config, NSError * _Nullable error) {
            if (error || !config) {
                if (jsonOutput) {
                    printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error ? error.localizedDescription.UTF8String : "Unable to retrieve config");
                } else {
                    fprintf(stderr, "Error retrieving configuration: %s\n", error ? error.localizedDescription.UTF8String : "Unknown error");
                }
                exitCode = 1;
            } else {
                if (jsonOutput) {
                    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
                    printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
                } else {
                    printf("kty-ntfs Configuration:\n");
                    printf("  Global Auto-Mount:       %s\n", [config[@"auto_mount_enabled"] boolValue] ? "Enabled" : "Disabled");
                    printf("  Preferences File:        %s\n", [config[@"preferences_path"] UTF8String]);
                    printf("  Target Volume Rules:\n");
                    NSDictionary *targets = config[@"auto_mount_targets"];
                    if (!targets || targets.count == 0) {
                        printf("    (No specific volume rules configured; all NTFS volumes claimable)\n");
                    } else {
                        for (NSString *key in targets) {
                            NSDictionary *t = targets[key];
                            printf("    - %-20s [Auto-Mount: %s, Mode: %s]\n",
                                   key.UTF8String,
                                   [t[@"enabled"] boolValue] ? "ON" : "OFF",
                                   [t[@"read_only"] boolValue] ? "Read-Only" : "Read/Write");
                        }
                    }
                }
            }
            dispatch_semaphore_signal(sem);
        }];
    }

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [conn invalidate];
    return exitCode;
}

static int CommandLS(NSString *targetWithDevice, BOOL jsonOutput) {
    if (!targetWithDevice || targetWithDevice.length == 0) {
        fprintf(stderr, "Error: Target required in format <device>:[path] (e.g. disk0s4:/ or disk0s4)\n");
        return 1;
    }

    NSString *device = nil;
    NSString *path = @"/";
    NSRange colon = [targetWithDevice rangeOfString:@":"];
    if (colon.location != NSNotFound) {
        device = [targetWithDevice substringToIndex:colon.location];
        path = [targetWithDevice substringFromIndex:colon.location + 1];
        if (path.length == 0) path = @"/";
    } else {
        device = targetWithDevice;
    }

    device = [device stringByReplacingOccurrencesOfString:@"/dev/" withString:@""];

    NSXPCConnection *conn = GetDaemonConnection();
    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        if (jsonOutput) {
            printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error.localizedDescription.UTF8String);
        } else {
            fprintf(stderr, "Error connecting to daemon: %s\n", error.localizedDescription.UTF8String);
        }
        exitCode = 1;
        dispatch_semaphore_signal(sem);
    }];

    [proxy listDirectoryOnDevice:device path:path withReply:^(NSArray<NSDictionary *> * _Nullable entries, NSError * _Nullable error) {
        if (error || !entries) {
            if (jsonOutput) {
                printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error ? error.localizedDescription.UTF8String : "Directory listing failed");
            } else {
                fprintf(stderr, "Directory listing failed: %s\n", error ? error.localizedDescription.UTF8String : "Unknown error");
            }
            exitCode = 1;
        } else {
            if (jsonOutput) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:entries options:NSJSONWritingPrettyPrinted error:nil];
                printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            } else {
                printf("Directory listing for %s:%s\n", device.UTF8String, path.UTF8String);
                printf("%-10s %-12s %-30s\n", "TYPE", "SIZE", "NAME");
                printf("------------------------------------------------------------\n");
                for (NSDictionary *e in entries) {
                    BOOL isDir = [e[@"is_directory"] boolValue];
                    uint64_t size = [e[@"size"] unsignedLongLongValue];
                    NSString *name = e[@"name"] ?: @"";
                    printf("%-10s %-12llu %-30s\n",
                           isDir ? "DIR" : "FILE",
                           (unsigned long long)size,
                           name.UTF8String);
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    [conn invalidate];
    return exitCode;
}

static int CommandCP(NSString *src, NSString *dest, BOOL allowMetadata, BOOL jsonOutput) {
    if (!src || !dest) {
        fprintf(stderr, "Usage: kty-ntfs cp <source> <destination> [options]\n");
        fprintf(stderr, "Examples:\n");
        fprintf(stderr, "  kty-ntfs cp local.txt disk0s4:/Users/Alice/Desktop/local.txt\n");
        fprintf(stderr, "  kty-ntfs cp disk0s4:/Windows/notepad.exe ./notepad.exe\n");
        return 1;
    }

    BOOL srcIsNTFS = ([src rangeOfString:@":"].location != NSNotFound);
    BOOL destIsNTFS = ([dest rangeOfString:@":"].location != NSNotFound);

    if (srcIsNTFS && destIsNTFS) {
        fprintf(stderr, "Error: Cross-device NTFS-to-NTFS direct copy not supported; copy via host scratchpad.\n");
        return 1;
    }
    if (!srcIsNTFS && !destIsNTFS) {
        fprintf(stderr, "Error: One argument must specify an NTFS device target (e.g. disk0s4:/path)\n");
        return 1;
    }

    NSXPCConnection *conn = GetDaemonConnection();
    __block int exitCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    id<KTYDaemonProtocol> proxy = [conn remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
        if (jsonOutput) {
            printf("{\"status\": \"error\", \"message\": \"%s\"}\n", error.localizedDescription.UTF8String);
        } else {
            fprintf(stderr, "Error connecting to daemon: %s\n", error.localizedDescription.UTF8String);
        }
        exitCode = 1;
        dispatch_semaphore_signal(sem);
    }];

    if (destIsNTFS) {
        /* Host -> NTFS */
        NSRange colon = [dest rangeOfString:@":"];
        NSString *device = [dest substringToIndex:colon.location];
        NSString *destPath = [dest substringFromIndex:colon.location + 1];
        if (destPath.length == 0) destPath = @"/";

        device = [device stringByReplacingOccurrencesOfString:@"/dev/" withString:@""];
        NSString *hostSrc = [src stringByStandardizingPath];

        [proxy copyFileToNTFS:device
                   sourcePath:hostSrc
              destinationPath:destPath
          allowSystemMetadata:allowMetadata
                    withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
            if (error || !result) {
                if (error.userInfo[@"KTYGuidance"]) {
                    printf("\n%s\n", [error.userInfo[@"KTYGuidance"] UTF8String]);
                } else {
                    fprintf(stderr, "Copy failed: %s\n", error ? error.localizedDescription.UTF8String : "Unknown error");
                }
                exitCode = 1;
            } else {
                if (jsonOutput) {
                    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
                    printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
                } else {
                    printf("==> Successfully transferred file to NTFS volume (%s):\n", device.UTF8String);
                    printf("    Destination: %s\n", [result[@"destination"] UTF8String]);
                    printf("    SHA-256:     %s\n", [result[@"sha256"] UTF8String]);
                    printf("    BLAKE3:      %s\n", [result[@"blake3"] UTF8String]);
                    printf("    ADS Streams: Recorded & Verified (kty.integrity.*)\n");
                }
            }
            dispatch_semaphore_signal(sem);
        }];
    } else {
        /* NTFS -> Host */
        NSRange colon = [src rangeOfString:@":"];
        NSString *device = [src substringToIndex:colon.location];
        NSString *ntfsSrc = [src substringFromIndex:colon.location + 1];
        device = [device stringByReplacingOccurrencesOfString:@"/dev/" withString:@""];
        NSString *hostDst = [dest stringByStandardizingPath];

        [proxy copyFileFromNTFS:device
                     sourcePath:ntfsSrc
                destinationPath:hostDst
                      withReply:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
            if (error || !result) {
                fprintf(stderr, "Extract failed: %s\n", error ? error.localizedDescription.UTF8String : "Unknown error");
                exitCode = 1;
            } else {
                if (jsonOutput) {
                    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
                    printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
                } else {
                    printf("==> Successfully extracted file from %s:%s to %s\n",
                           device.UTF8String, ntfsSrc.UTF8String, hostDst.UTF8String);
                }
            }
            dispatch_semaphore_signal(sem);
        }];
    }

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
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

        if ([subcmd isEqualToString:@"check"]) {
            if (argc < 3) {
                fprintf(stderr, "Usage: kty-ntfs check <device-or-path> [--json]\n");
                return 1;
            }
            NSString *target = [NSString stringWithUTF8String:argv[2]];
            BOOL json = NO;
            for (int i = 3; i < argc; i++) {
                if (strcmp(argv[i], "--json") == 0) json = YES;
            }
            return CommandCheck(target, json);
        }

        if ([subcmd isEqualToString:@"config"]) {
            BOOL json = NO;
            NSString *target = nil;
            NSNumber *enableAutoMount = nil;
            NSNumber *readOnly = nil;

            for (int i = 2; i < argc; i++) {
                NSString *arg = [NSString stringWithUTF8String:argv[i]];
                if ([arg isEqualToString:@"--json"]) {
                    json = YES;
                } else if ([arg isEqualToString:@"--target"] && i + 1 < argc) {
                    target = [NSString stringWithUTF8String:argv[++i]];
                } else if ([arg isEqualToString:@"--enable"]) {
                    enableAutoMount = @YES;
                } else if ([arg isEqualToString:@"--disable"]) {
                    enableAutoMount = @NO;
                } else if ([arg isEqualToString:@"--readonly"]) {
                    readOnly = @YES;
                } else if ([arg isEqualToString:@"--auto-mount"] && i + 1 < argc) {
                    NSString *val = [NSString stringWithUTF8String:argv[++i]];
                    enableAutoMount = [val.lowercaseString isEqualToString:@"on"] ? @YES : @NO;
                }
            }
            return CommandConfig(json, target, enableAutoMount, readOnly);
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

        if ([subcmd isEqualToString:@"ls"]) {
            if (argc < 3) {
                fprintf(stderr, "Usage: kty-ntfs ls <device>:[path] [--json]\n");
                return 1;
            }
            NSString *target = [NSString stringWithUTF8String:argv[2]];
            BOOL json = NO;
            for (int i = 3; i < argc; i++) {
                if (strcmp(argv[i], "--json") == 0) json = YES;
            }
            return CommandLS(target, json);
        }

        if ([subcmd isEqualToString:@"cp"]) {
            if (argc < 4) {
                fprintf(stderr, "Usage: kty-ntfs cp <src> <dest> [--allow-system-metadata] [--json]\n");
                return 1;
            }
            NSString *src = [NSString stringWithUTF8String:argv[2]];
            NSString *dest = [NSString stringWithUTF8String:argv[3]];
            BOOL allowMeta = NO;
            BOOL json = NO;
            for (int i = 4; i < argc; i++) {
                if (strcmp(argv[i], "--allow-system-metadata") == 0) allowMeta = YES;
                if (strcmp(argv[i], "--json") == 0) json = YES;
            }
            return CommandCP(src, dest, allowMeta, json);
        }

        fprintf(stderr, "Unknown command: %s\n", subcmd.UTF8String);
        PrintHelp();
        return 1;
    }
}
