#import <Foundation/Foundation.h>

#define KTY_NTFSD_MACH_SERVICE @"com.knowthankyew.ntfsd"

NS_ASSUME_NONNULL_BEGIN

@protocol KTYDaemonProtocol <NSObject>

- (void)getStatusWithReply:(void (^)(NSDictionary * _Nullable status, NSError * _Nullable error))reply;

- (void)listDisksWithReply:(void (^)(NSArray<NSDictionary *> * _Nullable disks, NSError * _Nullable error))reply;

- (void)mountDevice:(NSString *)deviceBSDName
         targetPath:(nullable NSString *)targetPath
           readOnly:(BOOL)readOnly
allowSystemMetadata:(BOOL)allowSystemMetadata
          withReply:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))reply;

- (void)unmountTarget:(NSString *)targetPathOrBSD
            withReply:(void (^)(BOOL success, NSError * _Nullable error))reply;

- (void)getConfigWithReply:(void (^)(NSDictionary * _Nullable config, NSError * _Nullable error))reply;

- (void)setGlobalAutoMountEnabled:(BOOL)enabled
                        withReply:(void (^)(BOOL success, NSError * _Nullable error))reply;

- (void)setAutoMountTarget:(NSString *)volumeTarget
                   enabled:(BOOL)enabled
                  readOnly:(BOOL)readOnly
                 withReply:(void (^)(BOOL success, NSError * _Nullable error))reply;

- (void)checkSafetyForTarget:(NSString *)target
                   withReply:(void (^)(NSDictionary * _Nullable report, NSError * _Nullable error))reply;

- (void)stopDaemonWithReply:(void (^)(BOOL success, NSError * _Nullable error))reply;

@end

NS_ASSUME_NONNULL_END
