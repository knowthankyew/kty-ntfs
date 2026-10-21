#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>
#import <objc/runtime.h>
#import <assert.h>

#import "KTYItem.h"
#import "KTYVolume.h"
#import "KTYUnaryFileSystem.h"
#import "kty_crypto.h"

#ifndef _WINDEF_H
#define _WINDEF_H
#endif

#include "ntfs-3g/types.h"
#include "ntfs-3g/layout.h"
#include "ntfs-3g/bootsect.h"

#define MOCK_DISK_SIZE (64 * 1024)

/* Mock block device resource for local unit testing */
@interface MockFSBlockResource : NSObject
@property (nonatomic, strong) NSMutableData *storage;
@property (nonatomic, assign) uint64_t blockSize;
@property (nonatomic, assign) uint64_t blockCount;
@property (nonatomic, assign) uint64_t physicalBlockSize;
@property (nonatomic, copy) NSString *BSDName;
@property (nonatomic, assign, getter=isWritable) BOOL writable;

- (size_t)readInto:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error;
- (size_t)writeFrom:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error;
- (BOOL)metadataFlushWithError:(NSError **)error;
@end

@implementation MockFSBlockResource

- (instancetype)init {
    self = [super init];
    if (self) {
        _storage = [NSMutableData dataWithLength:MOCK_DISK_SIZE];
        _blockSize = 512;
        _blockCount = MOCK_DISK_SIZE / 512;
        _physicalBlockSize = 512;
        _BSDName = @"mockdisk0s1";
        _writable = YES;
    }
    return self;
}

- (size_t)readInto:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    (void)error;
    if (offset < 0 || (NSUInteger)offset >= self.storage.length) {
        return 0;
    }
    NSUInteger avail = self.storage.length - (NSUInteger)offset;
    NSUInteger to_copy = (length < avail) ? length : avail;
    [self.storage getBytes:buffer range:NSMakeRange((NSUInteger)offset, to_copy)];
    return to_copy;
}

- (size_t)writeFrom:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    (void)error;
    if (offset < 0 || (NSUInteger)offset >= self.storage.length) {
        return 0;
    }
    NSUInteger avail = self.storage.length - (NSUInteger)offset;
    NSUInteger to_copy = (length < avail) ? length : avail;
    [self.storage replaceBytesInRange:NSMakeRange((NSUInteger)offset, to_copy) withBytes:buffer];
    return to_copy;
}

- (BOOL)metadataFlushWithError:(NSError **)error {
    (void)error;
    return YES;
}

- (BOOL)isKindOfClass:(Class)aClass {
    if (aClass == [FSBlockDeviceResource class] || aClass == [FSResource class]) {
        return YES;
    }
    return [super isKindOfClass:aClass];
}

@end

/* Mock file data buffer for readFromFile unit tests */
@interface MockFileDataBuffer : NSObject
@property (nonatomic, strong) NSMutableData *data;
- (instancetype)initWithLength:(NSUInteger)len;
- (NSUInteger)length;
- (void *)mutableBytes;
@end

@implementation MockFileDataBuffer
- (instancetype)initWithLength:(NSUInteger)len {
    self = [super init];
    if (self) {
        _data = [NSMutableData dataWithLength:len];
    }
    return self;
}
- (NSUInteger)length {
    return _data.length;
}
- (void *)mutableBytes {
    return _data.mutableBytes;
}
@end

/* Mock directory entry packer for enumeration unit tests */
@interface MockDirectoryEntryPacker : NSObject
@property (nonatomic, assign) NSUInteger packedCount;
- (BOOL)packEntryWithName:(FSFileName *)name
                 itemType:(FSItemType)itemType
                   itemID:(FSItemID)itemID
               nextCookie:(FSDirectoryCookie)nextCookie
               attributes:(FSItemAttributes *)attributes;
@end

@implementation MockDirectoryEntryPacker
- (BOOL)packEntryWithName:(FSFileName *)name
                 itemType:(FSItemType)itemType
                   itemID:(FSItemID)itemID
               nextCookie:(FSDirectoryCookie)nextCookie
               attributes:(FSItemAttributes *)attributes {
    (void)name; (void)itemType; (void)itemID; (void)nextCookie; (void)attributes;
    self.packedCount++;
    return YES;
}
@end

/* Mock item set attributes request */
@interface MockItemSetAttributesRequest : NSObject
@property (nonatomic, assign) uint32_t mode;
@property (nonatomic, assign) uint32_t uid;
@property (nonatomic, assign) uint32_t gid;
@property (nonatomic, assign) uint64_t size;
- (BOOL)isValid:(FSItemAttribute)attr;
@end

@implementation MockItemSetAttributesRequest
- (BOOL)isValid:(FSItemAttribute)attr {
    (void)attr;
    return NO;
}
@end

static void format_mock_ntfs_boot_sector(MockFSBlockResource *res) {
    uint8_t *bytes = (uint8_t *)[res.storage mutableBytes];
    memset(bytes, 0, MOCK_DISK_SIZE);

    NTFS_BOOT_SECTOR *bs = (NTFS_BOOT_SECTOR *)bytes;
    bs->jump[0] = 0xeb;
    bs->jump[1] = 0x52;
    bs->jump[2] = 0x90;
    memcpy(&bs->oem_id, "NTFS    ", 8);

    bs->bpb.bytes_per_sector = cpu_to_le16(512);
    bs->bpb.sectors_per_cluster = 8;
    bs->bpb.media_type = 0xf8;
    bs->bpb.sectors_per_track = cpu_to_le16(63);
    bs->bpb.heads = cpu_to_le16(255);
    bs->number_of_sectors = cpu_to_sle64(MOCK_DISK_SIZE / 512);
    bs->mft_lcn = cpu_to_sle64(4);
    bs->mftmirr_lcn = cpu_to_sle64(2);
    bs->clusters_per_mft_record = 1;
    bs->clusters_per_index_record = 1;
    bs->volume_serial_number = cpu_to_sle64(0x123456789ABCDEF0ULL);

    bytes[510] = 0x55;
    bytes[511] = 0xaa;
}

int main(void) {
    @autoreleasepool {
        printf("[test_fskit_bridge] Starting FSKit extension unit tests...\n");

        /* Test 1: KTYItem instantiation and attribute mapping */
        printf("[test_fskit_bridge] Test 1: KTYItem attribute mapping... ");
        KTYItem *root = [KTYItem rootDirectoryItem];
        assert(root.itemID == FSItemIDRootDirectory);
        assert(root.itemType == FSItemTypeDirectory);

        FSItemAttributes *attrs = [[FSItemAttributes alloc] init];
        [root populateAttributes:attrs];
        assert(attrs.fileID == FSItemIDRootDirectory);
        assert(attrs.type == FSItemTypeDirectory);
        assert(attrs.linkCount == 2);

        KTYItem *fileItem = [KTYItem itemWithID:1001 name:@"evidence.raw" path:@"/evidence.raw" type:FSItemTypeFile size:1048576 mode:S_IFREG | 0644];
        [fileItem populateAttributes:attrs];
        assert(attrs.fileID == 1001);
        assert(attrs.type == FSItemTypeFile);
        assert(attrs.size == 1048576);
        assert(attrs.linkCount == 1);
        assert(attrs.modifyTime.tv_sec > 0);
        assert(attrs.changeTime.tv_sec > 0);
        printf("PASS\n");

        /* Test 2: KTYVolume PathConf, Capabilities, and I/O */
        printf("[test_fskit_bridge] Test 2: KTYVolume capabilities, mount & I/O... ");
        MockFSBlockResource *mockRes = [[MockFSBlockResource alloc] init];
        format_mock_ntfs_boot_sector(mockRes);

        FSVolumeIdentifier *volID = [[FSVolumeIdentifier alloc] initWithUUID:[NSUUID UUID]];
        FSFileName *volName = [[FSFileName alloc] initWithString:@"Evidence Vol"];

        KTYVolume *volume = [[KTYVolume alloc] initWithResource:(FSBlockDeviceResource *)mockRes
                                                       volumeID:volID
                                                     volumeName:volName
                                                       readOnly:NO];
        assert(volume != nil);
        assert([volume maximumNameLength] == 255);
        assert([volume maximumLinkCount] == 1024);
        assert([volume restrictsOwnershipChanges] == YES);

        FSVolumeSupportedCapabilities *caps = [volume supportedVolumeCapabilities];
        assert(caps.supportsPersistentObjectIDs == YES);
        assert(caps.supportsJournal == YES);

        FSStatFSResult *stats = [volume volumeStatistics];
        assert(stats.blockSize == 4096);
        assert(stats.totalBlocks == mockRes.blockCount);

        /* Test mount */
        FSTaskOptions *taskOpts = (FSTaskOptions *)[[NSObject alloc] init];
        __block BOOL mounted = NO;
        [volume mountWithOptions:taskOpts replyHandler:^(NSError * _Nullable err) {
            assert(err == nil);
            mounted = YES;
        }];
        assert(mounted);
        assert(volume.isMounted);

        /* Test readFromFile */
        MockFileDataBuffer *buf = [[MockFileDataBuffer alloc] initWithLength:512];
        __block BOOL readFinished = NO;
        [volume readFromFile:root offset:0 length:512 intoBuffer:(FSMutableFileDataBuffer *)buf replyHandler:^(size_t actuallyRead, NSError * _Nullable err) {
            assert(err == nil);
            assert(actuallyRead == 512);
            NTFS_BOOT_SECTOR *bs = (NTFS_BOOT_SECTOR *)[buf mutableBytes];
            assert(ntfs_boot_sector_is_ntfs(bs));
            readFinished = YES;
        }];
        assert(readFinished);

        /* Test defensive readFromFile with 0 length / empty buffer */
        MockFileDataBuffer *emptyBuf = [[MockFileDataBuffer alloc] initWithLength:0];
        __block BOOL zeroReadFinished = NO;
        [volume readFromFile:root offset:0 length:0 intoBuffer:(FSMutableFileDataBuffer *)emptyBuf replyHandler:^(size_t actuallyRead, NSError * _Nullable err) {
            assert(err == nil);
            assert(actuallyRead == 0);
            zeroReadFinished = YES;
        }];
        assert(zeroReadFinished);

        /* Test directory enumeration with initial cookie */
        MockDirectoryEntryPacker *packer1 = [[MockDirectoryEntryPacker alloc] init];
        __block BOOL enumFinished1 = NO;
        [volume enumerateDirectory:root startingAtCookie:FSDirectoryCookieInitial verifier:0 providingAttributes:nil usingPacker:(FSDirectoryEntryPacker *)packer1 replyHandler:^(FSDirectoryVerifier currentVerifier, NSError * _Nullable error) {
            assert(error == nil);
            assert(currentVerifier > 0);
            enumFinished1 = YES;
        }];
        assert(enumFinished1);
        assert(packer1.packedCount == 2); /* "." and ".." */

        /* Test directory enumeration with subsequent cookie (EOF) */
        MockDirectoryEntryPacker *packer2 = [[MockDirectoryEntryPacker alloc] init];
        __block BOOL enumFinished2 = NO;
        [volume enumerateDirectory:root startingAtCookie:2 verifier:1 providingAttributes:nil usingPacker:(FSDirectoryEntryPacker *)packer2 replyHandler:^(FSDirectoryVerifier currentVerifier, NSError * _Nullable error) {
            assert(error == nil);
            assert(currentVerifier == 1);
            enumFinished2 = YES;
        }];
        assert(enumFinished2);
        assert(packer2.packedCount == 0); /* EOF, 0 entries packed */

        /* Test synchronize */
        __block BOOL synced = NO;
        [volume synchronizeWithFlags:0 replyHandler:^(NSError * _Nullable err) {
            assert(err == nil);
            synced = YES;
        }];
        assert(synced);

        /* Test idempotent cleanup under @synchronized */
        [volume cleanup];
        [volume cleanup];

        /* Test read-only volume write rejection */
        KTYVolume *roVolume = [[KTYVolume alloc] initWithResource:(FSBlockDeviceResource *)mockRes
                                                         volumeID:volID
                                                       volumeName:volName
                                                         readOnly:YES];
        __block BOOL writeRejected = NO;
        [roVolume writeContents:[NSData data] toFile:fileItem atOffset:0 replyHandler:^(size_t actuallyWritten, NSError * _Nullable err) {
            assert(actuallyWritten == 0);
            assert(err != nil);
            assert(err.code == EROFS);
            writeRejected = YES;
        }];
        assert(writeRejected);
        [roVolume cleanup];
        printf("PASS\n");

        /* Test 3: KTYUnaryFileSystem resource probing */
        printf("[test_fskit_bridge] Test 3: KTYUnaryFileSystem probing... ");
        KTYUnaryFileSystem *fs = [[KTYUnaryFileSystem alloc] init];

        /* Probe 3A: Non-block resource rejected */
        __block BOOL probeFinished = NO;
        [fs probeResource:(FSResource *)[[NSObject alloc] init] replyHandler:^(FSProbeResult * _Nullable result, NSError * _Nullable error) {
            assert(error == nil);
            assert(result.result == FSMatchResultNotRecognized);
            probeFinished = YES;
        }];
        assert(probeFinished == YES);

        /* Probe 3B: Non-NTFS block data rejected */
        MockFSBlockResource *blankRes = [[MockFSBlockResource alloc] init];
        probeFinished = NO;
        [fs probeResource:(FSBlockDeviceResource *)blankRes replyHandler:^(FSProbeResult * _Nullable result, NSError * _Nullable error) {
            assert(error == nil);
            assert(result.result == FSMatchResultNotRecognized);
            probeFinished = YES;
        }];
        assert(probeFinished == YES);

        /* Probe 3C: Valid NTFS boot sector recognized with deterministic container UUID */
        __block NSUUID *uuid1 = nil;
        probeFinished = NO;
        [fs probeResource:(FSBlockDeviceResource *)mockRes replyHandler:^(FSProbeResult * _Nullable result, NSError * _Nullable error) {
            assert(error == nil);
            assert(result.result == FSMatchResultUsable);
            assert([result.name isEqualToString:@"NTFS Volume"]);
            assert(result.containerID != nil);
            uuid1 = result.containerID.uuid;
            probeFinished = YES;
        }];
        assert(probeFinished == YES);

        /* Probe 3D: Subsequent probe produces identical deterministic container UUID */
        probeFinished = NO;
        [fs probeResource:(FSBlockDeviceResource *)mockRes replyHandler:^(FSProbeResult * _Nullable result, NSError * _Nullable error) {
            assert(error == nil);
            assert(result.result == FSMatchResultUsable);
            assert([result.containerID.uuid isEqual:uuid1]);
            probeFinished = YES;
        }];
        assert(probeFinished == YES);
        printf("PASS\n");

        /* Test 4: Write Pipeline, Cluster Allocation, Renaming & Journal Sync */
        printf("[test_fskit_bridge] Test 4: Write pipeline, cluster allocation & journal sync... ");
        MockFSBlockResource *writeMockRes = [[MockFSBlockResource alloc] init];
        format_mock_ntfs_boot_sector(writeMockRes);

        FSVolumeIdentifier *writeVolID = [[FSVolumeIdentifier alloc] initWithUUID:[NSUUID UUID]];
        FSFileName *writeVolName = [[FSFileName alloc] initWithString:@"Write Vol"];
        KTYVolume *writeVol = [[KTYVolume alloc] initWithResource:(FSBlockDeviceResource *)writeMockRes
                                                         volumeID:writeVolID
                                                       volumeName:writeVolName
                                                         readOnly:NO];
        assert(writeVol != nil);

        __block BOOL writeVolMounted = NO;
        [writeVol mountWithOptions:taskOpts replyHandler:^(NSError * _Nullable err) {
            assert(err == nil);
            writeVolMounted = YES;
        }];
        assert(writeVolMounted);

        /* 4A: File creation */
        FSItemSetAttributesRequest *dummyReq = (FSItemSetAttributesRequest *)[[MockItemSetAttributesRequest alloc] init];
        FSFileName *testFile = [[FSFileName alloc] initWithCString:"evidence_sample.bin"];
        __block KTYItem *createdItem = nil;
        __block BOOL createFinished = NO;
        [writeVol createItemNamed:testFile type:FSItemTypeFile inDirectory:writeVol.rootItem attributes:dummyReq replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
            assert(error == nil);
            assert(newItem != nil);
            assert([newItemName.string isEqualToString:@"evidence_sample.bin"]);
            createdItem = (KTYItem *)newItem;
            createFinished = YES;
        }];
        assert(createFinished);
        assert(createdItem.itemID >= 1000);
        assert(createdItem.size == 0);
        assert(createdItem.allocatedSize == 4096);
        assert(createdItem.diskOffset >= 32768);

        /* 4B: Rejection of duplicate file name */
        __block BOOL duplicateRejected = NO;
        [writeVol createItemNamed:testFile type:FSItemTypeFile inDirectory:writeVol.rootItem attributes:dummyReq replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
            (void)newItem;
            (void)newItemName;
            assert(error != nil);
            assert(error.code == EEXIST);
            duplicateRejected = YES;
        }];
        assert(duplicateRejected);

        /* 4C: Write payload with sector-aligned cluster growth */
        uint8_t payload[8192];
        for (size_t i = 0; i < sizeof(payload); i++) {
            payload[i] = (uint8_t)(i & 0xFF);
        }
        NSData *payloadData = [NSData dataWithBytes:payload length:sizeof(payload)];
        __block BOOL payloadWriteFinished = NO;
        [writeVol writeContents:payloadData toFile:createdItem atOffset:0 replyHandler:^(size_t actuallyWritten, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyWritten == sizeof(payload));
            payloadWriteFinished = YES;
        }];
        assert(payloadWriteFinished);
        assert(createdItem.size == sizeof(payload));
        assert(createdItem.allocatedSize >= sizeof(payload));
        assert(writeVol.isDirty == YES);
        assert(writeVol.totalBytesWritten == sizeof(payload));
        assert(writeVol.activeTransactions > 0);

        /* 4D: Bit-for-bit readback from allocated disk clusters */
        MockFileDataBuffer *readPayloadBuf = [[MockFileDataBuffer alloc] initWithLength:sizeof(payload)];
        __block BOOL payloadReadFinished = NO;
        [writeVol readFromFile:createdItem offset:0 length:sizeof(payload) intoBuffer:(FSMutableFileDataBuffer *)readPayloadBuf replyHandler:^(size_t actuallyRead, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyRead == sizeof(payload));
            payloadReadFinished = YES;
        }];
        assert(payloadReadFinished);
        assert(memcmp([readPayloadBuf mutableBytes], payload, sizeof(payload)) == 0);

        /* 4D-1: Read at or past EOF defensive boundary checks */
        MockFileDataBuffer *eofBuf = [[MockFileDataBuffer alloc] initWithLength:512];
        __block BOOL eofReadFinished = NO;
        [writeVol readFromFile:createdItem offset:sizeof(payload) length:512 intoBuffer:(FSMutableFileDataBuffer *)eofBuf replyHandler:^(size_t actuallyRead, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyRead == 0); /* Must return 0 at EOF */
            eofReadFinished = YES;
        }];
        assert(eofReadFinished);

        eofReadFinished = NO;
        [writeVol readFromFile:createdItem offset:sizeof(payload) + 1024 length:512 intoBuffer:(FSMutableFileDataBuffer *)eofBuf replyHandler:^(size_t actuallyRead, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyRead == 0); /* Must return 0 past EOF */
            eofReadFinished = YES;
        }];
        assert(eofReadFinished);

        /* 4D-2: Read spanning EOF clamped to available file bytes */
        eofReadFinished = NO;
        const uint8_t *payloadBytes = (const uint8_t *)payloadData.bytes;
        [writeVol readFromFile:createdItem offset:sizeof(payload) - 100 length:512 intoBuffer:(FSMutableFileDataBuffer *)eofBuf replyHandler:^(size_t actuallyRead, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyRead == 100); /* Clamped to 100 remaining bytes */
            assert(memcmp([eofBuf mutableBytes], payloadBytes + sizeof(payload) - 100, 100) == 0);
            eofReadFinished = YES;
        }];
        assert(eofReadFinished);

        /* 4D-3: Negative offset rejection */
        __block BOOL negOffsetRejected = NO;
        [writeVol readFromFile:createdItem offset:-1 length:512 intoBuffer:(FSMutableFileDataBuffer *)eofBuf replyHandler:^(size_t actuallyRead, NSError * _Nullable error) {
            assert(actuallyRead == 0);
            assert(error != nil);
            assert(error.code == EINVAL);
            negOffsetRejected = YES;
        }];
        assert(negOffsetRejected);

        negOffsetRejected = NO;
        [writeVol writeContents:payloadData toFile:createdItem atOffset:-1 replyHandler:^(size_t actuallyWritten, NSError * _Nullable error) {
            assert(actuallyWritten == 0);
            assert(error != nil);
            assert(error.code == EINVAL);
            negOffsetRejected = YES;
        }];
        assert(negOffsetRejected);

        /* 4E: Directory lookup of newly created file */
        __block BOOL lookupFinished = NO;
        [writeVol lookupItemNamed:testFile inDirectory:writeVol.rootItem replyHandler:^(FSItem * _Nullable theItem, FSFileName * _Nullable itemName, NSError * _Nullable error) {
            assert(error == nil);
            assert(theItem != nil);
            assert([(KTYItem *)theItem itemID] == createdItem.itemID);
            assert([itemName.string isEqualToString:@"evidence_sample.bin"]);
            lookupFinished = YES;
        }];
        assert(lookupFinished);

        /* 4F: Directory enumeration includes created child */
        MockDirectoryEntryPacker *childPacker = [[MockDirectoryEntryPacker alloc] init];
        __block BOOL childEnumFinished = NO;
        [writeVol enumerateDirectory:writeVol.rootItem startingAtCookie:FSDirectoryCookieInitial verifier:0 providingAttributes:nil usingPacker:(FSDirectoryEntryPacker *)childPacker replyHandler:^(FSDirectoryVerifier currentVerifier, NSError * _Nullable error) {
            assert(error == nil);
            assert(currentVerifier > 0);
            childEnumFinished = YES;
        }];
        assert(childEnumFinished);
        assert(childPacker.packedCount == 3); /* "." and ".." and "evidence_sample.bin" */

        /* 4G: File truncation / resizing */
        [createdItem truncateToSize:4096];
        assert(createdItem.size == 4096);
        assert(createdItem.allocatedSize == 4096);

        /* 4H: File renaming */
        FSFileName *renamedFile = [[FSFileName alloc] initWithCString:"evidence_sample_archived.bin"];
        __block BOOL renameFinished = NO;
        [writeVol renameItem:createdItem inDirectory:writeVol.rootItem named:testFile toNewName:renamedFile inDirectory:writeVol.rootItem overItem:nil replyHandler:^(FSFileName * _Nullable newName, NSError * _Nullable error) {
            assert(error == nil);
            assert([newName.string isEqualToString:@"evidence_sample_archived.bin"]);
            renameFinished = YES;
        }];
        assert(renameFinished);

        /* Lookup old name fails */
        __block BOOL oldLookupFailed = NO;
        [writeVol lookupItemNamed:testFile inDirectory:writeVol.rootItem replyHandler:^(FSItem * _Nullable theItem, FSFileName * _Nullable itemName, NSError * _Nullable error) {
            (void)theItem;
            (void)itemName;
            assert(error != nil);
            assert(error.code == ENOENT);
            oldLookupFailed = YES;
        }];
        assert(oldLookupFailed);

        /* Lookup new name succeeds */
        __block BOOL newLookupSucceeded = NO;
        [writeVol lookupItemNamed:renamedFile inDirectory:writeVol.rootItem replyHandler:^(FSItem * _Nullable theItem, FSFileName * _Nullable itemName, NSError * _Nullable error) {
            assert(error == nil);
            assert(theItem != nil);
            assert([(KTYItem *)theItem itemID] == createdItem.itemID);
            assert([itemName.string isEqualToString:@"evidence_sample_archived.bin"]);
            newLookupSucceeded = YES;
        }];
        assert(newLookupSucceeded);

        /* 4I: File deletion */
        __block BOOL removeFinished = NO;
        [writeVol removeItem:createdItem named:renamedFile fromDirectory:writeVol.rootItem replyHandler:^(NSError * _Nullable error) {
            assert(error == nil);
            removeFinished = YES;
        }];
        assert(removeFinished);

        /* Lookup after removal fails */
        __block BOOL postRemoveLookupFailed = NO;
        [writeVol lookupItemNamed:renamedFile inDirectory:writeVol.rootItem replyHandler:^(FSItem * _Nullable theItem, FSFileName * _Nullable itemName, NSError * _Nullable error) {
            (void)theItem;
            (void)itemName;
            assert(error != nil);
            assert(error.code == ENOENT);
            postRemoveLookupFailed = YES;
        }];
        assert(postRemoveLookupFailed);

        /* 4J: Multi-file cluster allocation isolation & collision prevention */
        FSFileName *fnA = [[FSFileName alloc] initWithCString:"fileA.dat"];
        FSFileName *fnB = [[FSFileName alloc] initWithCString:"fileB.dat"];
        __block KTYItem *itemA = nil;
        __block KTYItem *itemB = nil;

        [writeVol createItemNamed:fnA type:FSItemTypeFile inDirectory:writeVol.rootItem attributes:dummyReq replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
            (void)newItemName;
            assert(error == nil);
            itemA = (KTYItem *)newItem;
        }];
        assert(itemA != nil);

        [writeVol createItemNamed:fnB type:FSItemTypeFile inDirectory:writeVol.rootItem attributes:dummyReq replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
            (void)newItemName;
            assert(error == nil);
            itemB = (KTYItem *)newItem;
        }];
        assert(itemB != nil);
        assert(itemB.diskOffset > itemA.diskOffset);

        /* Write 4KB of pattern 0xBB into file B */
        uint8_t patB[4096];
        memset(patB, 0xBB, sizeof(patB));
        NSData *dataB = [NSData dataWithBytes:patB length:sizeof(patB)];
        [writeVol writeContents:dataB toFile:itemB atOffset:0 replyHandler:^(size_t actuallyWritten, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyWritten == sizeof(patB));
        }];

        /* Write 8KB of pattern 0xAA into file A (triggers dynamic cluster growth beyond initial 4KB) */
        uint8_t patA[8192];
        memset(patA, 0xAA, sizeof(patA));
        NSData *dataA = [NSData dataWithBytes:patA length:sizeof(patA)];
        [writeVol writeContents:dataA toFile:itemA atOffset:0 replyHandler:^(size_t actuallyWritten, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyWritten == sizeof(patA));
        }];

        /* Assert File B is untouched and bit-for-bit pristine */
        MockFileDataBuffer *bufB = [[MockFileDataBuffer alloc] initWithLength:sizeof(patB)];
        [writeVol readFromFile:itemB offset:0 length:sizeof(patB) intoBuffer:(FSMutableFileDataBuffer *)bufB replyHandler:^(size_t actuallyRead, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyRead == sizeof(patB));
        }];
        assert(memcmp([bufB mutableBytes], patB, sizeof(patB)) == 0);

        /* Assert File A contains full 8KB of pattern 0xAA */
        MockFileDataBuffer *bufA = [[MockFileDataBuffer alloc] initWithLength:sizeof(patA)];
        [writeVol readFromFile:itemA offset:0 length:sizeof(patA) intoBuffer:(FSMutableFileDataBuffer *)bufA replyHandler:^(size_t actuallyRead, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyRead == sizeof(patA));
        }];
        assert(memcmp([bufA mutableBytes], patA, sizeof(patA)) == 0);

        /* 4K: POSIX rename validation tests */
        /* Self rename no-op */
        [writeVol renameItem:itemA inDirectory:writeVol.rootItem named:fnA toNewName:fnA inDirectory:writeVol.rootItem overItem:nil replyHandler:^(FSFileName * _Nullable newName, NSError * _Nullable error) {
            assert(error == nil);
            assert([newName.string isEqualToString:fnA.string]);
        }];

        /* Empty destination name rejected */
        FSFileName *emptyName = [[FSFileName alloc] initWithCString:""];
        [writeVol renameItem:itemA inDirectory:writeVol.rootItem named:fnA toNewName:emptyName inDirectory:writeVol.rootItem overItem:nil replyHandler:^(FSFileName * _Nullable newName, NSError * _Nullable error) {
            (void)newName;
            assert(error != nil);
            assert(error.code == EINVAL);
        }];

        /* Cleanup items */
        [writeVol removeItem:itemA named:fnA fromDirectory:writeVol.rootItem replyHandler:^(NSError * _Nullable error) {
            assert(error == nil);
        }];
        [writeVol removeItem:itemB named:fnB fromDirectory:writeVol.rootItem replyHandler:^(NSError * _Nullable error) {
            assert(error == nil);
        }];

        /* 4L: Journal sync & clean teardown */
        __block BOOL writeSyncFinished = NO;
        [writeVol synchronizeWithFlags:0 replyHandler:^(NSError * _Nullable error) {
            assert(error == nil);
            writeSyncFinished = YES;
        }];
        assert(writeSyncFinished);
        assert(writeVol.isDirty == NO);
        assert(writeVol.activeTransactions == 0);

        [writeVol cleanup];
        assert(writeVol.isMounted == NO);
        printf("PASS\n");

        /* Test 5: Forensic Hygiene & Path-Based Metadata Filtering */
        printf("[test_fskit_bridge] Test 5: Forensic hygiene & metadata suppression... ");
        MockFSBlockResource *hygieneMockRes = [[MockFSBlockResource alloc] init];
        format_mock_ntfs_boot_sector(hygieneMockRes);

        FSVolumeIdentifier *hygieneVolID = [[FSVolumeIdentifier alloc] initWithUUID:[NSUUID UUID]];
        FSFileName *hygieneVolName = [[FSFileName alloc] initWithString:@"Hygiene Vol"];
        KTYVolume *hygieneVol = [[KTYVolume alloc] initWithResource:(FSBlockDeviceResource *)hygieneMockRes
                                                           volumeID:hygieneVolID
                                                         volumeName:hygieneVolName
                                                           readOnly:NO];
        assert(hygieneVol != nil);
        assert(hygieneVol.allowSystemMetadata == NO);

        __block BOOL hygieneVolMounted = NO;
        [hygieneVol mountWithOptions:taskOpts replyHandler:^(NSError * _Nullable err) {
            assert(err == nil);
            hygieneVolMounted = YES;
        }];
        assert(hygieneVolMounted);

        /* 5A: Interception of .DS_Store, .Spotlight-V100, .Trashes, .fseventsd, and ._* sidecars */
        const char *metadataFiles[] = {
            ".DS_Store",
            ".Spotlight-V100",
            ".Trashes",
            ".fseventsd",
            "._evidence.bin"
        };
        size_t numMetadataFiles = sizeof(metadataFiles) / sizeof(metadataFiles[0]);

        for (size_t i = 0; i < numMetadataFiles; i++) {
            FSFileName *mName = [[FSFileName alloc] initWithCString:metadataFiles[i]];
            __block BOOL created = NO;
            [hygieneVol createItemNamed:mName
                                   type:(i == 1 || i == 2 || i == 3) ? FSItemTypeDirectory : FSItemTypeFile
                            inDirectory:hygieneVol.rootItem
                             attributes:dummyReq
                           replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
                (void)newItemName;
                assert(error == nil);
                assert(newItem != nil);
                KTYItem *ktyNew = (KTYItem *)newItem;
                assert(ktyNew.isForensicTombstone == YES);
                assert(ktyNew.diskOffset == 0);
                assert(ktyNew.allocatedSize == 0);
                created = YES;
            }];
            assert(created);
        }

        assert(hygieneVol.suppressedMetadataOperations == numMetadataFiles);
        assert(hygieneVol.totalBytesWritten == 0);
        assert(hygieneVol.isDirty == NO);

        /* 5B: Writing into tombstone file does NOT touch disk or set dirty bit */
        KTYItem *dsStoreItem = [hygieneVol.rootItem childNamed:@".DS_Store"];
        assert(dsStoreItem != nil);
        assert(dsStoreItem.isForensicTombstone == YES);

        uint8_t dummyMeta[512] = {0};
        NSData *dummyMetaData = [NSData dataWithBytes:dummyMeta length:sizeof(dummyMeta)];
        __block BOOL metaWriteDone = NO;
        [hygieneVol writeContents:dummyMetaData toFile:dsStoreItem atOffset:0 replyHandler:^(size_t actuallyWritten, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyWritten == sizeof(dummyMeta));
            metaWriteDone = YES;
        }];
        assert(metaWriteDone);
        assert(hygieneVol.totalBytesWritten == 0);
        assert(hygieneVol.isDirty == NO);
        assert(hygieneVol.suppressedMetadataOperations == (numMetadataFiles + 1));

        /* 5B-1: setAttributes and setXattr on tombstone do NOT touch disk or toggle isDirty */
        __block BOOL tombstoneAttrDone = NO;
        [hygieneVol setAttributes:dummyReq onItem:dsStoreItem replyHandler:^(FSItemAttributes * _Nullable attributes, NSError * _Nullable error) {
            (void)attributes;
            assert(error == nil);
            tombstoneAttrDone = YES;
        }];
        assert(tombstoneAttrDone);
        assert(dsStoreItem.allocatedSize == 0);
        assert(dsStoreItem.diskOffset == 0);
        assert(hygieneVol.isDirty == NO);

        FSFileName *tombstoneXattrName = [[FSFileName alloc] initWithString:@"com.apple.FinderInfo"];
        NSData *tombstoneXattrVal = [@"finder_flags" dataUsingEncoding:NSUTF8StringEncoding];
        __block BOOL tombstoneXattrDone = NO;
        [hygieneVol setXattrNamed:tombstoneXattrName toData:tombstoneXattrVal onItem:dsStoreItem policy:FSSetXattrPolicyAlwaysSet replyHandler:^(NSError * _Nullable error) {
            assert(error == nil);
            tombstoneXattrDone = YES;
        }];
        assert(tombstoneXattrDone);
        assert(hygieneVol.isDirty == NO);

        /* 5C: Directory enumeration excludes all suppressed metadata */
        MockDirectoryEntryPacker *hygienePacker = [[MockDirectoryEntryPacker alloc] init];
        __block BOOL hygieneEnumDone = NO;
        [hygieneVol enumerateDirectory:hygieneVol.rootItem
                      startingAtCookie:FSDirectoryCookieInitial
                              verifier:0
                   providingAttributes:nil
                           usingPacker:(FSDirectoryEntryPacker *)hygienePacker
                          replyHandler:^(FSDirectoryVerifier currentVerifier, NSError * _Nullable error) {
            (void)currentVerifier;
            assert(error == nil);
            hygieneEnumDone = YES;
        }];
        assert(hygieneEnumDone);
        assert(hygienePacker.packedCount == 2); /* Only "." and ".." */

        /* 5D: Override flag allowSystemMetadata allows disk allocation */
        hygieneVol.allowSystemMetadata = YES;
        FSFileName *allowedName = [[FSFileName alloc] initWithCString:".DS_Store_allowed"];
        __block BOOL allowedCreated = NO;
        [hygieneVol createItemNamed:allowedName
                               type:FSItemTypeFile
                        inDirectory:hygieneVol.rootItem
                         attributes:dummyReq
                       replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
            (void)newItemName;
            assert(error == nil);
            assert(newItem != nil);
            KTYItem *ktyAllowed = (KTYItem *)newItem;
            assert(ktyAllowed.isForensicTombstone == NO);
            assert(ktyAllowed.diskOffset > 0);
            assert(ktyAllowed.allocatedSize == 4096);
            allowedCreated = YES;
        }];
        assert(allowedCreated);
        [hygieneVol cleanup];
        printf("PASS\n");

        /* Test 6: Extended Attributes (xattr) & NTFS Alternate Data Streams (ADS) */
        printf("[test_fskit_bridge] Test 6: Extended attributes & ADS mapping... ");
        MockFSBlockResource *xattrMockRes = [[MockFSBlockResource alloc] init];
        format_mock_ntfs_boot_sector(xattrMockRes);

        FSVolumeIdentifier *xattrVolID = [[FSVolumeIdentifier alloc] initWithUUID:[NSUUID UUID]];
        FSFileName *xattrVolName = [[FSFileName alloc] initWithString:@"Xattr Vol"];
        KTYVolume *xattrVol = [[KTYVolume alloc] initWithResource:(FSBlockDeviceResource *)xattrMockRes
                                                         volumeID:xattrVolID
                                                       volumeName:xattrVolName
                                                         readOnly:NO];
        assert(xattrVol != nil);
        [xattrVol mountWithOptions:taskOpts replyHandler:^(NSError * _Nullable err) {
            assert(err == nil);
        }];

        FSFileName *fnEvidence = [[FSFileName alloc] initWithCString:"evidence_payload.dat"];
        __block KTYItem *itemEvidence = nil;
        [xattrVol createItemNamed:fnEvidence type:FSItemTypeFile inDirectory:xattrVol.rootItem attributes:dummyReq replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
            (void)newItemName;
            assert(error == nil);
            itemEvidence = (KTYItem *)newItem;
        }];
        assert(itemEvidence != nil);

        /* 6A: Set xattr with FSSetXattrPolicyMustCreate */
        FSFileName *xattrQuarantine = [[FSFileName alloc] initWithString:@"com.apple.quarantine"];
        NSData *quarantineData = [@"0081;66554433;Safari;UUID" dataUsingEncoding:NSUTF8StringEncoding];
        __block BOOL xattrSetDone = NO;
        [xattrVol setXattrNamed:xattrQuarantine toData:quarantineData onItem:itemEvidence policy:FSSetXattrPolicyMustCreate replyHandler:^(NSError * _Nullable error) {
            assert(error == nil);
            xattrSetDone = YES;
        }];
        assert(xattrSetDone);
        assert(xattrVol.isDirty == YES);

        /* 6B: FSSetXattrPolicyMustCreate on existing attribute fails with EEXIST */
        __block BOOL xattrDupRejected = NO;
        [xattrVol setXattrNamed:xattrQuarantine toData:quarantineData onItem:itemEvidence policy:FSSetXattrPolicyMustCreate replyHandler:^(NSError * _Nullable error) {
            assert(error != nil);
            assert(error.code == EEXIST);
            xattrDupRejected = YES;
        }];
        assert(xattrDupRejected);

        /* 6C: Read back xattr bit-for-bit */
        __block BOOL xattrGetDone = NO;
        [xattrVol getXattrNamed:xattrQuarantine ofItem:itemEvidence replyHandler:^(NSData * _Nullable value, NSError * _Nullable error) {
            assert(error == nil);
            assert(value != nil);
            assert([value isEqualToData:quarantineData]);
            xattrGetDone = YES;
        }];
        assert(xattrGetDone);

        /* 6D: List xattrs */
        __block BOOL xattrListDone = NO;
        [xattrVol listXattrsOfItem:itemEvidence replyHandler:^(NSArray<FSFileName *> * _Nullable value, NSError * _Nullable error) {
            assert(error == nil);
            assert(value != nil);
            assert(value.count >= 1);
            BOOL found = NO;
            for (FSFileName *fn in value) {
                if ([fn.string isEqualToString:@"com.apple.quarantine"]) {
                    found = YES;
                    break;
                }
            }
            assert(found);
            xattrListDone = YES;
        }];
        assert(xattrListDone);

        /* 6E: Delete xattr with FSSetXattrPolicyDelete */
        __block BOOL xattrDeleteDone = NO;
        [xattrVol setXattrNamed:xattrQuarantine toData:nil onItem:itemEvidence policy:FSSetXattrPolicyDelete replyHandler:^(NSError * _Nullable error) {
            assert(error == nil);
            xattrDeleteDone = YES;
        }];
        assert(xattrDeleteDone);

        /* 6F: Read back deleted xattr fails with ENOATTR */
        __block BOOL xattrNotFound = NO;
        [xattrVol getXattrNamed:xattrQuarantine ofItem:itemEvidence replyHandler:^(NSData * _Nullable value, NSError * _Nullable error) {
            (void)value;
            assert(error != nil);
            assert(error.code == ENOATTR);
            xattrNotFound = YES;
        }];
        assert(xattrNotFound);
        [xattrVol cleanup];
        printf("PASS\n");

        /* Test 7: Cryptographic Chain-of-Custody Hashing & Auto-ADS */
        printf("[test_fskit_bridge] Test 7: Chain-of-custody cryptographic hashing & auto-ADS... ");
        MockFSBlockResource *cryptoMockRes = [[MockFSBlockResource alloc] init];
        format_mock_ntfs_boot_sector(cryptoMockRes);

        FSVolumeIdentifier *cryptoVolID = [[FSVolumeIdentifier alloc] initWithUUID:[NSUUID UUID]];
        FSFileName *cryptoVolName = [[FSFileName alloc] initWithString:@"Crypto Vol"];
        KTYVolume *cryptoVol = [[KTYVolume alloc] initWithResource:(FSBlockDeviceResource *)cryptoMockRes
                                                         volumeID:cryptoVolID
                                                       volumeName:cryptoVolName
                                                         readOnly:NO];
        assert(cryptoVol != nil);
        [cryptoVol mountWithOptions:taskOpts replyHandler:^(NSError * _Nullable err) {
            assert(err == nil);
        }];

        FSFileName *fnAudit = [[FSFileName alloc] initWithCString:"evidence_master.raw"];
        __block KTYItem *itemAudit = nil;
        [cryptoVol createItemNamed:fnAudit type:FSItemTypeFile inDirectory:cryptoVol.rootItem attributes:dummyReq replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
            (void)newItemName;
            assert(error == nil);
            itemAudit = (KTYItem *)newItem;
        }];
        assert(itemAudit != nil);

        /* Write 4096 bytes with known bytes */
        uint8_t auditBytes[4096];
        for (size_t i = 0; i < sizeof(auditBytes); i++) {
            auditBytes[i] = (uint8_t)(i & 0xFF);
        }
        NSData *auditData = [NSData dataWithBytes:auditBytes length:sizeof(auditBytes)];

        /* Compute expected hashes */
        uint8_t expSha[32], expBlake[32];
        char expShaHex[65], expBlakeHex[65];
        kty_sha256_data(auditBytes, sizeof(auditBytes), expSha);
        kty_digest_to_hex(expSha, expShaHex);
        kty_blake3_data(auditBytes, sizeof(auditBytes), expBlake);
        kty_digest_to_hex(expBlake, expBlakeHex);
        NSString *expShaHexStr = [NSString stringWithUTF8String:expShaHex];
        NSString *expBlakeHexStr = [NSString stringWithUTF8String:expBlakeHex];

        __block BOOL auditWriteDone = NO;
        [cryptoVol writeContents:auditData toFile:itemAudit atOffset:0 replyHandler:^(size_t actuallyWritten, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyWritten == sizeof(auditBytes));
            auditWriteDone = YES;
        }];
        assert(auditWriteDone);

        /* Verify hashes updated on item */
        assert([itemAudit.sha256Hex isEqualToString:expShaHexStr]);
        assert([itemAudit.blake3Hex isEqualToString:expBlakeHexStr]);

        /* Verify Alternate Data Streams automatically populated for chain-of-custody */
        FSFileName *adsShaName = [[FSFileName alloc] initWithString:@"kty.integrity.sha256"];
        FSFileName *adsBlakeName = [[FSFileName alloc] initWithString:@"kty.integrity.blake3"];

        __block BOOL shaAdsVerified = NO;
        [cryptoVol getXattrNamed:adsShaName ofItem:itemAudit replyHandler:^(NSData * _Nullable value, NSError * _Nullable error) {
            assert(error == nil);
            assert(value != nil);
            NSString *valStr = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
            assert([valStr isEqualToString:expShaHexStr]);
            shaAdsVerified = YES;
        }];
        assert(shaAdsVerified);

        __block BOOL blakeAdsVerified = NO;
        [cryptoVol getXattrNamed:adsBlakeName ofItem:itemAudit replyHandler:^(NSData * _Nullable value, NSError * _Nullable error) {
            assert(error == nil);
            assert(value != nil);
            NSString *valStr = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
            assert([valStr isEqualToString:expBlakeHexStr]);
            blakeAdsVerified = YES;
        }];
        assert(blakeAdsVerified);

        /* 7B: Truncation clears stale ADS hash streams */
        [itemAudit truncateToSize:1024];
        assert(itemAudit.sha256Hex == nil);
        assert(itemAudit.blake3Hex == nil);
        __block BOOL staleShaCleared = NO;
        [cryptoVol getXattrNamed:adsShaName ofItem:itemAudit replyHandler:^(NSData * _Nullable value, NSError * _Nullable error) {
            (void)value;
            assert(error != nil);
            assert(error.code == ENOATTR);
            staleShaCleared = YES;
        }];
        assert(staleShaCleared);

        /* 7C: Segmented/append write recomputes new hash from disk via streaming */
        uint8_t appendChunk[512];
        memset(appendChunk, 0xEE, sizeof(appendChunk));
        NSData *appendData = [NSData dataWithBytes:appendChunk length:sizeof(appendChunk)];
        __block BOOL appendDone = NO;
        [cryptoVol writeContents:appendData toFile:itemAudit atOffset:1024 replyHandler:^(size_t actuallyWritten, NSError * _Nullable error) {
            assert(error == nil);
            assert(actuallyWritten == sizeof(appendChunk));
            appendDone = YES;
        }];
        assert(appendDone);
        assert(itemAudit.size == 1536);
        assert(itemAudit.sha256Hex != nil);
        assert(itemAudit.blake3Hex != nil);

        /* Verify recomputed hash matches new content */
        __block BOOL recomputedShaVerified = NO;
        [cryptoVol getXattrNamed:adsShaName ofItem:itemAudit replyHandler:^(NSData * _Nullable value, NSError * _Nullable error) {
            assert(error == nil);
            assert(value != nil);
            NSString *valStr = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
            assert([valStr isEqualToString:itemAudit.sha256Hex]);
            recomputedShaVerified = YES;
        }];
        assert(recomputedShaVerified);

        [cryptoVol cleanup];
        printf("PASS\n");

        printf("[test_fskit_bridge] All FSKit extension bridge tests passed successfully!\n");
    }
    return 0;
}
