// SPDX-License-Identifier: MIT
/*
 * BLAKE2s generic-compression microbenchmark.
 *
 * The compression core is adapted from Linux lib/crypto/blake2s.c:
 * Copyright (C) 2015-2019 Jason A. Donenfeld
 *
 * Keep the measured implementation structurally aligned with the Linux
 * generic implementation: two out-of-line memcpy calls, a fully unrolled
 * ten-round loop, and one context update per 64-byte block.  The compact
 * reference implementation below is deliberately not unrolled.
 */

#include <stddef.h>
#include <stdint.h>

#ifndef BLAKE2S_BENCH_CALLS
#define BLAKE2S_BENCH_CALLS 16
#endif

#ifndef BLAKE2S_BLOCKS_PER_CALL
#define BLAKE2S_BLOCKS_PER_CALL 1
#endif

enum {
    BLAKE2S_BLOCK_SIZE = 64,
    BLAKE2S_HASH_SIZE = 32,
    BLAKE2S_INPUT_BLOCKS = 16
};

enum blake2s_iv {
    BLAKE2S_IV0 = 0x6a09e667U,
    BLAKE2S_IV1 = 0xbb67ae85U,
    BLAKE2S_IV2 = 0x3c6ef372U,
    BLAKE2S_IV3 = 0xa54ff53aU,
    BLAKE2S_IV4 = 0x510e527fU,
    BLAKE2S_IV5 = 0x9b05688cU,
    BLAKE2S_IV6 = 0x1f83d9abU,
    BLAKE2S_IV7 = 0x5be0cd19U
};

struct blake2s_ctx {
    uint32_t h[8];
    uint32_t t[2];
    uint32_t f[2];
    uint8_t buf[BLAKE2S_BLOCK_SIZE];
    unsigned int buflen;
    unsigned int outlen;
};

struct blake2s_block {
    uint32_t word[BLAKE2S_BLOCK_SIZE / sizeof(uint32_t)];
};

_Static_assert(BLAKE2S_BENCH_CALLS > 0,
               "BLAKE2S_BENCH_CALLS must be positive");
_Static_assert(BLAKE2S_BLOCKS_PER_CALL > 0,
               "BLAKE2S_BLOCKS_PER_CALL must be positive");
_Static_assert(BLAKE2S_BLOCKS_PER_CALL <= BLAKE2S_INPUT_BLOCKS,
               "BLAKE2S_BLOCKS_PER_CALL exceeds the input corpus");
_Static_assert(sizeof(struct blake2s_ctx) == 120,
               "BLAKE2s context layout differs from Linux");

static const uint8_t blake2s_sigma[10][16] = {
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    { 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    { 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    { 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    { 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    { 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    { 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    { 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    { 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 }
};

/*
 * The Linux RISC-V memcpy path uses a 32-bit loop for these aligned 32- and
 * 64-byte copies. Keep this out of line because the measured kernel function
 * also calls out to memcpy twice per block.
 */
__attribute__((noinline))
void *memcpy(void *destination, const void *source, size_t bytes)
{
    void *const result = destination;
    uint32_t *destination_word = (uint32_t *)destination;
    const uint32_t *source_word = (const uint32_t *)source;

    while (bytes >= sizeof(uint32_t)) {
        *destination_word++ = *source_word++;
        bytes -= sizeof(uint32_t);
    }

    if (bytes != 0) {
        uint8_t *destination_byte = (uint8_t *)destination_word;
        const uint8_t *source_byte = (const uint8_t *)source_word;

        while (bytes-- != 0)
            *destination_byte++ = *source_byte++;
    }

    return result;
}

static const struct blake2s_block blake2s_input[BLAKE2S_INPUT_BLOCKS]
    __attribute__((aligned(64))) = {
        [0 ... BLAKE2S_INPUT_BLOCKS - 1] = {
            .word = {
                0x6e65704fU, 0x34365652U, 0x4c422073U, 0x32656b41U,
                0x6d6f6320U, 0x73657270U, 0x6e6f6973U, 0x6e656220U,
                0x616d6863U, 0x30206b72U, 0x34333231U, 0x38373635U,
                0x62613930U, 0x66656463U, 0x4b4f2120U, 0x5a595857U
            }
        }
    };

static struct blake2s_ctx measured_ctx __attribute__((aligned(64)));

static inline uint32_t ror32(uint32_t word, unsigned int shift)
{
    return (word >> shift) | (word << (32U - shift));
}

static inline void blake2s_increment_counter(struct blake2s_ctx *ctx,
                                              uint32_t increment)
{
    ctx->t[0] += increment;
    ctx->t[1] += ctx->t[0] < increment;
}

__attribute__((noinline))
void blake2s_compress_generic(struct blake2s_ctx *ctx, const uint8_t *data,
                              size_t nblocks, uint32_t increment)
{
    uint32_t m[16];
    uint32_t v[16];

    /*
     * Linux proves all in-tree callers pass at least one block and emits this
     * as a do/while loop. Express that contract directly so the standalone
     * symbol retains the same entry path and code size.
     */
    do {
        blake2s_increment_counter(ctx, increment);
        memcpy(m, data, BLAKE2S_BLOCK_SIZE);
        memcpy(v, ctx->h, BLAKE2S_HASH_SIZE);
        v[8] = BLAKE2S_IV0;
        v[9] = BLAKE2S_IV1;
        v[10] = BLAKE2S_IV2;
        v[11] = BLAKE2S_IV3;
        v[12] = BLAKE2S_IV4 ^ ctx->t[0];
        v[13] = BLAKE2S_IV5 ^ ctx->t[1];
        v[14] = BLAKE2S_IV6 ^ ctx->f[0];
        v[15] = BLAKE2S_IV7 ^ ctx->f[1];

#define G(round, index, a, b, c, d) do {                              \
        a += b + m[blake2s_sigma[round][2 * (index) + 0]];            \
        d = ror32(d ^ a, 16);                                         \
        c += d;                                                        \
        b = ror32(b ^ c, 12);                                         \
        a += b + m[blake2s_sigma[round][2 * (index) + 1]];            \
        d = ror32(d ^ a, 8);                                          \
        c += d;                                                        \
        b = ror32(b ^ c, 7);                                          \
    } while (0)

#pragma GCC unroll 65534
        for (int round = 0; round < 10; ++round) {
            G(round, 0, v[0], v[4], v[8], v[12]);
            G(round, 1, v[1], v[5], v[9], v[13]);
            G(round, 2, v[2], v[6], v[10], v[14]);
            G(round, 3, v[3], v[7], v[11], v[15]);
            G(round, 4, v[0], v[5], v[10], v[15]);
            G(round, 5, v[1], v[6], v[11], v[12]);
            G(round, 6, v[2], v[7], v[8], v[13]);
            G(round, 7, v[3], v[4], v[9], v[14]);
        }
#undef G

        for (int index = 0; index < 8; ++index)
            ctx->h[index] ^= v[index] ^ v[index + 8];

        data += BLAKE2S_BLOCK_SIZE;
    } while (--nblocks > 0);
}

static void blake2s_init(struct blake2s_ctx *ctx)
{
    ctx->h[0] = BLAKE2S_IV0 ^ 0x01010020U;
    ctx->h[1] = BLAKE2S_IV1;
    ctx->h[2] = BLAKE2S_IV2;
    ctx->h[3] = BLAKE2S_IV3;
    ctx->h[4] = BLAKE2S_IV4;
    ctx->h[5] = BLAKE2S_IV5;
    ctx->h[6] = BLAKE2S_IV6;
    ctx->h[7] = BLAKE2S_IV7;
    ctx->t[0] = 0;
    ctx->t[1] = 0;
    ctx->f[0] = 0;
    ctx->f[1] = 0;
    ctx->buflen = 0;
    ctx->outlen = BLAKE2S_HASH_SIZE;
}

void blake2s_bench_reset(void)
{
    blake2s_init(&measured_ctx);
}

static uint32_t blake2s_checksum(const struct blake2s_ctx *ctx)
{
    uint32_t checksum = ctx->t[0] ^ ctx->t[1];

    for (int index = 0; index < 8; ++index)
        checksum ^= ror32(ctx->h[index], (unsigned int)(index + 1));
    return checksum;
}

__attribute__((noinline))
uint32_t blake2s_bench_run(void)
{
#pragma GCC unroll 1
    for (unsigned int call = 0; call < BLAKE2S_BENCH_CALLS; ++call) {
        blake2s_compress_generic(
            &measured_ctx, (const uint8_t *)blake2s_input,
            BLAKE2S_BLOCKS_PER_CALL, BLAKE2S_BLOCK_SIZE);
    }

    return blake2s_checksum(&measured_ctx);
}

/*
 * A compact, indexed implementation provides a code-generation-independent
 * correctness check after the measured region.
 */
__attribute__((noinline))
static void blake2s_compress_reference(struct blake2s_ctx *ctx,
                                       const struct blake2s_block *blocks,
                                       size_t nblocks)
{
#pragma GCC unroll 1
    while (nblocks-- != 0) {
        uint32_t v[16];
        const uint32_t *const m = blocks->word;

        blake2s_increment_counter(ctx, BLAKE2S_BLOCK_SIZE);
#pragma GCC unroll 1
        for (int index = 0; index < 8; ++index)
            v[index] = ctx->h[index];
        v[8] = BLAKE2S_IV0;
        v[9] = BLAKE2S_IV1;
        v[10] = BLAKE2S_IV2;
        v[11] = BLAKE2S_IV3;
        v[12] = BLAKE2S_IV4 ^ ctx->t[0];
        v[13] = BLAKE2S_IV5 ^ ctx->t[1];
        v[14] = BLAKE2S_IV6 ^ ctx->f[0];
        v[15] = BLAKE2S_IV7 ^ ctx->f[1];

#define G_REFERENCE(round, index, a, b, c, d) do {                    \
        a += b + m[blake2s_sigma[round][2 * (index) + 0]];            \
        d = ror32(d ^ a, 16);                                         \
        c += d;                                                        \
        b = ror32(b ^ c, 12);                                         \
        a += b + m[blake2s_sigma[round][2 * (index) + 1]];            \
        d = ror32(d ^ a, 8);                                          \
        c += d;                                                        \
        b = ror32(b ^ c, 7);                                          \
    } while (0)

#pragma GCC unroll 1
        for (int round = 0; round < 10; ++round) {
            G_REFERENCE(round, 0, v[0], v[4], v[8], v[12]);
            G_REFERENCE(round, 1, v[1], v[5], v[9], v[13]);
            G_REFERENCE(round, 2, v[2], v[6], v[10], v[14]);
            G_REFERENCE(round, 3, v[3], v[7], v[11], v[15]);
            G_REFERENCE(round, 4, v[0], v[5], v[10], v[15]);
            G_REFERENCE(round, 5, v[1], v[6], v[11], v[12]);
            G_REFERENCE(round, 6, v[2], v[7], v[8], v[13]);
            G_REFERENCE(round, 7, v[3], v[4], v[9], v[14]);
        }
#undef G_REFERENCE

#pragma GCC unroll 1
        for (int index = 0; index < 8; ++index)
            ctx->h[index] ^= v[index] ^ v[index + 8];

        ++blocks;
    }
}

__attribute__((noinline))
int blake2s_bench_verify(uint32_t measured_checksum)
{
    struct blake2s_ctx reference_ctx;

    blake2s_init(&reference_ctx);
#pragma GCC unroll 1
    for (unsigned int call = 0; call < BLAKE2S_BENCH_CALLS; ++call) {
        blake2s_compress_reference(
            &reference_ctx, blake2s_input, BLAKE2S_BLOCKS_PER_CALL);
    }

    if (measured_checksum != blake2s_checksum(&reference_ctx))
        return 0;
    if (measured_ctx.t[0] != reference_ctx.t[0] ||
        measured_ctx.t[1] != reference_ctx.t[1])
        return 0;
#pragma GCC unroll 1
    for (int index = 0; index < 8; ++index) {
        if (measured_ctx.h[index] != reference_ctx.h[index])
            return 0;
    }
    return 1;
}
