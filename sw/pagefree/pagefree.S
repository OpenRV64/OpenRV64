/*
 * Linux page-freeing loop microbenchmark.
 *
 * PAGEFREE_KERNEL:
 *   0 = __free_pages_core() meminit loop
 *   1 = __free_pages_prepare() tail-page flags loop
 *
 * The matching Linux image uses a 64-byte struct page.  A 256 MiB physical
 * memory therefore has 65,536 descriptors and a 4 MiB mem_map.  The quick
 * default uses 8,192 descriptors; the full target retains the complete
 * footprint.
 *
 * The measured loops preserve the instruction order and I-cache alignment of
 * Linux vmlinux:
 *
 *   __free_pages_core+0x18 at PC[4:0] = 8
 *   __free_pages_ok+0x1d4 at PC[4:0] = 20
 *
 * Results at pagefree_drain_end:
 *   a0 = PAGEFREE_KERNEL
 *   a1 = measured loop cycles
 *   a2 = measured loop instructions retired
 *   a3 = descriptor count
 *   a4 = cycles through the post-loop FENCE
 */

.ifndef PAGEFREE_KERNEL
.equ PAGEFREE_KERNEL, 0
.endif

.ifndef PAGEFREE_RECORDS
.equ PAGEFREE_RECORDS, 8192
.endif

.if ((PAGEFREE_KERNEL < 0) || (PAGEFREE_KERNEL > 1))
.error "PAGEFREE_KERNEL must be 0 (core) or 1 (tail)"
.endif

.if ((PAGEFREE_RECORDS < 1024) || ((PAGEFREE_RECORDS % 1024) != 0))
.error "PAGEFREE_RECORDS must be a multiple of 1024"
.endif

.equ PAGEFREE_RECORD_BYTES, 64
.equ PAGEFREE_INITIAL_FLAGS, 0xdeadbeefcafebfff
.equ PAGEFREE_CORE_MASK,    0xffffffffffffdfff
.equ PAGEFREE_TAIL_MASK,    0xffffffffffe00000
.equ PAGEFREE_CORE_FLAGS,   0xdeadbeefcafe9fff
.equ PAGEFREE_TAIL_FLAGS,   0xdeadbeefcae00000
.equ PAGEFREE_PASS,         0x5041474546524545 /* "PAGEFREE" */
.equ PAGEFREE_FAIL,         0x504147454641494c /* "PAGEFAIL" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

_start:
    la      sp, __stack_top
    la      s0, pagefree_records
    li      s1, PAGEFREE_RECORDS

.if PAGEFREE_KERNEL == 0
    /*
     * Match __free_pages_core:
     *
     *   beq counter, nr_pages, end
     *   ld flags; sw 0, _refcount; addiw counter
     *   and flags; sd flags; addi page, 64; jump
     */
    lui     s3, 0xffffe
    addi    s3, s3, -1
    li      s4, 0

    /* Linux loop begins at offset 8 in a 32-byte instruction line. */
    .balign 32
    csrr    s5, mcycle
    csrr    s6, minstret

.globl pagefree_measure_begin
pagefree_measure_begin:
    beq     s4, s1, .Lmeasure_done
    ld      t0, 0(s0)
    sw      zero, 52(s0)
    addiw   s4, s4, 1
    and     t0, t0, s3
    sd      t0, 0(s0)
    addi    s0, s0, PAGEFREE_RECORD_BYTES
    j       pagefree_measure_begin
.else
    /*
     * Match the common __free_pages_prepare tail-page path:
     *
     *   lw check_pages_enabled; ld flags; bgtz check
     *   lui mask; and flags; sd flags; addi page, 64
     *   beq page, end; beqz compound, loop
     */
    slli    s1, s1, 6
    add     s1, s0, s1
    la      s3, pagefree_check_pages_enabled
    li      s4, 0

    /* Linux loop begins at offset 20 in a 32-byte instruction line. */
    .balign 32
    nop
    nop
    nop
    csrr    s5, mcycle
    csrr    s6, minstret

.globl pagefree_measure_begin
pagefree_measure_begin:
    lw      t0, 0(s3)
    ld      t1, 0(s0)
    bgtz    t0, .Lfail
    lui     t2, 0xffe00
    and     t1, t1, t2
    sd      t1, 0(s0)
    addi    s0, s0, PAGEFREE_RECORD_BYTES
    beq     s0, s1, .Lmeasure_done
    beqz    s4, pagefree_measure_begin
    j       .Lfail
.endif

.Lmeasure_done:
    csrr    t0, mcycle
    csrr    t1, minstret
    sub     a1, t0, s5
    sub     a2, t1, s6
    li      a0, PAGEFREE_KERNEL
    li      a3, PAGEFREE_RECORDS

.globl pagefree_measure_end
pagefree_measure_end:
    nop

    /*
     * The loop result is retirement throughput.  Report a second cycle count
     * after ordering the stores so a posted-store implementation cannot hide
     * all of its drain cost.
     */
    fence   rw, rw
    csrr    t0, mcycle
    sub     a4, t0, s5
    /*
     * The 3-wide harness samples architectural registers when the done PC
     * retires.  Keep that PC out of the same retire group as the a4 write.
     */
    nop
    nop
    nop
    nop

.globl pagefree_drain_end
pagefree_drain_end:
    nop

    /* Verify every descriptor outside the measured region. */
    la      s0, pagefree_records
    li      s1, PAGEFREE_RECORDS
.if PAGEFREE_KERNEL == 0
    li      s2, PAGEFREE_CORE_FLAGS
    li      s3, 0
.else
    li      s2, PAGEFREE_TAIL_FLAGS
    li      s3, 1
.endif

.Lverify:
    ld      t0, 0(s0)
    bne     t0, s2, .Lfail
    lw      t0, 52(s0)
    bne     t0, s3, .Lfail
    addi    s0, s0, PAGEFREE_RECORD_BYTES
    addi    s1, s1, -1
    bnez    s1, .Lverify

    li      a0, PAGEFREE_PASS

.globl pagefree_done
pagefree_done:
    ebreak

.Lfail:
    li      a0, PAGEFREE_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.size _start, .-_start

.section .data.pagefree_control, "aw", @progbits
.balign 64
.globl pagefree_check_pages_enabled
pagefree_check_pages_enabled:
    .word 0
    .zero 60

.section .data.pagefree_records, "aw", @progbits
.balign 64
.globl pagefree_records
.type pagefree_records, @object
pagefree_records:
    .rept PAGEFREE_RECORDS
        .quad PAGEFREE_INITIAL_FLAGS
        .zero 44
        .word 1
        .zero 8
    .endr
.size pagefree_records, .-pagefree_records
