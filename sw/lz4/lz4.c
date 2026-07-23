#include <stddef.h>
#include <stdint.h>

enum {
    LZ4_OUTPUT_BYTES = 65536,
    LZ4_BLOCK_BYTES = 1024,
    LZ4_BLOCKS = LZ4_OUTPUT_BYTES / LZ4_BLOCK_BYTES,
    LZ4_FIRST_LITERAL_BYTES = 64,
    LZ4_REPEAT_LITERAL_BYTES = 16,
    LZ4_MATCH_EXTENSION_BYTES = 4
};

/*
 * A valid raw LZ4 block with 64 sequences.  The first emits 64 literal bytes
 * and a 960-byte match at offset 64.  Each following sequence emits 16
 * literals and a 1008-byte match at offset 1024.
 *
 * The 1584-byte input expands to 64 KiB.  Multiple sequences matter here:
 * using one enormous match would reduce LZ4 to a byte-copy loop and largely
 * omit its token, length, literal, offset, and match transitions.
 */
struct __attribute__((packed)) lz4_first_sequence {
    uint8_t token;
    uint8_t literal_length_extension;
    uint8_t literal[LZ4_FIRST_LITERAL_BYTES];
    uint8_t offset[2];
    uint8_t match_length_extension[LZ4_MATCH_EXTENSION_BYTES];
};

struct __attribute__((packed)) lz4_repeat_sequence {
    uint8_t token;
    uint8_t literal_length_extension;
    uint8_t literal[LZ4_REPEAT_LITERAL_BYTES];
    uint8_t offset[2];
    uint8_t match_length_extension[LZ4_MATCH_EXTENSION_BYTES];
};

struct __attribute__((packed)) lz4_corpus {
    struct lz4_first_sequence first;
    struct lz4_repeat_sequence repeat[LZ4_BLOCKS - 1];
};

static const struct lz4_corpus compressed = {
    .first = {
        .token = 0xff,
        .literal_length_extension = 49,
        .literal = {
            'O', 'p', 'e', 'n', 'R', 'V', '6', '4',
            ' ', 'L', 'Z', '4', ' ', 'p', 'r', 'e',
            'f', 'e', 't', 'c', 'h', ' ', 'b', 'e',
            'n', 'c', 'h', 'm', 'a', 'r', 'k', ':',
            ' ', '0', '1', '2', '3', '4', '5', '6',
            '7', '8', '9', 'a', 'b', 'c', 'd', 'e',
            'f', ' ', '-', ' ', '6', '4', '-', 'b',
            'y', 't', 'e', ' ', 's', 'e', 'e', 'd'
        },
        .offset = {64, 0},
        .match_length_extension = {255, 255, 255, 176}
    },
    .repeat = {
        [0 ... LZ4_BLOCKS - 2] = {
            .token = 0xff,
            .literal_length_extension = 1,
            .literal = {
                'L', 'Z', '4', '-', 's', 'e', 'q', 'u',
                'e', 'n', 'c', 'e', '-', '0', '1', '6'
            },
            .offset = {0, 4},
            .match_length_extension = {255, 255, 255, 224}
        }
    }
};

_Static_assert(sizeof(compressed) == 1584, "unexpected LZ4 corpus layout");

static uint8_t output[LZ4_OUTPUT_BYTES] __attribute__((aligned(64)));

uint64_t lz4_cycles;

static size_t extend_length(const uint8_t **cursor, const uint8_t *end,
                            size_t length)
{
    uint8_t extension;

    do {
        if (*cursor == end)
            return (size_t)-1;
        extension = *(*cursor)++;
        length += extension;
    } while (extension == 255);

    return length;
}

__attribute__((noinline))
size_t lz4_decode_bench(void)
{
    const uint8_t *cursor = (const uint8_t *)&compressed;
    const uint8_t *const end = cursor + sizeof(compressed);
    uint8_t *destination = output;
    uint8_t *const output_end = output + sizeof(output);

    while (cursor != end) {
        const uint8_t token = *cursor++;
        size_t literal_length = token >> 4;
        size_t match_length;
        size_t produced;
        size_t offset;
        uint8_t *match;

        if (literal_length == 15) {
            literal_length = extend_length(&cursor, end, literal_length);
            if (literal_length == (size_t)-1)
                return 0;
        }
        if ((size_t)(end - cursor) < literal_length ||
            (size_t)(output_end - destination) < literal_length)
            return 0;

        for (size_t index = 0; index < literal_length; ++index)
            *destination++ = *cursor++;

        if (cursor == end)
            return (size_t)(destination - output);
        if ((size_t)(end - cursor) < 2)
            return 0;

        offset = (size_t)cursor[0] | ((size_t)cursor[1] << 8);
        cursor += 2;
        produced = (size_t)(destination - output);
        if (offset == 0 || offset > produced)
            return 0;

        match_length = (token & 15) + 4;
        if ((token & 15) == 15) {
            match_length = extend_length(&cursor, end, match_length);
            if (match_length == (size_t)-1)
                return 0;
        }
        if ((size_t)(output_end - destination) < match_length)
            return 0;

        match = destination - offset;
        for (size_t index = 0; index < match_length; ++index)
            *destination++ = *match++;
    }

    return (size_t)(destination - output);
}

__attribute__((noinline))
int lz4_verify(size_t decoded_bytes)
{
    if (decoded_bytes != sizeof(output))
        return 0;

    for (size_t block = 0; block < LZ4_BLOCKS; ++block) {
        for (size_t index = 0; index < LZ4_BLOCK_BYTES; ++index) {
            uint8_t expected =
                compressed.first.literal[index &
                                         (LZ4_FIRST_LITERAL_BYTES - 1)];

            if (block != 0 && index < LZ4_REPEAT_LITERAL_BYTES)
                expected = compressed.repeat[0].literal[index];
            if (output[block * LZ4_BLOCK_BYTES + index] != expected)
                return 0;
        }
    }

    return 1;
}
