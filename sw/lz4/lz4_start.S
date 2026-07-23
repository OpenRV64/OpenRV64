.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

.equ LZ4_PASS, 0x4c5a345f5f4f4b21 /* "LZ4__OK!" */
.equ LZ4_FAIL, 0x4c5a345f5f424421 /* "LZ4__BD!" */

_start:
    la      sp, __stack_top
    fence   rw, rw
    csrr    s0, mcycle

.globl lz4_measure_begin
lz4_measure_begin:
    call    lz4_decode_bench
    addi    s1, a0, 0

    fence   rw, rw
    csrr    t0, mcycle
    sub     a0, t0, s0
    la      t1, lz4_cycles
    sd      a0, 0(t1)

.globl lz4_measure_end
lz4_measure_end:
    nop

    addi    a0, s1, 0
    call    lz4_verify
    beqz    a0, .Lfail
    li      a0, LZ4_PASS
    ebreak

.Lfail:
    li      a0, LZ4_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.size _start, .-_start
