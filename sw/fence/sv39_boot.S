/*
 * Common Sv39 bootstrap for the fence correctness, microbenchmark, and
 * existing atomic workloads.
 *
 * Supervisor virtual mappings:
 *
 *   0x40000000-0x4003ffff -> 0x80000000-0x8003ffff (RWX)
 *   0x40040000-0x40040fff -> 0x10000000-0x10000fff (RW device)
 *
 * The supervisor memory mapping is deliberately non-identity.  A workload
 * cannot accidentally pass by using untranslated virtual addresses.
 */

.section .text.boot, "ax", @progbits
.option norvc
.globl fence_vm_boot
.type fence_vm_boot, @function

fence_vm_boot:
    la      t0, fence_machine_trap
    csrw    mtvec, t0

    /* 16 MiB NAPOT RAM region at 0x80000000. */
    li      t0, 0x201fffff
    csrw    pmpaddr0, t0

    /* 4 KiB NAPOT device region at 0x10000000. */
    li      t0, 0x040001ff
    csrw    pmpaddr1, t0

    /* RWX NAPOT entries for RAM and the directed-test device page. */
    li      t0, 0x1f1f
    csrw    pmpcfg0, t0

    /* Permit supervisor reads of cycle. */
    li      t0, 1
    csrw    mcounteren, t0

    la      t0, fence_root_page_table
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0

    /*
     * This is the one unavoidable translation fence in the non-VMA suite:
     * it activates the initial page tables.  Workload code executes no
     * SFENCE.VMA or SATP write.
     */
    sfence.vma x0, x0

    la      t0, _start
    csrw    mepc, t0
    li      t0, 0x800
    csrw    mstatus, t0
    mret

fence_machine_trap:
    csrr    t0, mcause
    li      t1, 3
    beq     t0, t1, fence_vm_done
    li      a0, 0x564d545241504641 /* "VMTRAPFA" */

.globl fence_vm_done
fence_vm_done:
    nop
.Lfence_machine_halt:
    j       .Lfence_machine_halt

.size fence_vm_boot, .-fence_vm_boot

/*
 * Three-level Sv39 page tables.  A/D are preset because the current walker
 * implements Svade semantics rather than atomically updating clear A/D bits.
 */
.section .page_table.root, "a", @progbits
.balign 4096
.globl fence_root_page_table
fence_root_page_table:
    .zero 8
    /* VPN[2] 1 -> physical 0x80041000. */
    .dword 0x0000000020010401
    .zero 4096 - 16

.section .page_table.level1, "a", @progbits
.balign 4096
fence_level1_page_table:
    /* VPN[1] 0 -> physical 0x80042000 (normal memory and device). */
    .dword 0x0000000020010801
    .zero (512 - 1) * 8

.section .page_table.level0, "a", @progbits
.balign 4096
fence_level0_page_table:
    .set fence_vm_leaf_pte, 0x00000000200000cf
    .rept 64
        .dword fence_vm_leaf_pte
        .set fence_vm_leaf_pte, fence_vm_leaf_pte + 0x400
    .endr
    /* 0x40040000 -> 0x10000000, supervisor RW, A/D preset, non-exec. */
    .dword 0x00000000040000c7
    .zero (512 - 65) * 8
