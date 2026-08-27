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
    .equ SPI_STREAM_START, 0x38
    .equ SPI_STREAM_STATUS, 0x40
    .equ SPI_STREAM_RELEASE, 0x48
    .equ SPI_STREAM_CRC32, 0x50
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
     * Sector reads reuse the only sector buffer, so preserve the descriptor
     * table in initialized DDR before the first payload read overwrites sector
     * zero. Subroutine frames grow below this allocation and cannot alias it.
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

#ifndef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    /* Fill two SPI BRAM banks while software drains the preceding bank. */
    mv      a0, s6
    mv      a1, s7
    mv      a2, s9
    call    sd_read_start
    bnez    a0, read_fail
    li      s6, 0                   /* next ping-pong bank to consume */
#endif

.Lsector:
    beqz    s7, header_fail
#ifdef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    mv      a0, s6
    call    sd_read_sector
    bnez    a0, read_fail
#else
    mv      a0, s6
    call    sd_read_block
    bnez    a0, .Lread_abort
#endif
    li      a1, 512
    bgeu    s9, a1, .Lcopy
    mv      a1, s9
.Lcopy:
    mv      a0, s8
#ifdef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    mv      a2, s10
#endif
#ifndef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    mv      a3, s6
#endif
    call    copy_sector
    sub     s9, s9, a2             /* a2 returns copied byte count */
    mv      s8, a0
#ifdef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    mv      s10, a1
#endif
#ifdef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    addi    s6, s6, 1
#else
    li      t0, 1
    sll     t0, t0, s6
    sd      t0, SPI_STREAM_RELEASE(s2)
    xori    s6, s6, 1
#endif
    addi    s7, s7, -1
    bnez    s9, .Lsector
#ifndef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    call    sd_read_stop
    bnez    a0, read_fail
    j       .Lstream_stopped
.Lread_abort:
    call    sd_read_stop
    j       read_fail
.Lstream_stopped:
#endif
    bnez    s7, header_fail
#ifdef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    not     s10, s10
    slli    s10, s10, 32
    srli    s10, s10, 32
#else
    ld      s10, SPI_STREAM_CRC32(s2)
#endif
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
    addi    sp, sp, -32
    sd      ra, 24(sp)
    sd      s10, 16(sp)
    li      t0, 12
    xor     t0, t0, a0
    seqz    t0, t0
    sd      t0, 8(sp)              /* CMD12 has one stuff byte before R1 */
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
    ld      t0, 8(sp)
    beqz    t0, 1f
    li      a0, 1
    call    spi_xfer               /* discard CMD12's mandatory stuff byte */
1:
    li      t0, -1
    sd      t0, SPI_TX_LO(s2)
    li      s10, 65536
2:
    li      a0, 1
    call    spi_xfer
    andi    a0, a0, 0xff
    andi    t0, a0, 0x80
    beqz    t0, 3f
    addi    s10, s10, -1
    bnez    s10, 2b
    li      a0, -1
3:
    ld      s10, 16(sp)
    ld      ra, 24(sp)
    addi    sp, sp, 32
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

/* a0=LBA; read one SDHC sector into the inferred 512-byte BRAM with CMD17. */
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
    bnez    a0, 1f
    call    sd_receive_block
    mv      s10, a0
    j       2f
1:
    li      s10, -1
2:
    call    sd_end
    mv      a0, s10
    ld      s10, 0(sp)
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

/* a0=first LBA, a1=block count, a2=exact bytes; start buffered CMD18. */
sd_read_start:
    addi    sp, sp, -32
    sd      ra, 24(sp)
    sd      s10, 16(sp)
    sd      s11, 8(sp)
    mv      t2, a0
    slli    s11, a2, 32
    or      s11, s11, a1
    ori     t0, s3, 1
    sd      t0, SPI_CONTROL(s2)
    li      a0, 18
    mv      a1, t2
    li      a2, 0xff
    call    sd_command
    mv      s10, a0
    bnez    s10, 1f
    sd      s11, SPI_STREAM_START(s2)
    j       2f
1:
    call    sd_end
2:
    mv      a0, s10
    ld      s11, 8(sp)
    ld      s10, 16(sp)
    ld      ra, 24(sp)
    addi    sp, sp, 32
    ret

/* Receive a block through blocking transfers for CMD17 and legacy controls. */
sd_receive_block:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s10, 0(sp)
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
    mv      a0, s10
    ld      s10, 0(sp)
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

/* a0=bank index; wait until the autonomous receiver publishes that bank. */
sd_read_block:
    li      t2, 65536
    li      t1, 2
    sll     t1, t1, a0
1:
    ld      t0, SPI_STREAM_STATUS(s2)
    andi    t3, t0, 8
    bnez    t3, 2f
    and     t3, t0, t1
    bnez    t3, 3f
    addi    t2, t2, -1
    bnez    t2, 1b
2:
    li      a0, -1
    ret
3:
    li      a0, 0
    ret

/* Stop a CMD18 stream with CMD12/R1b, then release chip select. */
sd_read_stop:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s10, 0(sp)
    li      a0, 12
    li      a1, 0
    li      a2, 0xff
    call    sd_command
    bnez    a0, 3f
    li      s10, 65536
1:
    li      a0, 1
    call    spi_xfer
    andi    t0, a0, 0xff
    li      t1, 0xff
    beq     t0, t1, 2f
    addi    s10, s10, -1
    bnez    s10, 1b
    j       3f
2:
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
#ifdef FPGA_SD_BOOT_LEGACY_COPY_CRC
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

/* Legacy byte-copy path retained only for source-matched A/B measurement. */
copy_sector:
    addi    t0, s2, SPI_BUFFER
#ifndef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    slli    t1, a3, 9
    add     t0, t0, t1
#endif
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
#else
crc32_bytes:
    li      t0, -1
    la      t6, crc32_table
1:
    beqz    a1, 2f
    lbu     t1, 0(a0)
    xor     t1, t0, t1
    andi    t1, t1, 0xff
    slli    t1, t1, 2
    add     t1, t6, t1
    lwu     t1, 0(t1)
    srliw   t0, t0, 8
    xor     t0, t0, t1
    addi    a0, a0, 1
    addi    a1, a1, -1
    j       1b
2:
    not     t0, t0
    slli    a0, t0, 32
    srli    a0, a0, 32
    ret

#ifdef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
/* a0=DDR destination, a1=count, a2=CRC state; returns dest, CRC, count. */
copy_sector:
    addi    t0, s2, SPI_BUFFER
#ifndef FPGA_SD_BOOT_LEGACY_SINGLE_BLOCK
    slli    t1, a3, 9
    add     t0, t0, t1
#endif
    mv      t3, a1
    la      t6, crc32_table
    or      t4, t0, a0
    andi    t4, t4, 7
    bnez    t4, 3f
1:
    li      t4, 8
    bltu    a1, t4, 3f
    ld      t5, 0(t0)
    sd      t5, 0(a0)
    li      t2, 8
2:
    xor     t1, a2, t5
    andi    t1, t1, 0xff
    slli    t1, t1, 2
    add     t1, t6, t1
    lwu     t1, 0(t1)
    srliw   a2, a2, 8
    xor     a2, a2, t1
    srli    t5, t5, 8
    addi    t2, t2, -1
    bnez    t2, 2b
    addi    t0, t0, 8
    addi    a0, a0, 8
    addi    a1, a1, -8
    j       1b
3:
    beqz    a1, 5f
    lbu     t5, 0(t0)
    sb      t5, 0(a0)
    xor     t1, a2, t5
    andi    t1, t1, 0xff
    slli    t1, t1, 2
    add     t1, t6, t1
    lwu     t1, 0(t1)
    srliw   a2, a2, 8
    xor     a2, a2, t1
    addi    t0, t0, 1
    addi    a0, a0, 1
    addi    a1, a1, -1
    j       3b
5:
    mv      a1, a2
    mv      a2, t3
    ret
#else
/* Hardware-CRC path: copy exact bytes using wide accesses where aligned. */
copy_sector:
    addi    t0, s2, SPI_BUFFER
    slli    t1, a3, 9
    add     t0, t0, t1
    mv      t3, a1
    or      t4, t0, a0
    andi    t4, t4, 7
    bnez    t4, 3f
1:
    li      t4, 8
    bltu    a1, t4, 3f
    ld      t5, 0(t0)
    sd      t5, 0(a0)
    addi    t0, t0, 8
    addi    a0, a0, 8
    addi    a1, a1, -8
    j       1b
3:
    beqz    a1, 5f
    lbu     t5, 0(t0)
    sb      t5, 0(a0)
    addi    t0, t0, 1
    addi    a0, a0, 1
    addi    a1, a1, -1
    j       3b
5:
    mv      a2, t3
    ret
#endif
#endif

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

#ifndef FPGA_SD_BOOT_LEGACY_COPY_CRC
    /* Generated at assembly time; polynomial 0xedb88320, reflected form. */
    .balign 4
crc32_table:
    .macro crc32_table_entry index
        .set crc32_value, \index
        .rept 8
            .if (crc32_value & 1)
                .set crc32_value, (crc32_value >> 1) ^ 0xedb88320
            .else
                .set crc32_value, crc32_value >> 1
            .endif
        .endr
        .word crc32_value
    .endm
    .set crc32_index, 0
    .rept 256
        crc32_table_entry crc32_index
        .set crc32_index, crc32_index + 1
    .endr
#endif

    .size _start, . - _start
