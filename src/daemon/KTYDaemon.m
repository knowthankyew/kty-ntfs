#import "KTYDaemon.h"
#import <sys/stat.h>
#import <sys/param.h>
#import <sys/mount.h>
#import <unistd.h>
#include "kty_safety.h"
#include "kty_transfer.h"

@implementation KTYMountedVolumeInfo

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"bsd_name"] = self.bsdName ?: @"";
    dict[@"device_node"] = self.devicePath ?: @"";
    dict[@"mount_point"] = self.mountPoint ?: @"";
    dict[@"volume_name"] = self.volumeName ?: @"";
    dict[@"volume_uuid"] = self.volumeUUID ?: @"";
    dict[@"volume_type"] = self.volumeType ?: @"NTFS";
    dict[@"fs_type"] = self.volumeType ?: @"NTFS";
    dict[@"read_only"] = @(self.readOnly);
    dict[@"allow_system_metadata"] = @(self.allowSystemMetadata);
    dict[@"mount_time"] = @((uint64_t)self.mountTime);
    dict[@"kty_managed"] = @YES;
    if (self.ktyVolume) {
        dict[@"is_dirty"] = @(self.ktyVolume.isDirty);
        dict[@"total_bytes_written"] = @(self.ktyVolume.totalBytesWritten);
        dict[@"active_transactions"] = @(self.ktyVolume.activeTransactions);
        dict[@"suppressed_metadata_operations"] = @(self.ktyVolume.suppressedMetadataOperations);
    }
    return dict;
}

@end

static void KTYDiskAppearedCallback(DADiskRef disk, void *context) {
    if (!disk || !context) return;
    KTYDaemon *daemon = (__bridge KTYDaemon *)context;
    CFDictionaryRef desc = DADiskCopyDescription(disk);
    if (desc) {
        NSDictionary *dict = (__bridge_transfer NSDictionary *)desc;
        const char *bsdNameC = DADiskGetBSDName(disk);
        if (bsdNameC) {
            NSString *bsdName = [NSString stringWithUTF8String:bsdNameC];
            [daemon registerDiskAppeared:bsdName description:dict];
        }
    }
}

static void KTYDiskDisappearedCallback(DADiskRef disk, void *context) {
    if (!disk || !context) return;
    KTYDaemon *daemon = (__bridge KTYDaemon *)context;
    const char *bsdNameC = DADiskGetBSDName(disk);
    if (bsdNameC) {
        NSString *bsdName = [NSString stringWithUTF8String:bsdNameC];
        [daemon registerDiskDisappeared:bsdName];
    }
}

static DADissenterRef KTYDiskMountApprovalCallback(DADiskRef disk, void *context) {
    if (!disk || !context) return NULL;
    KTYDaemon *daemon = (__bridge KTYDaemon *)context;
    return [daemon evaluateMountApprovalForDisk:disk];
}

@interface KTYDaemon () {
    DASessionRef _daSession;
    CFRunLoopRef _scheduledRunLoop;
}
@property (nonatomic, assign) time_t startTime;
@property (nonatomic, strong) NSXPCListener *listener;
@property (nonatomic, strong) NSMutableDictionary<NSString *, KTYMountedVolumeInfo *> *mountedVolumes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *detectedDisks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *autoMountTargets;
@end

static NSString * const KTYPreferencesFilePath = @"/Library/Preferences/com.knowthankyew.ntfsd.plist";

@implementation KTYDaemon

- (void)loadPreferences {
    if ([[NSFileManager defaultManager] fileExistsAtPath:KTYPreferencesFilePath]) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:KTYPreferencesFilePath];
        if (dict) {
            if (dict[@"auto_mount_enabled"]) {
                _autoMountEnabled = [dict[@"auto_mount_enabled"] boolValue];
            }
            if ([dict[@"auto_mount_targets"] isKindOfClass:[NSDictionary class]]) {
                _autoMountTargets = [dict[@"auto_mount_targets"] mutableCopy];
            }
        }
    }
}

- (void)savePreferences {
    if (!self.machServiceName) return;
    NSDictionary *dict = @{
        @"auto_mount_enabled": @(self.autoMountEnabled),
        @"auto_mount_targets": self.autoMountTargets ?: @{}
    };
    [dict writeToFile:KTYPreferencesFilePath atomically:YES];
}

+ (instancetype)sharedDaemon {
    static KTYDaemon *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KTYDaemon alloc] initWithMachServiceName:KTY_NTFSD_MACH_SERVICE];
    });
    return instance;
}

- (instancetype)initWithMachServiceName:(nullable NSString *)serviceName {
    self = [super init];
    if (self) {
        _machServiceName = [serviceName copy];
        _autoMountEnabled = YES;
        _startTime = time(NULL);
        _mountedVolumes = [NSMutableDictionary dictionary];
        _detectedDisks = [NSMutableDictionary dictionary];
        _autoMountTargets = [NSMutableDictionary dictionary];
        _daSession = NULL;
        if (serviceName != nil) {
            [self loadPreferences];
        }
    }
    return self;
}

- (BOOL)startWithEndpoint:(NSXPCListenerEndpoint * _Nullable * _Nullable)outEndpoint
                    error:(NSError **)error {
    @synchronized (self) {
        _startTime = time(NULL);

        if (self.machServiceName) {
            _listener = [[NSXPCListener alloc] initWithMachServiceName:self.machServiceName];
        } else {
            _listener = [NSXPCListener anonymousListener];
        }

        if (!_listener) {
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{NSLocalizedDescriptionKey: @"Failed to create XPC listener"}];
            }
            return NO;
        }

        _listener.delegate = self;
        [_listener resume];

        if (outEndpoint) {
            *outEndpoint = _listener.endpoint;
        }

        /* Initialize DiskArbitration Session */
        _daSession = DASessionCreate(kCFAllocatorDefault);
        if (_daSession) {
            _scheduledRunLoop = CFRunLoopGetCurrent();
            CFRetain(_scheduledRunLoop);
            DASessionScheduleWithRunLoop(_daSession, _scheduledRunLoop, kCFRunLoopDefaultMode);
            DARegisterDiskAppearedCallback(_daSession, NULL, KTYDiskAppearedCallback, (__bridge void *)self);
            DARegisterDiskDisappearedCallback(_daSession, NULL, KTYDiskDisappearedCallback, (__bridge void *)self);
            DARegisterDiskMountApprovalCallback(_daSession, NULL, KTYDiskMountApprovalCallback, (__bridge void *)self);
        }

        return YES;
    }
}

- (void)stop {
    @synchronized (self) {
        if (_listener) {
            [_listener suspend];
            [_listener invalidate];
            _listener = nil;
        }

        /* Unmount all active mounts gracefully */
        NSArray<NSString *> *allKeys = [self.mountedVolumes.allKeys copy];
        for (NSString *key in allKeys) {
            KTYMountedVolumeInfo *info = self.mountedVolumes[key];
            if (info.ktyVolume) {
                [info.ktyVolume cleanup];
            }
        }
        [self.mountedVolumes removeAllObjects];

        if (_daSession) {
            if (_scheduledRunLoop) {
                DASessionUnscheduleFromRunLoop(_daSession, _scheduledRunLoop, kCFRunLoopDefaultMode);
                CFRelease(_scheduledRunLoop);
                _scheduledRunLoop = NULL;
            }
            CFRelease(_daSession);
            _daSession = NULL;
        }
    }
}

- (void)dealloc {
    [self stop];
}

#pragma mark - DiskArbitration Management

- (void)registerDiskAppeared:(NSString *)bsdName description:(NSDictionary *)desc {
    if (!bsdName) return;
    @synchronized (self) {
        self.detectedDisks[bsdName] = desc ?: @{};
    }
}

- (void)registerDiskDisappeared:(NSString *)bsdName {
    if (!bsdName) return;
    @synchronized (self) {
        [self.detectedDisks removeObjectForKey:bsdName];
        KTYMountedVolumeInfo *info = self.mountedVolumes[bsdName];
        if (info) {
            if (info.ktyVolume) {
                [info.ktyVolume cleanup];
            }
            [self.mountedVolumes removeObjectForKey:bsdName];
        }
    }
}

- (nullable DADissenterRef)evaluateMountApprovalForDiskDescription:(nullable NSDictionary *)dict {
    if (!dict) return NULL;
    @synchronized (self) {
        if (!self.autoMountEnabled) {
            return NULL;
        }

        NSString *content = dict[(NSString *)kDADiskDescriptionMediaContentKey];
        NSString *type = dict[(NSString *)kDADiskDescriptionVolumeTypeKey];

        BOOL isNTFS = NO;
        if (content && ([content isEqualToString:@"Windows_NTFS"] ||
                        [content isEqualToString:@"EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"])) {
            isNTFS = YES;
        }
        if (type && [type isEqualToString:@"ntfs"]) {
            isNTFS = YES;
        }

        if (isNTFS) {
            NSString *bsdName = dict[(NSString *)kDADiskDescriptionMediaBSDNameKey];
            NSString *volName = dict[(NSString *)kDADiskDescriptionVolumeNameKey];
            NSString *volUUID = [dict[(NSString *)kDADiskDescriptionMediaUUIDKey] description];

            NSDictionary *rule = nil;
            if (volName && self.autoMountTargets[volName]) rule = self.autoMountTargets[volName];
            if (!rule && bsdName && self.autoMountTargets[bsdName]) rule = self.autoMountTargets[bsdName];
            if (!rule && volUUID && self.autoMountTargets[volUUID]) rule = self.autoMountTargets[volUUID];

            if (rule && [rule[@"enabled"] boolValue] == NO) {
                return NULL; /* User explicitly disabled auto-mounting for this volume */
            }

            /* Dissents standard read-only kernel mount, claiming for kty-ntfs */
            DADissenterRef dissenter = DADissenterCreate(
                kCFAllocatorDefault,
                kDAReturnBusy,
                CFSTR("Claimed by knowthankyew NTFS engine (kty-ntfs)")
            );
            return dissenter;
        }

        return NULL;
    }
}

- (nullable DADissenterRef)evaluateMountApprovalForDisk:(nullable DADiskRef)disk {
    if (!disk) return NULL;
    @synchronized (self) {
        if (!self.autoMountEnabled) {
            return NULL;
        }

        CFDictionaryRef desc = DADiskCopyDescription(disk);
        if (!desc) return NULL;
        NSDictionary *dict = (__bridge_transfer NSDictionary *)desc;
        return [self evaluateMountApprovalForDiskDescription:dict];
    }
}

#pragma mark - Metrics Aggregation

- (uint64_t)totalSuppressedMetadataOperations {
    @synchronized (self) {
        uint64_t count = 0;
        for (KTYMountedVolumeInfo *info in self.mountedVolumes.allValues) {
            if (info.ktyVolume) {
                count += info.ktyVolume.suppressedMetadataOperations;
            }
        }
        return count;
    }
}

- (uint64_t)totalTransactions {
    @synchronized (self) {
        uint64_t count = 0;
        for (KTYMountedVolumeInfo *info in self.mountedVolumes.allValues) {
            if (info.ktyVolume) {
                count += info.ktyVolume.activeTransactions;
            }
        }
        return count;
    }
}

- (uint64_t)totalBytesWritten {
    @synchronized (self) {
        uint64_t bytes = 0;
        for (KTYMountedVolumeInfo *info in self.mountedVolumes.allValues) {
            if (info.ktyVolume) {
                bytes += info.ktyVolume.totalBytesWritten;
            }
        }
        return bytes;
    }
}

#pragma mark - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    (void)listener;
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(KTYDaemonProtocol)];
    newConnection.exportedObject = self;
    [newConnection resume];
    return YES;
}

#pragma mark - KTYDaemonProtocol Implementation

- (void)getStatusWithReply:(void (^)(NSDictionary * _Nullable status, NSError * _Nullable error))reply {
    @synchronized (self) {
        time_t now = time(NULL);
        uint64_t uptime = (now >= self.startTime) ? (uint64_t)(now - self.startTime) : 0;

        NSDictionary *status = @{
            @"daemon_version": @"0.1.0",
            @"pid": @(getpid()),
            @"uptime_seconds": @(uptime),
            @"active_mounts_count": @(self.mountedVolumes.count),
            @"detected_disks_count": @(self.detectedDisks.count),
            @"total_transactions": @([self totalTransactions]),
            @"total_bytes_written": @([self totalBytesWritten]),
            @"suppressed_metadata_operations": @([self totalSuppressedMetadataOperations]),
            @"forensic_hygiene_mode": @"STRICT (Host metadata suppressed by default)",
            @"auto_mount_enabled": @(self.autoMountEnabled)
        };
        reply(status, nil);
    }
}

static NSString *KTYDetermineFileSystemType(NSDictionary *desc) {
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

- (void)listDisksWithReply:(void (^)(NSArray<NSDictionary *> * _Nullable disks, NSError * _Nullable error))reply {
    @synchronized (self) {
        NSMutableArray<NSDictionary *> *list = [NSMutableArray array];

        /* Include currently mounted volumes (managed by kty-ntfs) */
        for (KTYMountedVolumeInfo *info in self.mountedVolumes.allValues) {
            NSMutableDictionary *d = [[info toDictionary] mutableCopy];
            d[@"is_mounted"] = @YES;
            d[@"kty_managed"] = @YES;
            d[@"fs_type"] = info.volumeType ?: @"NTFS";
            if (self.detectedDisks[info.bsdName]) {
                NSDictionary *rawDesc = self.detectedDisks[info.bsdName];
                if (rawDesc[(NSString *)kDADiskDescriptionMediaSizeKey]) {
                    d[@"media_size"] = rawDesc[(NSString *)kDADiskDescriptionMediaSizeKey];
                }
            }
            [list addObject:d];
        }

        /* Include detected unmounted or OS-mounted disks */
        for (NSString *bsd in self.detectedDisks) {
            if (self.mountedVolumes[bsd]) continue;
            NSDictionary *rawDesc = self.detectedDisks[bsd];
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"bsd_name"] = bsd;
            d[@"device_node"] = [NSString stringWithFormat:@"/dev/%@", bsd];
            d[@"volume_name"] = rawDesc[(NSString *)kDADiskDescriptionVolumeNameKey] ?: @"";
            d[@"media_size"] = rawDesc[(NSString *)kDADiskDescriptionMediaSizeKey] ?: @0;
            d[@"volume_uuid"] = rawDesc[(NSString *)kDADiskDescriptionMediaUUIDKey] ? [rawDesc[(NSString *)kDADiskDescriptionMediaUUIDKey] description] : @"";
            
            NSString *fsType = KTYDetermineFileSystemType(rawDesc);
            d[@"fs_type"] = fsType;
            d[@"volume_type"] = fsType;

            BOOL isMounted = (rawDesc[(NSString *)kDADiskDescriptionVolumePathKey] != nil);
            d[@"is_mounted"] = @(isMounted);
            d[@"kty_managed"] = @NO;
            if (isMounted) {
                NSURL *pathURL = rawDesc[(NSString *)kDADiskDescriptionVolumePathKey];
                NSString *mPoint = [pathURL respondsToSelector:@selector(path)] ? pathURL.path : [pathURL description];
                d[@"mount_point"] = mPoint ?: @"";
            } else {
                d[@"mount_point"] = @"";
            }

            d[@"read_only"] = @NO;
            d[@"allow_system_metadata"] = @NO;
            [list addObject:d];
        }

        /* Sort consistently by BSD device name (e.g. disk0, disk0s1, disk0s2, disk1, disk1s1...) */
        [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSString *bsdA = a[@"bsd_name"] ?: @"";
            NSString *bsdB = b[@"bsd_name"] ?: @"";
            return [bsdA localizedStandardCompare:bsdB];
        }];

        reply(list, nil);
    }
}

- (void)mountDevice:(NSString *)deviceBSDName
         targetPath:(nullable NSString *)targetPath
           readOnly:(BOOL)readOnly
allowSystemMetadata:(BOOL)allowSystemMetadata
          withReply:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!deviceBSDName || deviceBSDName.length == 0) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey: @"Device BSD name required"}]);
            return;
        }

        NSString *bsd = [deviceBSDName stringByReplacingOccurrencesOfString:@"/dev/" withString:@""];
        if (self.mountedVolumes[bsd]) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EEXIST userInfo:@{NSLocalizedDescriptionKey: @"Device already mounted"}]);
            return;
        }

        NSDictionary *rawDesc = self.detectedDisks[bsd];

        /* Check Fast Startup & safety preflight if write mount is requested */
        if (!readOnly) {
            kty_safety_report_t report;
            NSString *checkTarget = [NSString stringWithFormat:@"/dev/%@", bsd];
            if (rawDesc && rawDesc[(NSString *)kDADiskDescriptionVolumePathKey]) {
                NSURL *mUrl = rawDesc[(NSString *)kDADiskDescriptionVolumePathKey];
                NSString *mPath = [mUrl respondsToSelector:@selector(path)] ? mUrl.path : [mUrl description];
                if (mPath.length > 0) {
                    checkTarget = mPath;
                }
            }

            int sRc = kty_check_volume_safety(checkTarget.UTF8String, &report);
            if (sRc == 0 && (!report.safe_for_write || report.is_hibernated || report.metadata_cached)) {
                char guidanceBuf[2048] = {0};
                NSString *volName = rawDesc[(NSString *)kDADiskDescriptionVolumeNameKey] ?: bsd;
                kty_format_fast_startup_guidance(volName.UTF8String, guidanceBuf, sizeof(guidanceBuf));

                NSDictionary *userInfo = @{
                    NSLocalizedDescriptionKey: @"Windows Fast Startup (Hibernation) is active. Write access blocked to prevent Windows filesystem corruption.",
                    @"KTYFastStartupActive": @YES,
                    @"KTYGuidance": [NSString stringWithUTF8String:guidanceBuf],
                    @"status_summary": [NSString stringWithUTF8String:report.status_summary]
                };
                reply(nil, [NSError errorWithDomain:@"com.knowthankyew.kty-ntfs.safety" code:EPERM userInfo:userInfo]);
                return;
            }
        }

        /* If macOS default driver has this device mounted read-only, safely unmount it first */
        if (rawDesc && rawDesc[(NSString *)kDADiskDescriptionVolumePathKey]) {
            if (self->_daSession) {
                DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, self->_daSession, bsd.UTF8String);
                if (disk) {
                    DADiskUnmount(disk, kDADiskUnmountOptionDefault, NULL, NULL);
                    CFRelease(disk);
                }
            }
        }

        NSString *mountPoint = targetPath;
        if (!mountPoint || mountPoint.length == 0) {
            NSString *vName = rawDesc[(NSString *)kDADiskDescriptionVolumeNameKey];
            if (vName && vName.length > 0) {
                mountPoint = [NSString stringWithFormat:@"/Volumes/%@", vName];
            } else {
                mountPoint = [NSString stringWithFormat:@"/Volumes/%@", bsd];
            }
        }

        KTYMountedVolumeInfo *info = [[KTYMountedVolumeInfo alloc] init];
        info.bsdName = bsd;
        info.devicePath = [NSString stringWithFormat:@"/dev/%@", bsd];
        info.mountPoint = mountPoint;
        info.volumeName = rawDesc[(NSString *)kDADiskDescriptionVolumeNameKey] ?: bsd;
        info.volumeUUID = [[NSUUID UUID] UUIDString];
        info.readOnly = readOnly;
        info.allowSystemMetadata = allowSystemMetadata;
        info.mountTime = time(NULL);

        self.mountedVolumes[bsd] = info;

        reply([info toDictionary], nil);
    }
}

- (void)unmountTarget:(NSString *)targetPathOrBSD
            withReply:(void (^)(BOOL success, NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!targetPathOrBSD || targetPathOrBSD.length == 0) {
            reply(NO, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey: @"Target required"}]);
            return;
        }

        NSString *cleanTarget = [targetPathOrBSD stringByReplacingOccurrencesOfString:@"/dev/" withString:@""];
        NSString *stdTarget = [targetPathOrBSD stringByStandardizingPath];
        NSString *foundKey = nil;

        for (NSString *key in self.mountedVolumes) {
            KTYMountedVolumeInfo *info = self.mountedVolumes[key];
            NSString *stdMount = [info.mountPoint stringByStandardizingPath];
            if ([info.bsdName isEqualToString:cleanTarget] ||
                [info.mountPoint isEqualToString:targetPathOrBSD] ||
                [stdMount isEqualToString:stdTarget]) {
                foundKey = key;
                break;
            }
        }

        if (!foundKey) {
            reply(NO, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:@{NSLocalizedDescriptionKey: @"Mount target not found"}]);
            return;
        }

        KTYMountedVolumeInfo *info = self.mountedVolumes[foundKey];
        if (info.ktyVolume) {
            [info.ktyVolume synchronizeWithFlags:0 replyHandler:^(NSError * _Nullable err) {
                (void)err;
            }];
            [info.ktyVolume cleanup];
        }

        [self.mountedVolumes removeObjectForKey:foundKey];
        reply(YES, nil);
    }
}

- (void)getConfigWithReply:(void (^)(NSDictionary * _Nullable config, NSError * _Nullable error))reply {
    @synchronized (self) {
        NSDictionary *cfg = @{
            @"auto_mount_enabled": @(self.autoMountEnabled),
            @"auto_mount_targets": [self.autoMountTargets copy] ?: @{},
            @"preferences_path": KTYPreferencesFilePath
        };
        reply(cfg, nil);
    }
}

- (void)setGlobalAutoMountEnabled:(BOOL)enabled
                        withReply:(void (^)(BOOL success, NSError * _Nullable error))reply {
    @synchronized (self) {
        self.autoMountEnabled = enabled;
        [self savePreferences];
        reply(YES, nil);
    }
}

- (void)setAutoMountTarget:(NSString *)volumeTarget
                   enabled:(BOOL)enabled
                  readOnly:(BOOL)readOnly
                 withReply:(void (^)(BOOL success, NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!volumeTarget || volumeTarget.length == 0) {
            reply(NO, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey: @"Volume target required"}]);
            return;
        }

        self.autoMountTargets[volumeTarget] = @{
            @"target": volumeTarget,
            @"enabled": @(enabled),
            @"read_only": @(readOnly)
        };
        [self savePreferences];
        reply(YES, nil);
    }
}

- (void)checkSafetyForTarget:(NSString *)target
                   withReply:(void (^)(NSDictionary * _Nullable report, NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!target || target.length == 0) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey: @"Target required"}]);
            return;
        }

        NSString *bsd = [target stringByReplacingOccurrencesOfString:@"/dev/" withString:@""];
        NSDictionary *rawDesc = self.detectedDisks[bsd];
        NSString *checkTarget = target;
        if (rawDesc && rawDesc[(NSString *)kDADiskDescriptionVolumePathKey]) {
            NSURL *mUrl = rawDesc[(NSString *)kDADiskDescriptionVolumePathKey];
            NSString *mPath = [mUrl respondsToSelector:@selector(path)] ? mUrl.path : [mUrl description];
            if (mPath.length > 0) {
                checkTarget = mPath;
            }
        }

        kty_safety_report_t rep;
        int rc = kty_check_volume_safety(checkTarget.UTF8String, &rep);
        if (rc < 0) {
            NSString *errMsg = [NSString stringWithUTF8String:rep.status_summary] ?: @"Safety check failed";
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:(errno != 0 ? errno : EIO) userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
            return;
        }

        char guidanceBuf[2048] = {0};
        NSString *vName = rawDesc[(NSString *)kDADiskDescriptionVolumeNameKey] ?: target;
        kty_format_fast_startup_guidance(vName.UTF8String, guidanceBuf, sizeof(guidanceBuf));

        NSDictionary *res = @{
            @"target": target,
            @"volume_name": [NSString stringWithUTF8String:rep.volume_name] ?: @"",
            @"has_hiberfile": @(rep.has_hiberfile),
            @"is_hibernated": @(rep.is_hibernated),
            @"is_dirty": @(rep.is_dirty),
            @"metadata_cached": @(rep.metadata_cached),
            @"safe_for_write": @(rep.safe_for_write),
            @"status_summary": [NSString stringWithUTF8String:rep.status_summary] ?: @"",
            @"guidance": [NSString stringWithUTF8String:guidanceBuf] ?: @""
        };
        reply(res, nil);
    }
}

- (void)listDirectoryOnDevice:(NSString *)deviceBSDName
                         path:(NSString *)path
                    withReply:(void (^)(NSArray<NSDictionary *> * _Nullable entries, NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!deviceBSDName || deviceBSDName.length == 0) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey: @"Device name required"}]);
            return;
        }

        NSString *devPath = nil;
        NSString *bsd = nil;
        if ([deviceBSDName hasPrefix:@"/"]) {
            devPath = deviceBSDName;
            if ([deviceBSDName hasPrefix:@"/dev/"]) {
                bsd = [deviceBSDName substringFromIndex:5];
            } else {
                bsd = [deviceBSDName lastPathComponent];
            }
        } else {
            bsd = deviceBSDName;
            devPath = [NSString stringWithFormat:@"/dev/%@", bsd];
        }

        kty_dir_listing_t listing;
        int rc = kty_transfer_list_dir(devPath.UTF8String, path.UTF8String ?: "/", &listing);
        if (rc < 0) {
            int err = -rc;
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:strerror(err)] ?: @"Directory listing failed"}]);
            return;
        }

        NSMutableArray<NSDictionary *> *res = [NSMutableArray arrayWithCapacity:listing.count];
        for (size_t i = 0; i < listing.count; i++) {
            [res addObject:@{
                @"name": [NSString stringWithUTF8String:listing.entries[i].name] ?: @"",
                @"is_directory": @(listing.entries[i].is_directory),
                @"size": @(listing.entries[i].size)
            }];
        }
        kty_transfer_free_listing(&listing);
        reply(res, nil);
    }
}

- (void)copyFileToNTFS:(NSString *)deviceBSDName
            sourcePath:(NSString *)sourcePath
       destinationPath:(NSString *)destinationPath
   allowSystemMetadata:(BOOL)allowSystemMetadata
             withReply:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!deviceBSDName || !sourcePath || !destinationPath) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey: @"Invalid arguments"}]);
            return;
        }

        NSString *devPath = nil;
        NSString *bsd = nil;
        if ([deviceBSDName hasPrefix:@"/"]) {
            devPath = deviceBSDName;
            if ([deviceBSDName hasPrefix:@"/dev/"]) {
                bsd = [deviceBSDName substringFromIndex:5];
            } else {
                bsd = [deviceBSDName lastPathComponent];
            }
        } else {
            bsd = deviceBSDName;
            devPath = [NSString stringWithFormat:@"/dev/%@", bsd];
        }

        /* Check Fast Startup safety */
        kty_safety_report_t safety;
        if (kty_check_volume_safety(devPath.UTF8String, &safety) == 0) {
            if (!safety.safe_for_write || safety.is_hibernated || safety.metadata_cached || safety.is_dirty) {
                char guidanceBuf[2048] = {0};
                NSString *volName = self.detectedDisks[bsd][(NSString *)kDADiskDescriptionVolumeNameKey] ?: bsd;
                kty_format_fast_startup_guidance(volName.UTF8String, guidanceBuf, sizeof(guidanceBuf));

                NSDictionary *userInfo = @{
                    NSLocalizedDescriptionKey: @"Windows Fast Startup is active. Write operation rejected to protect filesystem integrity.",
                    @"KTYFastStartupActive": @YES,
                    @"KTYGuidance": [NSString stringWithUTF8String:guidanceBuf] ?: @"",
                    @"status_summary": [NSString stringWithUTF8String:safety.status_summary] ?: @""
                };
                reply(nil, [NSError errorWithDomain:@"com.knowthankyew.kty-ntfs.safety" code:EPERM userInfo:userInfo]);
                return;
            }
        }

        /* If macOS default driver has this device mounted read-only, safely unmount it before writing */
        NSDictionary *rawDesc = self.detectedDisks[bsd];
        if (rawDesc && rawDesc[(NSString *)kDADiskDescriptionVolumePathKey]) {
            if (self->_daSession) {
                DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, self->_daSession, bsd.UTF8String);
                if (disk) {
                    DADiskUnmount(disk, kDADiskUnmountOptionDefault, NULL, NULL);
                    CFRelease(disk);
                }
            }
        }

        char sha256_hex[65] = {0};
        char blake3_hex[65] = {0};
        int rc = -EBUSY;
        for (int attempt = 0; attempt < 15; attempt++) {
            rc = kty_transfer_copy_to_ntfs(
                devPath.UTF8String,
                sourcePath.UTF8String,
                destinationPath.UTF8String,
                allowSystemMetadata,
                sha256_hex,
                blake3_hex
            );
            if (rc != -EBUSY) {
                break;
            }
            usleep(100 * 1000); /* Wait 100ms for kernel unmount to release device locks */
        }

        if (rc < 0) {
            int err = -rc;
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:strerror(err)] ?: @"File copy to NTFS failed"}]);
            return;
        }

        NSDictionary *res = @{
            @"device": bsd,
            @"source": sourcePath,
            @"destination": destinationPath,
            @"sha256": [NSString stringWithUTF8String:sha256_hex] ?: @"",
            @"blake3": [NSString stringWithUTF8String:blake3_hex] ?: @"",
            @"status": @"success"
        };
        reply(res, nil);
    }
}

- (void)copyFileFromNTFS:(NSString *)deviceBSDName
              sourcePath:(NSString *)sourcePath
         destinationPath:(NSString *)destinationPath
               withReply:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!deviceBSDName || !sourcePath || !destinationPath) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey: @"Invalid arguments"}]);
            return;
        }

        NSString *devPath = nil;
        NSString *bsd = nil;
        if ([deviceBSDName hasPrefix:@"/"]) {
            devPath = deviceBSDName;
            if ([deviceBSDName hasPrefix:@"/dev/"]) {
                bsd = [deviceBSDName substringFromIndex:5];
            } else {
                bsd = [deviceBSDName lastPathComponent];
            }
        } else {
            bsd = deviceBSDName;
            devPath = [NSString stringWithFormat:@"/dev/%@", bsd];
        }

        int rc = kty_transfer_copy_from_ntfs(devPath.UTF8String, sourcePath.UTF8String, destinationPath.UTF8String);
        if (rc < 0) {
            int err = -rc;
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:strerror(err)] ?: @"File copy from NTFS failed"}]);
            return;
        }

        NSDictionary *res = @{
            @"device": bsd,
            @"source": sourcePath,
            @"destination": destinationPath,
            @"status": @"success"
        };
        reply(res, nil);
    }
}

- (void)stopDaemonWithReply:(void (^)(BOOL success, NSError * _Nullable error))reply {
    reply(YES, nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stop];
        CFRunLoopStop(CFRunLoopGetMain());
    });
}

@end
