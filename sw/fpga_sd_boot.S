    .option norvc
    .section .text.startup, "ax", @progbits
    .globl _start
    .type _start, @function

    .equ UART_BASE,       0x10000000
    .equ UART_THR,        0
    .equ UART_IER,        1
    .equ UART_FCR,        2
    .equ UART_LCR,        3
    .equ UART_LSR,        5
    .equ UART_LSR_THRE,   0x20
#ifndef FPGA_SD_BOOT_UART_DIVISOR
#define FPGA_SD_BOOT_UART_DIVISOR 5
#endif
    .equ UART_DIVISOR,    FPGA_SD_BOOT_UART_DIVISOR

    .equ SPI_BASE,        0x10030000
    .equ SPI_CONTROL,     0x00
    .equ SPI_STATUS,      0x08
    .equ SPI_XFER,        0x10
    .equ SPI_TX_LO,       0x18
    .equ SPI_TX_HI,       0x20
    .equ SPI_RX_LO,       0x28
    .equ SPI_RX_HI,       0x30
    .equ SPI_BUFFER,      0x100

    .equ IMAGE_ENTRY,     0x40
    .equ IMAGE_ENTRY_SIZE, 32
    .equ IMAGE_ENTRY_COUNT, 4
    .equ IMAGE_FIRST_LBA, 8
    .equ DDR_BASE,        0x80000000
    .equ DDR_LIMIT,       0x90000000

_start:
    csrr    s0, mhartid
    li      sp, 0x800ff000
    li      s1, UART_BASE
    li      s2, SPI_BASE
    li      s3, 0                   /* control bits with CS inactive */
    call    uart_init
    la      a0, start_message
    call    uart_puts

    ld      t0, SPI_STATUS(s2)
    andi    t0, t0, 4
    beqz    t0, card_fail

    /* SD SPI entry requires at least 74 clocks with chip select high. */
    sd      s3, SPI_CONTROL(s2)
    li      t0, -1
    sd      t0, SPI_TX_LO(s2)
    sd      t0, SPI_TX_HI(s2)
    li      a0, 16
    call    spi_xfer

    /* CMD0: enter SPI idle state. */
    ori     t0, s3, 1
    sd      t0, SPI_CONTROL(s2)
    li      a0, 0
    li      a1, 0
    li      a2, 0x95
    call    sd_command
    li      t0, 1
    bne     a0, t0, init_fail
    call    sd_end

    /* CMD8: require an SD v2 card and the 0x1aa voltage/check pattern. */
    ori     t0, s3, 1
    sd      t0, SPI_CONTROL(s2)
    li      a0, 8
    li      a1, 0x1aa
    li      a2, 0x87
    call    sd_command
    li      t0, 1
    bne     a0, t0, init_fail
    li      a0, 4
    call    spi_xfer
    li      t0, 0xaa010000
    slli    a0, a0, 32
    srli    a0, a0, 32
    slli    t0, t0, 32
    srli    t0, t0, 32
    bne     a0, t0, init_fail
    call    sd_end

    /* ACMD41(HCS), preceded by CMD55, until the card leaves idle. */
    li      s4, 10000
.Lacmd41:
    ori     t0, s3, 1
    sd      t0, SPI_CONTROL(s2)
    li      a0, 55
    li      a1, 0
    li      a2, 0xff
    call    sd_command
    li      t0, 1
    bgtu    a0, t0, init_fail
    call    sd_end

    ori     t0, s3, 1
    sd      t0, SPI_CONTROL(s2)
    li      a0, 41
    li      a1, 0x40000000
    li      a2, 0xff
    call    sd_command
    mv      t1, a0
    call    sd_end
    beqz    t1, .Lcard_ready
    li      t0, 1
    bne     t1, t0, init_fail
    addi    s4, s4, -1
    bnez    s4, .Lacmd41
    j       init_fail

.Lcard_ready:
    /* CMD58: only block-addressed SDHC/SDXC media are supported. */
    ori     t0, s3, 1
    sd      t0, SPI_CONTROL(s2)
    li      a0, 58
    li      a1, 0
    li      a2, 0xff
    call    sd_command
    bnez    a0, init_fail
    li      a0, 4
    call    spi_xfer
    andi    t0, a0, 0x40           /* OCR CCS bit in first wire byte */
    beqz    t0, init_fail
    call    sd_end
    li      s3, 2                  /* fast clock, CS inactive */
    sd      s3, SPI_CONTROL(s2)

    /* Sector zero is a CRC-protected raw-image header. */
    li      a0, 0
    call    sd_read_sector
    bnez    a0, read_fail
    addi    s4, s2, SPI_BUFFER
    ld      t0, 0(s4)
    li      t1, 0x314453343656524f /* "ORV64SD1", little endian */
    bne     t0, t1, header_fail
    lwu     t0, 8(s4)
    li      t1, 1
    bne     t0, t1, header_fail
    lwu     t0, 12(s4)
    li      t1, 512
    bne     t0, t1, header_fail
    lwu     t0, 16(s4)
    li      t1, IMAGE_ENTRY_SIZE
    bne     t0, t1, header_fail
    lwu     t0, 20(s4)
    li      t1, IMAGE_ENTRY_COUNT
    bne     t0, t1, header_fail
    ld      t0, 24(s4)
    beqz    t0, header_fail
    andi    t0, t0, 511
    bnez    t0, header_fail

    mv      a0, s4
    li      a1, 508
    call    crc32_bytes
    lwu     t0, 508(s4)
    bne     a0, t0, header_fail

    /*
     * CMD17 reuses the only sector buffer, so preserve the descriptor table
     * in initialized DDR before the first payload read overwrites sector 0.
     * Subroutine frames grow below this allocation and cannot alias it.
     */
    addi    t0, s4, IMAGE_ENTRY
    addi    sp, sp, -(IMAGE_ENTRY_SIZE * IMAGE_ENTRY_COUNT)
    mv      s4, sp
    mv      t1, s4
    li      t2, (IMAGE_ENTRY_SIZE * IMAGE_ENTRY_COUNT) / 8
.Lcopy_entries:
    ld      t3, 0(t0)
    sd      t3, 0(t1)
    addi    t0, t0, 8
    addi    t1, t1, 8
    addi    t2, t2, -1
    bnez    t2, .Lcopy_entries
    li      s5, IMAGE_ENTRY_COUNT
.Lentry:
    /* The first entry must install the fixed trampoline at the jump target. */
    li      t0, IMAGE_ENTRY_COUNT
    bne     s5, t0, .Lentry_fields
    ld      t1, 0(s4)
    li      t2, 0x504d415254       /* "TRAMP" */
    bne     t1, t2, header_fail
    ld      t1, 16(s4)
    li      t2, DDR_BASE
    bne     t1, t2, header_fail

.Lentry_fields:
    lwu     s6, 8(s4)              /* current LBA */
    lwu     s7, 12(s4)             /* allocated sectors */
    ld      s8, 16(s4)             /* destination */
    lwu     s9, 24(s4)             /* remaining bytes */
    lwu     s11, 28(s4)            /* expected CRC-32 */
    beqz    s7, header_fail
    beqz    s9, header_fail
    li      t0, IMAGE_FIRST_LBA
    bltu    s6, t0, header_fail
    addi    t0, s9, 511
    srli    t0, t0, 9
    bne     t0, s7, header_fail
    li      t0, DDR_BASE
    bltu    s8, t0, header_fail
    add     t1, s8, s9
    bltu    t1, s8, header_fail
    li      t0, DDR_LIMIT
    bgtu    t1, t0, header_fail
    li      s10, -1                /* IEEE CRC-32 initial state */

.Lsector:
    mv      a0, s6
    call    sd_read_sector
    bnez    a0, read_fail
    li      a1, 512
    bgeu    s9, a1, .Lcopy
    mv      a1, s9
.Lcopy:
    mv      a0, s8
    mv      a2, s10
    call    copy_sector
    sub     s9, s9, a2             /* a2 returns copied byte count */
    mv      s8, a0
    mv      s10, a1
    addi    s6, s6, 1
    addi    s7, s7, -1
    bnez    s9, .Lsector
    bnez    s7, header_fail
    not     s10, s10
    slli    s10, s10, 32
    srli    s10, s10, 32
    bne     s10, s11, crc_fail
    addi    s4, s4, IMAGE_ENTRY_SIZE
    addi    s5, s5, -1
    bnez    s5, .Lentry

    fence   rw, rw
    fence.i
    la      a0, pass_message
    call    uart_puts
    mv      a0, s0
    li      t0, DDR_BASE
    jr      t0

card_fail:
    la      a0, card_fail_message
    j       fail
init_fail:
    la      a0, init_fail_message
    j       fail
header_fail:
    la      a0, header_fail_message
    j       fail
read_fail:
    la      a0, read_fail_message
    j       fail
crc_fail:
    la      a0, crc_fail_message
fail:
    call    uart_puts
1:
    wfi
    j       1b

/* a0=length; returns RX_LO in a0 and RX_HI in a1. */
spi_xfer:
    sd      a0, SPI_XFER(s2)
1:
    ld      t0, SPI_STATUS(s2)
    andi    t0, t0, 1
    bnez    t0, 1b
    ld      a0, SPI_RX_LO(s2)
    ld      a1, SPI_RX_HI(s2)
    ret

/* a0=command, a1=big-endian command argument, a2=CRC; returns R1. */
sd_command:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s10, 0(sp)
    andi    t0, a0, 0x3f
    ori     t0, t0, 0x40
    srli    t1, a1, 24
    andi    t1, t1, 0xff
    slli    t1, t1, 8
    or      t0, t0, t1
    srli    t1, a1, 16
    andi    t1, t1, 0xff
    slli    t1, t1, 16
    or      t0, t0, t1
    srli    t1, a1, 8
    andi    t1, t1, 0xff
    slli    t1, t1, 24
    or      t0, t0, t1
    andi    t1, a1, 0xff
    slli    t1, t1, 32
    or      t0, t0, t1
    andi    t1, a2, 0xff
    slli    t1, t1, 40
    or      t0, t0, t1
    sd      t0, SPI_TX_LO(s2)
    li      t0, -1
    sd      t0, SPI_TX_HI(s2)
    li      a0, 6
    call    spi_xfer
    li      t0, -1
    sd      t0, SPI_TX_LO(s2)
    li      s10, 65536
1:
    li      a0, 1
    call    spi_xfer
    andi    a0, a0, 0xff
    andi    t0, a0, 0x80
    beqz    t0, 2f
    addi    s10, s10, -1
    bnez    s10, 1b
    li      a0, -1
2:
    ld      s10, 0(sp)
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

/* Deassert CS and provide the required trailing clocks. */
sd_end:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s3, SPI_CONTROL(s2)
    li      a0, 1
    call    spi_xfer
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

/* a0=LBA; read one SDHC sector into the inferred 512-byte BRAM. */
sd_read_sector:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s10, 0(sp)
    mv      t2, a0
    ori     t0, s3, 1
    sd      t0, SPI_CONTROL(s2)
    li      a0, 17
    mv      a1, t2
    li      a2, 0xff
    call    sd_command
    bnez    a0, 3f
    li      s10, 65536
1:
    li      a0, 1
    call    spi_xfer
    andi    t0, a0, 0xff
    li      t1, 0xff
    bne     t0, t1, 2f
    addi    s10, s10, -1
    bnez    s10, 1b
    j       3f
2:
    li      t1, 0xfe
    bne     t0, t1, 3f
    li      a0, 512
    call    spi_xfer
    li      a0, 2                  /* discard card CRC */
    call    spi_xfer
    li      s10, 0
    j       4f
3:
    li      s10, -1
4:
    call    sd_end
    mv      a0, s10
    ld      s10, 0(sp)
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

/* a0=buffer, a1=length; return zlib-compatible CRC-32 in a0. */
crc32_bytes:
    li      t0, -1
    li      t6, 0xedb88320
1:
    beqz    a1, 4f
    lbu     t1, 0(a0)
    xor     t0, t0, t1
    li      t2, 8
2:
    andi    t3, t0, 1
    srliw   t0, t0, 1
    beqz    t3, 3f
    xor     t0, t0, t6
3:
    addi    t2, t2, -1
    bnez    t2, 2b
    addi    a0, a0, 1
    addi    a1, a1, -1
    j       1b
4:
    not     t0, t0
    slli    a0, t0, 32
    srli    a0, a0, 32
    ret

/* a0=DDR destination, a1=count, a2=CRC state; returns dest, CRC, count. */
copy_sector:
    addi    t0, s2, SPI_BUFFER
    mv      t3, a1
    li      t6, 0xedb88320
1:
    beqz    a1, 5f
    lbu     t1, 0(t0)
    sb      t1, 0(a0)
    xor     a2, a2, t1
    li      t2, 8
2:
    andi    t4, a2, 1
    srliw   a2, a2, 1
    beqz    t4, 3f
    xor     a2, a2, t6
3:
    addi    t2, t2, -1
    bnez    t2, 2b
    addi    t0, t0, 1
    addi    a0, a0, 1
    addi    a1, a1, -1
    j       1b
5:
    mv      a1, a2
    mv      a2, t3
    ret

uart_init:
    sb      zero, UART_IER(s1)
    li      t0, 0x83
    sb      t0, UART_LCR(s1)
    li      t0, UART_DIVISOR
    sb      t0, 0(s1)
    sb      zero, 1(s1)
    li      t0, 0x03
    sb      t0, UART_LCR(s1)
    li      t0, 0x07
    sb      t0, UART_FCR(s1)
    ret

uart_putc:
1:
    lbu     t0, UART_LSR(s1)
    andi    t0, t0, UART_LSR_THRE
    beqz    t0, 1b
    sb      a0, UART_THR(s1)
    ret

uart_puts:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s10, 0(sp)
    mv      s10, a0
1:
    lbu     a0, 0(s10)
    beqz    a0, 2f
    call    uart_putc
    addi    s10, s10, 1
    j       1b
2:
    ld      s10, 0(sp)
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

    .balign 8
start_message:
    .asciz  "OPENRV64 SD BOOT START\r\n"
pass_message:
    .asciz  "OPENRV64 SD BOOT PASS\r\n"
card_fail_message:
    .asciz  "OPENRV64 SD BOOT NO CARD\r\n"
init_fail_message:
    .asciz  "OPENRV64 SD BOOT INIT FAIL\r\n"
header_fail_message:
    .asciz  "OPENRV64 SD BOOT HEADER FAIL\r\n"
read_fail_message:
    .asciz  "OPENRV64 SD BOOT READ FAIL\r\n"
crc_fail_message:
    .asciz  "OPENRV64 SD BOOT CRC FAIL\r\n"

    .size _start, . - _start
