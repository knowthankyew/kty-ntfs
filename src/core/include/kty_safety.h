#ifndef _KTY_SAFETY_H
#define _KTY_SAFETY_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool has_hiberfile;           /* hiberfil.sys exists on disk */
    bool is_hibernated;           /* hiberfil.sys contains HIBR / hibr magic (Windows Fast Startup / Hybrid Sleep active) */
    bool is_dirty;                /* Dirty bit or uncommitted NTFS transaction log */
    bool metadata_cached;         /* LogFile restart page version 2.0 (metadata cached in memory by Windows) */
    bool safe_for_write;          /* Safe to mount for write operations */
    char volume_name[128];        /* Volume label or identifier */
    char status_summary[256];     /* Concise diagnostic status */
} kty_safety_report_t;

/**
 * Perform a deep safety pre-flight check on an NTFS volume path or raw device.
 * Detects Windows Fast Startup (hiberfil.sys magic), journal recovery states, and dirty flags.
 * Returns 0 on success, -1 on fatal error.
 */
int kty_check_volume_safety(const char *target_path, kty_safety_report_t *out_report);

/**
 * Inspect raw buffer header (e.g. 4096-byte hiberfil.sys header) for hibernation magic.
 * Returns true if active hibernation (HIBR/hibr) is present.
 */
bool kty_inspect_hiberfile_header(const uint8_t *header_buf, size_t len);

/**
 * Format a comprehensive, user-friendly, and searchable guidance message explaining
 * Windows Fast Startup, why write mounting is blocked, step-by-step instructions for
 * disabling Fast Startup in Windows Control Panel GUI, the powercfg CLI command,
 * and the cold restart alternative.
 */
int kty_format_fast_startup_guidance(const char *volume_name_or_target, char *buf, size_t buf_len);

#ifdef __cplusplus
}
#endif

#endif /* _KTY_SAFETY_H */
