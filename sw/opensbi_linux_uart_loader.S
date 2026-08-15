    .option norvc
    .section .text.startup, "ax", @progbits
    .globl _start
    .type _start, @function

#ifndef OPENRV64_FDT_ADDR
#define OPENRV64_FDT_ADDR 0x8ff00000
#endif

#ifndef OPENRV64_UART_CLOCK_FREQUENCY
#define OPENRV64_UART_CLOCK_FREQUENCY 1843200
#endif

#if (OPENRV64_UART_CLOCK_FREQUENCY % 1843200) != 0
#error UART clock must be an integer multiple of 1.8432 MHz for 115200 baud
#endif

    .equ UART_BASE,       0x10000000
    .equ UART_RBR,        0
    .equ UART_THR,        0
    .equ UART_DLL,        0
    .equ UART_IER,        1
    .equ UART_DLM,        1
    .equ UART_FCR,        2
    .equ UART_LCR,        3
    .equ UART_LSR,        5
    .equ UART_LSR_DR,     0x01
    .equ UART_LSR_THRE,   0x20
    .equ UART_DIVISOR,    (OPENRV64_UART_CLOCK_FREQUENCY / 1843200)

    .equ LINUX_ADDR,      0x80200000
    .equ OPENSBI_ADDR,    0x80100000
    .equ LINUX_MAX_BYTES, (OPENRV64_FDT_ADDR - LINUX_ADDR)

/*
 * The FPGA's fixed DDR loader places this stage at 0x8000_0000, OpenSBI at
 * 0x8010_0000, and the FDT below the top of RAM.  Receiving the kernel in
 * software keeps the CPU as the only live MIG client and adds no FPGA-side
 * arbitration or UART loader state.
 *
 * Wire format after the READY line:
 *
 *   8 bytes  ASCII "ORV64LNX"
 *   4 bytes  payload length, little endian
 *   4 bytes  IEEE CRC-32, little endian (the value returned by zlib.crc32)
 *   N bytes  raw RISC-V Linux Image for address 0x8020_0000, sent in blocks
 *            of at most 1024 bytes. The target writes aligned 64-bit words
 *            and returns '+' after each block.
 */
_start:
    mv      s0, a0                  /* preserve mhartid for OpenSBI */
    li      sp, 0x80010000          /* private stack below OpenSBI */
    li      s7, UART_BASE

    /* Disable interrupts, program 8N1 and the exact 115200-baud divisor. */
    sb      zero, UART_IER(s7)
    li      t0, 0x83
    sb      t0, UART_LCR(s7)
    li      t0, UART_DIVISOR
    sb      t0, UART_DLL(s7)
    srli    t0, t0, 8
    sb      t0, UART_DLM(s7)
    li      t0, 0x03
    sb      t0, UART_LCR(s7)
    li      t0, 0x07
    sb      t0, UART_FCR(s7)

.Lrestart:
    la      a0, ready_message
    call    uart_puts

    la      s1, protocol_magic
    li      s2, 8
.Lmagic_loop:
    call    uart_getc
    lbu     t0, 0(s1)
    bne     a0, t0, .Lbad_header
    addi    s1, s1, 1
    addi    s2, s2, -1
    bnez    s2, .Lmagic_loop

    call    uart_get_u32
    mv      s2, a0                  /* payload length */
    call    uart_get_u32
    mv      s3, a0                  /* expected CRC-32 */

    beqz    s2, .Lbad_header
    li      t0, LINUX_MAX_BYTES
    bgtu    s2, t0, .Lbad_header
    andi    t0, s2, 3
    bnez    t0, .Lbad_header       /* Linux Image is at least word aligned */

    la      a0, start_message
    call    uart_puts

    li      s1, LINUX_ADDR
    mv      s5, s2
    li      s4, -1                  /* IEEE CRC-32 initial value */
    li      s6, 0xedb88320
    li      s8, 0                   /* bytes received in this wire block */
    li      s9, 0                   /* bytes assembled in this DDR word */
    li      s10, 0                  /* little-endian DDR store word */

.Lpayload_loop:
    call    uart_getc
    slli    t2, s9, 3
    sll     t3, a0, t2
    or      s10, s10, t3

    xor     s4, s4, a0
    li      t0, 8
.Lcrc_bit:
    andi    t1, s4, 1
    srliw   s4, s4, 1
    beqz    t1, .Lcrc_next
    xor     s4, s4, s6
.Lcrc_next:
    addi    t0, t0, -1
    bnez    t0, .Lcrc_bit

    addi    s5, s5, -1
    addi    s8, s8, 1
    slli    t0, s5, 48             /* progress every 64 KiB */
    bnez    t0, .Lno_progress
    li      a0, '.'
    call    uart_putc
.Lno_progress:
    addi    s9, s9, 1
    li      t0, 8
    beq     s9, t0, .Lstore_word
    bnez    s5, .Lpayload_loop

    /* A word-aligned Image can only leave four bytes after full words. */
    sw      s10, 0(s1)
    addi    s1, s1, 4
    j       .Lword_stored

.Lstore_word:
    sd      s10, 0(s1)
    addi    s1, s1, 8
.Lword_stored:
    li      s9, 0
    li      s10, 0
    li      t0, 1024
    beq     s8, t0, .Lack_block
    bnez    s5, .Lpayload_loop
.Lack_block:
    li      a0, '+'
    call    uart_putc
    li      s8, 0
    bnez    s5, .Lpayload_loop

    not     s4, s4
    slli    s4, s4, 32
    srli    s4, s4, 32
    bne     s4, s3, .Lbad_crc

    fence   rw, rw
    fence.i
    la      a0, pass_message
    call    uart_puts

    mv      a0, s0
    li      a1, OPENRV64_FDT_ADDR
    li      a2, 0
    li      t0, OPENSBI_ADDR
    jr      t0

.Lbad_header:
    la      a0, header_fail_message
    call    uart_puts
    j       .Lrestart

.Lbad_crc:
    la      a0, crc_fail_message
    call    uart_puts
    j       .Lrestart

/* Return one received byte in a0. */
uart_getc:
1:
    lbu     t0, UART_LSR(s7)
    andi    t0, t0, UART_LSR_DR
    beqz    t0, 1b
    lbu     a0, UART_RBR(s7)
    ret

/* Receive one little-endian 32-bit word in a0. */
uart_get_u32:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s8, 0(sp)
    li      s8, 0
    call    uart_getc
    or      s8, s8, a0
    call    uart_getc
    slli    a0, a0, 8
    or      s8, s8, a0
    call    uart_getc
    slli    a0, a0, 16
    or      s8, s8, a0
    call    uart_getc
    slli    a0, a0, 24
    or      a0, s8, a0
    ld      s8, 0(sp)
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

/* Send the byte in a0 after the transmitter holding register empties. */
uart_putc:
1:
    lbu     t0, UART_LSR(s7)
    andi    t0, t0, UART_LSR_THRE
    beqz    t0, 1b
    sb      a0, UART_THR(s7)
    ret

/* Send the NUL-terminated string at a0. */
uart_puts:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s8, 0(sp)
    mv      s8, a0
1:
    lbu     a0, 0(s8)
    beqz    a0, 2f
    call    uart_putc
    addi    s8, s8, 1
    j       1b
2:
    ld      s8, 0(sp)
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

    .balign 8
protocol_magic:
    .ascii  "ORV64LNX"
ready_message:
    .asciz  "OPENRV64 LINUX LOAD READY\r\n"
start_message:
    .asciz  "OPENRV64 LINUX LOAD START\r\n"
pass_message:
    .asciz  "\r\nOPENRV64 LINUX LOAD PASS\r\n"
header_fail_message:
    .asciz  "OPENRV64 LINUX LOAD HEADER FAIL\r\n"
crc_fail_message:
    .asciz  "\r\nOPENRV64 LINUX LOAD CRC FAIL\r\n"

    .size _start, . - _start
