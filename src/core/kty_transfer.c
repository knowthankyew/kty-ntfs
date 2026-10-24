#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/param.h>

#include "kty_transfer.h"
#include "kty_safety.h"
#include "kty_crypto.h"
#include "ntfs-3g/types.h"
#include "ntfs-3g/layout.h"
#include "ntfs-3g/volume.h"
#include "ntfs-3g/inode.h"
#include "ntfs-3g/dir.h"
#include "ntfs-3g/attrib.h"
#include "ntfs-3g/unistr.h"

static void normalize_device_node(const char *in_dev, char *out_node, size_t out_len) {
    if (!in_dev || !out_node || out_len == 0) return;

    if (strncmp(in_dev, "/dev/r", 6) == 0) {
        snprintf(out_node, out_len, "%s", in_dev);
    } else if (strncmp(in_dev, "/dev/", 5) == 0) {
        const char *name = in_dev + 5;
        snprintf(out_node, out_len, "/dev/r%s", name);
    } else {
        snprintf(out_node, out_len, "/dev/r%s", in_dev);
    }
}

static int kty_filldir_cb(void *dirent, const ntfschar *name,
                          const int name_len, const int name_type,
                          const s64 pos, const MFT_REF mref,
                          const unsigned dt_type) {
    (void)pos; (void)mref;
    /* Skip DOS 8.3 short names if long name is present */
    if (name_type == FILE_NAME_DOS) {
        return 0;
    }

    kty_dir_listing_t *listing = (kty_dir_listing_t *)dirent;
    char *utf8 = NULL;
    int utf8_len = ntfs_ucstombs(name, name_len, &utf8, 0);
    if (utf8_len <= 0 || !utf8) {
        return 0;
    }

    /* Suppress internal / forensic metadata */
    if (strcmp(utf8, ".DS_Store") == 0 ||
        strcmp(utf8, "$RECYCLE.BIN") == 0 ||
        strncmp(utf8, "._", 2) == 0) {
        free(utf8);
        return 0;
    }

    if (listing->count >= listing->capacity) {
        size_t new_cap = (listing->capacity == 0) ? 32 : listing->capacity * 2;
        kty_file_entry_t *new_entries = (kty_file_entry_t *)realloc(listing->entries, new_cap * sizeof(kty_file_entry_t));
        if (!new_entries) {
            free(utf8);
            return -1;
        }
        listing->entries = new_entries;
        listing->capacity = new_cap;
    }

    kty_file_entry_t *entry = &listing->entries[listing->count++];
    memset(entry, 0, sizeof(*entry));
    snprintf(entry->name, sizeof(entry->name), "%s", utf8);
    entry->is_directory = (dt_type == NTFS_DT_DIR);

    free(utf8);
    return 0;
}

int kty_transfer_list_dir(const char *device_path, const char *dir_path, kty_dir_listing_t *out_listing) {
    if (!device_path || !out_listing) {
        return -EINVAL;
    }

    memset(out_listing, 0, sizeof(*out_listing));

    char dev_node[PATH_MAX];
    normalize_device_node(device_path, dev_node, sizeof(dev_node));

    ntfs_volume *vol = ntfs_mount(dev_node, NTFS_MNT_RDONLY);
    if (!vol) {
        /* Fallback to non-raw /dev/diskXsY */
        char block_node[PATH_MAX];
        snprintf(block_node, sizeof(block_node), "/dev/%s",
                 (strncmp(device_path, "/dev/r", 6) == 0) ? device_path + 6 :
                 (strncmp(device_path, "/dev/", 5) == 0) ? device_path + 5 : device_path);
        vol = ntfs_mount(block_node, NTFS_MNT_RDONLY);
    }

    if (!vol) {
        return -errno;
    }

    const char *target_dir = (dir_path && dir_path[0]) ? dir_path : "/";
    ntfs_inode *dir_ni = ntfs_pathname_to_inode(vol, NULL, target_dir);
    if (!dir_ni) {
        int err = errno;
        ntfs_umount(vol, FALSE);
        return -err;
    }

    s64 pos = 0;
    int readdir_rc = ntfs_readdir(dir_ni, &pos, out_listing, kty_filldir_cb);
    int err = (readdir_rc < 0) ? (errno != 0 ? errno : EIO) : 0;

    ntfs_inode_close(dir_ni);
    ntfs_umount(vol, FALSE);

    if (err != 0) {
        kty_transfer_free_listing(out_listing);
        return -err;
    }
    return 0;
}

void kty_transfer_free_listing(kty_dir_listing_t *listing) {
    if (listing) {
        if (listing->entries) {
            free(listing->entries);
            listing->entries = NULL;
        }
        listing->count = 0;
        listing->capacity = 0;
    }
}

int kty_transfer_copy_to_ntfs(
    const char *device_path,
    const char *host_src_path,
    const char *ntfs_dest_path,
    bool allow_system_metadata,
    char *out_sha256_hex,
    char *out_blake3_hex
) {
    if (!device_path || !host_src_path || !ntfs_dest_path) {
        return -EINVAL;
    }

    /* Forensic cleanliness check */
    if (!allow_system_metadata) {
        const char *base = strrchr(host_src_path, '/');
        const char *fname = base ? base + 1 : host_src_path;
        if (strcmp(fname, ".DS_Store") == 0 || strncmp(fname, "._", 2) == 0) {
            return -EPERM;
        }
    }

    /* Fail-closed Fast Startup safety check */
    kty_safety_report_t safety;
    if (kty_check_volume_safety(device_path, &safety) == 0) {
        if (!safety.safe_for_write || safety.is_hibernated || safety.metadata_cached || safety.is_dirty) {
            return -EPERM;
        }
    }

    /* Open local host source file */
    int src_fd = open(host_src_path, O_RDONLY);
    if (src_fd < 0) {
        return -errno;
    }

    struct stat st;
    if (fstat(src_fd, &st) < 0) {
        int err = errno;
        close(src_fd);
        return -err;
    }

    s64 file_size = (s64)st.st_size;

    /* Open NTFS volume */
    char dev_node[PATH_MAX];
    normalize_device_node(device_path, dev_node, sizeof(dev_node));

    ntfs_volume *vol = ntfs_mount(dev_node, 0);
    if (!vol) {
        char block_node[PATH_MAX];
        snprintf(block_node, sizeof(block_node), "/dev/%s",
                 (strncmp(device_path, "/dev/r", 6) == 0) ? device_path + 6 :
                 (strncmp(device_path, "/dev/", 5) == 0) ? device_path + 5 : device_path);
        vol = ntfs_mount(block_node, 0);
    }

    if (!vol) {
        close(src_fd);
        return -errno;
    }

    /* Split ntfs_dest_path into directory and filename */
    char dir_part[PATH_MAX];
    char file_part[256];

    const char *last_slash = strrchr(ntfs_dest_path, '/');
    if (!last_slash) {
        snprintf(dir_part, sizeof(dir_part), "/");
        snprintf(file_part, sizeof(file_part), "%s", ntfs_dest_path);
    } else if (last_slash == ntfs_dest_path) {
        snprintf(dir_part, sizeof(dir_part), "/");
        snprintf(file_part, sizeof(file_part), "%s", last_slash + 1);
    } else {
        size_t dlen = (size_t)(last_slash - ntfs_dest_path);
        snprintf(dir_part, sizeof(dir_part), "%.*s", (int)dlen, ntfs_dest_path);
        snprintf(file_part, sizeof(file_part), "%s", last_slash + 1);
    }

    /* If destination is a directory or empty filename, derive from source */
    if (file_part[0] == '\0') {
        const char *src_base = strrchr(host_src_path, '/');
        snprintf(file_part, sizeof(file_part), "%s", src_base ? src_base + 1 : host_src_path);
    }

    ntfs_inode *dir_ni = ntfs_pathname_to_inode(vol, NULL, dir_part);
    if (!dir_ni) {
        int err = errno;
        close(src_fd);
        ntfs_umount(vol, FALSE);
        return -err;
    }

    /* Create file inode in directory */
    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(file_part, &uname);
    if (ulen <= 0 || !uname) {
        close(src_fd);
        ntfs_inode_close(dir_ni);
        ntfs_umount(vol, FALSE);
        return -EINVAL;
    }

    ntfs_inode *file_ni = ntfs_create(dir_ni, 0, uname, (u8)ulen, S_IFREG);
    free(uname);

    if (!file_ni) {
        /* If already exists, open existing inode */
        char full_target_path[PATH_MAX];
        snprintf(full_target_path, sizeof(full_target_path), "%s/%s",
                 strcmp(dir_part, "/") == 0 ? "" : dir_part, file_part);
        file_ni = ntfs_pathname_to_inode(vol, NULL, full_target_path);
    }

    if (!file_ni) {
        int err = errno;
        close(src_fd);
        ntfs_inode_close(dir_ni);
        ntfs_umount(vol, FALSE);
        return -err;
    }

    /* Write data payload to unnamed data attribute */
    ntfs_attr *na = ntfs_attr_open(file_ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) {
        int err = errno;
        close(src_fd);
        ntfs_inode_close(file_ni);
        ntfs_inode_close(dir_ni);
        ntfs_umount(vol, FALSE);
        return -err;
    }

    /* Truncate / resize to target file size to cleanly overwrite any old content */
    if (ntfs_attr_truncate(na, file_size) < 0) {
        int err = errno ? errno : EIO;
        ntfs_attr_close(na);
        close(src_fd);
        ntfs_inode_close(file_ni);
        ntfs_inode_close(dir_ni);
        ntfs_umount(vol, FALSE);
        return -err;
    }

    /* Initialize streaming cryptographic hash engines */
    kty_sha256_ctx sha_ctx;
    kty_blake3_ctx b3_ctx;
    kty_sha256_init(&sha_ctx);
    kty_blake3_init(&b3_ctx);

    /* Stream payload from host to NTFS in 64KB chunks */
    uint8_t chunk[64 * 1024];
    s64 pos = 0;
    while (pos < file_size) {
        s64 to_read = ((file_size - pos) < (s64)sizeof(chunk)) ? (file_size - pos) : (s64)sizeof(chunk);
        ssize_t bytes_read = read(src_fd, chunk, (size_t)to_read);
        if (bytes_read <= 0) {
            int err = (bytes_read < 0) ? errno : EIO;
            ntfs_attr_close(na);
            close(src_fd);
            ntfs_inode_close(file_ni);
            ntfs_inode_close(dir_ni);
            ntfs_umount(vol, FALSE);
            return -err;
        }

        kty_sha256_update(&sha_ctx, chunk, (size_t)bytes_read);
        kty_blake3_update(&b3_ctx, chunk, (size_t)bytes_read);

        s64 written = ntfs_attr_pwrite(na, pos, (s64)bytes_read, chunk);
        if (written < (s64)bytes_read) {
            int err = errno ? errno : EIO;
            ntfs_attr_close(na);
            close(src_fd);
            ntfs_inode_close(file_ni);
            ntfs_inode_close(dir_ni);
            ntfs_umount(vol, FALSE);
            return -err;
        }
        pos += written;
    }
    close(src_fd);
    ntfs_attr_close(na);

    /* Finalize hash calculations */
    uint8_t sha256_dig[32];
    uint8_t blake3_dig[32];
    char sha_hex[65] = {0};
    char b3_hex[65] = {0};

    kty_sha256_final(&sha_ctx, sha256_dig);
    kty_digest_to_hex(sha256_dig, sha_hex);

    kty_blake3_final(&b3_ctx, blake3_dig);
    kty_digest_to_hex(blake3_dig, b3_hex);

    if (out_sha256_hex) snprintf(out_sha256_hex, 65, "%s", sha_hex);
    if (out_blake3_hex) snprintf(out_blake3_hex, 65, "%s", b3_hex);

    /* Write Alternate Data Streams for chain-of-custody (updating if exists) */
    ntfschar *ads_name = NULL;
    int ads_len = ntfs_mbstoucs("kty.integrity.sha256", &ads_name);
    if (ads_len > 0 && ads_name) {
        ntfs_attr *ads_attr = ntfs_attr_open(file_ni, AT_DATA, ads_name, (u8)ads_len);
        if (ads_attr) {
            ntfs_attr_truncate(ads_attr, 64);
            ntfs_attr_pwrite(ads_attr, 0, 64, sha_hex);
            ntfs_attr_close(ads_attr);
        } else {
            ntfs_attr_add(file_ni, AT_DATA, ads_name, (u8)ads_len, (const u8 *)sha_hex, 64);
        }
        free(ads_name);
    }

    ads_name = NULL;
    ads_len = ntfs_mbstoucs("kty.integrity.blake3", &ads_name);
    if (ads_len > 0 && ads_name) {
        ntfs_attr *ads_attr = ntfs_attr_open(file_ni, AT_DATA, ads_name, (u8)ads_len);
        if (ads_attr) {
            ntfs_attr_truncate(ads_attr, 64);
            ntfs_attr_pwrite(ads_attr, 0, 64, b3_hex);
            ntfs_attr_close(ads_attr);
        } else {
            ntfs_attr_add(file_ni, AT_DATA, ads_name, (u8)ads_len, (const u8 *)b3_hex, 64);
        }
        free(ads_name);
    }

    ntfs_inode_close(file_ni);
    ntfs_inode_close(dir_ni);

    /* Safe unmount, journal commit, and dirty bit clean */
    ntfs_umount(vol, FALSE);
    return 0;
}

int kty_transfer_copy_from_ntfs(
    const char *device_path,
    const char *ntfs_src_path,
    const char *host_dest_path
) {
    if (!device_path || !ntfs_src_path || !host_dest_path) {
        return -EINVAL;
    }

    char dev_node[PATH_MAX];
    normalize_device_node(device_path, dev_node, sizeof(dev_node));

    ntfs_volume *vol = ntfs_mount(dev_node, NTFS_MNT_RDONLY);
    if (!vol) {
        char block_node[PATH_MAX];
        snprintf(block_node, sizeof(block_node), "/dev/%s",
                 (strncmp(device_path, "/dev/r", 6) == 0) ? device_path + 6 :
                 (strncmp(device_path, "/dev/", 5) == 0) ? device_path + 5 : device_path);
        vol = ntfs_mount(block_node, NTFS_MNT_RDONLY);
    }

    if (!vol) {
        return -errno;
    }

    ntfs_inode *file_ni = ntfs_pathname_to_inode(vol, NULL, ntfs_src_path);
    if (!file_ni) {
        int err = errno;
        ntfs_umount(vol, FALSE);
        return -err;
    }

    ntfs_attr *na = ntfs_attr_open(file_ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) {
        int err = errno;
        ntfs_inode_close(file_ni);
        ntfs_umount(vol, FALSE);
        return -err;
    }

    s64 file_size = na->data_size;
    int dst_fd = open(host_dest_path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (dst_fd < 0) {
        int err = errno;
        ntfs_attr_close(na);
        ntfs_inode_close(file_ni);
        ntfs_umount(vol, FALSE);
        return -err;
    }

    if (file_size > 0) {
        uint8_t chunk[64 * 1024];
        s64 pos = 0;
        while (pos < file_size) {
            s64 to_read = ((file_size - pos) < (s64)sizeof(chunk)) ? (file_size - pos) : (s64)sizeof(chunk);
            s64 bytes_read = ntfs_attr_pread(na, pos, to_read, chunk);
            if (bytes_read <= 0) break;
            if (write(dst_fd, chunk, (size_t)bytes_read) != bytes_read) break;
            pos += bytes_read;
        }
    }

    close(dst_fd);
    ntfs_attr_close(na);
    ntfs_inode_close(file_ni);
    ntfs_umount(vol, FALSE);
    return 0;
}
