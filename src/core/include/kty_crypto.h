/*
 * kty-ntfs: Forensic Cryptographic Engine (SHA-256 & BLAKE3)
 *
 * Implements hardware-accelerated SHA-256 via CommonCrypto and the official
 * reference tree-hashing specification of BLAKE3 for chain-of-custody integrity.
 *
 * Invariant 1: Zero networking or socket symbols.
 * Invariant 3: Bit-for-bit reproducible cross-platform hashing.
 * Invariant 4: Fail-closed verification.
 * Invariant 5: Universal arm64/x86_64, memory-safe, ASan-clean.
 */

#ifndef KTY_CRYPTO_H
#define KTY_CRYPTO_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <CommonCrypto/CommonDigest.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- SHA-256 Engine --- */
#define KTY_SHA256_DIGEST_LEN 32

typedef CC_SHA256_CTX kty_sha256_ctx;

void kty_sha256_init(kty_sha256_ctx *ctx);
void kty_sha256_update(kty_sha256_ctx *ctx, const void *data, size_t len);
void kty_sha256_final(kty_sha256_ctx *ctx, uint8_t digest[KTY_SHA256_DIGEST_LEN]);
void kty_sha256_data(const void *data, size_t len, uint8_t digest[KTY_SHA256_DIGEST_LEN]);

/* --- BLAKE3 Engine (Official Tree-Hashing Specification) --- */
#define KTY_BLAKE3_DIGEST_LEN 32
#define KTY_BLAKE3_CHUNK_LEN  1024
#define KTY_BLAKE3_BLOCK_LEN  64

typedef struct {
    uint32_t cv[8];
    uint64_t chunk_counter;
    uint8_t buf[KTY_BLAKE3_BLOCK_LEN];
    uint8_t buf_len;
    uint8_t blocks_compressed;
    uint8_t flags;
} kty_blake3_chunk_state;

typedef struct {
    uint32_t key[8];
    kty_blake3_chunk_state chunk;
    uint32_t cv_stack[54 * 8];
    uint8_t cv_stack_len;
    uint8_t flags;
} kty_blake3_ctx;

void kty_blake3_init(kty_blake3_ctx *ctx);
void kty_blake3_update(kty_blake3_ctx *ctx, const void *data, size_t len);
void kty_blake3_final(const kty_blake3_ctx *ctx, uint8_t digest[KTY_BLAKE3_DIGEST_LEN]);
void kty_blake3_data(const void *data, size_t len, uint8_t digest[KTY_BLAKE3_DIGEST_LEN]);

/* --- Forensic Formatting Utility --- */
void kty_digest_to_hex(const uint8_t digest[32], char hex[65]);

#ifdef __cplusplus
}
#endif

#endif /* KTY_CRYPTO_H */
