/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * USER1-loaded M-mode probe for the Linux CPU-node walk. The trigger is set
 * just after of_get_property("reg") returns in of_get_cpu_hwid(). OpenSBI
 * passes its architectural trap snapshot in a0 and the executable workspace
 * in a2. Results begin at workspace byte 0x800.
 *
 * Kernel pointers are S-mode virtual addresses. The probe captures them twice:
 * first through MPRV, then through a software Sv39 walk and physical load. The
 * comparison diagnoses the core's MPRV/translation path independently of the
 * kernel pointer and its page tables.
 */

    .section .text
    .option norvc
    .globl _start
    .type _start, @function

    .equ RESULT_OFFSET,       0x800
    .equ RESULT_MAGIC,        0x44544250524f4231 /* "DTBPROB1" */
    .equ SNAP_MEPC,           (10 * 8)
    .equ SNAP_MSTATUS,        (11 * 8)
    .equ SNAP_SATP,           (12 * 8)
    .equ SNAP_GPR,            (20 * 8)
    .equ SNAP_X1,             (SNAP_GPR + 1 * 8)
    .equ SNAP_X2,             (SNAP_GPR + 2 * 8)
    .equ SNAP_X8,             (SNAP_GPR + 8 * 8)
    .equ SNAP_X9,             (SNAP_GPR + 9 * 8)
    .equ SNAP_X10,            (SNAP_GPR + 10 * 8)
    .equ SNAP_X11,            (SNAP_GPR + 11 * 8)
    .equ SNAP_X18,            (SNAP_GPR + 18 * 8)

    .equ PROPERTY_RECORDS,    12
    .equ PROPERTY_RECORD_BASE, 0x240
    .equ PROPERTY_RECORD_SIZE, 104
    .equ WALK_PROPERTY_BASE,  0x720
    .equ WALK_STACK_BASE,     0x760
    .equ WALK_NODE_BASE,      0x7e0

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
    ld      t0, SNAP_X10(a0)
    sd      t0, 24(t5)       /* of_get_property return/value pointer */
    ld      t0, SNAP_X2(a0)
    sd      t0, 32(t5)       /* trapped stack pointer */
    ld      t0, SNAP_X8(a0)
    sd      t0, 40(t5)       /* address-cell count */
    ld      t0, SNAP_X9(a0)
    sd      t0, 48(t5)       /* requested CPU address index */
    ld      t0, SNAP_X18(a0)
    sd      t0, 56(t5)       /* struct device_node pointer */
    ld      t0, SNAP_X11(a0)
    sd      t0, 64(t5)
    ld      t0, SNAP_X1(a0)
    sd      t0, 72(t5)
    ld      t0, SNAP_MSTATUS(a0)
    sd      t0, 80(t5)
    sd      zero, 88(t5)      /* captured property-record count */

    /* Returned property value: expected to be the big-endian CPU reg cell. */
    ld      a3, 24(t5)
    addi    a4, t5, 0x80
    li      a1, 64
    jal     ra, copy_virtual_bytes

    /* Current of_get_cpu_hwid stack frame, including the property length. */
    ld      a3, 32(t5)
    addi    a4, t5, 0xc0
    li      a1, 128
    jal     ra, copy_virtual_bytes

    /* The flattened/unflattened device_node object and its property links. */
    ld      a3, 56(t5)
    addi    a4, t5, 0x140
    li      a1, 256
    jal     ra, copy_virtual_bytes

    /* Repeat the three reads with an explicit software Sv39 page-table walk. */
    ld      a3, 24(t5)
    li      a4, WALK_PROPERTY_BASE
    add     a4, t5, a4
    li      a1, 64
    jal     ra, copy_virtual_bytes_walk

    ld      a3, 32(t5)
    li      a4, WALK_STACK_BASE
    add     a4, t5, a4
    li      a1, 128
    jal     ra, copy_virtual_bytes_walk

    ld      a3, 56(t5)
    li      a4, WALK_NODE_BASE
    add     a4, t5, a4
    li      a1, 256
    jal     ra, copy_virtual_bytes_walk

    /*
     * Linux's linked objects for this exact kernel use:
     *
     *   device_node.properties = +0x58
     *   property.name          = +0x00
     *   property.length        = +0x08 (32 bits)
     *   property.value         = +0x10
     *   property.next          = +0x18
     *
     * The first 32 bytes of each record are the property object, preceded by
     * its virtual address. They are followed by 32 bytes from name and value.
     * Capture a bounded list so corrupt linkage cannot run the stub forever.
     */
    li      t0, (WALK_NODE_BASE + 0x58)
    add     t0, t5, t0
    ld      a5, 0(t0)         /* walked device_node + properties offset */
    li      a6, PROPERTY_RECORD_BASE
    add     a6, t5, a6
    li      a7, PROPERTY_RECORDS
3:
    beqz    a5, 5f
    sd      a5, 0(a6)
    mv      a3, a5
    addi    a4, a6, 8
    li      a1, 32
    jal     ra, copy_virtual_bytes_walk

    ld      a3, 8(a6)        /* property.name */
    addi    a4, a6, 40
    li      a1, 32
    jal     ra, copy_virtual_bytes_walk

    ld      a3, 24(a6)       /* property.value */
    addi    a4, a6, 72
    li      a1, 32
    jal     ra, copy_virtual_bytes_walk

    ld      a5, 32(a6)       /* property.next */
    ld      t0, 88(t5)
    addi    t0, t0, 1
    sd      t0, 88(t5)
    addi    a6, a6, PROPERTY_RECORD_SIZE
    addi    a7, a7, -1
    bnez    a7, 3b
5:

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
    /* satp.PPN << 12, with the top four mode/ASID bits discarded. */
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
    bnez    t3, 7f
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
    bnez    t3, 10f
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
    j       11f

7:  /* Level-2 leaf: preserve the low 30 virtual-address bits. */
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

10: /* Level-1 leaf: preserve the low 21 virtual-address bits. */
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
