#ifndef _KTY_IO_H
#define _KTY_IO_H

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <sys/stat.h>
#include "ntfs-3g/types.h"
#include "ntfs-3g/device.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    KTY_IO_MODE_POSIX = 1,
    KTY_IO_MODE_RESOURCE = 2,
} kty_io_mode_t;

/* Callback signatures for user-space block device resources (e.g. FSKit FSBlockDeviceResource) */
typedef s64 (*kty_block_read_fn)(void *resource_ctx, void *buf, s64 count, s64 offset);
typedef s64 (*kty_block_write_fn)(void *resource_ctx, const void *buf, s64 count, s64 offset);
typedef int (*kty_block_sync_fn)(void *resource_ctx);

typedef struct kty_io_channel {
    kty_io_mode_t mode;
    int fd;                             /* POSIX file descriptor (for KTY_IO_MODE_POSIX) */
    void *resource_ctx;                 /* Opaque resource context (for KTY_IO_MODE_RESOURCE) */
    kty_block_read_fn read_cb;
    kty_block_write_fn write_cb;
    kty_block_sync_fn sync_cb;
    s64 total_bytes;
    int sector_size;
    bool read_only;
} kty_io_channel_t;

/**
 * Global operations table for kty_ntfs devices.
 */
extern struct ntfs_device_operations kty_device_ops;

/**
 * Allocate and configure an ntfs_device using a POSIX file path or disk device path.
 */
struct ntfs_device *kty_device_alloc_fd(const char *path, int flags);

/**
 * Allocate and configure an ntfs_device using memory-mapped or FSKit resource callbacks.
 */
struct ntfs_device *kty_device_alloc_resource(
    const char *name,
    void *resource_ctx,
    kty_block_read_fn read_cb,
    kty_block_write_fn write_cb,
    kty_block_sync_fn sync_cb,
    s64 total_size,
    int sector_size,
    bool read_only
);

/**
 * Flush all pending dirty buffers to the underlying media and issue physical hardware flush.
 */
int kty_device_full_sync(struct ntfs_device *dev);

#ifdef __cplusplus
}
#endif

#endif /* _KTY_IO_H */
