/* Repository-local, retirement-ordered test-control sequences. */

#define OPENRV64_START_TEST_HINT_WORD 0x7a100013
#define OPENRV64_START_TRACE_HINT_WORD 0x7a200013
#define OPENRV64_END_TRACE_HINT_WORD 0x7a300013

.macro OPENRV64_START_TEST
    /* 32-bit words keep the tag-to-EBREAK PC delta unambiguous with RVC. */
    .option push
    .option norvc
    .word   OPENRV64_START_TEST_HINT_WORD
    ebreak
    .option pop
.endm

.macro OPENRV64_START_TRACE
    .option push
    .option norvc
    .word   OPENRV64_START_TRACE_HINT_WORD
    ebreak
    .option pop
.endm

.macro OPENRV64_END_TRACE
    .option push
    .option norvc
    .word   OPENRV64_END_TRACE_HINT_WORD
    ebreak
    .option pop
.endm
