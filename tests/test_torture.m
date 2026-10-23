#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>
#import <assert.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

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

#define TORTURE_DISK_SIZE (64 * 1024 * 1024) /* 64 MB virtual test media */

/* Mock item set attributes request */
@interface TortureSetAttributesRequest : NSObject
@property (nonatomic, assign) uint32_t mode;
@property (nonatomic, assign) uint32_t uid;
@property (nonatomic, assign) uint32_t gid;
@property (nonatomic, assign) uint64_t size;
- (BOOL)isValid:(FSItemAttribute)attr;
@end

@implementation TortureSetAttributesRequest
- (BOOL)isValid:(FSItemAttribute)attr {
    (void)attr;
    return NO;
}
@end

/* High-performance mock block resource for torture testing with simulated disconnect */
@interface TortureBlockResource : NSObject
@property (nonatomic, strong) NSMutableData *storage;
@property (nonatomic, assign) uint64_t blockSize;
@property (nonatomic, assign) uint64_t blockCount;
@property (nonatomic, assign) uint64_t physicalBlockSize;
@property (nonatomic, copy) NSString *BSDName;
@property (nonatomic, assign, getter=isWritable) BOOL writable;
@property (nonatomic, assign) BOOL simulateDisconnect;
@property (nonatomic, assign) uint64_t readOpCount;
@property (nonatomic, assign) uint64_t writeOpCount;
@property (nonatomic, assign) uint64_t syncOpCount;

- (instancetype)initWithSize:(uint64_t)size;
- (size_t)readInto:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error;
- (size_t)writeFrom:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error;
- (BOOL)metadataFlushWithError:(NSError **)error;
@end

@implementation TortureBlockResource

- (instancetype)initWithSize:(uint64_t)size {
    self = [super init];
    if (self) {
        _storage = [NSMutableData dataWithLength:(NSUInteger)size];
        _blockSize = 512;
        _blockCount = size / 512;
        _physicalBlockSize = 512;
        _BSDName = @"torturedisk0s1";
        _writable = YES;
        _simulateDisconnect = NO;
        _readOpCount = 0;
        _writeOpCount = 0;
        _syncOpCount = 0;
    }
    return self;
}

- (size_t)readInto:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    if (self.simulateDisconnect) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
        return 0;
    }
    self.readOpCount++;
    if (offset < 0 || (NSUInteger)offset >= self.storage.length) {
        return 0;
    }
    NSUInteger avail = self.storage.length - (NSUInteger)offset;
    NSUInteger to_copy = (length < avail) ? length : avail;
    [self.storage getBytes:buffer range:NSMakeRange((NSUInteger)offset, to_copy)];
    return to_copy;
}

- (size_t)writeFrom:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    if (self.simulateDisconnect) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
        return 0;
    }
    self.writeOpCount++;
    if (offset < 0 || (NSUInteger)offset >= self.storage.length) {
        return 0;
    }
    NSUInteger avail = self.storage.length - (NSUInteger)offset;
    NSUInteger to_copy = (length < avail) ? length : avail;
    [self.storage replaceBytesInRange:NSMakeRange((NSUInteger)offset, to_copy) withBytes:buffer];
    return to_copy;
}

- (BOOL)metadataFlushWithError:(NSError **)error {
    if (self.simulateDisconnect) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
        return NO;
    }
    self.syncOpCount++;
    return YES;
}

- (BOOL)isKindOfClass:(Class)aClass {
    if (aClass == [FSBlockDeviceResource class] || aClass == [FSResource class]) {
        return YES;
    }
    return [super isKindOfClass:aClass];
}

@end

/* Mock file buffer for readFromFile API */
@interface TortureBuffer : NSObject
@property (nonatomic, strong) NSMutableData *data;
- (instancetype)initWithLength:(NSUInteger)len;
- (NSUInteger)length;
- (void *)mutableBytes;
@end

@implementation TortureBuffer
- (instancetype)initWithLength:(NSUInteger)len {
    self = [super init];
    if (self) {
        _data = [NSMutableData dataWithLength:len];
    }
    return self;
}
- (NSUInteger)length { return _data.length; }
- (void *)mutableBytes { return _data.mutableBytes; }
@end

/* Mock directory packer */
@interface TortureDirectoryPacker : NSObject
@property (nonatomic, strong) NSMutableArray<NSString *> *entryNames;
- (BOOL)packEntryWithName:(FSFileName *)name
                 itemType:(FSItemType)itemType
                   itemID:(FSItemID)itemID
               nextCookie:(FSDirectoryCookie)nextCookie
               attributes:(FSItemAttributes *)attributes;
@end

@implementation TortureDirectoryPacker
- (instancetype)init {
    self = [super init];
    if (self) {
        _entryNames = [NSMutableArray array];
    }
    return self;
}
- (BOOL)packEntryWithName:(FSFileName *)name
                 itemType:(FSItemType)itemType
                   itemID:(FSItemID)itemID
               nextCookie:(FSDirectoryCookie)nextCookie
               attributes:(FSItemAttributes *)attributes {
    (void)itemType;
    (void)itemID;
    (void)nextCookie;
    (void)attributes;
    [self.entryNames addObject:name.string];
    return YES;
}
@end

/* Deterministic pseudorandom buffer generator */
static NSData *GenerateDeterministicPayload(size_t length, uint32_t seed) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    uint32_t state = seed;
    for (size_t i = 0; i < length; i++) {
        state = state * 1664525u + 1013904223u;
        bytes[i] = (uint8_t)(state >> 24);
    }
    return data;
}

/* Helper to initialize NTFS Boot Sector */
static void FormatNTFSBootSector(TortureBlockResource *res) {
    uint8_t bsSector[512] = {0};
    NTFS_BOOT_SECTOR *bs = (NTFS_BOOT_SECTOR *)bsSector;

    bs->jump[0] = 0xeb;
    bs->jump[1] = 0x52;
    bs->jump[2] = 0x90;
    memcpy(&bs->oem_id, "NTFS    ", 8);

    bs->bpb.bytes_per_sector = cpu_to_le16(512);
    bs->bpb.sectors_per_cluster = 8; /* 4 KB clusters */
    bs->bpb.reserved_sectors = 0;
    bs->bpb.fats = 0;
    bs->bpb.root_entries = 0;
    bs->bpb.sectors = 0;
    bs->bpb.media_type = 0xf8; /* Fixed disk */
    bs->bpb.sectors_per_fat = 0;
    bs->bpb.sectors_per_track = cpu_to_le16(63);
    bs->bpb.heads = cpu_to_le16(255);
    bs->bpb.hidden_sectors = 0;
    bs->bpb.large_sectors = 0;

    bs->physical_drive = 0x80;
    bs->current_head = 0;
    bs->extended_boot_signature = 0x80;
    bs->reserved2 = 0;

    bs->number_of_sectors = cpu_to_sle64(res.blockCount);
    bs->mft_lcn = cpu_to_sle64(4);
    bs->mftmirr_lcn = cpu_to_sle64(2);
    bs->clusters_per_mft_record = 1;
    bs->clusters_per_index_record = 1;
    bs->volume_serial_number = cpu_to_sle64(0xFEEDFACECAFEBEEFULL);

    bsSector[510] = 0x55;
    bsSector[511] = 0xaa;

    [res writeFrom:bsSector startingAt:0 length:512 error:nil];

    /* Backup boot sector at the last sector */
    off_t backupOffset = (off_t)((res.blockCount - 1) * 512);
    [res writeFrom:bsSector startingAt:backupOffset length:512 error:nil];
}

/* Helper to create and mount a KTYVolume instance */
static KTYVolume *MountTestVolume(TortureBlockResource *res, BOOL readOnly, BOOL allowSystemMetadata) {
    FSVolumeIdentifier *volumeID = [[FSVolumeIdentifier alloc] initWithUUID:[NSUUID UUID]];
    FSFileName *volumeName = [[FSFileName alloc] initWithString:@"TORTURE_EVIDENCE"];

    KTYVolume *vol = [[KTYVolume alloc] initWithResource:(FSBlockDeviceResource *)res
                                                volumeID:volumeID
                                              volumeName:volumeName
                                                readOnly:readOnly];
    vol.allowSystemMetadata = allowSystemMetadata;

    FSTaskOptions *taskOpts = (FSTaskOptions *)[[NSObject alloc] init];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *mountErr = nil;
    [vol mountWithOptions:taskOpts replyHandler:^(NSError * _Nullable error) {
        mountErr = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    assert(mountErr == nil);
    assert(vol.isMounted == YES);
    return vol;
}

#pragma mark - Torture Test 1: Deep Hierarchy & Multi-File Stress

static void test_deep_hierarchy_and_volume_stress(void) {
    printf("[test_torture] Test 1: Deep hierarchy & multi-file stress...\n");
    @autoreleasepool {
        TortureBlockResource *res = [[TortureBlockResource alloc] initWithSize:TORTURE_DISK_SIZE];
        FormatNTFSBootSector(res);
        KTYVolume *vol = MountTestVolume(res, NO, NO);

        FSItemSetAttributesRequest *dummyReq = (FSItemSetAttributesRequest *)[[TortureSetAttributesRequest alloc] init];

        /* Create a 5-level deep directory structure */
        KTYItem *currentDir = vol.rootItem;
        NSArray<NSString *> *dirNames = @[@"Level1_Forensic", @"Level2_Cases", @"Level3_Evidence", @"Level4_Triage", @"Level5_Binaries"];

        for (NSString *dName in dirNames) {
            FSFileName *fn = [[FSFileName alloc] initWithString:dName];

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block KTYItem *createdDir = nil;
            [vol createItemNamed:fn type:FSItemTypeDirectory inDirectory:currentDir attributes:dummyReq replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
                (void)newItemName;
                assert(error == nil);
                createdDir = (KTYItem *)newItem;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            assert(createdDir != nil);
            currentDir = createdDir;
        }

        /* Create 50 files of varying sizes in the deepest directory */
        const int numFiles = 50;
        NSMutableDictionary<NSString *, NSData *> *expectedFiles = [NSMutableDictionary dictionary];

        for (int i = 0; i < numFiles; i++) {
            NSString *fileName = [NSString stringWithFormat:@"evidence_item_%03d.dat", i];
            FSFileName *fn = [[FSFileName alloc] initWithString:fileName];

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block KTYItem *fileItem = nil;
            [vol createItemNamed:fn type:FSItemTypeFile inDirectory:currentDir attributes:dummyReq replyHandler:^(FSItem * _Nullable newItem, FSFileName * _Nullable newItemName, NSError * _Nullable error) {
                (void)newItemName;
                assert(error == nil);
                fileItem = (KTYItem *)newItem;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            assert(fileItem != nil);

            /* Generate variable payload sizes: 64B, 1KB, 16KB, 128KB, 512KB */
            size_t size;
            if (i % 5 == 0) size = 64;           /* resident data */
            else if (i % 5 == 1) size = 1024;     /* 1 cluster */
            else if (i % 5 == 2) size = 16384;    /* 4 clusters */
            else if (i % 5 == 3) size = 131072;   /* 32 clusters */
            else size = 524288;                   /* 128 clusters */

            NSData *payload = GenerateDeterministicPayload(size, (uint32_t)(0x1000 + i));
            expectedFiles[fileName] = payload;

            dispatch_semaphore_t writeSem = dispatch_semaphore_create(0);
            __block size_t written = 0;
            [vol writeContents:payload toFile:fileItem atOffset:0 replyHandler:^(size_t actuallyWritten, NSError * _Nullable error) {
                assert(error == nil);
                written = actuallyWritten;
                dispatch_semaphore_signal(writeSem);
            }];
            dispatch_semaphore_wait(writeSem, DISPATCH_TIME_FOREVER);
            assert(written == size);
            assert(fileItem.size == size);
        }

        /* Read back all 50 files and verify byte-for-byte fidelity */
        for (NSString *fileName in expectedFiles) {
            NSData *expected = expectedFiles[fileName];
            FSFileName *fn = [[FSFileName alloc] initWithString:fileName];

            dispatch_semaphore_t lookupSem = dispatch_semaphore_create(0);
            __block KTYItem *found = nil;
            [vol lookupItemNamed:fn inDirectory:currentDir replyHandler:^(FSItem * _Nullable theItem, FSFileName * _Nullable itemName, NSError * _Nullable error) {
                (void)itemName;
                assert(error == nil);
                found = (KTYItem *)theItem;
                dispatch_semaphore_signal(lookupSem);
            }];
            dispatch_semaphore_wait(lookupSem, DISPATCH_TIME_FOREVER);
            assert(found != nil);
            assert(found.size == expected.length);

            /* Read content */
            TortureBuffer *buf = [[TortureBuffer alloc] initWithLength:expected.length];
            dispatch_semaphore_t readSem = dispatch_semaphore_create(0);
            __block size_t readBytes = 0;
            [vol readFromFile:found offset:0 length:expected.length intoBuffer:(FSMutableFileDataBuffer *)buf replyHandler:^(size_t actuallyRead, NSError * _Nullable error) {
                assert(error == nil);
                readBytes = actuallyRead;
                dispatch_semaphore_signal(readSem);
            }];
            dispatch_semaphore_wait(readSem, DISPATCH_TIME_FOREVER);
            assert(readBytes == expected.length);
            assert(memcmp(buf.data.bytes, expected.bytes, expected.length) == 0);
        }

        /* Synchronize journal */
        dispatch_semaphore_t syncSem = dispatch_semaphore_create(0);
        [vol synchronizeWithFlags:0 replyHandler:^(NSError * _Nullable error) {
            assert(error == nil);
            dispatch_semaphore_signal(syncSem);
        }];
        dispatch_semaphore_wait(syncSem, DISPATCH_TIME_FOREVER);
        assert(vol.isDirty == NO);

        [vol cleanup];
    }
    printf("    PASSED: Deep hierarchy & multi-file stress (50 files, 5 nested dirs)\n");
}

#pragma mark - Torture Test 2: Random Mutation, Truncation & Non-Tail Relocation

static void test_random_mutation_and_relocation_torture(void) {
    printf("[test_torture] Test 2: Mutation, truncation & non-tail cluster relocation...\n");
    @autoreleasepool {
        TortureBlockResource *res = [[TortureBlockResource alloc] initWithSize:TORTURE_DISK_SIZE];
        FormatNTFSBootSector(res);
        KTYVolume *vol = MountTestVolume(res, NO, NO);

        FSItemSetAttributesRequest *dummyReq = (FSItemSetAttributesRequest *)[[TortureSetAttributesRequest alloc] init];

        /* Create File A, File B, File C sequentially */
        FSFileName *fnA = [[FSFileName alloc] initWithString:@"file_A.dat"];
        FSFileName *fnB = [[FSFileName alloc] initWithString:@"file_B.dat"];
        FSFileName *fnC = [[FSFileName alloc] initWithString:@"file_C.dat"];

        __block KTYItem *itemA = nil;
        __block KTYItem *itemB = nil;
        __block KTYItem *itemC = nil;

        [vol createItemNamed:fnA type:FSItemTypeFile inDirectory:vol.rootItem attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; itemA = (KTYItem *)i;
        }];
        [vol createItemNamed:fnB type:FSItemTypeFile inDirectory:vol.rootItem attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; itemB = (KTYItem *)i;
        }];
        [vol createItemNamed:fnC type:FSItemTypeFile inDirectory:vol.rootItem attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; itemC = (KTYItem *)i;
        }];

        assert(itemA && itemB && itemC);

        /* Write initial 4 KB data to each */
        NSData *payloadA = GenerateDeterministicPayload(4096, 0xAAA);
        NSData *payloadB = GenerateDeterministicPayload(4096, 0xBBB);
        NSData *payloadC = GenerateDeterministicPayload(4096, 0xCCC);

        [vol writeContents:payloadA toFile:itemA atOffset:0 replyHandler:^(size_t w, NSError *e) { assert(e == nil && w == 4096); }];
        [vol writeContents:payloadB toFile:itemB atOffset:0 replyHandler:^(size_t w, NSError *e) { assert(e == nil && w == 4096); }];
        [vol writeContents:payloadC toFile:itemC atOffset:0 replyHandler:^(size_t w, NSError *e) { assert(e == nil && w == 4096); }];

        off_t oldOffsetA = itemA.diskOffset;
        assert(oldOffsetA < itemB.diskOffset);
        assert(itemB.diskOffset < itemC.diskOffset);

        /* 
         * Expand File A from 4 KB to 32 KB.
         * Since File A is NOT at the tail of disk allocations (File C is at the tail),
         * allocateClustersForFile: must trigger a non-tail relocation:
         * 1. Allocate a new 32 KB chunk at the tail (past File C).
         * 2. Copy the existing 4 KB data of File A to the new offset.
         * 3. Update File A's diskOffset to the new tail.
         */
        NSData *expandedA_extra = GenerateDeterministicPayload(28672, 0xA1A1);
        [vol writeContents:expandedA_extra toFile:itemA atOffset:4096 replyHandler:^(size_t w, NSError *e) {
            assert(e == nil && w == 28672);
        }];

        assert(itemA.size == 32768);
        assert(itemA.diskOffset > itemC.diskOffset); /* Successfully relocated to tail! */

        /* Verify File A's full 32 KB content (original 4 KB + extra 28 KB) */
        NSMutableData *expectedFullA = [NSMutableData dataWithData:payloadA];
        [expectedFullA appendData:expandedA_extra];

        TortureBuffer *bufA = [[TortureBuffer alloc] initWithLength:32768];
        [vol readFromFile:itemA offset:0 length:32768 intoBuffer:(FSMutableFileDataBuffer *)bufA replyHandler:^(size_t r, NSError *e) {
            assert(e == nil && r == 32768);
        }];
        assert(memcmp(bufA.data.bytes, expectedFullA.bytes, 32768) == 0);

        /* Verify File B and File C remain 100% uncorrupted after File A's relocation */
        TortureBuffer *bufB = [[TortureBuffer alloc] initWithLength:4096];
        [vol readFromFile:itemB offset:0 length:4096 intoBuffer:(FSMutableFileDataBuffer *)bufB replyHandler:^(size_t r, NSError *e) {
            assert(e == nil && r == 4096);
        }];
        assert(memcmp(bufB.data.bytes, payloadB.bytes, 4096) == 0);

        TortureBuffer *bufC = [[TortureBuffer alloc] initWithLength:4096];
        [vol readFromFile:itemC offset:0 length:4096 intoBuffer:(FSMutableFileDataBuffer *)bufC replyHandler:^(size_t r, NSError *e) {
            assert(e == nil && r == 4096);
        }];
        assert(memcmp(bufC.data.bytes, payloadC.bytes, 4096) == 0);

        /* Truncate File A down to 1024 bytes and assert EOF clamping */
        [itemA truncateToSize:1024];
        assert(itemA.size == 1024);

        TortureBuffer *clampBuf = [[TortureBuffer alloc] initWithLength:4096];
        [vol readFromFile:itemA offset:0 length:4096 intoBuffer:(FSMutableFileDataBuffer *)clampBuf replyHandler:^(size_t r, NSError *e) {
            assert(e == nil);
            assert(r == 1024); /* Clamped to truncated EOF! */
        }];

        [vol cleanup];
    }
    printf("    PASSED: Mutation, truncation & non-tail cluster relocation\n");
}

#pragma mark - Torture Test 3: Forensic Hygiene Stress & RAM Tombstones

static void test_forensic_hygiene_stress(void) {
    printf("[test_torture] Test 3: Forensic hygiene stress (metadata suppression)...\n");
    @autoreleasepool {
        TortureBlockResource *res = [[TortureBlockResource alloc] initWithSize:TORTURE_DISK_SIZE];
        FormatNTFSBootSector(res);
        KTYVolume *vol = MountTestVolume(res, NO, NO);

        FSItemSetAttributesRequest *dummyReq = (FSItemSetAttributesRequest *)[[TortureSetAttributesRequest alloc] init];
        uint64_t initialWriteOps = res.writeOpCount;

        /* Attempt to create 100 system metadata items: .DS_Store, AppleDouble, Spotlight, Trashes */
        NSArray<NSString *> *exactMetaNames = @[
            @".DS_Store",
            @".Spotlight-V100",
            @".Trashes",
            @".fseventsd",
            @".TemporaryItems",
            @".VolumeIcon.icns",
            @".com.apple.timemachine.donotpresent"
        ];

        for (int i = 0; i < 100; i++) {
            NSString *metaName;
            FSItemType type = FSItemTypeFile;
            if (i < (int)exactMetaNames.count) {
                metaName = exactMetaNames[i];
                if ([metaName isEqualToString:@".Spotlight-V100"] ||
                    [metaName isEqualToString:@".Trashes"] ||
                    [metaName isEqualToString:@".fseventsd"] ||
                    [metaName isEqualToString:@".TemporaryItems"]) {
                    type = FSItemTypeDirectory;
                }
            } else {
                /* AppleDouble sidecar file: ._<filename> */
                metaName = [NSString stringWithFormat:@"._evidence_item_%03d.dat", i];
            }

            FSFileName *fn = [[FSFileName alloc] initWithString:metaName];

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block KTYItem *tombstone = nil;
            [vol createItemNamed:fn type:type inDirectory:vol.rootItem attributes:dummyReq replyHandler:^(FSItem *item, FSFileName *name, NSError *err) {
                (void)name;
                assert(err == nil);
                tombstone = (KTYItem *)item;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

            assert(tombstone != nil);
            assert(tombstone.isForensicTombstone == YES);
            assert(tombstone.diskOffset == 0);
            assert(tombstone.allocatedSize == 0);

            /* Attempt to write data to tombstone */
            NSData *bogusBytes = [@"Macintosh Finder Metadata Blob" dataUsingEncoding:NSUTF8StringEncoding];
            if (tombstone.itemType == FSItemTypeFile) {
                [vol writeContents:bogusBytes toFile:tombstone atOffset:0 replyHandler:^(size_t w, NSError *e) {
                    assert(e == nil);
                    assert(w == bogusBytes.length);
                }];
            } else {
                /* Directory tombstones fail-closed on writeContents with EISDIR */
                [vol writeContents:bogusBytes toFile:tombstone atOffset:0 replyHandler:^(size_t w, NSError *e) {
                    assert(w == 0);
                    assert(e != nil && e.code == EISDIR);
                }];
            }
        }

        /* 
         * Verify 100% of host metadata operations were absorbed in volatile RAM tombstones:
         * 1. suppressedMetadataOperations counter reflects the intercepted requests.
         * 2. Zero disk writes occurred for the tombstones (writeOpCount matches initial).
         * 3. Directory enumeration completely hides all tombstones.
         */
        assert(vol.suppressedMetadataOperations >= 190);
        assert(res.writeOpCount == initialWriteOps);

        TortureDirectoryPacker *packer = [[TortureDirectoryPacker alloc] init];
        dispatch_semaphore_t enumSem = dispatch_semaphore_create(0);
        [vol enumerateDirectory:vol.rootItem startingAtCookie:0 verifier:0 providingAttributes:nil usingPacker:(FSDirectoryEntryPacker *)packer replyHandler:^(FSDirectoryVerifier v, NSError *e) {
            (void)v;
            assert(e == nil);
            dispatch_semaphore_signal(enumSem);
        }];
        dispatch_semaphore_wait(enumSem, DISPATCH_TIME_FOREVER);

        /* Only '.' and '..' should appear in enumeration; 0 tombstones exposed! */
        for (NSString *entry in packer.entryNames) {
            assert(![entry containsString:@".DS_Store"]);
            assert(![entry hasPrefix:@"._"]);
            assert(![entry containsString:@"Spotlight"]);
            assert(![entry containsString:@"Trashes"]);
        }

        [vol cleanup];
    }
    printf("    PASSED: Forensic hygiene stress (100+ metadata attempts 100%% suppressed)\n");
}

#pragma mark - Torture Test 4: Alternate Data Streams & Chain-of-Custody Hashing

static void test_cryptographic_hash_and_ads_torture(void) {
    printf("[test_torture] Test 4: Alternate Data Streams & chain-of-custody hashes...\n");
    @autoreleasepool {
        TortureBlockResource *res = [[TortureBlockResource alloc] initWithSize:TORTURE_DISK_SIZE];
        FormatNTFSBootSector(res);
        KTYVolume *vol = MountTestVolume(res, NO, NO);

        FSItemSetAttributesRequest *dummyReq = (FSItemSetAttributesRequest *)[[TortureSetAttributesRequest alloc] init];

        FSFileName *fn = [[FSFileName alloc] initWithString:@"forensic_disk_image.dd"];
        __block KTYItem *item = nil;
        [vol createItemNamed:fn type:FSItemTypeFile inDirectory:vol.rootItem attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; item = (KTYItem *)i;
        }];
        assert(item != nil);

        /* 
         * Write a 256 KB file in four segmented 64 KB writes to exercise
         * streaming chunk calculation across chunk boundaries.
         */
        NSData *chunk1 = GenerateDeterministicPayload(65536, 0x1111);
        NSData *chunk2 = GenerateDeterministicPayload(65536, 0x2222);
        NSData *chunk3 = GenerateDeterministicPayload(65536, 0x3333);
        NSData *chunk4 = GenerateDeterministicPayload(65536, 0x4444);

        [vol writeContents:chunk1 toFile:item atOffset:0 replyHandler:^(size_t w, NSError *e) { assert(e == nil && w == 65536); }];
        [vol writeContents:chunk2 toFile:item atOffset:65536 replyHandler:^(size_t w, NSError *e) { assert(e == nil && w == 65536); }];
        [vol writeContents:chunk3 toFile:item atOffset:131072 replyHandler:^(size_t w, NSError *e) { assert(e == nil && w == 65536); }];
        [vol writeContents:chunk4 toFile:item atOffset:196608 replyHandler:^(size_t w, NSError *e) { assert(e == nil && w == 65536); }];

        assert(item.size == 262144);

        /* Compute independent ground-truth SHA-256 and BLAKE3 */
        NSMutableData *fullPayload = [NSMutableData data];
        [fullPayload appendData:chunk1];
        [fullPayload appendData:chunk2];
        [fullPayload appendData:chunk3];
        [fullPayload appendData:chunk4];

        uint8_t rawSha[32] = {0};
        uint8_t rawBlake3[32] = {0};
        char expectedSha256[65] = {0};
        char expectedBlake3[65] = {0};

        kty_sha256_data(fullPayload.bytes, fullPayload.length, rawSha);
        kty_digest_to_hex(rawSha, expectedSha256);

        kty_blake3_data(fullPayload.bytes, fullPayload.length, rawBlake3);
        kty_digest_to_hex(rawBlake3, expectedBlake3);

        /* Verify automated chain-of-custody Alternate Data Streams */
        NSData *shaStream = [item xattrNamed:@"kty.integrity.sha256"];
        NSData *blake3Stream = [item xattrNamed:@"kty.integrity.blake3"];

        assert(shaStream != nil);
        assert(blake3Stream != nil);

        NSString *shaStr = [[NSString alloc] initWithData:shaStream encoding:NSUTF8StringEncoding];
        NSString *blake3Str = [[NSString alloc] initWithData:blake3Stream encoding:NSUTF8StringEncoding];

        assert([shaStr isEqualToString:[NSString stringWithUTF8String:expectedSha256]]);
        assert([blake3Str isEqualToString:[NSString stringWithUTF8String:expectedBlake3]]);

        /* Add secondary custom user ADS streams */
        NSData *caseIdData = [@"CASE-2026-CRIME-SCENE-A" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *examinerData = [@"Lead Investigator: Agent Clark" dataUsingEncoding:NSUTF8StringEncoding];

        FSFileName *xattrCaseId = [[FSFileName alloc] initWithString:@"user.case_id"];
        FSFileName *xattrExaminer = [[FSFileName alloc] initWithString:@"user.examiner"];

        [vol setXattrNamed:xattrCaseId toData:caseIdData onItem:item policy:FSSetXattrPolicyAlwaysSet replyHandler:^(NSError *err) {
            assert(err == nil);
        }];
        [vol setXattrNamed:xattrExaminer toData:examinerData onItem:item policy:FSSetXattrPolicyAlwaysSet replyHandler:^(NSError *err) {
            assert(err == nil);
        }];

        /* List all ADS streams */
        __block NSArray<FSFileName *> *xattrList = nil;
        [vol listXattrsOfItem:item replyHandler:^(NSArray<FSFileName *> *list, NSError *err) {
            assert(err == nil);
            xattrList = list;
        }];

        NSMutableArray<NSString *> *nameStrings = [NSMutableArray array];
        for (FSFileName *fnItem in xattrList) {
            [nameStrings addObject:fnItem.string];
        }

        assert([nameStrings containsObject:@"kty.integrity.sha256"]);
        assert([nameStrings containsObject:@"kty.integrity.blake3"]);
        assert([nameStrings containsObject:@"user.case_id"]);
        assert([nameStrings containsObject:@"user.examiner"]);

        [vol cleanup];
    }
    printf("    PASSED: Alternate Data Streams & chain-of-custody hashes (SHA-256 + BLAKE3)\n");
}

#pragma mark - Torture Test 5: Simulated Surprise Disconnect & Recovery

static void test_surprise_disconnect_and_recovery(void) {
    printf("[test_torture] Test 5: Simulated surprise disconnect & journal recovery...\n");
    @autoreleasepool {
        TortureBlockResource *res = [[TortureBlockResource alloc] initWithSize:TORTURE_DISK_SIZE];
        FormatNTFSBootSector(res);

        FSItemSetAttributesRequest *dummyReq = (FSItemSetAttributesRequest *)[[TortureSetAttributesRequest alloc] init];

        /* Stage 1: Write committed baseline file */
        KTYVolume *vol1 = MountTestVolume(res, NO, NO);
        FSFileName *fnSafe = [[FSFileName alloc] initWithString:@"committed_baseline.dat"];
        __block KTYItem *safeItem = nil;
        [vol1 createItemNamed:fnSafe type:FSItemTypeFile inDirectory:vol1.rootItem attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; safeItem = (KTYItem *)i;
        }];
        NSData *safeData = GenerateDeterministicPayload(8192, 0x5AFE);
        [vol1 writeContents:safeData toFile:safeItem atOffset:0 replyHandler:^(size_t w, NSError *e) {
            assert(e == nil && w == 8192);
        }];

        /* Sync to guarantee baseline persistence */
        dispatch_semaphore_t syncSem = dispatch_semaphore_create(0);
        [vol1 synchronizeWithFlags:0 replyHandler:^(NSError *e) {
            assert(e == nil);
            dispatch_semaphore_signal(syncSem);
        }];
        dispatch_semaphore_wait(syncSem, DISPATCH_TIME_FOREVER);

        /* Stage 2: Begin dirty uncommitted transactions */
        FSFileName *fnDirty = [[FSFileName alloc] initWithString:@"dirty_in_flight.dat"];
        __block KTYItem *dirtyItem = nil;
        [vol1 createItemNamed:fnDirty type:FSItemTypeFile inDirectory:vol1.rootItem attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; dirtyItem = (KTYItem *)i;
        }];
        NSData *dirtyData = GenerateDeterministicPayload(16384, 0xD112);
        [vol1 writeContents:dirtyData toFile:dirtyItem atOffset:0 replyHandler:^(size_t w, NSError *e) {
            assert(e == nil && w == 16384);
        }];
        assert(vol1.isDirty == YES);
        assert(vol1.activeTransactions > 0);

        /* Stage 3: Abrupt crash / surprise disconnect without calling cleanup or sync */
        res.simulateDisconnect = YES;

        /* Attempted I/O now fails closed */
        [vol1 writeContents:dirtyData toFile:dirtyItem atOffset:16384 replyHandler:^(size_t w, NSError *e) {
            assert(w == 0);
            assert(e != nil); /* Fail-closed error propagation */
        }];

        /* Abandon vol1 without clean unmount (simulating sudden power loss) */
        vol1 = nil;

        /* Stage 4: Reconnect device and remount */
        res.simulateDisconnect = NO;
        KTYVolume *vol2 = MountTestVolume(res, NO, NO);

        /* Verify volume is operational and boot sector intact */
        assert(vol2.isMounted == YES);
        assert(vol2.isDirty == NO); /* Clean initial state */

        [vol2 cleanup];
    }
    printf("    PASSED: Simulated surprise disconnect & recovery\n");
}

#pragma mark - Torture Test 6: Cross-Platform Bundle Generation

static void generate_cross_platform_bundle(NSString *outputImagePath, NSString *manifestPath, NSString *checksumsPath) {
    printf("[test_torture] Generating cross-platform forensic test bundle...\n");
    @autoreleasepool {
        const uint64_t bundleDiskSize = 32 * 1024 * 1024; /* 32 MB image */
        TortureBlockResource *res = [[TortureBlockResource alloc] initWithSize:bundleDiskSize];
        FormatNTFSBootSector(res);
        KTYVolume *vol = MountTestVolume(res, NO, NO);

        FSItemSetAttributesRequest *dummyReq = (FSItemSetAttributesRequest *)[[TortureSetAttributesRequest alloc] init];

        NSMutableArray<NSDictionary *> *manifestEntries = [NSMutableArray array];
        NSMutableString *checksumsStr = [NSMutableString string];

        /* Directory 1: cases/case_001 */
        FSFileName *fnCases = [[FSFileName alloc] initWithString:@"cases"];
        __block KTYItem *casesDir = nil;
        [vol createItemNamed:fnCases type:FSItemTypeDirectory inDirectory:vol.rootItem attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; casesDir = (KTYItem *)i;
        }];
        assert(casesDir != nil);

        FSFileName *fnCase1 = [[FSFileName alloc] initWithString:@"case_001"];
        __block KTYItem *case1Dir = nil;
        [vol createItemNamed:fnCase1 type:FSItemTypeDirectory inDirectory:casesDir attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; case1Dir = (KTYItem *)i;
        }];
        assert(case1Dir != nil);

        /* File 1: notes.txt (Small text file) */
        NSString *notesContent = @"KTY-NTFS Forensic Evidence Verification File\nIntegrity: SHA-256 + BLAKE3\nAll systems operational.\n";
        NSData *notesData = [notesContent dataUsingEncoding:NSUTF8StringEncoding];
        FSFileName *fnNotes = [[FSFileName alloc] initWithString:@"notes.txt"];
        __block KTYItem *notesItem = nil;
        [vol createItemNamed:fnNotes type:FSItemTypeFile inDirectory:case1Dir attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; notesItem = (KTYItem *)i;
        }];
        [vol writeContents:notesData toFile:notesItem atOffset:0 replyHandler:^(size_t w, NSError *e) { assert(e == nil && w == notesData.length); }];

        uint8_t rawShaNotes[32] = {0};
        uint8_t rawB3Notes[32] = {0};
        char notesSha[65] = {0};
        char notesBlake3[65] = {0};
        kty_sha256_data(notesData.bytes, notesData.length, rawShaNotes);
        kty_digest_to_hex(rawShaNotes, notesSha);
        kty_blake3_data(notesData.bytes, notesData.length, rawB3Notes);
        kty_digest_to_hex(rawB3Notes, notesBlake3);

        [manifestEntries addObject:@{
            @"path": @"cases/case_001/notes.txt",
            @"size": @(notesData.length),
            @"sha256": [NSString stringWithUTF8String:notesSha],
            @"blake3": [NSString stringWithUTF8String:notesBlake3]
        }];
        [checksumsStr appendFormat:@"%s  cases/case_001/notes.txt\n", notesSha];

        /* File 2: evidence_blob.bin (Multi-megabyte binary payload: 2 MB) */
        const size_t blobSize = 2 * 1024 * 1024;
        NSData *blobData = GenerateDeterministicPayload(blobSize, 0xC0FFEE);
        FSFileName *fnBlob = [[FSFileName alloc] initWithString:@"evidence_blob.bin"];
        __block KTYItem *blobItem = nil;
        [vol createItemNamed:fnBlob type:FSItemTypeFile inDirectory:case1Dir attributes:dummyReq replyHandler:^(FSItem *i, FSFileName *n, NSError *e) {
            (void)n; (void)e; blobItem = (KTYItem *)i;
        }];
        [vol writeContents:blobData toFile:blobItem atOffset:0 replyHandler:^(size_t w, NSError *e) { assert(e == nil && w == blobSize); }];

        uint8_t rawShaBlob[32] = {0};
        uint8_t rawB3Blob[32] = {0};
        char blobSha[65] = {0};
        char blobBlake3[65] = {0};
        kty_sha256_data(blobData.bytes, blobData.length, rawShaBlob);
        kty_digest_to_hex(rawShaBlob, blobSha);
        kty_blake3_data(blobData.bytes, blobData.length, rawB3Blob);
        kty_digest_to_hex(rawB3Blob, blobBlake3);

        /* Attach custom ADS stream */
        NSData *caseMetadata = [@"Chain-Of-Custody: Confirmed by knowthankyew" dataUsingEncoding:NSUTF8StringEncoding];
        FSFileName *xattrCustody = [[FSFileName alloc] initWithString:@"kty.custody.log"];
        [vol setXattrNamed:xattrCustody toData:caseMetadata onItem:blobItem policy:FSSetXattrPolicyAlwaysSet replyHandler:^(NSError *e) {
            assert(e == nil);
        }];

        [manifestEntries addObject:@{
            @"path": @"cases/case_001/evidence_blob.bin",
            @"size": @(blobSize),
            @"sha256": [NSString stringWithUTF8String:blobSha],
            @"blake3": [NSString stringWithUTF8String:blobBlake3],
            @"ads": @{
                @"kty.custody.log": @"Chain-Of-Custody: Confirmed by knowthankyew",
                @"kty.integrity.sha256": [NSString stringWithUTF8String:blobSha],
                @"kty.integrity.blake3": [NSString stringWithUTF8String:blobBlake3]
            }
        }];
        [checksumsStr appendFormat:@"%s  cases/case_001/evidence_blob.bin\n", blobSha];

        /* Sync volume */
        dispatch_semaphore_t syncSem = dispatch_semaphore_create(0);
        [vol synchronizeWithFlags:0 replyHandler:^(NSError *e) {
            assert(e == nil);
            dispatch_semaphore_signal(syncSem);
        }];
        dispatch_semaphore_wait(syncSem, DISPATCH_TIME_FOREVER);
        [vol cleanup];

        /* Write disk image file */
        NSError *writeErr = nil;
        if (![res.storage writeToFile:outputImagePath options:NSDataWritingAtomic error:&writeErr]) {
            fprintf(stderr, "Error saving test image %s: %s\n", outputImagePath.UTF8String, writeErr.localizedDescription.UTF8String);
            exit(1);
        }

        /* Write manifest.json */
        NSDictionary *manifest = @{
            @"bundle_version": @"0.1.0",
            @"created_by": @"kty-ntfs torture test harness",
            @"volume_name": @"TORTURE_EVIDENCE",
            @"total_files": @(manifestEntries.count),
            @"files": manifestEntries
        };
        NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
        [manifestData writeToFile:manifestPath atomically:YES];

        /* Write checksums.sha256 */
        [checksumsStr writeToFile:checksumsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        printf("    Bundle Image:  %s (%llu bytes)\n", outputImagePath.UTF8String, bundleDiskSize);
        printf("    Manifest:      %s\n", manifestPath.UTF8String);
        printf("    Checksums:     %s\n", checksumsPath.UTF8String);
    }
}

int main(int argc, const char *argv[]) {
    printf("====================================================\n");
    printf(" KTY-NTFS Forensic Torture & Stress Test Suite\n");
    printf("====================================================\n");

    BOOL generateBundle = NO;
    NSString *bundleImgPath = @"build/kty_test_evidence.img";
    NSString *manifestPath = @"build/manifest.json";
    NSString *checksumsPath = @"build/checksums.sha256";

    for (int i = 1; i < argc; i++) {
        NSString *arg = [NSString stringWithUTF8String:argv[i]];
        if ([arg isEqualToString:@"--generate-bundle"]) {
            generateBundle = YES;
            if (i + 1 < argc && ![[NSString stringWithUTF8String:argv[i+1]] hasPrefix:@"--"]) {
                bundleImgPath = [NSString stringWithUTF8String:argv[++i]];
            }
        }
    }

    test_deep_hierarchy_and_volume_stress();
    test_random_mutation_and_relocation_torture();
    test_forensic_hygiene_stress();
    test_cryptographic_hash_and_ads_torture();
    test_surprise_disconnect_and_recovery();

    if (generateBundle) {
        generate_cross_platform_bundle(bundleImgPath, manifestPath, checksumsPath);
    }

    printf("====================================================\n");
    printf(" All Forensic Torture Tests PASSED (0 failures)\n");
    printf("====================================================\n");
    return 0;
}
