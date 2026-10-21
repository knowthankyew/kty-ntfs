#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>

#ifndef _WINDEF_H
#define _WINDEF_H
#endif
#include "kty_io.h"
#include "kty_crypto.h"

#ifndef ENOATTR
#define ENOATTR 93
#endif

NS_ASSUME_NONNULL_BEGIN

@interface KTYItem : FSItem

@property (nonatomic, assign) FSItemID itemID;
@property (nonatomic, assign) FSItemType itemType;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) uint64_t size;
@property (nonatomic, assign) uint64_t allocatedSize;
@property (nonatomic, assign) off_t diskOffset;
@property (nonatomic, assign) uint32_t mode;
@property (nonatomic, assign) uint32_t uid;
@property (nonatomic, assign) uint32_t gid;
@property (nonatomic, assign) time_t mtime;
@property (nonatomic, assign) time_t ctime;
@property (nonatomic, strong, readonly, nullable) NSMutableDictionary<NSString *, KTYItem *> *children;

/* Forensic Hygiene & Metadata Suppression */
@property (nonatomic, assign) BOOL isForensicTombstone;

/* Extended Attributes & Alternate Data Streams (ADS) */
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, NSData *> *extendedAttributes;

/* Cryptographic Chain-of-Custody Hashes */
@property (nonatomic, copy, nullable) NSString *sha256Hex;
@property (nonatomic, copy, nullable) NSString *blake3Hex;

+ (instancetype)rootDirectoryItem;
+ (instancetype)itemWithID:(FSItemID)itemID
                      name:(NSString *)name
                      path:(NSString *)path
                      type:(FSItemType)type
                      size:(uint64_t)size
                      mode:(uint32_t)mode;

- (void)addChild:(KTYItem *)child;
- (void)removeChildNamed:(NSString *)name;
- (nullable KTYItem *)childNamed:(NSString *)name;
- (void)truncateToSize:(uint64_t)newSize;
- (void)populateAttributes:(FSItemAttributes *)attributes;

/* Extended Attributes Operations */
- (nullable NSData *)xattrNamed:(NSString *)name;
- (BOOL)setXattrNamed:(NSString *)name
                 data:(nullable NSData *)data
               policy:(FSSetXattrPolicy)policy
                error:(NSError **)error;
- (NSArray<NSString *> *)listXattrNames;
- (BOOL)removeXattrNamed:(NSString *)name error:(NSError **)error;

/* Forensic Integrity Hashing */
- (void)updateForensicHashesWithData:(NSData *)data offset:(uint64_t)offset;
- (void)recomputeForensicHashesFromDevice:(struct ntfs_device *)dev;

/* System Metadata Detection */
+ (BOOL)isSystemMetadataName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
