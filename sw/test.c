
#include <stdint.h>

/*
 * Small CoreMark-shaped stall probe.  This is not CoreMark and has no score;
 * it deliberately preserves the dependency shapes which are awkward for a
 * short in-order issue window:
 *
 *   load cursor -> load byte -> branch
 *   state -> counter address -> load/increment/store
 *   short forward state-machine branches inside a backward loop
 *
 * Volatile input and counters keep those operations present at -O2.  Keeping
 * the walker out of line also makes each call begin with the pointer load used
 * by CoreMark's state-transition routine.
 */
static const volatile uint8_t coremark_stall_input[] =
    "12,+3.4e-5,x9,7.0,+q,-18e+2,0z,44.1,";

volatile uint64_t coremark_stall_sink = UINT64_C(0x6d5a56a9811c9dc5);

static __attribute__((noinline)) uint32_t
coremark_stall_walk(const volatile uint8_t **cursor_ref,
                    volatile uint32_t counters[4],
                    uint32_t seed)
{
    const volatile uint8_t *cursor = *cursor_ref;
    uint32_t state = seed & 3u;
    uint32_t mix = seed;
    unsigned int step;

    for (step = 0; step < 64u; step++) {
        uint8_t symbol = *cursor;
        uint8_t lookahead;
        uint32_t count;

        if (symbol == 0u) {
            cursor = coremark_stall_input;
            symbol = *cursor;
        }
        lookahead = cursor[1];

        count = counters[state];
        counters[state] = count + 1u;

        switch (state) {
        case 0:
            if ((symbol >= (uint8_t)'0') &&
                (symbol <= (uint8_t)'9')) {
                state = 1;
            } else if ((symbol == (uint8_t)'+') ||
                       (symbol == (uint8_t)'-')) {
                state = 2;
            } else {
                state = 3;
            }
            break;

        case 1:
            if (symbol == (uint8_t)'.') {
                state = 2;
            } else if (symbol == (uint8_t)',') {
                state = 0;
            } else if ((symbol < (uint8_t)'0') ||
                       (symbol > (uint8_t)'9')) {
                state = 3;
            }
            break;

        case 2:
            if ((symbol == (uint8_t)'e') ||
                (symbol == (uint8_t)'E')) {
                state = 3;
            } else if (symbol == (uint8_t)',') {
                state = 0;
            } else {
                state = 1;
            }
            break;

        default:
            if (symbol == (uint8_t)',') {
                state = 0;
            } else if ((symbol >= (uint8_t)'0') &&
                       (symbol <= (uint8_t)'9')) {
                state = 1;
            } else {
                state = 3;
            }
            break;
        }

        if ((lookahead == (uint8_t)',') || (lookahead == 0u)) {
            mix ^= counters[(state + 1u) & 3u];
        } else {
            mix += ((uint32_t)symbol << (state & 7u)) ^ count;
        }
        mix = (mix << 5) | (mix >> 27);
        cursor++;
    }

    *cursor_ref = cursor;
    return mix;
}

__attribute__((noinline, used)) unsigned long long
coremark_stall_probe(void)
{
    volatile uint32_t counters[4] = {0u, 0u, 0u, 0u};
    const volatile uint8_t *cursor = coremark_stall_input;
    uint32_t mix = UINT32_C(0x811c9dc5);
    unsigned int pass;

    for (pass = 0; pass < 8u; pass++) {
        mix ^= coremark_stall_walk(&cursor, counters, mix);
        mix = (mix << 7) | (mix >> 25);
        coremark_stall_sink = mix;
    }

    return ((uint64_t)mix << 32) ^
           ((uint64_t)counters[0] << 24) ^
           ((uint64_t)counters[1] << 16) ^
           ((uint64_t)counters[2] << 8) ^
           (uint64_t)counters[3];
}

unsigned long long main()
{
#ifdef TEST_RUN_COREMARK_STALL_PROBE
    return coremark_stall_probe();
#else
    unsigned long long sum = 0, sum2 = 120;
    volatile unsigned long long test, test2;

    for (int i = 0; i < 100; i++) {
        asm volatile ("addi %0, %0, 1\n"
                      //"addi %1, %1, -1\n"
                      "sd %0, %2\n"
                : "+r"(sum), "+r"(sum2), "=m"(test), "=m"(test2) : : "memory");
    }
    return sum;
#endif
}
