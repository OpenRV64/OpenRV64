/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * USER1-loaded M-mode probe for the paging_init memblock-range failure.
 *
 * Results begin at workspace byte 0x800.  Kernel virtual data is captured
 * through both MPRV and an independent Sv39 page-table walk so a corrupt
 * producer can be distinguished from a translation/cache read failure.
 */

    .section .text
    .option norvc
    .globl _start
    .type _start, @function

    .equ RESULT_OFFSET,       0x800
    .equ RESULT_MAGIC,        0x4d454d424c4b5031 /* "MEMBLKP1" */
    .equ MEMBLOCK_VA,         0xffffffff80411648

    .equ SNAP_MEPC,           (10 * 8)
    .equ SNAP_MSTATUS,        (11 * 8)
    .equ SNAP_SATP,           (12 * 8)
    .equ SNAP_GPR,            (20 * 8)
    .equ SNAP_X2,             (SNAP_GPR + 2 * 8)
    .equ SNAP_X12,            (SNAP_GPR + 12 * 8)
    .equ SNAP_X13,            (SNAP_GPR + 13 * 8)
    .equ SNAP_X21,            (SNAP_GPR + 21 * 8)

    .equ STACK_BYTES,         128
    .equ MEMBLOCK_BYTES,      96
    .equ REGION_BYTES,        384 /* 16 struct memblock_region records */

    .equ MPRV_STACK,          0x080
    .equ WALK_STACK,          0x100
    .equ MPRV_MEMBLOCK,       0x180
    .equ WALK_MEMBLOCK,       0x1e0
    .equ MPRV_REGIONS,        0x240
    .equ WALK_REGIONS,        0x3c0
    .equ OPENSBI_LINE,        0x540

_start:
    mv      t6, ra
    li      t5, RESULT_OFFSET
    add     t5, a2, t5

    li      t0, RESULT_MAGIC
    sd      t0, 0(t5)
    ld      t0, SNAP_MEPC(a0)
    sd      t0, 8(t5)
    ld      t0, SNAP_SATP(a0)
    sd      t0, 16(t5)
    ld      t0, SNAP_MSTATUS(a0)
    sd      t0, 24(t5)
    ld      t0, SNAP_X2(a0)
    sd      t0, 32(t5)
    ld      t0, SNAP_X12(a0)
    sd      t0, 40(t5)
    ld      t0, SNAP_X13(a0)
    sd      t0, 48(t5)
    ld      t0, SNAP_X21(a0)
    sd      t0, 56(t5)

    /* Capture the paging_init stack, including slots +24, +32 and +40. */
    ld      a3, 32(t5)
    addi    a4, t5, MPRV_STACK
    li      a1, STACK_BYTES
    jal     ra, copy_virtual_bytes

    ld      a3, 32(t5)
    addi    a4, t5, WALK_STACK
    li      a1, STACK_BYTES
    jal     ra, copy_virtual_bytes_walk

    /* Capture struct memblock and obtain memory.regions from its walked copy. */
    li      a3, MEMBLOCK_VA
    li      a4, MPRV_MEMBLOCK
    add     a4, t5, a4
    li      a1, MEMBLOCK_BYTES
    jal     ra, copy_virtual_bytes

    li      a3, MEMBLOCK_VA
    li      a4, WALK_MEMBLOCK
    add     a4, t5, a4
    li      a1, MEMBLOCK_BYTES
    jal     ra, copy_virtual_bytes_walk

    li      t0, (WALK_MEMBLOCK + 0x28)
    add     t0, t5, t0
    ld      a3, 0(t0)
    sd      a3, 64(t5)
    li      a4, MPRV_REGIONS
    add     a4, t5, a4
    li      a1, REGION_BYTES
    jal     ra, copy_virtual_bytes

    ld      a3, 64(t5)
    li      a4, WALK_REGIONS
    add     a4, t5, a4
    li      a1, REGION_BYTES
    jal     ra, copy_virtual_bytes_walk

    /* Reference bytes around the matching OpenSBI BSS symbol. */
    li      a3, 0x80142900
    li      a4, OPENSBI_LINE
    add     a4, t5, a4
    li      a1, 128
1:
    lbu     t0, 0(a3)
    sb      t0, 0(a4)
    addi    a3, a3, 1
    addi    a4, a4, 1
    addi    a1, a1, -1
    bnez    a1, 1b

    fence   rw, rw
    mv      ra, t6
    li      a0, 1
    ret
    .size _start, .-_start

    .type copy_virtual_bytes, @function
copy_virtual_bytes:
    beqz    a3, 3f
    csrr    t0, mstatus
    li      t1, 0x1800       /* MSTATUS.MPP mask */
    not     t1, t1
    and     t1, t0, t1
    li      t2, 0x20800      /* MPRV=1, MPP=S */
    or      t1, t1, t2
2:
    csrw    mstatus, t1
    lbu     t3, 0(a3)
    csrw    mstatus, t0
    sb      t3, 0(a4)
    addi    a3, a3, 1
    addi    a4, a4, 1
    addi    a1, a1, -1
    bnez    a1, 2b
    csrw    mstatus, t0
3:
    ret
    .size copy_virtual_bytes, .-copy_virtual_bytes

    .type copy_virtual_bytes_walk, @function
copy_virtual_bytes_walk:
    beqz    a3, 9f
4:
    /* satp.PPN << 12, discarding mode and ASID. */
    csrr    t0, satp
    slli    t0, t0, 20
    srli    t0, t0, 8

    /* Level 2. */
    srli    t1, a3, 30
    andi    t1, t1, 0x1ff
    slli    t1, t1, 3
    add     t0, t0, t1
    ld      t2, 0(t0)
    andi    t3, t2, 1
    beqz    t3, 8f
    andi    t3, t2, 0x0e
    bnez    t3, 5f
    srli    t0, t2, 10
    slli    t0, t0, 12

    /* Level 1. */
    srli    t1, a3, 21
    andi    t1, t1, 0x1ff
    slli    t1, t1, 3
    add     t0, t0, t1
    ld      t2, 0(t0)
    andi    t3, t2, 1
    beqz    t3, 8f
    andi    t3, t2, 0x0e
    bnez    t3, 6f
    srli    t0, t2, 10
    slli    t0, t0, 12

    /* Level 0. */
    srli    t1, a3, 12
    andi    t1, t1, 0x1ff
    slli    t1, t1, 3
    add     t0, t0, t1
    ld      t2, 0(t0)
    andi    t3, t2, 1
    beqz    t3, 8f
    andi    t3, t2, 0x0e
    beqz    t3, 8f
    srli    t0, t2, 10
    slli    t0, t0, 12
    li      t3, -1
    slli    t3, t3, 12
    and     t0, t0, t3
    li      t4, -1
    srli    t4, t4, 52
    and     t4, a3, t4
    or      t0, t0, t4
    j       7f

5:  /* Level-2 leaf. */
    srli    t0, t2, 10
    slli    t0, t0, 12
    li      t3, -1
    slli    t3, t3, 30
    and     t0, t0, t3
    li      t4, -1
    srli    t4, t4, 34
    and     t4, a3, t4
    or      t0, t0, t4
    j       7f

6:  /* Level-1 leaf. */
    srli    t0, t2, 10
    slli    t0, t0, 12
    li      t3, -1
    slli    t3, t3, 21
    and     t0, t0, t3
    li      t4, -1
    srli    t4, t4, 43
    and     t4, a3, t4
    or      t0, t0, t4
7:
    lbu     t3, 0(t0)
    j       10f
8:
    li      t3, 0xee
10:
    sb      t3, 0(a4)
    addi    a3, a3, 1
    addi    a4, a4, 1
    addi    a1, a1, -1
    bnez    a1, 4b
9:
    ret
    .size copy_virtual_bytes_walk, .-copy_virtual_bytes_walk
