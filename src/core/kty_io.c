#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "kty_io.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/stat.h>

#if defined(__APPLE__) || defined(__DARWIN__)
#include <sys/disk.h>
#endif

#include "ntfs-3g/support.h"
#include "ntfs-3g/logging.h"
#include "ntfs-3g/misc.h"

#define KTY_CHANNEL(dev) ((kty_io_channel_t *)((dev)->d_private))

static int kty_io_fsync(int fd) {
#if defined(__APPLE__) || defined(__DARWIN__)
#ifdef F_FULLFSYNC
    int ret = fcntl(fd, F_FULLFSYNC, NULL);
    if (ret == 0) {
        return 0;
    }
#endif
#endif
    return fsync(fd);
}

static int kty_op_open(struct ntfs_device *dev, int flags) {
    if (!dev || !dev->d_private) {
        errno = EINVAL;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    if (NDevOpen(dev)) {
        errno = EBUSY;
        return -1;
    }

    if (chan->mode == KTY_IO_MODE_POSIX) {
        struct stat st;
        if (stat(dev->d_name, &st) != 0) {
            ntfs_log_perror("kty_io: Failed to stat device '%s'", dev->d_name);
            return -1;
        }

        if (S_ISBLK(st.st_mode)) {
            NDevSetBlock(dev);
        }

        chan->fd = open(dev->d_name, flags);
        if (chan->fd < 0) {
            int err = errno;
            if (err == EACCES && ((flags & O_RDWR) == O_RDWR)) {
                /* If denied rw access, attempt read-only fallback */
                flags = (flags & ~O_RDWR) | O_RDONLY;
                chan->fd = open(dev->d_name, flags);
                if (chan->fd >= 0) {
                    NDevSetReadOnly(dev);
                    chan->read_only = true;
                } else {
                    errno = err;
                    return -1;
                }
            } else {
                return -1;
            }
        }

        /* Determine total size and sector size */
        if (S_ISBLK(st.st_mode)) {
#if defined(__APPLE__) || defined(__DARWIN__)
            uint64_t block_count = 0;
            uint32_t block_size = 512;
            if (ioctl(chan->fd, DKIOCGETBLOCKCOUNT, &block_count) == 0 &&
                ioctl(chan->fd, DKIOCGETBLOCKSIZE, &block_size) == 0) {
                chan->total_bytes = (s64)(block_count * block_size);
                chan->sector_size = (int)block_size;
            } else {
                chan->total_bytes = (s64)st.st_size;
                chan->sector_size = 512;
            }
#else
            chan->total_bytes = (s64)st.st_size;
            chan->sector_size = 512;
#endif
        } else {
            chan->total_bytes = (s64)st.st_size;
            chan->sector_size = 512;
        }

        if ((flags & O_RDWR) != O_RDWR) {
            NDevSetReadOnly(dev);
            chan->read_only = true;
        }
    } else if (chan->mode == KTY_IO_MODE_RESOURCE) {
        if (!chan->read_cb) {
            errno = EINVAL;
            return -1;
        }
        if (chan->read_only) {
            NDevSetReadOnly(dev);
        }
    }

    NDevSetOpen(dev);
    return 0;
}

static int kty_op_close(struct ntfs_device *dev) {
    if (!dev || !dev->d_private) {
        errno = EINVAL;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    if (!NDevOpen(dev)) {
        errno = EBADF;
        return -1;
    }

    if (chan->mode == KTY_IO_MODE_POSIX) {
        if (chan->fd >= 0) {
            if (NDevDirty(dev)) {
                kty_io_fsync(chan->fd);
            }
            if (close(chan->fd) != 0) {
                return -1;
            }
            chan->fd = -1;
        }
    } else if (chan->mode == KTY_IO_MODE_RESOURCE) {
        if (NDevDirty(dev) && chan->sync_cb) {
            chan->sync_cb(chan->resource_ctx);
        }
    }

    NDevClearOpen(dev);
    NDevClearDirty(dev);
    return 0;
}

static s64 kty_op_seek(struct ntfs_device *dev, s64 offset, int whence) {
    if (!dev || !dev->d_private || !NDevOpen(dev)) {
        errno = EBADF;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    if (chan->mode == KTY_IO_MODE_POSIX) {
        return (s64)lseek(chan->fd, (off_t)offset, whence);
    }

    /* Resource callbacks do not maintain a stateful cursor; return current/requested offset */
    if (whence == SEEK_SET) {
        return offset;
    }
    errno = ENOTSUP;
    return -1;
}

static s64 kty_op_read(struct ntfs_device *dev, void *buf, s64 count) {
    if (!dev || !dev->d_private || !NDevOpen(dev) || !buf) {
        errno = EBADF;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    if (chan->mode == KTY_IO_MODE_POSIX) {
        return (s64)read(chan->fd, buf, (size_t)count);
    }

    errno = ENOTSUP;
    return -1;
}

static s64 kty_op_write(struct ntfs_device *dev, const void *buf, s64 count) {
    if (!dev || !dev->d_private || !NDevOpen(dev) || !buf) {
        errno = EBADF;
        return -1;
    }

    if (NDevReadOnly(dev)) {
        errno = EROFS;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    if (chan->mode == KTY_IO_MODE_POSIX) {
        s64 written = (s64)write(chan->fd, buf, (size_t)count);
        if (written > 0) {
            NDevSetDirty(dev);
        }
        return written;
    }

    errno = ENOTSUP;
    return -1;
}

static s64 kty_op_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset) {
    if (!dev || !dev->d_private || !NDevOpen(dev) || !buf || count < 0 || offset < 0) {
        errno = EINVAL;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    if (chan->mode == KTY_IO_MODE_POSIX) {
        s64 total = 0;
        while (total < count) {
            ssize_t res = pread(chan->fd, (char *)buf + total, (size_t)(count - total), (off_t)(offset + total));
            if (res < 0) {
                if (errno == EINTR) {
                    continue;
                }
                return -1;
            }
            if (res == 0) {
                break; /* EOF */
            }
            total += res;
        }
        return total;
    } else if (chan->mode == KTY_IO_MODE_RESOURCE) {
        if (!chan->read_cb) {
            errno = EINVAL;
            return -1;
        }
        return chan->read_cb(chan->resource_ctx, buf, count, offset);
    }

    errno = ENOTSUP;
    return -1;
}

static s64 kty_op_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset) {
    if (!dev || !dev->d_private || !NDevOpen(dev) || !buf || count < 0 || offset < 0) {
        errno = EINVAL;
        return -1;
    }

    if (NDevReadOnly(dev)) {
        errno = EROFS;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    if (chan->mode == KTY_IO_MODE_POSIX) {
        s64 total = 0;
        while (total < count) {
            ssize_t res = pwrite(chan->fd, (const char *)buf + total, (size_t)(count - total), (off_t)(offset + total));
            if (res < 0) {
                if (errno == EINTR) {
                    continue;
                }
                return -1;
            }
            if (res == 0) {
                break;
            }
            total += res;
        }
        if (total > 0) {
            NDevSetDirty(dev);
        }
        return total;
    } else if (chan->mode == KTY_IO_MODE_RESOURCE) {
        if (!chan->write_cb) {
            errno = EROFS;
            return -1;
        }
        s64 written = chan->write_cb(chan->resource_ctx, buf, count, offset);
        if (written > 0) {
            NDevSetDirty(dev);
        }
        return written;
    }

    errno = ENOTSUP;
    return -1;
}

static int kty_op_sync(struct ntfs_device *dev) {
    if (!dev || !dev->d_private || !NDevOpen(dev)) {
        errno = EBADF;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    int res = 0;

    if (chan->mode == KTY_IO_MODE_POSIX) {
        res = kty_io_fsync(chan->fd);
    } else if (chan->mode == KTY_IO_MODE_RESOURCE) {
        if (chan->sync_cb) {
            res = chan->sync_cb(chan->resource_ctx);
        }
    }

    if (res == 0) {
        NDevClearDirty(dev);
    }
    return res;
}

static int kty_op_stat(struct ntfs_device *dev, struct stat *buf) {
    if (!dev || !dev->d_private || !buf) {
        errno = EINVAL;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    if (chan->mode == KTY_IO_MODE_POSIX) {
        if (chan->fd >= 0) {
            return fstat(chan->fd, buf);
        }
        return stat(dev->d_name, buf);
    }

    /* Fabricate safe synthetic stat for resource devices */
    memset(buf, 0, sizeof(struct stat));
    buf->st_mode = S_IFBLK | 0640;
    buf->st_size = (off_t)chan->total_bytes;
    buf->st_blksize = chan->sector_size > 0 ? chan->sector_size : 512;
    buf->st_blocks = (buf->st_size + 511) / 512;
    return 0;
}

static int kty_op_ioctl(struct ntfs_device *dev, unsigned long request, void *argp) {
    if (!dev || !dev->d_private || !NDevOpen(dev)) {
        errno = EBADF;
        return -1;
    }

    kty_io_channel_t *chan = KTY_CHANNEL(dev);
    if (chan->mode == KTY_IO_MODE_POSIX) {
        return ioctl(chan->fd, request, argp);
    }

    errno = ENOTSUP;
    return -1;
}

struct ntfs_device_operations kty_device_ops = {
    .open = kty_op_open,
    .close = kty_op_close,
    .seek = kty_op_seek,
    .read = kty_op_read,
    .write = kty_op_write,
    .pread = kty_op_pread,
    .pwrite = kty_op_pwrite,
    .sync = kty_op_sync,
    .stat = kty_op_stat,
    .ioctl = kty_op_ioctl,
};

struct ntfs_device *kty_device_alloc_fd(const char *path, int flags) {
    if (!path) {
        errno = EINVAL;
        return NULL;
    }

    kty_io_channel_t *chan = (kty_io_channel_t *)calloc(1, sizeof(kty_io_channel_t));
    if (!chan) {
        errno = ENOMEM;
        return NULL;
    }

    chan->mode = KTY_IO_MODE_POSIX;
    chan->fd = -1;
    chan->read_only = ((flags & O_RDWR) != O_RDWR);

    struct ntfs_device *dev = ntfs_device_alloc(path, 0, &kty_device_ops, chan);
    if (!dev) {
        free(chan);
        return NULL;
    }

    return dev;
}

struct ntfs_device *kty_device_alloc_resource(
    const char *name,
    void *resource_ctx,
    kty_block_read_fn read_cb,
    kty_block_write_fn write_cb,
    kty_block_sync_fn sync_cb,
    s64 total_size,
    int sector_size,
    bool read_only
) {
    if (!name || !read_cb) {
        errno = EINVAL;
        return NULL;
    }

    kty_io_channel_t *chan = (kty_io_channel_t *)calloc(1, sizeof(kty_io_channel_t));
    if (!chan) {
        errno = ENOMEM;
        return NULL;
    }

    chan->mode = KTY_IO_MODE_RESOURCE;
    chan->fd = -1;
    chan->resource_ctx = resource_ctx;
    chan->read_cb = read_cb;
    chan->write_cb = write_cb;
    chan->sync_cb = sync_cb;
    chan->total_bytes = total_size;
    chan->sector_size = sector_size > 0 ? sector_size : 512;
    chan->read_only = read_only;

    struct ntfs_device *dev = ntfs_device_alloc(name, 0, &kty_device_ops, chan);
    if (!dev) {
        free(chan);
        return NULL;
    }

    return dev;
}

int kty_device_full_sync(struct ntfs_device *dev) {
    if (!dev || !dev->d_ops || !dev->d_ops->sync) {
        errno = EINVAL;
        return -1;
    }
    return dev->d_ops->sync(dev);
}
