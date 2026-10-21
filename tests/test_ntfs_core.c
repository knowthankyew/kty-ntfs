#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>

#include "kty_io.h"
#include "ntfs-3g/types.h"
#include "ntfs-3g/layout.h"
#include "ntfs-3g/bootsect.h"
#include "ntfs-3g/device.h"

#define SYNTHETIC_DISK_SIZE (64 * 1024) /* 64 KB */

typedef struct {
    uint8_t memory[SYNTHETIC_DISK_SIZE];
    bool sync_called;
} synthetic_disk_t;

static s64 test_read_cb(void *ctx, void *buf, s64 count, s64 offset) {
    synthetic_disk_t *disk = (synthetic_disk_t *)ctx;
    if (offset < 0 || offset >= SYNTHETIC_DISK_SIZE) {
        return 0;
    }
    s64 avail = SYNTHETIC_DISK_SIZE - offset;
    s64 to_copy = (count < avail) ? count : avail;
    memcpy(buf, disk->memory + offset, (size_t)to_copy);
    return to_copy;
}

static s64 test_write_cb(void *ctx, const void *buf, s64 count, s64 offset) {
    synthetic_disk_t *disk = (synthetic_disk_t *)ctx;
    if (offset < 0 || offset >= SYNTHETIC_DISK_SIZE) {
        return 0;
    }
    s64 avail = SYNTHETIC_DISK_SIZE - offset;
    s64 to_copy = (count < avail) ? count : avail;
    memcpy(disk->memory + offset, buf, (size_t)to_copy);
    return to_copy;
}

static int test_sync_cb(void *ctx) {
    synthetic_disk_t *disk = (synthetic_disk_t *)ctx;
    disk->sync_called = true;
    return 0;
}

static void init_synthetic_ntfs_boot_sector(synthetic_disk_t *disk) {
    memset(disk->memory, 0, SYNTHETIC_DISK_SIZE);

    NTFS_BOOT_SECTOR *bs = (NTFS_BOOT_SECTOR *)disk->memory;
    bs->jump[0] = 0xeb;
    bs->jump[1] = 0x52;
    bs->jump[2] = 0x90;
    memcpy(&bs->oem_id, "NTFS    ", 8);

    /* BIOS Parameter Block */
    bs->bpb.bytes_per_sector = cpu_to_le16(512);
    bs->bpb.sectors_per_cluster = 8;
    bs->bpb.reserved_sectors = 0;
    bs->bpb.fats = 0;
    bs->bpb.root_entries = 0;
    bs->bpb.sectors = 0;
    bs->bpb.media_type = 0xf8; /* Fixed hard disk */
    bs->bpb.sectors_per_fat = 0;
    bs->bpb.sectors_per_track = cpu_to_le16(63);
    bs->bpb.heads = cpu_to_le16(255);
    bs->bpb.hidden_sectors = 0;
    bs->bpb.large_sectors = 0;

    bs->physical_drive = 0x80;
    bs->current_head = 0;
    bs->extended_boot_signature = 0x80;
    bs->reserved2 = 0;

    bs->number_of_sectors = cpu_to_sle64(SYNTHETIC_DISK_SIZE / 512);
    bs->mft_lcn = cpu_to_sle64(4);
    bs->mftmirr_lcn = cpu_to_sle64(2);
    bs->clusters_per_mft_record = 1;
    bs->clusters_per_index_record = 1;
    bs->volume_serial_number = cpu_to_sle64(0x123456789ABCDEF0ULL);

    /* End-of-sector boot signature at offset 510: 0x55, 0xaa (little-endian 0xaa55) */
    disk->memory[510] = 0x55;
    disk->memory[511] = 0xaa;
}

int main(void) {
    printf("[test_ntfs_core] Starting headless NTFS engine unit tests...\n");

    /* Test 1: Fail-closed parameter validation */
    printf("[test_ntfs_core] Test 1: Parameter validation... ");
    errno = 0;
    struct ntfs_device *bad_dev = kty_device_alloc_fd(NULL, 0);
    assert(bad_dev == NULL);
    assert(errno == EINVAL);

    errno = 0;
    bad_dev = kty_device_alloc_resource(NULL, NULL, NULL, NULL, NULL, 0, 0, true);
    assert(bad_dev == NULL);
    assert(errno == EINVAL);
    printf("PASS\n");

    /* Test 2: In-memory synthetic block device & boot sector parsing */
    printf("[test_ntfs_core] Test 2: In-memory NTFS boot sector verification... ");
    synthetic_disk_t disk;
    init_synthetic_ntfs_boot_sector(&disk);

    struct ntfs_device *dev = kty_device_alloc_resource(
        "synthetic://ramdisk0",
        &disk,
        test_read_cb,
        test_write_cb,
        test_sync_cb,
        SYNTHETIC_DISK_SIZE,
        512,
        true /* Read-only */
    );
    assert(dev != NULL);
    assert(dev->d_ops != NULL);

    int open_res = dev->d_ops->open(dev, O_RDONLY);
    assert(open_res == 0);
    assert(NDevOpen(dev));
    assert(NDevReadOnly(dev));

    /* Read the boot sector */
    NTFS_BOOT_SECTOR read_bs;
    memset(&read_bs, 0, sizeof(read_bs));
    s64 bytes_read = dev->d_ops->pread(dev, &read_bs, sizeof(read_bs), 0);
    assert(bytes_read == sizeof(read_bs));

    /* Verify with ntfs-3g's native boot sector validator */
    BOOL is_ntfs = ntfs_boot_sector_is_ntfs(&read_bs);
    assert(is_ntfs == TRUE);

    /* Test write rejection on read-only mount */
    uint8_t test_byte = 0xFF;
    s64 write_res = dev->d_ops->pwrite(dev, &test_byte, 1, 1024);
    assert(write_res == -1);
    assert(errno == EROFS);

    int close_res = dev->d_ops->close(dev);
    assert(close_res == 0);
    assert(!NDevOpen(dev));

    int free_res = ntfs_device_free(dev);
    assert(free_res == 0);
    printf("PASS\n");

    /* Test 3: Read/Write device channel and hardware sync */
    printf("[test_ntfs_core] Test 3: Read/Write channel & sync callback... ");
    disk.sync_called = false;

    struct ntfs_device *rw_dev = kty_device_alloc_resource(
        "synthetic://ramdisk1",
        &disk,
        test_read_cb,
        test_write_cb,
        test_sync_cb,
        SYNTHETIC_DISK_SIZE,
        512,
        false /* Read-write */
    );
    assert(rw_dev != NULL);

    assert(rw_dev->d_ops->open(rw_dev, O_RDWR) == 0);
    assert(!NDevReadOnly(rw_dev));

    const char test_payload[] = "KNOWTHANKYEW_FORENSIC_PAYLOAD";
    s64 payload_len = (s64)strlen(test_payload);
    s64 written = rw_dev->d_ops->pwrite(rw_dev, test_payload, payload_len, 2048);
    assert(written == payload_len);
    assert(NDevDirty(rw_dev));

    /* Verify payload in synthetic memory */
    assert(memcmp(disk.memory + 2048, test_payload, (size_t)payload_len) == 0);

    /* Perform sync */
    assert(kty_device_full_sync(rw_dev) == 0);
    assert(disk.sync_called == true);
    assert(!NDevDirty(rw_dev));

    assert(rw_dev->d_ops->close(rw_dev) == 0);
    assert(ntfs_device_free(rw_dev) == 0);
    printf("PASS\n");

    printf("[test_ntfs_core] All headless NTFS engine tests passed successfully!\n");
    return 0;
}
