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
#include <sys/mount.h>

#include "kty_safety.h"
#include "ntfs-3g/types.h"
#include "ntfs-3g/layout.h"
#include "ntfs-3g/volume.h"
#include "ntfs-3g/device.h"

#define HIBERFILE_HEADER_SIZE 4096

bool kty_inspect_hiberfile_header(const uint8_t *header_buf, size_t len) {
    if (!header_buf || len < 4) {
        return false;
    }
    if ((memcmp(header_buf, "hibr", 4) == 0) ||
        (memcmp(header_buf, "HIBR", 4) == 0)) {
        return true;
    }
    return false;
}

int kty_format_fast_startup_guidance(const char *volume_name_or_target, char *buf, size_t buf_len) {
    if (!buf || buf_len == 0) return -1;
    const char *target = (volume_name_or_target && volume_name_or_target[0]) ? volume_name_or_target : "BOOTCAMP";

    return snprintf(buf, buf_len,
        "================================================================================\n"
        " [!] CAUTION: Windows Fast Startup (Hibernation) is Active on '%s'\n"
        "================================================================================\n"
        " Windows Fast Startup (also known as Fast Boot or Hybrid Sleep) is active.\n"
        " In this state, Windows does not cleanly dismount the filesystem; it saves\n"
        " the active kernel session and dirty disk cache to 'hiberfil.sys'.\n\n"
        " Writing to this partition from macOS while Fast Startup is active will cause\n"
        " filesystem desynchronization, corrupted files, or automatic Windows chkdsk\n"
        " rollbacks upon next boot.\n\n"
        " HOW TO SAFELY DISABLE FAST STARTUP (Turn off Fastboot in Windows):\n"
        " --------------------------------------------------------------------------------\n"
        " Option 1: Via Windows Settings / Control Panel (Recommended for UI Users)\n"
        "   1. Restart and boot into Windows.\n"
        "   2. Open the Start menu, type 'Control Panel', and launch it.\n"
        "   3. Navigate to: Hardware and Sound  -->  Power Options.\n"
        "   4. In the left sidebar, click 'Choose what the power buttons do'.\n"
        "   5. Click the administrator shield link: 'Change settings that are currently unavailable'.\n"
        "   6. Under 'Shutdown settings' at the bottom, uncheck:\n"
        "      [ ] 'Turn on fast startup (recommended)'\n"
        "   7. Click 'Save changes' and shut down or restart back into macOS.\n\n"
        " Option 2: Via Windows Command Prompt or PowerShell (CLI Shortcut)\n"
        "   1. In Windows, right-click the Start Menu and choose 'Terminal (Admin)'\n"
        "      or 'Command Prompt (Admin)'.\n"
        "   2. Run: powercfg /h off\n"
        "   (This disables hibernation and turns off Fast Startup immediately).\n\n"
        " Option 3: One-Time Clean Cold Restart\n"
        "   In Windows, hold down the Shift key while clicking 'Shut down' or 'Restart'\n"
        "   in the Start Menu, or run in Command Prompt: shutdown /s /t 0\n\n"
        " SAFE IMMEDIATE ACCESS:\n"
        "   You can safely mount this partition right now in read-only mode to browse\n"
        "   and copy files to your Mac without modifying the disk:\n"
        "      kty-ntfs mount %s --readonly\n"
        "================================================================================",
        target, target);
}

static int inspect_hiberfile_at_path(const char *dir_path, kty_safety_report_t *out_report) {
    char hiber_path[PATH_MAX];
    const char *names[] = {"hiberfil.sys", "HIBERFIL.SYS", NULL};
    int fd = -1;

    for (int i = 0; names[i] != NULL; i++) {
        snprintf(hiber_path, sizeof(hiber_path), "%s/%s", dir_path, names[i]);
        fd = open(hiber_path, O_RDONLY);
        if (fd >= 0) break;
    }

    if (fd < 0) {
        if (errno == ENOENT) {
            out_report->has_hiberfile = false;
            out_report->is_hibernated = false;
            out_report->safe_for_write = true;
            snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                     "Clean (hiberfil.sys not found; Fast Startup is disabled)");
            return 0;
        }
        return -1;
    }

    out_report->has_hiberfile = true;
    uint8_t header[HIBERFILE_HEADER_SIZE];
    memset(header, 0, sizeof(header));
    ssize_t bytes_read = read(fd, header, sizeof(header));
    close(fd);

    if (bytes_read < 4) {
        /* Incomplete or truncated file; fail closed for safety */
        out_report->is_hibernated = true;
        out_report->safe_for_write = false;
        snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                 "Warning: hiberfil.sys header is incomplete or truncated");
        return 0;
    }

    if (kty_inspect_hiberfile_header(header, (size_t)bytes_read)) {
        out_report->is_hibernated = true;
        out_report->safe_for_write = false;
        snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                 "Fast Startup Active (hiberfil.sys contains HIBR/hibr signature)");
    } else {
        out_report->is_hibernated = false;
        out_report->safe_for_write = true;
        snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                 "Clean (hiberfil.sys present but header is zeroed; safe for read/write)");
    }

    return 0;
}

int kty_check_volume_safety(const char *target_path, kty_safety_report_t *out_report) {
    if (!target_path || !out_report) {
        return -1;
    }

    memset(out_report, 0, sizeof(*out_report));
    out_report->safe_for_write = false; /* Fail-closed default */

    /* Copy volume name / target */
    const char *base = strrchr(target_path, '/');
    const char *name = base ? (base + 1) : target_path;
    snprintf(out_report->volume_name, sizeof(out_report->volume_name), "%s", name);

    struct stat st;
    if (stat(target_path, &st) == 0 && S_ISDIR(st.st_mode)) {
        return inspect_hiberfile_at_path(target_path, out_report);
    }

    /* Target is a device or device name (e.g. disk0s4, /dev/disk0s4) */
    char dev_path[PATH_MAX];
    if (strncmp(target_path, "/dev/", 5) == 0) {
        snprintf(dev_path, sizeof(dev_path), "%s", target_path);
    } else {
        snprintf(dev_path, sizeof(dev_path), "/dev/%s", target_path);
    }

    /* Check if this device is currently mounted at a directory in macOS */
    struct statfs *mntbuf = NULL;
    int mntsize = getmntinfo(&mntbuf, MNT_NOWAIT);
    if (mntsize > 0 && mntbuf) {
        for (int i = 0; i < mntsize; i++) {
            if (strcmp(mntbuf[i].f_mntfromname, dev_path) == 0) {
                int res = inspect_hiberfile_at_path(mntbuf[i].f_mntonname, out_report);
                if (res == 0) {
                    return 0;
                }
            }
        }
    }

    /* Unmounted or raw access: attempt read-only inspection via libntfs */
    ntfs_volume *vol = ntfs_mount(dev_path, NTFS_MNT_RDONLY | NTFS_MNT_IGNORE_HIBERFILE);
    if (vol) {
        errno = 0;
        int hiber_rc = ntfs_volume_check_hiberfile(vol, 0);
        if (hiber_rc < 0 && errno == EPERM) {
            out_report->has_hiberfile = true;
            out_report->is_hibernated = true;
            out_report->safe_for_write = false;
            snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                     "Fast Startup Active (hiberfil.sys contains HIBR signature)");
            ntfs_umount(vol, FALSE);
            return 0;
        }

        /* Check transaction log cached metadata (restart page version 2.0) */
        errno = 0;
        int log_rc = ntfs_volume_check_logfile(vol);
        if (log_rc < 0) {
            if (errno == EPERM) {
                out_report->metadata_cached = true;
                out_report->safe_for_write = false;
                snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                         "Fast Startup Active (metadata cached in Windows RAM)");
                ntfs_umount(vol, FALSE);
                return 0;
            } else {
                out_report->is_dirty = true;
                out_report->safe_for_write = false;
                snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                         "Unclean (NTFS transaction log is dirty or uncommitted)");
                ntfs_umount(vol, FALSE);
                return 0;
            }
        }

        if (vol->flags & VOLUME_IS_DIRTY) {
            out_report->is_dirty = true;
            out_report->safe_for_write = false;
            snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                     "Unclean (Volume dirty flag is set; Windows chkdsk required)");
            ntfs_umount(vol, FALSE);
            return 0;
        }

        out_report->safe_for_write = true;
        snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                 "Clean (No hibernation state detected; safe for read/write)");
        ntfs_umount(vol, FALSE);
        return 0;
    }

    /* If raw open failed (e.g. permission denied or device not found), check errno */
    if (errno == EACCES || errno == EPERM) {
        snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                 "Permission Denied: Root privileges required to inspect raw block device %s directly", dev_path);
    } else {
        snprintf(out_report->status_summary, sizeof(out_report->status_summary),
                 "Unable to inspect %s: %s", dev_path, strerror(errno));
    }

    return -1;
}
