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
@property (nonatomic, strong) KTYItem *rootItem;
@property (nonatomic, assign) uint64_t nextItemID;
@property (nonatomic, assign) off_t nextClusterOffset;
@property (nonatomic, assign) off_t totalDeviceSize;
@property (nonatomic, assign) BOOL isDirty;
@property (nonatomic, assign) uint64_t totalBytesWritten;
@property (nonatomic, assign) uint32_t activeTransactions;
@property (nonatomic, assign) uint64_t suppressedMetadataOperations;
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
        _allowSystemMetadata = NO;
        _suppressedMetadataOperations = 0;
        _isMounted = NO;
        _rootItem = [KTYItem rootDirectoryItem];
        _nextItemID = 1000;
        _nextClusterOffset = 32768; /* Start allocations past reserved metadata/boot cluster space */
        _isDirty = NO;
        _totalBytesWritten = 0;
        _activeTransactions = 0;

        s64 total_size = (s64)(resource.blockCount * resource.blockSize);
        _totalDeviceSize = (off_t)total_size;
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
    @synchronized (self) {
        if (_ntfsDevice) {
            if (_isDirty && _ntfsDevice->d_ops && NDevOpen(_ntfsDevice)) {
                kty_device_full_sync(_ntfsDevice);
                _isDirty = NO;
            }
            if (_ntfsDevice->d_ops && NDevOpen(_ntfsDevice)) {
                _ntfsDevice->d_ops->close(_ntfsDevice);
            }
            kty_device_free(_ntfsDevice);
            _ntfsDevice = NULL;
        }
        _isMounted = NO;
        _activeTransactions = 0;
    }
}

- (BOOL)allocateClustersForFile:(KTYItem *)ktyItem
                     neededSize:(uint64_t)neededSize
                          error:(NSError **)error {
    uint64_t neededAlloc = (neededSize + 4095) & ~4095ULL;
    if (neededAlloc == 0) {
        neededAlloc = 4096;
    }

    if (ktyItem.allocatedSize >= neededAlloc && ktyItem.diskOffset > 0) {
        return YES;
    }

    /* Check if current allocation is at the tail of disk allocations */
    if (ktyItem.diskOffset > 0 && (ktyItem.diskOffset + (off_t)ktyItem.allocatedSize) == self.nextClusterOffset) {
        off_t additional = (off_t)(neededAlloc - ktyItem.allocatedSize);
        if (self.totalDeviceSize > 0 && (self.nextClusterOffset + additional) > self.totalDeviceSize) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil];
            return NO;
        }
        self.nextClusterOffset += additional;
        ktyItem.allocatedSize = neededAlloc;
        return YES;
    }

    /* File is not at tail (or has no offset); allocate new contiguous chunk at tail */
    if (self.totalDeviceSize > 0 && (self.nextClusterOffset + (off_t)neededAlloc) > self.totalDeviceSize) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil];
        return NO;
    }

    off_t newOffset = self.nextClusterOffset;
    if (ktyItem.size > 0 && ktyItem.diskOffset > 0 && self.ntfsDevice && self.ntfsDevice->d_ops && NDevOpen(self.ntfsDevice)) {
        size_t copyLen = (size_t)ktyItem.size;
        void *tmpBuf = malloc(copyLen);
        if (!tmpBuf) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
            return NO;
        }
        s64 r = self.ntfsDevice->d_ops->pread(self.ntfsDevice, tmpBuf, (s64)copyLen, (s64)ktyItem.diskOffset);
        if (r > 0) {
            self.ntfsDevice->d_ops->pwrite(self.ntfsDevice, tmpBuf, r, (s64)newOffset);
        }
        free(tmpBuf);
    }

    self.nextClusterOffset += (off_t)neededAlloc;
    ktyItem.diskOffset = newOffset;
    ktyItem.allocatedSize = neededAlloc;
    return YES;
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
    reply(self.rootItem, nil);
}

- (void)deactivateWithOptions:(FSDeactivateOptions)options
                 replyHandler:(void (^)(NSError * _Nullable err))reply {
    (void)options;
    [self cleanup];
    reply(nil);
}

- (void)mountWithOptions:(FSTaskOptions *)options
           replyHandler:(void(^)(NSError * _Nullable error))reply {
    @synchronized (self) {
        if (options && [options.description containsString:@"allow-system-metadata"]) {
            self.allowSystemMetadata = YES;
        }

        if (self.allowSystemMetadata) {
            fprintf(stderr, "[kty-ntfs forensic policy] WARNING: --allow-system-metadata is ENABLED. Host system metadata (.DS_Store, Spotlight, Trashes) is permitted. Volume is NOT forensically clean.\n");
        }

        if (!self.ntfsDevice) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]);
            return;
        }

        int flags = self.readOnly ? O_RDONLY : O_RDWR;
        if (self.ntfsDevice->d_ops && self.ntfsDevice->d_ops->open(self.ntfsDevice, flags) != 0) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
            return;
        }

        if (NDevReadOnly(self.ntfsDevice)) {
            self.readOnly = YES;
        }

        self.isMounted = YES;
        reply(nil);
    }
}

- (void)unmountWithReplyHandler:(void(^)(void))reply {
    [self cleanup];
    reply();
}

- (void)synchronizeWithFlags:(FSSyncFlags)flags
                replyHandler:(void(^)(NSError * _Nullable error))reply {
    (void)flags;
    @synchronized (self) {
        if (self.ntfsDevice) {
            kty_device_full_sync(self.ntfsDevice);
        }
        _isDirty = NO;
        _activeTransactions = 0;
        reply(nil);
    }
}

- (void)getAttributes:(FSItemGetAttributesRequest *)desiredAttributes
               ofItem:(FSItem *)item
         replyHandler:(void(^)(FSItemAttributes * _Nullable attributes,
                               NSError * _Nullable error))reply {
    (void)desiredAttributes;
    @synchronized (self) {
        FSItemAttributes *attrs = [[FSItemAttributes alloc] init];

        if ([item isKindOfClass:[KTYItem class]]) {
            [(KTYItem *)item populateAttributes:attrs];
        } else {
            [self.rootItem populateAttributes:attrs];
        }

        reply(attrs, nil);
    }
}

- (void)setAttributes:(FSItemSetAttributesRequest *)newAttributes
               onItem:(FSItem *)item
         replyHandler:(void(^)(FSItemAttributes * _Nullable attributes,
                               NSError * _Nullable error))reply {
    @synchronized (self) {
        if (self.readOnly) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
            return;
        }

        if (!item || ![item isKindOfClass:[KTYItem class]]) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        KTYItem *ktyItem = (KTYItem *)item;
        if (newAttributes && [newAttributes respondsToSelector:@selector(isValid:)]) {
            if ([newAttributes isValid:FSItemAttributeSize] && ktyItem.itemType == FSItemTypeFile) {
                if (newAttributes.size > ktyItem.allocatedSize) {
                    NSError *allocErr = nil;
                    if (![self allocateClustersForFile:ktyItem neededSize:newAttributes.size error:&allocErr]) {
                        reply(nil, allocErr ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil]);
                        return;
                    }
                }
                [ktyItem truncateToSize:newAttributes.size];
                _isDirty = YES;
                _activeTransactions++;
            }
            if ([newAttributes isValid:FSItemAttributeMode]) {
                ktyItem.mode = newAttributes.mode;
            }
            if ([newAttributes isValid:FSItemAttributeModifyTime]) {
                ktyItem.mtime = newAttributes.modifyTime.tv_sec;
            }
            if ([newAttributes isValid:FSItemAttributeChangeTime]) {
                ktyItem.ctime = newAttributes.changeTime.tv_sec;
            }
        }

        FSItemAttributes *attrs = [[FSItemAttributes alloc] init];
        [ktyItem populateAttributes:attrs];
        reply(attrs, nil);
    }
}

- (void)lookupItemNamed:(FSFileName *)name
            inDirectory:(FSItem *)directory
           replyHandler:(void(^)(FSItem * _Nullable theItem,
                                 FSFileName * _Nullable itemName,
                                 NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!name) {
            reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        NSString *lookupName = name.string;
        if ([lookupName isEqualToString:@"."] || [lookupName isEqualToString:@"/"]) {
            reply(self.rootItem, name, nil);
            return;
        }

        KTYItem *parentDir = (directory && [directory isKindOfClass:[KTYItem class]]) ? (KTYItem *)directory : self.rootItem;
        KTYItem *found = [parentDir childNamed:lookupName];
        if (found) {
            reply(found, name, nil);
            return;
        }

        reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil]);
    }
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
    @synchronized (self) {
        if (self.readOnly) {
            reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
            return;
        }

        if (!name || name.string.length == 0) {
            reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        KTYItem *parentDir = (directory && [directory isKindOfClass:[KTYItem class]]) ? (KTYItem *)directory : self.rootItem;
        if (parentDir.itemType != FSItemTypeDirectory) {
            reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTDIR userInfo:nil]);
            return;
        }

        if ([parentDir childNamed:name.string] != nil) {
            reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EEXIST userInfo:nil]);
            return;
        }

        /* Forensic Hygiene: Intercept and silently drop host system metadata */
        if ([KTYItem isSystemMetadataName:name.string]) {
            if (!self.allowSystemMetadata) {
                _suppressedMetadataOperations++;
                FSItemID itemID = (FSItemID)self.nextItemID++;
                NSString *childPath = [parentDir.path isEqualToString:@"/"] 
                    ? [NSString stringWithFormat:@"/%@", name.string]
                    : [NSString stringWithFormat:@"%@/%@", parentDir.path, name.string];
                uint32_t mode = (type == FSItemTypeDirectory) ? (S_IFDIR | 0755) : (S_IFREG | 0644);
                KTYItem *tombstone = [KTYItem itemWithID:itemID
                                                   name:name.string
                                                   path:childPath
                                                   type:type
                                                   size:0
                                                   mode:mode];
                tombstone.isForensicTombstone = YES;
                tombstone.diskOffset = 0;
                tombstone.allocatedSize = 0;
                [parentDir addChild:tombstone];
                reply(tombstone, name, nil);
                return;
            } else {
                fprintf(stderr, "[kty-ntfs forensic policy] WARNING: Host system metadata modification allowed for '%s'. Volume is NOT forensically clean!\n", name.string.UTF8String);
            }
        }

        FSItemID itemID = (FSItemID)self.nextItemID++;
        NSString *childPath = [parentDir.path isEqualToString:@"/"] 
            ? [NSString stringWithFormat:@"/%@", name.string]
            : [NSString stringWithFormat:@"%@/%@", parentDir.path, name.string];

        BOOL hasAttrs = (newAttributes && [newAttributes respondsToSelector:@selector(isValid:)]);
        uint32_t mode = (type == FSItemTypeDirectory) ? (S_IFDIR | 0755) : (S_IFREG | 0644);
        if (hasAttrs && [newAttributes isValid:FSItemAttributeMode]) {
            mode = newAttributes.mode;
        }

        uint64_t initialSize = (type == FSItemTypeDirectory) ? 4096 : 0;
        KTYItem *newItem = [KTYItem itemWithID:itemID
                                          name:name.string
                                          path:childPath
                                          type:type
                                          size:initialSize
                                          mode:mode];

        if (hasAttrs && [newAttributes isValid:FSItemAttributeUID]) {
            newItem.uid = newAttributes.uid;
        }
        if (hasAttrs && [newAttributes isValid:FSItemAttributeGID]) {
            newItem.gid = newAttributes.gid;
        }

        if (type == FSItemTypeFile) {
            NSError *allocErr = nil;
            if (![self allocateClustersForFile:newItem neededSize:4096 error:&allocErr]) {
                reply(nil, nil, allocErr ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil]);
                return;
            }
        }

        [parentDir addChild:newItem];
        _isDirty = YES;
        _activeTransactions++;

        reply(newItem, name, nil);
    }
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
    int err = self.readOnly ? EROFS : ENOTSUP;
    reply(nil, nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil]);
}

- (void)createLinkToItem:(FSItem *)item
                   named:(FSFileName *)name
             inDirectory:(FSItem *)directory
            replyHandler:(void(^)(FSFileName * _Nullable linkName,
                                  NSError * _Nullable error))reply {
    (void)item;
    (void)name;
    (void)directory;
    int err = self.readOnly ? EROFS : ENOTSUP;
    reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil]);
}

- (void)removeItem:(FSItem *)item
             named:(FSFileName *)name
     fromDirectory:(FSItem *)directory
      replyHandler:(void(^)(NSError * _Nullable error))reply {
    (void)item;
    @synchronized (self) {
        if (self.readOnly) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
            return;
        }

        if (!name || name.string.length == 0) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        KTYItem *parentDir = (directory && [directory isKindOfClass:[KTYItem class]]) ? (KTYItem *)directory : self.rootItem;
        if (parentDir.itemType != FSItemTypeDirectory) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTDIR userInfo:nil]);
            return;
        }

        KTYItem *targetItem = [parentDir childNamed:name.string];
        if (!targetItem) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil]);
            return;
        }

        if (targetItem.isForensicTombstone) {
            _suppressedMetadataOperations++;
            [parentDir removeChildNamed:name.string];
            reply(nil);
            return;
        }

        if (targetItem.itemType == FSItemTypeDirectory && targetItem.children.count > 0) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTEMPTY userInfo:nil]);
            return;
        }

        if (targetItem.diskOffset > 0 && (targetItem.diskOffset + (off_t)targetItem.allocatedSize) == self.nextClusterOffset) {
            self.nextClusterOffset -= (off_t)targetItem.allocatedSize;
        }

        [parentDir removeChildNamed:name.string];
        _isDirty = YES;
        _activeTransactions++;

        reply(nil);
    }
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
    (void)overItem;
    @synchronized (self) {
        if (self.readOnly) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
            return;
        }

        if (!sourceName || sourceName.string.length == 0 ||
            !destinationName || destinationName.string.length == 0) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        KTYItem *srcDir = (sourceDirectory && [sourceDirectory isKindOfClass:[KTYItem class]]) ? (KTYItem *)sourceDirectory : self.rootItem;
        KTYItem *destDir = (destinationDirectory && [destinationDirectory isKindOfClass:[KTYItem class]]) ? (KTYItem *)destinationDirectory : self.rootItem;

        if (srcDir.itemType != FSItemTypeDirectory || destDir.itemType != FSItemTypeDirectory) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTDIR userInfo:nil]);
            return;
        }

        KTYItem *target = [srcDir childNamed:sourceName.string];
        if (!target) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil]);
            return;
        }

        /* Self-rename no-op */
        if (srcDir == destDir && [sourceName.string isEqualToString:destinationName.string]) {
            reply(destinationName, nil);
            return;
        }

        /* Prevent renaming a directory into its own sub-tree */
        if (target.itemType == FSItemTypeDirectory && [destDir.path hasPrefix:target.path]) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        /* Check destination conflict */
        KTYItem *existing = [destDir childNamed:destinationName.string];
        if (existing) {
            if (existing.itemType == FSItemTypeDirectory) {
                if (target.itemType != FSItemTypeDirectory) {
                    reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EISDIR userInfo:nil]);
                    return;
                }
                if (existing.children.count > 0) {
                    reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTEMPTY userInfo:nil]);
                    return;
                }
            } else if (target.itemType == FSItemTypeDirectory) {
                reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTDIR userInfo:nil]);
                return;
            }
            [destDir removeChildNamed:destinationName.string];
        }

        [srcDir removeChildNamed:sourceName.string];
        target.name = destinationName.string;
        target.path = [destDir.path isEqualToString:@"/"]
            ? [NSString stringWithFormat:@"/%@", destinationName.string]
            : [NSString stringWithFormat:@"%@/%@", destDir.path, destinationName.string];

        [destDir addChild:target];
        _isDirty = YES;
        _activeTransactions++;

        reply(destinationName, nil);
    }
}

- (void)enumerateDirectory:(FSItem *)directory
          startingAtCookie:(FSDirectoryCookie)cookie
                  verifier:(FSDirectoryVerifier)verifier
       providingAttributes:(FSItemGetAttributesRequest * _Nullable)attributes
               usingPacker:(FSDirectoryEntryPacker *)packer
              replyHandler:(void(^)(FSDirectoryVerifier currentVerifier,
                                    NSError * _Nullable error))reply {
    (void)attributes;
    @synchronized (self) {
        KTYItem *targetDir = (directory && [directory isKindOfClass:[KTYItem class]]) ? (KTYItem *)directory : self.rootItem;

        if (cookie == FSDirectoryCookieInitial) {
            FSFileName *dotName = [[FSFileName alloc] initWithCString:"."];
            if ([packer packEntryWithName:dotName itemType:FSItemTypeDirectory itemID:targetDir.itemID nextCookie:1 attributes:nil]) {
                FSFileName *dotDotName = [[FSFileName alloc] initWithCString:".."];
                [packer packEntryWithName:dotDotName itemType:FSItemTypeDirectory itemID:FSItemIDParentOfRoot nextCookie:2 attributes:nil];
            }

            if (targetDir.children) {
                NSUInteger idx = 0;
                for (NSString *childName in targetDir.children) {
                    KTYItem *child = targetDir.children[childName];
                    if (child.isForensicTombstone) {
                        /* Silently exclude intercepted system metadata from directory listing */
                        continue;
                    }
                    FSFileName *fn = [[FSFileName alloc] initWithString:child.name];
                    FSDirectoryCookie nextCookie = (FSDirectoryCookie)(idx + 3);
                    [packer packEntryWithName:fn itemType:child.itemType itemID:child.itemID nextCookie:nextCookie attributes:nil];
                    idx++;
                }
            }
        }

        reply(verifier ?: 1, nil);
    }
}

#pragma mark - FSVolumeReadWriteOperations

- (void)readFromFile:(FSItem *)item
              offset:(off_t)offset
              length:(size_t)length
          intoBuffer:(FSMutableFileDataBuffer *)buffer
        replyHandler:(void(^)(size_t actuallyRead,
                              NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!buffer || buffer.length == 0 || length == 0) {
            reply(0, nil);
            return;
        }

        if (offset < 0) {
            reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        if (!self.ntfsDevice || !self.ntfsDevice->d_ops) {
            reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]);
            return;
        }

        off_t read_offset = offset;
        size_t to_read = (length < buffer.length) ? length : buffer.length;

        if (item && [item isKindOfClass:[KTYItem class]]) {
            KTYItem *ktyItem = (KTYItem *)item;
            if (ktyItem.isForensicTombstone) {
                reply(0, nil);
                return;
            }
            if (ktyItem.itemType == FSItemTypeFile) {
                if ((uint64_t)offset >= ktyItem.size) {
                    /* At or past EOF */
                    reply(0, nil);
                    return;
                }
                uint64_t bytesAvailable = ktyItem.size - (uint64_t)offset;
                if ((uint64_t)to_read > bytesAvailable) {
                    to_read = (size_t)bytesAvailable;
                }
            }
            if (ktyItem.diskOffset > 0) {
                read_offset = ktyItem.diskOffset + offset;
            }
        }

        s64 res = self.ntfsDevice->d_ops->pread(self.ntfsDevice, [buffer mutableBytes], (s64)to_read, (s64)read_offset);
        if (res < 0) {
            reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
            return;
        }

        reply((size_t)res, nil);
    }
}

- (void)writeContents:(NSData *)contents
               toFile:(FSItem *)item
             atOffset:(off_t)offset
         replyHandler:(void(^)(size_t actuallyWritten,
                               NSError * _Nullable error))reply {
    @synchronized (self) {
        if (self.readOnly) {
            reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
            return;
        }

        if (!contents || contents.length == 0) {
            reply(0, nil);
            return;
        }

        if (offset < 0) {
            reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        if (!item || ![item isKindOfClass:[KTYItem class]]) {
            reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        KTYItem *ktyItem = (KTYItem *)item;
        if (ktyItem.itemType != FSItemTypeFile) {
            reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:EISDIR userInfo:nil]);
            return;
        }

        if (ktyItem.isForensicTombstone) {
            _suppressedMetadataOperations++;
            uint64_t endPos = (uint64_t)offset + contents.length;
            if (endPos > ktyItem.size) {
                ktyItem.size = endPos;
            }
            ktyItem.mtime = time(NULL);
            reply(contents.length, nil);
            return;
        }

        uint64_t endPos = (uint64_t)offset + contents.length;
        if (endPos < (uint64_t)offset) {
            reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:EFBIG userInfo:nil]);
            return;
        }

        uint64_t oldSize = ktyItem.size;
        uint64_t oldAlloc = ktyItem.allocatedSize;
        off_t oldOffset = ktyItem.diskOffset;
        time_t oldMtime = ktyItem.mtime;

        /* Allocate space via sector-aligned cluster management */
        if (endPos > ktyItem.allocatedSize) {
            NSError *allocErr = nil;
            if (![self allocateClustersForFile:ktyItem neededSize:endPos error:&allocErr]) {
                reply(0, allocErr ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil]);
                return;
            }
        }

        if (endPos > ktyItem.size) {
            ktyItem.size = endPos;
        }
        ktyItem.mtime = time(NULL);

        /* Write payload to underlying storage if device open */
        if (self.ntfsDevice && self.ntfsDevice->d_ops && NDevOpen(self.ntfsDevice)) {
            off_t write_offset = ktyItem.diskOffset + offset;
            s64 written = self.ntfsDevice->d_ops->pwrite(self.ntfsDevice, contents.bytes, (s64)contents.length, (s64)write_offset);
            if (written < 0) {
                /* Roll back state on I/O error to preserve fail-closed consistency */
                ktyItem.size = oldSize;
                ktyItem.allocatedSize = oldAlloc;
                ktyItem.diskOffset = oldOffset;
                ktyItem.mtime = oldMtime;
                reply(0, [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
                return;
            }
        }

        /* Update forensic integrity hashes (SHA-256 and BLAKE3) and ADS */
        [ktyItem updateForensicHashesWithData:contents offset:(uint64_t)offset];

        _isDirty = YES;
        _totalBytesWritten += contents.length;
        _activeTransactions++;

        reply(contents.length, nil);
    }
}

#pragma mark - FSVolumeXattrOperations (NTFS Alternate Data Streams)

- (void)getXattrNamed:(FSFileName *)name
               ofItem:(FSItem *)item
         replyHandler:(void (^)(NSData * _Nullable value,
                                NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!item || ![item isKindOfClass:[KTYItem class]]) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }
        if (!name || name.string.length == 0) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        KTYItem *ktyItem = (KTYItem *)item;
        NSData *data = [ktyItem xattrNamed:name.string];
        if (data) {
            reply(data, nil);
        } else {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOATTR userInfo:nil]);
        }
    }
}

- (void)setXattrNamed:(FSFileName *)name
               toData:(NSData * _Nullable)value
               onItem:(FSItem *)item
               policy:(FSSetXattrPolicy)policy
         replyHandler:(void (^)(NSError * _Nullable error))reply {
    @synchronized (self) {
        if (self.readOnly) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:EROFS userInfo:nil]);
            return;
        }
        if (!item || ![item isKindOfClass:[KTYItem class]]) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }
        if (!name || name.string.length == 0) {
            reply([NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        KTYItem *ktyItem = (KTYItem *)item;
        NSError *err = nil;
        BOOL ok = [ktyItem setXattrNamed:name.string data:value policy:policy error:&err];
        if (ok) {
            _isDirty = YES;
            _activeTransactions++;
            reply(nil);
        } else {
            reply(err ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
        }
    }
}

- (void)listXattrsOfItem:(FSItem *)item
            replyHandler:(void (^)(NSArray<FSFileName *> * _Nullable value,
                                   NSError * _Nullable error))reply {
    @synchronized (self) {
        if (!item || ![item isKindOfClass:[KTYItem class]]) {
            reply(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
            return;
        }

        KTYItem *ktyItem = (KTYItem *)item;
        NSArray<NSString *> *names = [ktyItem listXattrNames];
        NSMutableArray<FSFileName *> *fileNames = [NSMutableArray arrayWithCapacity:names.count];
        for (NSString *str in names) {
            [fileNames addObject:[[FSFileName alloc] initWithString:str]];
        }
        reply(fileNames, nil);
    }
}

@end
