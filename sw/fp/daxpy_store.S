/*
 * Store-only-memory RV64D DAXPY scheduling benchmark.
 *
 * Every measured phase executes 256 copies of y = 2.0 * 1.0 + y and stores
 * every result.  Operands are initialized through FMV.D.X before measurement,
 * so measured regions contain 256 FMADDs and 256 FSDs but no loads.  The
 * 1/4/16/32 variants match the dependency shapes of daxpy_compute.S.
 */

.equ MSTATUS_FS_INITIAL, 0x2000
.equ DAXPY_STORE_OPS,    256
.equ DAXPY_STORE_PASS,   0x4458535f4f4b2121 /* "DXS_OK!!" */
.equ DAXPY_STORE_FAIL,   0x4458535f42414421 /* "DXS_BAD!" */
.equ DAXPY_STORE_FLAGS,  0x4458535f464c4721 /* "DXS_FLG!" */

.macro INIT_ACCUMULATORS
    fmv.d.x f2,  zero
    fmv.d.x f3,  zero
    fmv.d.x f4,  zero
    fmv.d.x f5,  zero
    fmv.d.x f6,  zero
    fmv.d.x f7,  zero
    fmv.d.x f8,  zero
    fmv.d.x f9,  zero
    fmv.d.x f10, zero
    fmv.d.x f11, zero
    fmv.d.x f12, zero
    fmv.d.x f13, zero
    fmv.d.x f14, zero
    fmv.d.x f15, zero
    fmv.d.x f16, zero
    fmv.d.x f17, zero
.endm

.macro DAXPY_STORE_COMPUTE4
    fmadd.d f2, f0, f1, f2, rne
    fmadd.d f3, f0, f1, f3, rne
    fmadd.d f4, f0, f1, f4, rne
    fmadd.d f5, f0, f1, f5, rne
.endm

.macro DAXPY_STORE_COMPUTE16
    DAXPY_STORE_COMPUTE4
    fmadd.d f6,  f0, f1, f6,  rne
    fmadd.d f7,  f0, f1, f7,  rne
    fmadd.d f8,  f0, f1, f8,  rne
    fmadd.d f9,  f0, f1, f9,  rne
    fmadd.d f10, f0, f1, f10, rne
    fmadd.d f11, f0, f1, f11, rne
    fmadd.d f12, f0, f1, f12, rne
    fmadd.d f13, f0, f1, f13, rne
    fmadd.d f14, f0, f1, f14, rne
    fmadd.d f15, f0, f1, f15, rne
    fmadd.d f16, f0, f1, f16, rne
    fmadd.d f17, f0, f1, f17, rne
.endm

.macro DAXPY_STORE_WRITE4 base
    fsd     f2, \base+0(a0)
    fsd     f3, \base+8(a0)
    fsd     f4, \base+16(a0)
    fsd     f5, \base+24(a0)
.endm

.macro DAXPY_STORE_WRITE16 base
    DAXPY_STORE_WRITE4 \base
    fsd     f6,  \base+32(a0)
    fsd     f7,  \base+40(a0)
    fsd     f8,  \base+48(a0)
    fsd     f9,  \base+56(a0)
    fsd     f10, \base+64(a0)
    fsd     f11, \base+72(a0)
    fsd     f12, \base+80(a0)
    fsd     f13, \base+88(a0)
    fsd     f14, \base+96(a0)
    fsd     f15, \base+104(a0)
    fsd     f16, \base+112(a0)
    fsd     f17, \base+120(a0)
.endm

.macro FINISH_PHASE perf_offset, last_offset, expected
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t3, daxpy_store_perf
    sd      s2, \perf_offset(t3)
    sd      s3, \perf_offset+8(t3)
    la      t3, daxpy_store_output
    ld      t1, \last_offset(t3)
    li      t2, \expected
    bne     t1, t2, daxpy_store_fail
.endm

.section .text.startup, "ax", @progbits
.align 3
.globl _start
.type _start, @function
_start:
    li      t0, MSTATUS_FS_INITIAL
    csrs    mstatus, t0
    csrw    fflags, zero
    li      t0, 0x4000000000000000 /* alpha = 2.0 */
    fmv.d.x f0, t0
    li      t0, 0x3ff0000000000000 /* x = 1.0 */
    fmv.d.x f1, t0

    /* One 256-operation accumulator chain and 256 sequential stores. */
    INIT_ACCUMULATORS
    li      s5, 1
    la      a0, daxpy_store_output
    li      t0, 256
    li      s4, 1
    rdcycle s0
    rdinstret s1
.Ldaxpy_store_u1:
    fmadd.d f2, f0, f1, f2, rne
    fsd     f2, 0(a0)
    addi    a0, a0, 8
    addi    t0, t0, -1
    bnez    t0, .Ldaxpy_store_u1
    FINISH_PHASE 0, 2040, 0x4080000000000000 /* 512.0 */

    /* Four independent 64-operation chains. */
    INIT_ACCUMULATORS
    li      s5, 4
    la      a0, daxpy_store_output
    li      t0, 64
    li      s4, 2
    rdcycle s0
    rdinstret s1
.Ldaxpy_store_u4:
    DAXPY_STORE_COMPUTE4
    DAXPY_STORE_WRITE4 0
    addi    a0, a0, 32
    addi    t0, t0, -1
    bnez    t0, .Ldaxpy_store_u4
    FINISH_PHASE 16, 2040, 0x4060000000000000 /* 128.0 */

    /* Sixteen independent 16-operation chains. */
    INIT_ACCUMULATORS
    li      s5, 16
    la      a0, daxpy_store_output
    li      t0, 16
    li      s4, 3
    rdcycle s0
    rdinstret s1
.Ldaxpy_store_u16:
    DAXPY_STORE_COMPUTE16
    DAXPY_STORE_WRITE16 0
    addi    a0, a0, 128
    addi    t0, t0, -1
    bnez    t0, .Ldaxpy_store_u16
    FINISH_PHASE 32, 2040, 0x4040000000000000 /* 32.0 */

    /* Two sixteen-wide waves per body, retaining all 256 result stores. */
    INIT_ACCUMULATORS
    li      s5, 32
    la      a0, daxpy_store_output
    li      t0, 8
    li      s4, 4
    rdcycle s0
    rdinstret s1
.Ldaxpy_store_u32:
    DAXPY_STORE_COMPUTE16
    DAXPY_STORE_WRITE16 0
    DAXPY_STORE_COMPUTE16
    DAXPY_STORE_WRITE16 128
    addi    a0, a0, 256
    addi    t0, t0, -1
    bnez    t0, .Ldaxpy_store_u32
    FINISH_PHASE 48, 2040, 0x4040000000000000 /* 32.0 */

    frflags t0
    bnez    t0, daxpy_store_fail_flags
    la      a1, daxpy_store_perf
    li      a2, 4
    li      a3, DAXPY_STORE_OPS
    li      a0, DAXPY_STORE_PASS
.globl daxpy_store_done
daxpy_store_done:
    ebreak
    j       .

.globl daxpy_store_fail
daxpy_store_fail:
    mv      a1, s5
    mv      a2, t1
    mv      a3, t2
    li      a0, DAXPY_STORE_FAIL
    ebreak
    j       .

.globl daxpy_store_fail_flags
daxpy_store_fail_flags:
    mv      a1, t0
    li      a0, DAXPY_STORE_FLAGS
    ebreak
    j       .
.size _start, .-_start

.section .data, "aw", @progbits
.align 3
.globl daxpy_store_perf
daxpy_store_perf:
    .zero 64
.globl daxpy_store_output
daxpy_store_output:
    .zero 2048
