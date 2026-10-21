#import "KTYVolume.h"
#import <sys/stat.h>

#ifndef _WINDEF_H
#define _WINDEF_H
#endif

#include "ntfs-3g/types.h"
#include "ntfs-3g/layout.h"
#include "ntfs-3g/bootsect.h"
#include "ntfs-3g/device.h"

static s64 kty_fskit_read_cb(void *ctx, void *buf, s64 count, s64 offset) {
    FSBlockDeviceResource *res = (__bridge FSBlockDeviceResource *)ctx;
    NSError *error = nil;
    size_t read_bytes = [res readInto:buf startingAt:(off_t)offset length:(size_t)count error:&error];
    if (error) {
        return -1;
    }
    return (s64)read_bytes;
}

static s64 kty_fskit_write_cb(void *ctx, const void *buf, s64 count, s64 offset) {
    FSBlockDeviceResource *res = (__bridge FSBlockDeviceResource *)ctx;
    NSError *error = nil;
    size_t written = [res writeFrom:(void *)buf startingAt:(off_t)offset length:(size_t)count error:&error];
    if (error) {
        return -1;
    }
    return (s64)written;
}

static int kty_fskit_sync_cb(void *ctx) {
    FSBlockDeviceResource *res = (__bridge FSBlockDeviceResource *)ctx;
    NSError *error = nil;
    BOOL ok = [res metadataFlushWithError:&error];
    return (ok && !error) ? 0 : -1;
}

@interface KTYVolume ()
@property (nonatomic, strong) FSBlockDeviceResource *blockResource;
@property (nonatomic, assign) struct ntfs_device *ntfsDevice;
@end

@implementation KTYVolume

- (instancetype)initWithResource:(FSBlockDeviceResource *)resource
                        volumeID:(FSVolumeIdentifier *)volumeID
                      volumeName:(FSFileName *)volumeName
                        readOnly:(BOOL)readOnly {
    self = [super initWithVolumeID:volumeID volumeName:volumeName];
    if (self) {
        _blockResource = resource;
        _readOnly = readOnly;
        _isMounted = NO;

        s64 total_size = (s64)(resource.blockCount * resource.blockSize);
        int sector_size = (int)(resource.physicalBlockSize > 0 ? resource.physicalBlockSize : 512);

        _ntfsDevice = kty_device_alloc_resource(
            [resource.BSDName UTF8String] ?: "ntfs_block_device",
            (__bridge void *)resource,
            kty_fskit_read_cb,
            kty_fskit_write_cb,
            kty_fskit_sync_cb,
            total_size,
            sector_size,
            readOnly
        );
    }
    return self;
}

- (void)cleanup {
    if (_ntfsDevice) {
        if (_ntfsDevice->d_ops && NDevOpen(_ntfsDevice)) {
            _ntfsDevice->d_ops->close(_ntfsDevice);
        }
        kty_device_free(_ntfsDevice);
        _ntfsDevice = NULL;
    }
    _isMounted = NO;
}

- (void)dealloc {
    [self cleanup];
}

#pragma mark - FSVolumePathConfOperations

- (NSInteger)maximumLinkCount {
    return 1024;
}

- (NSInteger)maximumNameLength {
    return 255;
}

- (BOOL)restrictsOwnershipChanges {
    return YES;
}

- (BOOL)truncatesLongNames {
    return NO;
}

#pragma mark - FSVolumeOperations

- (FSVolumeSupportedCapabilities *)supportedVolumeCapabilities {
    FSVolumeSupportedCapabilities *caps = [[FSVolumeSupportedCapabilities alloc] init];
    caps.supportsPersistentObjectIDs = YES;
    caps.supportsJournal = YES;
    caps.supportsActiveJournal = YES;
    caps.supportsHardLinks = YES;
    caps.supportsSymbolicLinks = YES;
    return caps;
}

- (FSStatFSResult *)volumeStatistics {
    FSStatFSResult *stats = [[FSStatFSResult alloc] initWithFileSystemTypeName:@"ntfs"];
    stats.blockSize = 4096;
    stats.ioSize = 65536;

    uint64_t total_blocks = self.blockResource ? self.blockResource.blockCount : 0;
    uint64_t blk_size = (self.blockResource && self.blockResource.blockSize > 0) ? self.blockResource.blockSize : 512;

    stats.totalBlocks = total_blocks;
    stats.freeBlocks = total_blocks / 2;
    stats.availableBlocks = stats.freeBlocks;
    stats.usedBlocks = total_blocks - stats.freeBlocks;

    stats.totalBytes = total_blocks * blk_size;
    stats.freeBytes = stats.freeBlocks * stats.blockSize;
    stats.availableBytes = stats.freeBytes;
    stats.usedBytes = stats.totalBytes - stats.freeBytes;
    return stats;
}

- (void)activateWithOptions:(FSTaskOptions *)options
              replyHandler:(void (^)(FSItem * _Nullable rootItem,
                                     NSError * _Nullable err))reply {
    (void)options;
    KTYItem *root = [KTYItem rootDirectoryItem];
    reply(root, nil);
}

- (void)deactivateWithOptions:(FSDeactivateOptions)options
                replyHandler:(void (^)(NSError * _Nullable err))reply {
    (void)options;
    [self cleanup];
    reply(nil);
}

- (void)mountWithOptions:(FSTaskOptions *)options
           replyHandler:(void(^)(NSError * _Nullable error))reply {
    (void)options;
    if (!self.ntfsDevice) {
        reply([NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]);
        return;
    }

    int flags = self.readOnly ? O_RDONLY : O_RDWR;
    if (self.ntfsDevice->d_ops && self.ntfsDevice->d_ops->open(self.ntfsDevice, flags) != 0) {
        reply([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        return;
    }

    self.isMounted = YES;
    reply(nil);
}

- (void)unmountWithReplyHandler:(void(^)(void))reply {
    [self cleanup];
    reply();
}

- (void)synchronizeWithFlags:(FSSyncFlags)flags
               replyHandler:(void(^)(NSError * _Nullable error))reply {
    (void)flags;
    if (self.ntfsDevice) {
        kty_device_full_sync(self.ntfsDevice);
    }
    reply(nil);
}

- (void)getAttributes:(FSItemGetAttributesRequest *)desiredAttributes
              ofItem:(FSItem *)item
        replyHandler:(void(^)(FSItemAttributes * _Nullable attributes,
                              NSError * _Nullable error))reply {
    (void)desiredAttributes;
    FSItemAttributes *attrs = [[FSItemAttributes alloc] init];

    if ([item isKindOfClass:[KTYItem class]]) {
        [(KTYItem *)item populateAttributes:attrs];
    } else {
        /* Default to root directory attributes */
        attrs.fileID = FSItemIDRootDirectory;
        attrs.type = FSItemTypeDirectory;
        attrs.size = 4096;
        attrs.allocSize = 4096;
        attrs.mode = S_IFDIR | 0755;
        attrs.uid = getuid();
        attrs.gid = getgid();
        attrs.linkCount = 2;
    }

    reply(attrs, nil);
}

- (void)setAttributes:(FSItemSetAttributesRequest *)newAttributes
              onItem:(FSItem *)item
        replyHandler:(void(^)(FSItemAttributes * _Nullable attributes,
                              NSError * _Nullable error))reply {
    (void)newAttributes;
    (void)item;
    if (self.readOnly) {
        reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
        return;
    }
    FSItemAttributes *attrs = [[FSItemAttributes alloc] init];
    reply(attrs, nil);
}

- (void)lookupItemNamed:(FSFileName *)name
           inDirectory:(FSItem *)directory
          replyHandler:(void(^)(FSItem * _Nullable theItem,
                                FSFileName * _Nullable itemName,
                                NSError * _Nullable error))reply {
    (void)directory;
    NSString *lookupName = name.string;
    if ([lookupName isEqualToString:@"."] || [lookupName isEqualToString:@"/"]) {
        KTYItem *root = [KTYItem rootDirectoryItem];
        reply(root, name, nil);
        return;
    }

    /* Not found in scaffold until directory indexes are parsed */
    reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil]);
}

- (void)reclaimItem:(FSItem *)item
      replyHandler:(void(^)(NSError * _Nullable error))reply {
    (void)item;
    reply(nil);
}

- (void)readSymbolicLink:(FSItem *)item
           replyHandler:(void(^)(FSFileName * _Nullable contents,
                                 NSError * _Nullable error))reply {
    (void)item;
    reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
}

- (void)createItemNamed:(FSFileName *)name
                  type:(FSItemType)type
           inDirectory:(FSItem *)directory
            attributes:(FSItemSetAttributesRequest *)newAttributes
          replyHandler:(void(^)(FSItem * _Nullable newItem,
                                FSFileName * _Nullable newItemName,
                                NSError * _Nullable error))reply {
    (void)name;
    (void)type;
    (void)directory;
    (void)newAttributes;
    reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
}

- (void)createSymbolicLinkNamed:(FSFileName *)name
                   inDirectory:(FSItem *)directory
                    attributes:(FSItemSetAttributesRequest *)newAttributes
                  linkContents:(FSFileName *)contents
                  replyHandler:(void(^)(FSItem * _Nullable newItem,
                                        FSFileName * _Nullable newItemName,
                                        NSError * _Nullable error))reply {
    (void)name;
    (void)directory;
    (void)newAttributes;
    (void)contents;
    reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
}

- (void)createLinkToItem:(FSItem *)item
                  named:(FSFileName *)name
            inDirectory:(FSItem *)directory
           replyHandler:(void(^)(FSFileName * _Nullable linkName,
                                 NSError * _Nullable error))reply {
    (void)item;
    (void)name;
    (void)directory;
    reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
}

- (void)removeItem:(FSItem *)item
            named:(FSFileName *)name
    fromDirectory:(FSItem *)directory
     replyHandler:(void(^)(NSError * _Nullable error))reply {
    (void)item;
    (void)name;
    (void)directory;
    reply([NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
}

- (void)renameItem:(FSItem *)item
      inDirectory:(FSItem *)sourceDirectory
            named:(FSFileName *)sourceName
        toNewName:(FSFileName *)destinationName
      inDirectory:(FSItem *)destinationDirectory
         overItem:(FSItem * _Nullable)overItem
     replyHandler:(void(^)(FSFileName * _Nullable newName,
                           NSError * _Nullable error))reply {
    (void)item;
    (void)sourceDirectory;
    (void)sourceName;
    (void)destinationName;
    (void)destinationDirectory;
    (void)overItem;
    reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
}

- (void)enumerateDirectory:(FSItem *)directory
         startingAtCookie:(FSDirectoryCookie)cookie
                 verifier:(FSDirectoryVerifier)verifier
      providingAttributes:(FSItemGetAttributesRequest * _Nullable)attributes
              usingPacker:(FSDirectoryEntryPacker *)packer
             replyHandler:(void(^)(FSDirectoryVerifier currentVerifier,
                                   NSError * _Nullable error))reply {
    (void)directory;
    (void)cookie;
    (void)verifier;
    (void)attributes;

    /* Pack standard directory entries */
    FSFileName *dotName = [[FSFileName alloc] initWithCString:"."];
    [packer packEntryWithName:dotName itemType:FSItemTypeDirectory itemID:FSItemIDRootDirectory nextCookie:1 attributes:nil];

    FSFileName *dotDotName = [[FSFileName alloc] initWithCString:".."];
    [packer packEntryWithName:dotDotName itemType:FSItemTypeDirectory itemID:FSItemIDParentOfRoot nextCookie:2 attributes:nil];

    reply(verifier, nil);
}

#pragma mark - FSVolumeReadWriteOperations

- (void)readFromFile:(FSItem *)item
             offset:(off_t)offset
             length:(size_t)length
         intoBuffer:(FSMutableFileDataBuffer *)buffer
       replyHandler:(void(^)(size_t actuallyRead,
                             NSError * _Nullable error))reply {
    (void)item;
    if (!self.ntfsDevice || !self.ntfsDevice->d_ops) {
        reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]);
        return;
    }

    size_t to_read = (length < buffer.length) ? length : buffer.length;
    s64 res = self.ntfsDevice->d_ops->pread(self.ntfsDevice, [buffer mutableBytes], (s64)to_read, (s64)offset);
    if (res < 0) {
        reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        return;
    }

    reply((size_t)res, nil);
}

- (void)writeContents:(NSData *)contents
               toFile:(FSItem *)item
             atOffset:(off_t)offset
         replyHandler:(void(^)(size_t actuallyWritten,
                               NSError * _Nullable error))reply {
    (void)contents;
    (void)item;
    (void)offset;
    if (self.readOnly) {
        reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
        return;
    }
    reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTSUP userInfo:nil]);
}

@end
