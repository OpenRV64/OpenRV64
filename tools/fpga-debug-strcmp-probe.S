/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * USER1-loaded M-mode probe for the property-name strcmp failure.
 *
 * OpenSBI passes the architectural trap snapshot in a0 and the executable
 * workspace in a2.  Results begin at workspace byte 0x800.  Kernel pointers
 * are copied through both MPRV and an independent software Sv39 walk.
 */

    .section .text
    .option norvc
    .globl _start
    .type _start, @function

    .equ RESULT_OFFSET,       0x800
    .equ RESULT_MAGIC,        0x53545250524f4231 /* "STRPROB1" */
    .equ SNAP_MEPC,           (10 * 8)
    .equ SNAP_MSTATUS,        (11 * 8)
    .equ SNAP_SATP,           (12 * 8)
    .equ SNAP_GPR,            (20 * 8)
    .equ SNAP_X1,             (SNAP_GPR + 1 * 8)
    .equ SNAP_X5,             (SNAP_GPR + 5 * 8)
    .equ SNAP_X6,             (SNAP_GPR + 6 * 8)
    .equ SNAP_X8,             (SNAP_GPR + 8 * 8)
    .equ SNAP_X9,             (SNAP_GPR + 9 * 8)
    .equ SNAP_X10,            (SNAP_GPR + 10 * 8)
    .equ SNAP_X11,            (SNAP_GPR + 11 * 8)

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
    ld      t0, SNAP_X1(a0)
    sd      t0, 32(t5)
    ld      t0, SNAP_X5(a0)
    sd      t0, 40(t5)
    ld      t0, SNAP_X6(a0)
    sd      t0, 48(t5)
    ld      t0, SNAP_X8(a0)
    sd      t0, 56(t5)       /* struct property pointer */
    ld      t0, SNAP_X9(a0)
    sd      t0, 64(t5)       /* requested property-name pointer */
    ld      t0, SNAP_X10(a0)
    sd      t0, 72(t5)       /* strcmp return / first string pointer */
    ld      t0, SNAP_X11(a0)
    sd      t0, 80(t5)       /* second string pointer after strcmp */

    /* struct property, including its name pointer at offset zero. */
    ld      a3, 56(t5)
    addi    a4, t5, 0x80
    li      a1, 32
    jal     ra, copy_virtual_bytes

    /* Name bytes from property.name and the requested name in x9. */
    ld      a3, 0x80(t5)
    addi    a4, t5, 0xa0
    li      a1, 64
    jal     ra, copy_virtual_bytes

    ld      a3, 64(t5)
    addi    a4, t5, 0xe0
    li      a1, 64
    jal     ra, copy_virtual_bytes

    /* Repeat all reads through an independent software Sv39 walk. */
    ld      a3, 56(t5)
    addi    a4, t5, 0x120
    li      a1, 32
    jal     ra, copy_virtual_bytes_walk

    ld      a3, 0x120(t5)
    addi    a4, t5, 0x140
    li      a1, 64
    jal     ra, copy_virtual_bytes_walk

    ld      a3, 64(t5)
    addi    a4, t5, 0x180
    li      a1, 64
    jal     ra, copy_virtual_bytes_walk

    fence   rw, rw
    mv      ra, t6
    li      a0, 1
    ret
    .size _start, .-_start

    .type copy_virtual_bytes, @function
copy_virtual_bytes:
    beqz    a3, 2f
    csrr    t0, mstatus
    li      t1, 0x1800       /* MSTATUS.MPP mask */
    not     t1, t1
    and     t1, t0, t1
    li      t2, 0x20800      /* MPRV=1, MPP=S */
    or      t1, t1, t2
1:
    csrw    mstatus, t1
    lbu     t3, 0(a3)
    csrw    mstatus, t0
    sb      t3, 0(a4)
    addi    a3, a3, 1
    addi    a4, a4, 1
    addi    a1, a1, -1
    bnez    a1, 1b
    csrw    mstatus, t0
2:
    ret
    .size copy_virtual_bytes, .-copy_virtual_bytes

    .type copy_virtual_bytes_walk, @function
copy_virtual_bytes_walk:
    beqz    a3, 9f
6:
    /* satp.PPN << 12, discarding mode and ASID. */
    csrr    t0, satp
    slli    t0, t0, 20
    srli    t0, t0, 8

    srli    t1, a3, 30
    andi    t1, t1, 0x1ff
    slli    t1, t1, 3
    add     t0, t0, t1
    ld      t2, 0(t0)
    andi    t3, t2, 1
    beqz    t3, 8f
    andi    t3, t2, 0x0e
    bnez    t3, 7f
    srli    t0, t2, 10
    slli    t0, t0, 12

    srli    t1, a3, 21
    andi    t1, t1, 0x1ff
    slli    t1, t1, 3
    add     t0, t0, t1
    ld      t2, 0(t0)
    andi    t3, t2, 1
    beqz    t3, 8f
    andi    t3, t2, 0x0e
    bnez    t3, 10f
    srli    t0, t2, 10
    slli    t0, t0, 12

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
    j       11f

7:  /* Level-2 leaf. */
    srli    t0, t2, 10
    slli    t0, t0, 12
    li      t3, -1
    slli    t3, t3, 30
    and     t0, t0, t3
    li      t4, -1
    srli    t4, t4, 34
    and     t4, a3, t4
    or      t0, t0, t4
    j       11f

10: /* Level-1 leaf. */
    srli    t0, t2, 10
    slli    t0, t0, 12
    li      t3, -1
    slli    t3, t3, 21
    and     t0, t0, t3
    li      t4, -1
    srli    t4, t4, 43
    and     t4, a3, t4
    or      t0, t0, t4
11:
    lbu     t3, 0(t0)
    j       12f
8:
    li      t3, 0xee
12:
    sb      t3, 0(a4)
    addi    a3, a3, 1
    addi    a4, a4, 1
    addi    a1, a1, -1
    bnez    a1, 6b
9:
    ret
    .size copy_virtual_bytes_walk, .-copy_virtual_bytes_walk
