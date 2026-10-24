#import "KTYDaemon.h"
#import <sys/stat.h>
#import <unistd.h>

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
@end

@implementation KTYDaemon

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
        _daSession = NULL;
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
                d[@"mount_point"] = [pathURL respondsToSelector:@selector(path)] ? pathURL.path : [pathURL description];
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

        NSString *mountPoint = targetPath;
        if (!mountPoint || mountPoint.length == 0) {
            mountPoint = [NSString stringWithFormat:@"/Volumes/%@", bsd];
        }

        KTYMountedVolumeInfo *info = [[KTYMountedVolumeInfo alloc] init];
        info.bsdName = bsd;
        info.devicePath = [NSString stringWithFormat:@"/dev/%@", bsd];
        info.mountPoint = mountPoint;
        info.volumeName = bsd;
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

- (void)stopDaemonWithReply:(void (^)(BOOL success, NSError * _Nullable error))reply {
    reply(YES, nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stop];
        CFRunLoopStop(CFRunLoopGetMain());
    });
}

@end
