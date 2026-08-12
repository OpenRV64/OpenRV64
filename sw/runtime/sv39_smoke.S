/*
 * Single-image Sv39 performance smoke driver.
 *
 * Each enabled workload is a callable function.  The driver records a
 * completion-fenced cycle interval for each function and checks its result
 * before proceeding.  Assembly workloads in this image have a clobber-all
 * test-function convention except for sp and ra; do not call them from C.
 */

#ifndef SV39_SMOKE_ENABLE_COREMARK
#define SV39_SMOKE_ENABLE_COREMARK 1
#endif
#ifndef SV39_SMOKE_ENABLE_BLAKE2S
#define SV39_SMOKE_ENABLE_BLAKE2S 1
#endif
#ifndef SV39_SMOKE_ENABLE_STREAM
#define SV39_SMOKE_ENABLE_STREAM 1
#endif
#ifndef SV39_SMOKE_ENABLE_ATOMIC
#define SV39_SMOKE_ENABLE_ATOMIC 1
#endif
#ifndef SV39_SMOKE_ENABLE_FENCE
#define SV39_SMOKE_ENABLE_FENCE 1
#endif
#ifndef SV39_SMOKE_ENABLE_STORE_EXTENSION
#define SV39_SMOKE_ENABLE_STORE_EXTENSION 1
#endif

.equ SV39_SMOKE_PASS,          0x535633395f4f4b21 /* "SV39_OK!" */
.equ SV39_SMOKE_FAIL_BASE,     0x5356333942414400 /* "SV39BAD\0" */
.equ SV39_SMOKE_COREMARK_PASS, 0x000000000a277880
.equ SV39_SMOKE_BLAKE2S_PASS,  1
.equ SV39_SMOKE_STREAM_PASS,   0x53545245414d4f4b /* "STREAMOK" */
.equ SV39_SMOKE_ATOMIC_PASS,   0x41544f4d49434f4b /* "ATOMICOK" */
.equ SV39_SMOKE_STORE_FAIL,    0x53544f5245424144 /* "STOREBAD" */

.set SV39_SMOKE_MASK, 0
#if SV39_SMOKE_ENABLE_COREMARK
.set SV39_SMOKE_MASK, SV39_SMOKE_MASK | 0x01
#endif
#if SV39_SMOKE_ENABLE_BLAKE2S
.set SV39_SMOKE_MASK, SV39_SMOKE_MASK | 0x02
#endif
#if SV39_SMOKE_ENABLE_STREAM
.set SV39_SMOKE_MASK, SV39_SMOKE_MASK | 0x04
#endif
#if SV39_SMOKE_ENABLE_ATOMIC
.set SV39_SMOKE_MASK, SV39_SMOKE_MASK | 0x08
#endif
#if SV39_SMOKE_ENABLE_FENCE
.set SV39_SMOKE_MASK, SV39_SMOKE_MASK | 0x10
#endif
#if SV39_SMOKE_ENABLE_STORE_EXTENSION
.set SV39_SMOKE_MASK, SV39_SMOKE_MASK | 0x20
#endif

.macro SV39_SMOKE_BEGIN
    fence   rw, rw
    csrr    t0, cycle
    la      t1, sv39_smoke_start_cycle
    sd      t0, 0(t1)
.endm

.macro SV39_SMOKE_END result_offset
    fence   rw, rw
    csrr    t0, cycle
    la      t1, sv39_smoke_start_cycle
    ld      t2, 0(t1)
    sub     t0, t0, t2
    la      t1, sv39_smoke_results
    sd      t0, \result_offset(t1)
.endm

.macro SV39_SMOKE_FAIL test_id
    li      a0, (SV39_SMOKE_FAIL_BASE + \test_id)
    li      a1, \test_id
    j       .Lsmoke_return
.endm

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl main
.globl test_main
.type main, @function
.type test_main, @function
main:
test_main:
    addi    sp, sp, -16
    sd      ra, 8(sp)

#if SV39_SMOKE_ENABLE_COREMARK
    SV39_SMOKE_BEGIN
    call    coremark_loop
    mv      t3, a0
    SV39_SMOKE_END 0
    li      t0, SV39_SMOKE_COREMARK_PASS
    beq     t3, t0, 1f
    SV39_SMOKE_FAIL 1
1:
#endif

#if SV39_SMOKE_ENABLE_BLAKE2S
    call    blake2s_bench_reset
    SV39_SMOKE_BEGIN
    call    blake2s_bench_run
    la      t0, sv39_smoke_blake2s_checksum
    sd      a0, 0(t0)
    SV39_SMOKE_END 8
    la      t0, sv39_smoke_blake2s_checksum
    ld      a0, 0(t0)
    call    blake2s_bench_verify
    li      t0, SV39_SMOKE_BLAKE2S_PASS
    beq     a0, t0, 2f
    SV39_SMOKE_FAIL 2
2:
#endif

#if SV39_SMOKE_ENABLE_STREAM
    SV39_SMOKE_BEGIN
    call    sv39_smoke_stream
    mv      t3, a0
    SV39_SMOKE_END 16
    li      t0, SV39_SMOKE_STREAM_PASS
    beq     t3, t0, 3f
    SV39_SMOKE_FAIL 3
3:
#endif

#if SV39_SMOKE_ENABLE_ATOMIC
    SV39_SMOKE_BEGIN
    call    sv39_smoke_atomic
    mv      t3, a0
    SV39_SMOKE_END 24
    li      t0, SV39_SMOKE_ATOMIC_PASS
    beq     t3, t0, 4f
    SV39_SMOKE_FAIL 4
4:
#endif

#if SV39_SMOKE_ENABLE_FENCE
    SV39_SMOKE_BEGIN
    call    sv39_smoke_fence
    SV39_SMOKE_END 32
#endif

#if SV39_SMOKE_ENABLE_STORE_EXTENSION
    SV39_SMOKE_BEGIN
    call    sv39_smoke_store_extension
    mv      t3, a0
    SV39_SMOKE_END 40
    beqz    t3, .Lstore_extension_fail
    li      t0, SV39_SMOKE_STORE_FAIL
    bne     t3, t0, 6f
.Lstore_extension_fail:
    SV39_SMOKE_FAIL 6
6:
#endif

    la      t0, sv39_smoke_results
    ld      a1, 0(t0)
    ld      a2, 8(t0)
    ld      a3, 16(t0)
    ld      a4, 24(t0)
    ld      a5, 32(t0)
    ld      a6, 40(t0)
    li      a7, SV39_SMOKE_MASK
    li      a0, SV39_SMOKE_PASS

.Lsmoke_return:
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret
.size main, .-main
.size test_main, .-test_main

.section .data.sv39_smoke, "aw", @progbits
.balign 64
.globl sv39_smoke_results
sv39_smoke_results:
    /* coremark, blake2s, stream, atomic, fence, store extension */
    .zero 6 * 8
sv39_smoke_start_cycle:
    .quad 0
sv39_smoke_blake2s_checksum:
    .quad 0
