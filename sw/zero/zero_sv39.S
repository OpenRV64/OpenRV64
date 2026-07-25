/*
 * Zero 256 KiB through a contiguous Sv39 virtual window whose 64 pages map
 * onto every other physical page:
 *
 *   VA 0x40040000 + i * 0x1000
 *       -> PA 0x80200000 + i * 0x2000, 0 <= i < 64
 *
 * The physical source image initializes each mapped page to a nonzero
 * pattern. Verification is outside the timed region.
 */

.equ ZERO_VADDR, 0x40040000
.equ ZERO_BYTES,  0x40000
.equ ZERO_WORDS,  (ZERO_BYTES / 8)
.equ ZERO_PASS,   0x5a45524f4f4b /* "ZEROOK" */
.equ ZERO_FAIL,   0x5a45524f4244 /* "ZEROBD" */

.section .text.boot, "ax", @progbits
.option norvc
.globl zero_vm_boot
.type zero_vm_boot, @function

zero_vm_boot:
    la      t0, machine_trap
    csrw    mtvec, t0

    /* One 16 MiB NAPOT PMP region covers 0x80000000-0x80ffffff. */
    li      t0, 0x201fffff
    csrw    pmpaddr0, t0
    li      t0, 0x1f
    csrw    pmpcfg0, t0

    /* Permit supervisor reads of the cycle shadow CSR. */
    li      t0, 1
    csrw    mcounteren, t0

    la      t0, root_page_table
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma x0, x0

    la      t0, zero_supervisor_start
    csrw    mepc, t0
    li      t0, 0x800
    csrw    mstatus, t0
    mret

machine_trap:
    csrr    t0, mcause
    li      t1, 3
    bne     t0, t1, machine_fail
    li      t1, ZERO_PASS
    bne     a0, t1, machine_fail
    j       zero_vm_done

machine_fail:
    li      a0, ZERO_FAIL

.globl zero_vm_done
zero_vm_done:
    nop
.Lmachine_halt:
    j       .Lmachine_halt

.size zero_vm_boot, .-zero_vm_boot

.section .text.startup, "ax", @progbits
.option norvc
.globl zero_supervisor_start
.type zero_supervisor_start, @function

zero_supervisor_start:
    la      sp, __stack_top
    li      s0, ZERO_VADDR
    li      s1, ZERO_WORDS

    fence   rw, rw
    csrr    s2, cycle

.globl zero_measure_begin
zero_measure_begin:
    sd      zero, 0(s0)
    sd      zero, 8(s0)
    sd      zero, 16(s0)
    sd      zero, 24(s0)
    sd      zero, 32(s0)
    sd      zero, 40(s0)
    sd      zero, 48(s0)
    sd      zero, 56(s0)
    addi    s0, s0, 64
    addi    s1, s1, -8
    bnez    s1, zero_measure_begin

    fence   rw, rw
    csrr    t0, cycle
    sub     a0, t0, s2
    la      t1, zero_cycles
    sd      a0, 0(t1)

.globl zero_measure_end
zero_measure_end:
    nop

    /* Verify every word through the same scattered virtual mapping. */
    li      s0, ZERO_VADDR
    li      s1, ZERO_WORDS
.Lverify:
    ld      t0, 0(s0)
    ld      t1, 8(s0)
    ld      t2, 16(s0)
    ld      t3, 24(s0)
    ld      t4, 32(s0)
    ld      t5, 40(s0)
    ld      t6, 48(s0)
    ld      a1, 56(s0)
    or      t0, t0, t1
    or      t0, t0, t2
    or      t0, t0, t3
    or      t0, t0, t4
    or      t0, t0, t5
    or      t0, t0, t6
    or      t0, t0, a1
    bnez    t0, .Lfail
    addi    s0, s0, 64
    addi    s1, s1, -8
    bnez    s1, .Lverify

    li      a0, ZERO_PASS
    ebreak

.Lfail:
    li      a0, ZERO_FAIL
    ebreak

.Lsupervisor_halt:
    j       .Lsupervisor_halt

.size zero_supervisor_start, .-zero_supervisor_start

.section .data, "aw", @progbits
.balign 8
zero_cycles:
    .dword 0

/*
 * Three-level Sv39 tables. The first 64 leaves map the supervisor image and
 * stack contiguously. The next 64 map the zeroing window with a 4 KiB hole
 * between successive physical pages. A/D are preset for Svade semantics.
 */
.section .page_table.root, "a", @progbits
.balign 4096
.globl root_page_table
root_page_table:
    .zero 8
    /* VPN[2] 1 -> physical 0x80301000. */
    .dword 0x00000000200c0401
    .zero 4096 - 16

.section .page_table.level1, "a", @progbits
.balign 4096
level1_page_table:
    /* VPN[1] 0 -> physical 0x80302000. */
    .dword 0x00000000200c0801
    .zero 4096 - 8

.section .page_table.level0, "a", @progbits
.balign 4096
level0_page_table:
    /* VA 0x40000000-0x4003ffff -> PA 0x80000000-0x8003ffff. */
    .set zero_image_pte, 0x00000000200000cf
    .rept 64
        .dword zero_image_pte
        .set zero_image_pte, zero_image_pte + 0x400
    .endr

    /* VA 0x40040000-0x4007ffff -> even pages at PA 0x80200000. */
    .set zero_scatter_pte, 0x00000000200800cf
    .rept 64
        .dword zero_scatter_pte
        .set zero_scatter_pte, zero_scatter_pte + 0x800
    .endr
    .zero (512 - 128) * 8

/*
 * Seed only the mapped physical pages so the stores and verification have an
 * observable effect. The testbench independently checks the exact VA->PA
 * mapping for every timed store.
 */
.section .zero_seed, "a", @progbits
.balign 4096
zero_seed:
    .rept 64
        .rept 512
            .dword 0xa5a55a5adeadbeef
        .endr
        .zero 4096
    .endr
