#ifndef _KTY_TRANSFER_H
#define _KTY_TRANSFER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char name[256];
    uint64_t size;
    bool is_directory;
    time_t mtime;
} kty_file_entry_t;

typedef struct {
    kty_file_entry_t *entries;
    size_t count;
    size_t capacity;
} kty_dir_listing_t;

/**
 * List files and directories within an NTFS partition.
 * @param device_path Block or raw character device path (e.g. /dev/rdisk0s4 or disk0s4).
 * @param dir_path Directory path within the NTFS volume (e.g. "/" or "/Users").
 * @param out_listing Structure to receive the array of entries.
 * Returns 0 on success, negative error code on failure.
 */
int kty_transfer_list_dir(const char *device_path, const char *dir_path, kty_dir_listing_t *out_listing);

/**
 * Free resources allocated by kty_transfer_list_dir.
 */
void kty_transfer_free_listing(kty_dir_listing_t *listing);

/**
 * Copy a file from the macOS host filesystem into an NTFS volume.
 * Performs Fast Startup / Hibernation safety preflight, computes SHA-256 and BLAKE3,
 * and writes the payload along with Alternate Data Streams.
 *
 * @param device_path Block or raw device path (e.g. /dev/rdisk0s4 or disk0s4).
 * @param host_src_path Local host file path to copy from.
 * @param ntfs_dest_path Destination path on the NTFS volume (e.g. "/Notes.txt" or "/Users/Alice/file.zip").
 * @param allow_system_metadata Whether to allow macOS metadata (.DS_Store).
 * @param out_sha256_hex Optional 65-byte buffer to receive SHA-256 hex string.
 * @param out_blake3_hex Optional 65-byte buffer to receive BLAKE3 hex string.
 * Returns 0 on success, negative error code on failure.
 */
int kty_transfer_copy_to_ntfs(
    const char *device_path,
    const char *host_src_path,
    const char *ntfs_dest_path,
    bool allow_system_metadata,
    char *out_sha256_hex,
    char *out_blake3_hex
);

/**
 * Copy a file from an NTFS volume to the macOS host filesystem.
 *
 * @param device_path Block or raw device path.
 * @param ntfs_src_path File path on the NTFS volume (e.g. "/Windows/notepad.exe").
 * @param host_dest_path Local host destination file path.
 * Returns 0 on success, negative error code on failure.
 */
int kty_transfer_copy_from_ntfs(
    const char *device_path,
    const char *ntfs_src_path,
    const char *host_dest_path
);

#ifdef __cplusplus
}
#endif

#endif /* _KTY_TRANSFER_H */
