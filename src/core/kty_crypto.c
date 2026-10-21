/*
 * kty-ntfs: Forensic Cryptographic Engine Implementation
 *
 * Provides SHA-256 and BLAKE3 hashing routines for evidence chain-of-custody.
 */

#include "kty_crypto.h"
#include <string.h>
#include <stdio.h>

/* =========================================================================
 * SHA-256 Implementation (CommonCrypto Native / Hardware-Accelerated)
 * ========================================================================= */

void kty_sha256_init(kty_sha256_ctx *ctx) {
    if (ctx) {
        CC_SHA256_Init(ctx);
    }
}

void kty_sha256_update(kty_sha256_ctx *ctx, const void *data, size_t len) {
    if (!ctx || !data || len == 0) return;
    const uint8_t *ptr = (const uint8_t *)data;
    while (len > 0) {
        CC_LONG chunk = (len > (size_t)UINT32_MAX) ? UINT32_MAX : (CC_LONG)len;
        CC_SHA256_Update(ctx, ptr, chunk);
        ptr += chunk;
        len -= chunk;
    }
}

void kty_sha256_final(kty_sha256_ctx *ctx, uint8_t digest[KTY_SHA256_DIGEST_LEN]) {
    if (ctx && digest) {
        CC_SHA256_Final(digest, ctx);
    }
}

void kty_sha256_data(const void *data, size_t len, uint8_t digest[KTY_SHA256_DIGEST_LEN]) {
    if (!digest) return;
    kty_sha256_ctx ctx;
    kty_sha256_init(&ctx);
    kty_sha256_update(&ctx, data, len);
    kty_sha256_final(&ctx, digest);
}

/* =========================================================================
 * BLAKE3 Implementation (Official Reference Tree-Hashing Specification)
 * ========================================================================= */

static const uint32_t BLAKE3_IV[8] = {
    0x6A09E667UL, 0xBB67AE85UL, 0x3C6EF372UL, 0xA54FF53AUL,
    0x510E527FUL, 0x9B05688CUL, 0x1F83D9ABUL, 0x5BE0CD19UL
};

static const uint8_t MSG_PERMUTATION[16] = {
    2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8
};

enum blake3_internal_flags {
    FLAG_CHUNK_START         = 1 << 0,
    FLAG_CHUNK_END           = 1 << 1,
    FLAG_PARENT              = 1 << 2,
    FLAG_ROOT                = 1 << 3,
    FLAG_KEYED_HASH          = 1 << 4,
    FLAG_DERIVE_KEY_CONTEXT  = 1 << 5,
    FLAG_DERIVE_KEY_MATERIAL = 1 << 6,
};

static inline uint32_t rotr32(uint32_t w, unsigned int c) {
    return (w >> c) | (w << (32 - c));
}

static inline void blake3_g(uint32_t *state, size_t a, size_t b, size_t c, size_t d, uint32_t mx, uint32_t my) {
    state[a] = state[a] + state[b] + mx;
    state[d] = rotr32(state[d] ^ state[a], 16);
    state[c] = state[c] + state[d];
    state[b] = rotr32(state[b] ^ state[c], 12);
    state[a] = state[a] + state[b] + my;
    state[d] = rotr32(state[d] ^ state[a], 8);
    state[c] = state[c] + state[d];
    state[b] = rotr32(state[b] ^ state[c], 7);
}

static inline void blake3_round(uint32_t *state, const uint32_t *msg) {
    blake3_g(state, 0, 4, 8, 12, msg[0], msg[1]);
    blake3_g(state, 1, 5, 9, 13, msg[2], msg[3]);
    blake3_g(state, 2, 6, 10, 14, msg[4], msg[5]);
    blake3_g(state, 3, 7, 11, 15, msg[6], msg[7]);
    blake3_g(state, 0, 5, 10, 15, msg[8], msg[9]);
    blake3_g(state, 1, 6, 11, 12, msg[10], msg[11]);
    blake3_g(state, 2, 7, 8, 13, msg[12], msg[13]);
    blake3_g(state, 3, 4, 9, 14, msg[14], msg[15]);
}

static void blake3_compress(const uint32_t cv[8],
                            const uint8_t block[64],
                            uint8_t block_len,
                            uint64_t counter,
                            uint8_t flags,
                            uint32_t out[16]) {
    uint32_t state[16];
    for (int i = 0; i < 8; i++) state[i] = cv[i];
    state[8] = BLAKE3_IV[0];
    state[9] = BLAKE3_IV[1];
    state[10] = BLAKE3_IV[2];
    state[11] = BLAKE3_IV[3];
    state[12] = (uint32_t)counter;
    state[13] = (uint32_t)(counter >> 32);
    state[14] = (uint32_t)block_len;
    state[15] = (uint32_t)flags;

    uint32_t msg[16];
    for (int i = 0; i < 16; i++) {
        msg[i] = (uint32_t)block[i*4] |
                 ((uint32_t)block[i*4 + 1] << 8) |
                 ((uint32_t)block[i*4 + 2] << 16) |
                 ((uint32_t)block[i*4 + 3] << 24);
    }

    uint32_t m[16];
    memcpy(m, msg, sizeof(m));

    for (int round = 0; round < 7; round++) {
        blake3_round(state, m);
        uint32_t permuted[16];
        for (int i = 0; i < 16; i++) {
            permuted[i] = m[MSG_PERMUTATION[i]];
        }
        memcpy(m, permuted, sizeof(m));
    }

    for (int i = 0; i < 8; i++) {
        out[i] = state[i] ^ state[i + 8];
        out[i + 8] = state[i + 8] ^ cv[i];
    }
}

static void chunk_state_init(kty_blake3_chunk_state *self, const uint32_t key[8], uint64_t chunk_counter, uint8_t flags) {
    memcpy(self->cv, key, sizeof(self->cv));
    self->chunk_counter = chunk_counter;
    memset(self->buf, 0, sizeof(self->buf));
    self->buf_len = 0;
    self->blocks_compressed = 0;
    self->flags = flags;
}

static size_t chunk_state_len(const kty_blake3_chunk_state *self) {
    return (size_t)self->blocks_compressed * KTY_BLAKE3_BLOCK_LEN + self->buf_len;
}

static uint8_t chunk_state_maybe_start_flag(const kty_blake3_chunk_state *self) {
    return self->blocks_compressed == 0 ? FLAG_CHUNK_START : 0;
}

typedef struct {
    uint32_t cv[8];
    uint8_t block[64];
    uint8_t block_len;
    uint64_t counter;
    uint8_t flags;
} blake3_output_t;

static blake3_output_t chunk_state_output(const kty_blake3_chunk_state *self) {
    blake3_output_t out;
    memcpy(out.cv, self->cv, sizeof(out.cv));
    memcpy(out.block, self->buf, sizeof(out.block));
    out.block_len = self->buf_len;
    out.counter = self->chunk_counter;
    out.flags = self->flags | chunk_state_maybe_start_flag(self) | FLAG_CHUNK_END;
    return out;
}

static void output_root_bytes(const blake3_output_t *self, uint8_t *out_slice, size_t out_slice_len) {
    uint64_t output_block_counter = 0;
    size_t out_offset = 0;
    while (out_offset < out_slice_len) {
        uint32_t words[16];
        blake3_compress(self->cv, self->block, self->block_len, output_block_counter, self->flags | FLAG_ROOT, words);
        for (size_t word = 0; word < 16; word++) {
            for (int byte = 0; byte < 4; byte++) {
                if (out_offset < out_slice_len) {
                    out_slice[out_offset++] = (uint8_t)(words[word] >> (8 * byte));
                }
            }
        }
        output_block_counter++;
    }
}

static void output_chaining_value(const blake3_output_t *self, uint32_t cv[8]) {
    uint32_t words[16];
    blake3_compress(self->cv, self->block, self->block_len, self->counter, self->flags, words);
    memcpy(cv, words, 32);
}

static void chunk_state_update(kty_blake3_chunk_state *self, const uint8_t *input, size_t input_len) {
    while (input_len > 0) {
        if (self->buf_len == KTY_BLAKE3_BLOCK_LEN) {
            uint32_t out[16];
            blake3_compress(self->cv, self->buf, KTY_BLAKE3_BLOCK_LEN, self->chunk_counter,
                            self->flags | chunk_state_maybe_start_flag(self), out);
            memcpy(self->cv, out, 32);
            self->blocks_compressed++;
            memset(self->buf, 0, sizeof(self->buf));
            self->buf_len = 0;
        }

        size_t want = KTY_BLAKE3_BLOCK_LEN - self->buf_len;
        size_t take = input_len < want ? input_len : want;
        memcpy(&self->buf[self->buf_len], input, take);
        self->buf_len += (uint8_t)take;
        input += take;
        input_len -= take;
    }
}

static blake3_output_t parent_output(const uint32_t left_child_cv[8],
                                     const uint32_t right_child_cv[8],
                                     const uint32_t key[8],
                                     uint8_t flags) {
    blake3_output_t out;
    memcpy(out.cv, key, sizeof(out.cv));
    uint8_t block[64];
    for (int i = 0; i < 8; i++) {
        block[i*4]   = (uint8_t)(left_child_cv[i]);
        block[i*4+1] = (uint8_t)(left_child_cv[i] >> 8);
        block[i*4+2] = (uint8_t)(left_child_cv[i] >> 16);
        block[i*4+3] = (uint8_t)(left_child_cv[i] >> 24);
    }
    for (int i = 0; i < 8; i++) {
        block[32 + i*4]   = (uint8_t)(right_child_cv[i]);
        block[32 + i*4+1] = (uint8_t)(right_child_cv[i] >> 8);
        block[32 + i*4+2] = (uint8_t)(right_child_cv[i] >> 16);
        block[32 + i*4+3] = (uint8_t)(right_child_cv[i] >> 24);
    }
    memcpy(out.block, block, 64);
    out.block_len = 64;
    out.counter = 0;
    out.flags = flags | FLAG_PARENT;
    return out;
}

static void blake3_hasher_push_stack(kty_blake3_ctx *self, const uint32_t cv[8]) {
    if (self->cv_stack_len < 54) {
        memcpy(&self->cv_stack[self->cv_stack_len * 8], cv, 32);
        self->cv_stack_len++;
    }
}

static void blake3_hasher_pop_stack(kty_blake3_ctx *self, uint32_t out[8]) {
    self->cv_stack_len--;
    memcpy(out, &self->cv_stack[self->cv_stack_len * 8], 32);
}

static void blake3_hasher_add_chunk_cv(kty_blake3_ctx *self, uint32_t new_cv[8], uint64_t total_chunks) {
    while ((total_chunks & 1) == 0) {
        uint32_t parent_cv[8];
        uint32_t left_child_cv[8];
        blake3_hasher_pop_stack(self, left_child_cv);
        blake3_output_t p = parent_output(left_child_cv, new_cv, self->key, self->flags);
        output_chaining_value(&p, parent_cv);
        memcpy(new_cv, parent_cv, 32);
        total_chunks >>= 1;
    }
    blake3_hasher_push_stack(self, new_cv);
}

void kty_blake3_init(kty_blake3_ctx *ctx) {
    if (!ctx) return;
    memcpy(ctx->key, BLAKE3_IV, sizeof(ctx->key));
    chunk_state_init(&ctx->chunk, BLAKE3_IV, 0, 0);
    ctx->cv_stack_len = 0;
    ctx->flags = 0;
}

void kty_blake3_update(kty_blake3_ctx *ctx, const void *data, size_t len) {
    if (!ctx || !data || len == 0) return;
    const uint8_t *in = (const uint8_t *)data;
    while (len > 0) {
        if (chunk_state_len(&ctx->chunk) == KTY_BLAKE3_CHUNK_LEN) {
            uint32_t chunk_cv[8];
            blake3_output_t chunk_out = chunk_state_output(&ctx->chunk);
            output_chaining_value(&chunk_out, chunk_cv);
            uint64_t total_chunks = ctx->chunk.chunk_counter + 1;
            blake3_hasher_add_chunk_cv(ctx, chunk_cv, total_chunks);
            chunk_state_init(&ctx->chunk, ctx->key, total_chunks, ctx->flags);
        }

        size_t want = KTY_BLAKE3_CHUNK_LEN - chunk_state_len(&ctx->chunk);
        size_t take = len < want ? len : want;
        chunk_state_update(&ctx->chunk, in, take);
        in += take;
        len -= take;
    }
}

void kty_blake3_final(const kty_blake3_ctx *ctx, uint8_t digest[KTY_BLAKE3_DIGEST_LEN]) {
    if (!ctx || !digest) return;
    blake3_output_t current_output = chunk_state_output(&ctx->chunk);
    size_t parent_nodes_remaining = (size_t)ctx->cv_stack_len;
    while (parent_nodes_remaining > 0) {
        parent_nodes_remaining--;
        uint32_t right_cv[8];
        output_chaining_value(&current_output, right_cv);
        current_output = parent_output(&ctx->cv_stack[parent_nodes_remaining * 8],
                                       right_cv,
                                       ctx->key,
                                       ctx->flags);
    }
    output_root_bytes(&current_output, digest, KTY_BLAKE3_DIGEST_LEN);
}

void kty_blake3_data(const void *data, size_t len, uint8_t digest[KTY_BLAKE3_DIGEST_LEN]) {
    if (!digest) return;
    kty_blake3_ctx ctx;
    kty_blake3_init(&ctx);
    kty_blake3_update(&ctx, data, len);
    kty_blake3_final(&ctx, digest);
}

/* =========================================================================
 * Formatting Utilities
 * ========================================================================= */

void kty_digest_to_hex(const uint8_t digest[32], char hex[65]) {
    if (!digest || !hex) return;
    static const char hex_chars[] = "0123456789abcdef";
    for (size_t i = 0; i < 32; i++) {
        hex[i * 2]     = hex_chars[(digest[i] >> 4) & 0x0F];
        hex[i * 2 + 1] = hex_chars[digest[i] & 0x0F];
    }
    hex[64] = '\0';
}
