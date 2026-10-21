#import "KTYItem.h"

@implementation KTYItem

+ (instancetype)rootDirectoryItem {
    KTYItem *item = [[KTYItem alloc] init];
    item.itemID = FSItemIDRootDirectory;
    item.itemType = FSItemTypeDirectory;
    item.name = @"/";
    item.path = @"/";
    item.size = 4096;
    item.mode = S_IFDIR | 0755;
    item.uid = getuid();
    item.gid = getgid();
    item.mtime = time(NULL);
    item.ctime = time(NULL);
    return item;
}

+ (instancetype)itemWithID:(FSItemID)itemID
                      name:(NSString *)name
                      path:(NSString *)path
                      type:(FSItemType)type
                      size:(uint64_t)size
                      mode:(uint32_t)mode {
    KTYItem *item = [[KTYItem alloc] init];
    item.itemID = itemID;
    item.itemType = type;
    item.name = [name copy];
    item.path = [path copy];
    item.size = size;
    item.mode = mode;
    item.uid = getuid();
    item.gid = getgid();
    item.mtime = time(NULL);
    item.ctime = time(NULL);
    return item;
}

- (void)populateAttributes:(FSItemAttributes *)attributes {
    attributes.fileID = self.itemID;
    attributes.type = self.itemType;
    attributes.size = self.size;
    attributes.allocSize = (self.size + 511) & ~511ULL;
    attributes.mode = self.mode;
    attributes.uid = self.uid;
    attributes.gid = self.gid;
    attributes.linkCount = (self.itemType == FSItemTypeDirectory) ? 2 : 1;

    struct timespec mt = { .tv_sec = self.mtime, .tv_nsec = 0 };
    attributes.modifyTime = mt;
    struct timespec ct = { .tv_sec = self.ctime, .tv_nsec = 0 };
    attributes.changeTime = ct;
}

@end
