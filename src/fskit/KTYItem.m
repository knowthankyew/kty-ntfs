#import "KTYItem.h"

@implementation KTYItem

+ (instancetype)rootDirectoryItem {
    KTYItem *item = [[KTYItem alloc] init];
    item.itemID = FSItemIDRootDirectory;
    item.itemType = FSItemTypeDirectory;
    item.name = @"/";
    item.path = @"/";
    item.size = 4096;
    item.allocatedSize = 4096;
    item.diskOffset = 0;
    item.mode = S_IFDIR | 0755;
    item.uid = getuid();
    item.gid = getgid();
    item.mtime = time(NULL);
    item.ctime = time(NULL);
    item->_children = [NSMutableDictionary dictionary];
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
    item.allocatedSize = (size + 4095) & ~4095ULL;
    item.diskOffset = 0;
    item.mode = mode;
    item.uid = getuid();
    item.gid = getgid();
    item.mtime = time(NULL);
    item.ctime = time(NULL);
    if (type == FSItemTypeDirectory) {
        item->_children = [NSMutableDictionary dictionary];
    }
    return item;
}

- (void)addChild:(KTYItem *)child {
    if (self.children && child.name) {
        self.children[child.name] = child;
        self.mtime = time(NULL);
    }
}

- (void)removeChildNamed:(NSString *)name {
    if (self.children && name) {
        [self.children removeObjectForKey:name];
        self.mtime = time(NULL);
    }
}

- (nullable KTYItem *)childNamed:(NSString *)name {
    return self.children ? self.children[name] : nil;
}

- (void)truncateToSize:(uint64_t)newSize {
    self.size = newSize;
    self.allocatedSize = (newSize + 4095) & ~4095ULL;
    self.mtime = time(NULL);
}

- (void)populateAttributes:(FSItemAttributes *)attributes {
    attributes.fileID = self.itemID;
    attributes.type = self.itemType;
    attributes.size = self.size;
    attributes.allocSize = self.allocatedSize > 0 ? self.allocatedSize : ((self.size + 4095) & ~4095ULL);
    attributes.mode = self.mode;
    attributes.uid = self.uid;
    attributes.gid = self.gid;
    attributes.linkCount = (self.itemType == FSItemTypeDirectory) ? (2 + (uint32_t)self.children.count) : 1;

    struct timespec mt = { .tv_sec = self.mtime, .tv_nsec = 0 };
    attributes.modifyTime = mt;
    struct timespec ct = { .tv_sec = self.ctime, .tv_nsec = 0 };
    attributes.changeTime = ct;
}

@end
