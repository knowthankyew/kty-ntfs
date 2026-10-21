#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>
#import "KTYItem.h"

#ifndef _WINDEF_H
#define _WINDEF_H
#endif
#include "kty_io.h"
#include "kty_crypto.h"

NS_ASSUME_NONNULL_BEGIN

@interface KTYVolume : FSVolume <FSVolumeOperations, FSVolumeReadWriteOperations, FSVolumePathConfOperations, FSVolumeXattrOperations>

@property (nonatomic, readonly) FSBlockDeviceResource *blockResource;
@property (nonatomic, readonly, nullable) struct ntfs_device *ntfsDevice;
@property (nonatomic, strong, readonly) KTYItem *rootItem;
@property (nonatomic, assign) BOOL isMounted;
@property (nonatomic, assign) BOOL readOnly;
@property (nonatomic, assign) BOOL allowSystemMetadata;
@property (nonatomic, assign, readonly) BOOL isDirty;
@property (nonatomic, assign, readonly) uint64_t totalBytesWritten;
@property (nonatomic, assign, readonly) uint32_t activeTransactions;
@property (nonatomic, assign, readonly) uint64_t suppressedMetadataOperations;

- (instancetype)initWithResource:(FSBlockDeviceResource *)resource
                        volumeID:(FSVolumeIdentifier *)volumeID
                      volumeName:(FSFileName *)volumeName
                        readOnly:(BOOL)readOnly;

- (void)cleanup;

@end

NS_ASSUME_NONNULL_END
