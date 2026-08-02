/*
 * Full-core F/D exception routing test.
 *
 * The FP load and store must reuse the ordinary LSU exception record.  A
 * legal decode that the current FPU cannot execute must become the ordinary
 * illegal-instruction exception at retirement, with mtval equal to the
 * original instruction word.
 */

.equ MSTATUS_FS_INITIAL, 0x2000
.equ BAD_ADDRESS,       0x90000000
.equ CAUSE_ILLEGAL,     2
.equ CAUSE_LOAD_ACCESS, 5
.equ CAUSE_STORE_ACCESS, 7
.equ FPFAULT_PASS,      0x4650464c545f4f4b /* "FPFLT_OK" */
.equ FPFAULT_FAIL,      0x4650464c545f4244 /* "FPFLT_BD" */

.section .text.startup, "ax", @progbits
.align 3
.globl _start
.type _start, @function
_start:
    la      t0, trap_entry
    csrw    mtvec, t0
    li      t0, MSTATUS_FS_INITIAL
    csrs    mstatus, t0

    li      s0, 0                   /* expected trap phase */
    li      s1, BAD_ADDRESS
    la      t0, fp_zero
    fld     ft0, 0(t0)

.globl faulting_fld
faulting_fld:
    fld     ft1, 0(s1)
    li      t0, 1
    bne     s0, t0, fail

.globl faulting_fsd
faulting_fsd:
    fsd     ft0, 0(s1)
    li      t0, 2
    bne     s0, t0, fail

    /* DYN decodes legally; reserved frm=5 is rejected by FPU execution. */
    li      t0, 5
    csrw    frm, t0
.globl unsupported_fp
unsupported_fp:
    fadd.d  ft1, ft0, ft0, dyn
    li      t0, 3
    bne     s0, t0, fail

    li      a0, FPFAULT_PASS
    ebreak
    j       .
.size _start, .-_start

.section .text.trap, "ax", @progbits
.align 2
.globl trap_entry
.type trap_entry, @function
trap_entry:
    csrr    t0, mcause
    csrr    t1, mtval
    csrr    t2, mepc

    beqz    s0, .Lcheck_load
    li      t3, 1
    beq     s0, t3, .Lcheck_store
    li      t3, 2
    beq     s0, t3, .Lcheck_unsupported
    j       fail

.Lcheck_load:
    li      t3, CAUSE_LOAD_ACCESS
    bne     t0, t3, fail
    li      t3, BAD_ADDRESS
    bne     t1, t3, fail
    la      t3, faulting_fld
    bne     t2, t3, fail
    li      s0, 1
    j       .Lresume

.Lcheck_store:
    li      t3, CAUSE_STORE_ACCESS
    bne     t0, t3, fail
    li      t3, BAD_ADDRESS
    bne     t1, t3, fail
    la      t3, faulting_fsd
    bne     t2, t3, fail
    li      s0, 2
    j       .Lresume

.Lcheck_unsupported:
    li      t3, CAUSE_ILLEGAL
    bne     t0, t3, fail
    la      t3, unsupported_fp
    bne     t2, t3, fail
    lwu     t3, 0(t2)
    bne     t1, t3, fail
    li      s0, 3

.Lresume:
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
.size trap_entry, .-trap_entry

.section .text, "ax", @progbits
.align 2
.globl fail
fail:
    li      a0, FPFAULT_FAIL
    ebreak
    j       .

.section .rodata, "a", @progbits
.align 3
fp_zero:
    .dword  0
