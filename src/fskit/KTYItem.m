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
    item.isForensicTombstone = NO;
    item->_children = [NSMutableDictionary dictionary];
    item->_extendedAttributes = [NSMutableDictionary dictionary];
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
    item.isForensicTombstone = NO;
    item->_extendedAttributes = [NSMutableDictionary dictionary];
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
    self.sha256Hex = nil;
    self.blake3Hex = nil;
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

/* =========================================================================
 * Extended Attributes & Alternate Data Streams (ADS)
 * ========================================================================= */

- (nullable NSData *)xattrNamed:(NSString *)name {
    if (!name) return nil;
    return self.extendedAttributes[name];
}

- (BOOL)setXattrNamed:(NSString *)name
                 data:(nullable NSData *)data
               policy:(FSSetXattrPolicy)policy
                error:(NSError **)error {
    if (!name || name.length == 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }

    BOOL exists = (self.extendedAttributes[name] != nil);

    if (policy == FSSetXattrPolicyDelete) {
        if (!exists) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOATTR userInfo:nil];
            return NO;
        }
        [self.extendedAttributes removeObjectForKey:name];
        self.mtime = time(NULL);
        return YES;
    }

    if (policy == FSSetXattrPolicyMustCreate && exists) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EEXIST userInfo:nil];
        return NO;
    }

    if (policy == FSSetXattrPolicyMustReplace && !exists) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOATTR userInfo:nil];
        return NO;
    }

    if (!data) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }

    self.extendedAttributes[name] = data;
    self.mtime = time(NULL);
    return YES;
}

- (NSArray<NSString *> *)listXattrNames {
    return self.extendedAttributes.allKeys;
}

- (BOOL)removeXattrNamed:(NSString *)name error:(NSError **)error {
    return [self setXattrNamed:name data:nil policy:FSSetXattrPolicyDelete error:error];
}

/* =========================================================================
 * Forensic Integrity Hashing & Chain-of-Custody ADS
 * ========================================================================= */

- (void)updateForensicHashesWithData:(NSData *)data offset:(uint64_t)offset {
    if (offset == 0 && data.length == self.size) {
        /* Single contiguous write of full file payload */
        uint8_t s_dig[KTY_SHA256_DIGEST_LEN];
        char s_hex[65];
        kty_sha256_data(data.bytes, data.length, s_dig);
        kty_digest_to_hex(s_dig, s_hex);
        self.sha256Hex = [NSString stringWithUTF8String:s_hex];

        uint8_t b_dig[KTY_BLAKE3_DIGEST_LEN];
        char b_hex[65];
        kty_blake3_data(data.bytes, data.length, b_dig);
        kty_digest_to_hex(b_dig, b_hex);
        self.blake3Hex = [NSString stringWithUTF8String:b_hex];
    } else {
        self.sha256Hex = nil;
        self.blake3Hex = nil;
    }

    /* Auto-publish Alternate Data Streams for chain-of-custody */
    if (self.sha256Hex) {
        self.extendedAttributes[@"kty.integrity.sha256"] = [self.sha256Hex dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (self.blake3Hex) {
        self.extendedAttributes[@"kty.integrity.blake3"] = [self.blake3Hex dataUsingEncoding:NSUTF8StringEncoding];
    }
}

- (void)recomputeForensicHashesFromDevice:(struct ntfs_device *)dev {
    if (!dev || !dev->d_ops || self.size == 0 || self.diskOffset == 0) return;
    size_t len = (size_t)self.size;
    void *buf = malloc(len);
    if (!buf) return;
    s64 r = dev->d_ops->pread(dev, buf, (s64)len, (s64)self.diskOffset);
    if (r == (s64)len) {
        uint8_t s_dig[KTY_SHA256_DIGEST_LEN];
        char s_hex[65];
        kty_sha256_data(buf, len, s_dig);
        kty_digest_to_hex(s_dig, s_hex);
        self.sha256Hex = [NSString stringWithUTF8String:s_hex];

        uint8_t b_dig[KTY_BLAKE3_DIGEST_LEN];
        char b_hex[65];
        kty_blake3_data(buf, len, b_dig);
        kty_digest_to_hex(b_dig, b_hex);
        self.blake3Hex = [NSString stringWithUTF8String:b_hex];

        self.extendedAttributes[@"kty.integrity.sha256"] = [self.sha256Hex dataUsingEncoding:NSUTF8StringEncoding];
        self.extendedAttributes[@"kty.integrity.blake3"] = [self.blake3Hex dataUsingEncoding:NSUTF8StringEncoding];
    }
    free(buf);
}

/* =========================================================================
 * System Metadata Identification
 * ========================================================================= */

+ (BOOL)isSystemMetadataName:(NSString *)name {
    if (!name || name.length == 0) return NO;
    if ([name isEqualToString:@".DS_Store"] ||
        [name isEqualToString:@".Spotlight-V100"] ||
        [name isEqualToString:@".Trashes"] ||
        [name isEqualToString:@".fseventsd"] ||
        [name isEqualToString:@".TemporaryItems"] ||
        [name isEqualToString:@".VolumeIcon.icns"] ||
        [name isEqualToString:@".com.apple.timemachine.donotpresent"]) {
        return YES;
    }
    if ([name hasPrefix:@"._"]) {
        return YES;
    }
    return NO;
}

@end
