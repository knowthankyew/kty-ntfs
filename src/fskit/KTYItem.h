#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KTYItem : FSItem

@property (nonatomic, assign) FSItemID itemID;
@property (nonatomic, assign) FSItemType itemType;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) uint64_t size;
@property (nonatomic, assign) uint32_t mode;
@property (nonatomic, assign) uint32_t uid;
@property (nonatomic, assign) uint32_t gid;
@property (nonatomic, assign) time_t mtime;
@property (nonatomic, assign) time_t ctime;

+ (instancetype)rootDirectoryItem;
+ (instancetype)itemWithID:(FSItemID)itemID
                      name:(NSString *)name
                      path:(NSString *)path
                      type:(FSItemType)type
                      size:(uint64_t)size
                      mode:(uint32_t)mode;

- (void)populateAttributes:(FSItemAttributes *)attributes;

@end

NS_ASSUME_NONNULL_END
