/*
 * Bare-metal single-chain pointer latency benchmark.
 *
 * The statically generated ring follows the Google Multi-Chase construction.
 * One complete untimed traversal warms page/cache metadata, then the measured
 * loop performs only dependent loads, counter updates, and a direct branch.
 */

.ifndef POINTER_CHASE_NODES
.equ POINTER_CHASE_NODES, 65536
.endif

.ifndef POINTER_CHASE_STEPS
.equ POINTER_CHASE_STEPS, 131072
.endif

.if ((POINTER_CHASE_NODES <= 0) || (POINTER_CHASE_STEPS <= 0))
.error "pointer-chase nodes and steps must be positive"
.endif

.if ((POINTER_CHASE_STEPS % POINTER_CHASE_NODES) != 0)
.error "pointer-chase steps must be a multiple of nodes"
.endif

.equ POINTER_CHASE_PASS, 0x5043484153454f4b /* "PCHASEOK" */
.equ POINTER_CHASE_FAIL, 0x5043484153454244 /* "PCHASEBD" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl main
.type main, @function

main:
    la      s0, pointer_chase_start
    li      s1, POINTER_CHASE_NODES

    /* Remove image first-touch effects from the measured traversal. */
.Lwarm:
    ld      s0, 0(s0)
    addi    s1, s1, -1
    bnez    s1, .Lwarm

    la      t0, pointer_chase_start
    bne     s0, t0, .Lfail
    li      s1, POINTER_CHASE_STEPS
    fence   rw, rw
.ifdef POINTER_CHASE_VM
    csrr    s2, cycle
.else
    csrr    s2, mcycle
.endif

.globl pointer_chase_measure_begin
pointer_chase_measure_begin:
    ld      s0, 0(s0)
    addi    s1, s1, -1
    bnez    s1, pointer_chase_measure_begin

    fence   rw, rw
.ifdef POINTER_CHASE_VM
    csrr    t1, cycle
.else
    csrr    t1, mcycle
.endif
    sub     a0, t1, s2
    la      t2, pointer_chase_cycles
    sd      a0, 0(t2)

.globl pointer_chase_measure_end
pointer_chase_measure_end:
    nop

    la      t0, pointer_chase_start
    bne     s0, t0, .Lfail
    li      a0, POINTER_CHASE_PASS
    ebreak

.Lfail:
    li      a0, POINTER_CHASE_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.size main, .-main

.section .data.pointer_chase_results, "aw", @progbits
.balign 8
.globl pointer_chase_cycles
.type pointer_chase_cycles, @object
pointer_chase_cycles:
    .quad 0
.size pointer_chase_cycles, .-pointer_chase_cycles
