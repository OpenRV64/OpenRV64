/*
 * Minimal Linux SMP userspace probe for OpenRV64.
 *
 * This deliberately avoids libc and futexes.  Two CLONE_THREAD workers are
 * pinned to distinct CPUs from the process affinity mask, synchronize through
 * RV64A atomics, and verify the CPU reported by getcpu() before and after a
 * short overlap window.
 */

    .option norvc
    .option nopic
    .option norelax

    .equ SYS_write,                 64
    .equ SYS_exit,                  93
    .equ SYS_exit_group,            94
    .equ SYS_sched_setaffinity,    122
    .equ SYS_sched_getaffinity,    123
    .equ SYS_sched_yield,          124
    .equ SYS_getcpu,               168
    .equ SYS_clone,                220

    .equ CLONE_VM,               0x00000100
    .equ CLONE_FS,               0x00000200
    .equ CLONE_FILES,            0x00000400
    .equ CLONE_SIGHAND,          0x00000800
    .equ CLONE_THREAD,           0x00010000
    .equ CLONE_SYSVSEM,          0x00040000
    .equ WORKER_CLONE_FLAGS,     (CLONE_VM | CLONE_FS | CLONE_FILES | \
                                  CLONE_SIGHAND | CLONE_THREAD | \
                                  CLONE_SYSVSEM)
    .equ WORK_ITERATIONS,        16384
    .equ WORKER_LINE_BYTES,      39
    .equ RESULT_LINE_BYTES,      17

    .section .text
    .balign 4
    .globl _start
    .type _start, @function
_start:
    /* Find the first two CPUs Linux permits this process to run on. */
    la      a2, allowed_mask
    sd      zero, 0(a2)
    li      a0, 0
    li      a1, 8
    li      a7, SYS_sched_getaffinity
    ecall
    blt     a0, zero, parent_fail

    ld      t0, allowed_mask
    li      t1, 0
    li      t2, -1
    li      t3, -1
.Lscan_cpu_mask:
    andi    t4, t0, 1
    beq     t4, zero, .Lscan_next
    bge     t2, zero, .Lscan_second
    addi    t2, t1, 0
    jal     zero, .Lscan_next
.Lscan_second:
    addi    t3, t1, 0
    jal     zero, .Lscan_done
.Lscan_next:
    srli    t0, t0, 1
    addi    t1, t1, 1
    li      t4, 64
    blt     t1, t4, .Lscan_cpu_mask
.Lscan_done:
    blt     t3, zero, parent_fail

    la      t0, target_cpus
    sw      t2, 0(t0)
    sw      t3, 4(t0)

    li      t0, 1
    sll     t0, t0, t2
    la      t1, worker_masks
    sd      t0, 0(t1)
    li      t0, 1
    sll     t0, t0, t3
    sd      t0, 8(t1)

    /* clone() returns here in both parent and child. */
    li      a0, WORKER_CLONE_FLAGS
    la      a1, worker0_stack_top
    addi    a1, a1, -16
    sd      zero, 0(a1)
    li      a2, 0
    li      a3, 0
    li      a4, 0
    li      a7, SYS_clone
    ecall
    beq     a0, zero, worker_entry
    blt     a0, zero, parent_fail

    li      a0, WORKER_CLONE_FLAGS
    la      a1, worker1_stack_top
    addi    a1, a1, -16
    li      t0, 1
    sd      t0, 0(a1)
    li      a2, 0
    li      a3, 0
    li      a4, 0
    li      a7, SYS_clone
    ecall
    beq     a0, zero, worker_entry
    blt     a0, zero, parent_fail

    /* No futex support is required: yield while the two workers finish. */
.Lparent_wait:
    la      t0, done_count
    lw      t1, 0(t0)
    li      t2, 2
    beq     t1, t2, .Lparent_done
    li      a7, SYS_sched_yield
    ecall
    jal     zero, .Lparent_wait

.Lparent_done:
    /* Acquire worker writes sequenced before their release AMOs. */
    fence   r, rw

    la      t0, failure
    lw      t1, 0(t0)
    bne     t1, zero, parent_fail
    la      t0, ready_count
    lw      t1, 0(t0)
    li      t2, 2
    bne     t1, t2, parent_fail

    la      t0, target_cpus
    lw      t1, 0(t0)
    lw      t2, 4(t0)
    beq     t1, t2, parent_fail
    la      t3, observed_before
    lw      t4, 0(t3)
    bne     t4, t1, parent_fail
    lw      t4, 4(t3)
    bne     t4, t2, parent_fail
    la      t3, observed_after
    lw      t4, 0(t3)
    bne     t4, t1, parent_fail
    lw      t4, 4(t3)
    bne     t4, t2, parent_fail
    la      t3, worker_checksums
    ld      t4, 0(t3)
    beq     t4, zero, parent_fail
    ld      t4, 8(t3)
    beq     t4, zero, parent_fail

    /* Render the observed logical CPU numbers into stable output records. */
    la      t0, observed_before
    lwu     a1, 0(t0)
    la      a0, worker0_before_digits
    jal     ra, store_hex_byte
    la      t0, observed_before
    lwu     a1, 4(t0)
    la      a0, worker1_before_digits
    jal     ra, store_hex_byte
    la      t0, observed_after
    lwu     a1, 0(t0)
    la      a0, worker0_after_digits
    jal     ra, store_hex_byte
    la      t0, observed_after
    lwu     a1, 4(t0)
    la      a0, worker1_after_digits
    jal     ra, store_hex_byte

    la      a1, worker0_line
    li      a2, WORKER_LINE_BYTES
    jal     ra, write_stdout
    blt     a0, zero, parent_fail
    la      a1, worker1_line
    li      a2, WORKER_LINE_BYTES
    jal     ra, write_stdout
    blt     a0, zero, parent_fail
    la      a1, pass_line
    li      a2, RESULT_LINE_BYTES
    jal     ra, write_stdout
    blt     a0, zero, parent_fail

    li      a0, 0
    li      a7, SYS_exit_group
    ecall
    jal     zero, .

    .size _start, . - _start

    .type worker_entry, @function
worker_entry:
    lw      s0, 0(sp)
    li      s1, 0

    /* Pin each thread to its assigned CPU. */
    la      t0, worker_masks
    slli    t1, s0, 3
    add     a2, t0, t1
    li      a0, 0
    li      a1, 8
    li      a7, SYS_sched_setaffinity
    ecall
    bge     a0, zero, .Lworker_getcpu_before
    li      s1, 1

.Lworker_getcpu_before:
    la      t0, observed_before
    slli    t1, s0, 2
    add     a0, t0, t1
    li      a1, 0
    li      a2, 0
    li      a7, SYS_getcpu
    ecall
    bge     a0, zero, .Lworker_check_before
    li      s1, 1

.Lworker_check_before:
    la      t0, observed_before
    slli    t1, s0, 2
    add     t0, t0, t1
    lw      t2, 0(t0)
    la      t0, target_cpus
    add     t0, t0, t1
    lw      t3, 0(t0)
    beq     t2, t3, .Lworker_ready
    li      s1, 1

.Lworker_ready:
    la      t0, ready_count
    li      t1, 1
    amoadd.w.aqrl zero, t1, (t0)

    /* Both pinned workers must reach this barrier before either can finish. */
.Lworker_barrier:
    lw      t1, 0(t0)
    li      t2, 2
    bne     t1, t2, .Lworker_barrier
    fence   r, rw

    li      t0, WORK_ITERATIONS
    li      t1, 0x9e3779b97f4a7c15
    addi    t2, s0, 1
.Lworker_work:
    xor     t1, t1, t2
    slli    t3, t1, 7
    xor     t1, t1, t3
    srli    t3, t1, 9
    xor     t1, t1, t3
    add     t1, t1, t2
    addi    t0, t0, -1
    bne     t0, zero, .Lworker_work
    la      t0, worker_checksums
    slli    t3, s0, 3
    add     t0, t0, t3
    sd      t1, 0(t0)

    la      t0, observed_after
    slli    t1, s0, 2
    add     a0, t0, t1
    li      a1, 0
    li      a2, 0
    li      a7, SYS_getcpu
    ecall
    bge     a0, zero, .Lworker_check_after
    li      s1, 1

.Lworker_check_after:
    la      t0, observed_after
    slli    t1, s0, 2
    add     t0, t0, t1
    lw      t2, 0(t0)
    la      t0, target_cpus
    add     t0, t0, t1
    lw      t3, 0(t0)
    beq     t2, t3, .Lworker_publish
    li      s1, 1

.Lworker_publish:
    beq     s1, zero, .Lworker_done
    la      t0, failure
    li      t1, 1
    amoswap.w.aqrl zero, t1, (t0)
.Lworker_done:
    la      t0, done_count
    li      t1, 1
    amoadd.w.aqrl zero, t1, (t0)
    li      a0, 0
    li      a7, SYS_exit
    ecall
    jal     zero, .

    .size worker_entry, . - worker_entry

    .type store_hex_byte, @function
store_hex_byte:
    la      t0, hex_digits
    srli    t1, a1, 4
    andi    t1, t1, 15
    add     t1, t0, t1
    lbu     t1, 0(t1)
    sb      t1, 0(a0)
    andi    t1, a1, 15
    add     t1, t0, t1
    lbu     t1, 0(t1)
    sb      t1, 1(a0)
    jalr    zero, 0(ra)
    .size store_hex_byte, . - store_hex_byte

    .type write_stdout, @function
write_stdout:
    li      a0, 1
    li      a7, SYS_write
    ecall
    jalr    zero, 0(ra)
    .size write_stdout, . - write_stdout

    .type parent_fail, @function
parent_fail:
    li      a0, 1
    la      a1, fail_line
    li      a2, RESULT_LINE_BYTES
    li      a7, SYS_write
    ecall
    li      a0, 1
    li      a7, SYS_exit_group
    ecall
    jal     zero, .
    .size parent_fail, . - parent_fail

    .section .rodata
hex_digits:
    .ascii  "0123456789abcdef"
pass_line:
    .ascii  "SMP_THREADS_PASS\n"
pass_line_end:
fail_line:
    .ascii  "SMP_THREADS_FAIL\n"
fail_line_end:

    .section .data
    .balign 8
target_cpus:
    .word   -1, -1
worker_masks:
    .dword  0, 0
observed_before:
    .word   -1, -1
observed_after:
    .word   -1, -1

worker0_line:
    .ascii  "worker0 cpu_before=0x"
worker0_before_digits:
    .ascii  "00"
    .ascii  " cpu_after=0x"
worker0_after_digits:
    .ascii  "00\n"
worker0_line_end:

worker1_line:
    .ascii  "worker1 cpu_before=0x"
worker1_before_digits:
    .ascii  "00"
    .ascii  " cpu_after=0x"
worker1_after_digits:
    .ascii  "00\n"
worker1_line_end:

    .section .bss
    .balign 8
allowed_mask:
    .skip   8
ready_count:
    .skip   4
done_count:
    .skip   4
failure:
    .skip   4
    .balign 8
worker_checksums:
    .skip   16

    .balign 16
worker0_stack:
    .skip   4096
worker0_stack_top:
    .balign 16
worker1_stack:
    .skip   4096
worker1_stack_top:

    .section .note.GNU-stack,"",@progbits
