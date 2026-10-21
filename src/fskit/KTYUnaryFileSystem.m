#import "KTYUnaryFileSystem.h"

#ifndef _WINDEF_H
#define _WINDEF_H
#endif

#include "ntfs-3g/types.h"
#include "ntfs-3g/layout.h"
#include "ntfs-3g/bootsect.h"

@implementation KTYUnaryFileSystem

- (void)probeResource:(FSResource *)resource
         replyHandler:(void(^)(FSProbeResult * _Nullable result,
                               NSError * _Nullable error))reply {
    if (![resource isKindOfClass:[FSBlockDeviceResource class]]) {
        reply([FSProbeResult notRecognizedProbeResult], nil);
        return;
    }

    FSBlockDeviceResource *blockRes = (FSBlockDeviceResource *)resource;
    uint8_t sector_buffer[512] = {0};
    NSError *readError = nil;

    size_t bytes_read = [blockRes readInto:sector_buffer startingAt:0 length:sizeof(sector_buffer) error:&readError];
    if (readError != nil || bytes_read < sizeof(sector_buffer)) {
        reply([FSProbeResult notRecognizedProbeResult], nil);
        return;
    }

    NTFS_BOOT_SECTOR *bs = (NTFS_BOOT_SECTOR *)sector_buffer;
    if (!ntfs_boot_sector_is_ntfs(bs)) {
        reply([FSProbeResult notRecognizedProbeResult], nil);
        return;
    }

    /* Valid NTFS volume identified */
    NSUUID *uuid = [NSUUID UUID];
    FSContainerIdentifier *containerID = [[FSContainerIdentifier alloc] initWithUUID:uuid];
    NSString *volumeName = @"NTFS Volume";

    FSProbeResult *probeResult = [FSProbeResult usableProbeResultWithName:volumeName containerID:containerID];
    reply(probeResult, nil);
}

- (void)loadResource:(FSResource *)resource
             options:(FSTaskOptions *)options
        replyHandler:(void (^)(FSVolume * _Nullable volume,
                               NSError * _Nullable err))reply {
    (void)options;
    if (![resource isKindOfClass:[FSBlockDeviceResource class]]) {
        reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTBLK userInfo:nil]);
        return;
    }

    FSBlockDeviceResource *blockRes = (FSBlockDeviceResource *)resource;
    FSVolumeIdentifier *volumeID = [[FSVolumeIdentifier alloc] initWithUUID:[NSUUID UUID]];
    FSFileName *volumeName = [[FSFileName alloc] initWithString:@"NTFS Volume"];

    BOOL readOnly = NO;
    if (!blockRes.isWritable) {
        readOnly = YES;
    }

    KTYVolume *volume = [[KTYVolume alloc] initWithResource:blockRes
                                                   volumeID:volumeID
                                                 volumeName:volumeName
                                                   readOnly:readOnly];

    reply(volume, nil);
}

- (void)unloadResource:(FSResource *)resource
               options:(FSTaskOptions *)options
          replyHandler:(void (^)(NSError * _Nullable err))reply {
    (void)resource;
    (void)options;
    reply(nil);
}

@end
