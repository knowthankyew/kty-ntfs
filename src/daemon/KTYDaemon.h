#import <Foundation/Foundation.h>
#import <DiskArbitration/DiskArbitration.h>
#import "KTYDaemonProtocol.h"
#import "KTYVolume.h"

NS_ASSUME_NONNULL_BEGIN

@interface KTYMountedVolumeInfo : NSObject

@property (nonatomic, copy) NSString *bsdName;
@property (nonatomic, copy) NSString *devicePath;
@property (nonatomic, copy) NSString *mountPoint;
@property (nonatomic, copy) NSString *volumeName;
@property (nonatomic, copy) NSString *volumeUUID;
@property (nonatomic, copy, nullable) NSString *volumeType;
@property (nonatomic, assign) BOOL readOnly;
@property (nonatomic, assign) BOOL allowSystemMetadata;
@property (nonatomic, strong, nullable) KTYVolume *ktyVolume;
@property (nonatomic, assign) time_t mountTime;

- (NSDictionary *)toDictionary;

@end

@interface KTYDaemon : NSObject <NSXPCListenerDelegate, KTYDaemonProtocol>

@property (nonatomic, assign, readonly) time_t startTime;
@property (nonatomic, assign) BOOL autoMountEnabled;
@property (nonatomic, copy, nullable) NSString *machServiceName;
@property (nonatomic, strong, readonly, nullable) NSXPCListener *listener;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, KTYMountedVolumeInfo *> *mountedVolumes;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, NSDictionary *> *detectedDisks;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, NSDictionary *> *autoMountTargets;

+ (instancetype)sharedDaemon;
- (instancetype)initWithMachServiceName:(nullable NSString *)serviceName;

- (BOOL)startWithEndpoint:(NSXPCListenerEndpoint * _Nullable * _Nullable)outEndpoint
                    error:(NSError **)error;
- (void)stop;

- (void)registerDiskAppeared:(NSString *)bsdName description:(NSDictionary *)desc;
- (void)registerDiskDisappeared:(NSString *)bsdName;
- (nullable DADissenterRef)evaluateMountApprovalForDisk:(nullable DADiskRef)disk;
- (nullable DADissenterRef)evaluateMountApprovalForDiskDescription:(nullable NSDictionary *)dict;

- (uint64_t)totalSuppressedMetadataOperations;
- (uint64_t)totalTransactions;
- (uint64_t)totalBytesWritten;

@end

NS_ASSUME_NONNULL_END
