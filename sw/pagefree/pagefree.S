/*
 * Linux page-freeing loop microbenchmark.
 *
 * PAGEFREE_KERNEL:
 *   0 = __free_pages_core() meminit loop
 *   1 = __free_pages_prepare() tail-page flags loop
 *   2 = repeated order-10 core + tail + buddy-list processing
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

.if ((PAGEFREE_KERNEL < 0) || (PAGEFREE_KERNEL > 2))
.error "PAGEFREE_KERNEL must be 0 (core), 1 (tail), or 2 (buddy)"
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
.equ PAGEFREE_BUDDY_ORDER,  10
.equ PAGEFREE_BUDDY_RECORDS, (1 << PAGEFREE_BUDDY_ORDER)
.equ PAGEFREE_BUDDY_BYTES,  (PAGEFREE_BUDDY_RECORDS * PAGEFREE_RECORD_BYTES)
.equ PAGEFREE_BUDDY_TYPE,   0xbadd1000
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
.elseif PAGEFREE_KERNEL == 1
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
.else
    /*
     * Match the boot-time memblock cadence.  Linux frees the largest aligned
     * block allowed by MAX_PAGE_ORDER=10:
     *
     *   1. clear Reserved/refcount across 1024 descriptors;
     *   2. run __free_pages_prepare() across the 1023 tail descriptors;
     *   3. prepare the head and insert the order-10 block on the free list;
     *   4. advance to the next 1024-descriptor block.
     *
     * The two long loops preserve the measured Linux instruction order and
     * I-cache offsets.  The final accounting/list operations preserve the
     * allocator's memory topology without importing the complete kernel zone
     * and static-key machinery.
     */
    slli    s7, s1, 6
    add     s7, s0, s7
    lui     s3, 0xffffe
    addi    s3, s3, -1
    li      s8, PAGEFREE_BUDDY_RECORDS
    la      s9, pagefree_check_pages_enabled
    mv      s10, s0
    li      s4, 0

    /* Linux core loop begins at offset 8 in a 32-byte instruction line. */
    .balign 32
    csrr    s5, mcycle
    csrr    s6, minstret

.globl pagefree_measure_begin
pagefree_measure_begin:
.Lbuddy_core_loop:
    beq     s4, s8, .Lbuddy_tail_setup
    ld      t0, 0(s0)
    sw      zero, 52(s0)
    addiw   s4, s4, 1
    and     t0, t0, s3
    sd      t0, 0(s0)
    addi    s0, s0, PAGEFREE_RECORD_BYTES
    j       .Lbuddy_core_loop

.Lbuddy_tail_setup:
    addi    t4, s10, PAGEFREE_RECORD_BYTES
    li      s4, 0
    j       .Lbuddy_tail_loop

    /*
     * Branch directly over the padding.  The Linux tail loop begins at byte
     * offset 20 of its 32-byte instruction line.
     */
    .balign 32
    nop
    nop
    nop
    nop
    nop
.Lbuddy_tail_loop:
    lw      t0, 0(s9)
    ld      t1, 0(t4)
    bgtz    t0, .Lfail
    lui     t2, 0xffe00
    and     t1, t1, t2
    sd      t1, 0(t4)
    addi    t4, t4, PAGEFREE_RECORD_BYTES
    beq     t4, s0, .Lbuddy_head_prepare
    beqz    s4, .Lbuddy_tail_loop
    j       .Lfail

.Lbuddy_head_prepare:
    /*
     * The common __free_pages_prepare() head path clears the same preparation
     * mask and resets private before __free_one_page() records the buddy
     * order.  Offset 48 is page_type/_mapcount in the matching 64-byte
     * descriptor; use a stable marker for the PageBuddy state.
     */
    ld      t0, 0(s10)
    lui     t1, 0xffe00
    and     t0, t0, t1
    sd      t0, 0(s10)
    sd      zero, 40(s10)

    /*
     * Representative order-10 free_one_page() fast path.  MAX_PAGE_ORDER is
     * already reached, so Linux does not walk or merge lower-order buddies.
     * It locks the zone, accounts 1024 pages, records order/PageBuddy on the
     * head descriptor, inserts page->buddy_list, and unlocks.
     */
    la      t0, pagefree_buddy_zone
    li      t1, 1
.Lbuddy_lock:
    amoswap.d.aqrl t2, t1, (t0)
    bnez    t2, .Lbuddy_lock

    li      t1, PAGEFREE_BUDDY_RECORDS
    addi    t6, t0, 8
    amoadd.d zero, t1, (t6)
    li      t1, 1
    addi    t6, t0, 16
    amoadd.d zero, t1, (t6)

    li      t1, PAGEFREE_BUDDY_ORDER
    sd      t1, 40(s10)
    li      t1, PAGEFREE_BUDDY_TYPE
    sw      t1, 48(s10)

    la      t3, pagefree_buddy_list
    addi    t5, s10, 8
    ld      t4, 0(t3)
    sd      t4, 0(t5)
    sd      t3, 8(t5)
    sd      t5, 8(t4)
    sd      t5, 0(t3)

    amoswap.d.rl zero, zero, (t0)

    beq     s0, s7, .Lmeasure_done
    mv      s10, s0
    li      s4, 0
    j       .Lbuddy_core_loop
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
.elseif PAGEFREE_KERNEL == 1
    li      s2, PAGEFREE_TAIL_FLAGS
    li      s3, 1
.else
    li      s2, PAGEFREE_TAIL_FLAGS
    li      s3, 0
    li      s4, 0
.endif

.Lverify:
    ld      t0, 0(s0)
    bne     t0, s2, .Lfail
    lw      t0, 52(s0)
    bne     t0, s3, .Lfail
.if PAGEFREE_KERNEL == 2
    bnez    s4, .Lverify_buddy_tail
    ld      t0, 40(s0)
    li      t1, PAGEFREE_BUDDY_ORDER
    bne     t0, t1, .Lfail
    lwu     t0, 48(s0)
    li      t1, PAGEFREE_BUDDY_TYPE
    bne     t0, t1, .Lfail
    j       .Lverify_buddy_record_done

.Lverify_buddy_tail:
    ld      t0, 40(s0)
    bnez    t0, .Lfail
    lw      t0, 48(s0)
    bnez    t0, .Lfail

.Lverify_buddy_record_done:
    addi    s4, s4, 1
    andi    s4, s4, PAGEFREE_BUDDY_RECORDS - 1
.endif
    addi    s0, s0, PAGEFREE_RECORD_BYTES
    addi    s1, s1, -1
    bnez    s1, .Lverify

.if PAGEFREE_KERNEL == 2
    /* Verify accounting and the circular list outside the measured region. */
    la      t0, pagefree_buddy_zone
    ld      t1, 0(t0)
    bnez    t1, .Lfail
    ld      t1, 8(t0)
    li      t2, PAGEFREE_RECORDS
    bne     t1, t2, .Lfail
    ld      t1, 16(t0)
    li      t2, PAGEFREE_RECORDS / PAGEFREE_BUDDY_RECORDS
    bne     t1, t2, .Lfail

    la      t0, pagefree_buddy_list
    ld      t1, 0(t0)
    li      t3, 0
.Lverify_buddy_list:
    beq     t1, t0, .Lverify_buddy_list_done
    addi    t3, t3, 1
    bgtu    t3, t2, .Lfail
    ld      t1, 0(t1)
    j       .Lverify_buddy_list
.Lverify_buddy_list_done:
    bne     t3, t2, .Lfail
.endif

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

.section .data.pagefree_buddy, "aw", @progbits
.balign 64
.globl pagefree_buddy_zone
pagefree_buddy_zone:
    .quad 0                         /* lock */
    .quad 0                         /* managed/free pages */
    .quad 0                         /* inserted order-10 blocks */
    .zero 40

.balign 64
.globl pagefree_buddy_list
pagefree_buddy_list:
    .quad pagefree_buddy_list       /* next */
    .quad pagefree_buddy_list       /* prev */
    .zero 48

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
