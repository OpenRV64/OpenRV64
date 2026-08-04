/* Linux RV64IMA process entry and raw clone trampoline. */

    .option norvc
    .option nopic
    .option norelax

    .equ SYS_exit,       93
    .equ SYS_exit_group, 94
    .equ SYS_clone,      220

    .section .text.start, "ax", @progbits
    .balign 4
    .globl _start
    .type _start, @function
_start:
    ld      a0, 0(sp)
    addi    a1, sp, 8
    call    openrv64_user_tests_main
    li      a7, SYS_exit_group
    ecall
1:
    j       1b
    .size _start, .-_start

/*
 * long openrv64_clone_worker(flags, child_stack_top, worker_id, child_tid)
 *
 * The child starts on a private stack, calls openrv64_user_worker(id), and
 * exits without returning through the parent's C frame.  CHILD_SETTID and
 * CHILD_CLEARTID let the parent observe actual thread exit without waitpid or
 * futex support.
 */
    .section .text, "ax", @progbits
    .balign 4
    .globl openrv64_clone_worker
    .type openrv64_clone_worker, @function
openrv64_clone_worker:
    addi    a1, a1, -16
    sd      a2, 0(a1)
    mv      a4, a3
    li      a2, 0
    li      a3, 0
    li      a7, SYS_clone
    ecall
    beqz    a0, .Lclone_child
    ret

.Lclone_child:
    ld      a0, 0(sp)
    call    openrv64_user_worker
    li      a7, SYS_exit
    ecall
2:
    j       2b
    .size openrv64_clone_worker, .-openrv64_clone_worker

    .section .note.GNU-stack, "", @progbits
