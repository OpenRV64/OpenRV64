#include <stdint.h>
#include <stddef.h>

#define UART_BASE          UINT64_C(0x10000000)
#define CLINT_BASE         UINT64_C(0x02000000)
#define PLIC_BASE          UINT64_C(0x0c000000)

#define CLINT_MTIMECMP     (CLINT_BASE + UINT64_C(0x4000))
#define CLINT_MTIME        (CLINT_BASE + UINT64_C(0xbff8))

#define PLIC_UART_PRIORITY (PLIC_BASE + UINT64_C(0x000004))
#define PLIC_ENABLE        (PLIC_BASE + UINT64_C(0x002000))
#define PLIC_THRESHOLD     (PLIC_BASE + UINT64_C(0x200000))
#define PLIC_CLAIM         (PLIC_BASE + UINT64_C(0x200004))
#define PLIC_UART_ID       1u

#define UART_RBR           0u
#define UART_THR           0u
#define UART_DLL           0u
#define UART_IER           1u
#define UART_DLM           1u
#define UART_IIR           2u
#define UART_FCR           2u
#define UART_LCR           3u
#define UART_LSR           5u
#define UART_MSR           6u

#define UART_IER_RX        (1u << 0)
#define UART_IER_TX        (1u << 1)
#define UART_IER_LINE      (1u << 2)
#define UART_LSR_DR        (1u << 0)
#define UART_IIR_NONE      (1u << 0)
#define UART_IIR_ID_MASK   0x0eu
#define UART_IIR_MODEM     0x00u
#define UART_IIR_THRE      0x02u
#define UART_IIR_RX        0x04u
#define UART_IIR_LINE      0x06u
#define UART_IIR_TIMEOUT   0x0cu

#define MSTATUS_MIE        (UINT64_C(1) << 3)
#define MIE_MTIE           (UINT64_C(1) << 7)
#define MIE_SEIE           (UINT64_C(1) << 9)
#define MCAUSE_INTERRUPT   (UINT64_C(1) << 63)
#define MCAUSE_MTIMER      7u
#define MCAUSE_SEXTERNAL   9u

#ifndef UART_TIMEOUT_TICKS
#define UART_TIMEOUT_TICKS UINT64_C(4096)
#endif

enum {
    RX_CAPACITY = 64,
    TX_CAPACITY = RX_CAPACITY + 8,
    UART_FIFO_CAPACITY = 16
};

extern void trap_entry(void);

static volatile uint8_t rx_line[RX_CAPACITY + 1];
static volatile size_t rx_length;
static volatile uint8_t line_ready;
static volatile uint8_t timed_out;

static volatile uint8_t tx_buffer[TX_CAPACITY];
static volatile size_t tx_length;
static volatile size_t tx_position;
static volatile uint8_t tx_done;
static volatile uint64_t trap_fault;

static inline uint8_t mmio_read8(uintptr_t address)
{
    return *(volatile uint8_t *)address;
}

static inline void mmio_write8(uintptr_t address, uint8_t value)
{
    *(volatile uint8_t *)address = value;
}

static inline uint32_t mmio_read32(uintptr_t address)
{
    return *(volatile uint32_t *)address;
}

static inline void mmio_write32(uintptr_t address, uint32_t value)
{
    *(volatile uint32_t *)address = value;
}

static inline uint64_t mmio_read64(uintptr_t address)
{
    return *(volatile uint64_t *)address;
}

static inline void mmio_write64(uintptr_t address, uint64_t value)
{
    *(volatile uint64_t *)address = value;
}

static inline void write_mtvec(uintptr_t value)
{
    __asm__ volatile ("csrw mtvec, %0" : : "r"(value) : "memory");
}

static inline void write_mie(uint64_t value)
{
    __asm__ volatile ("csrw mie, %0" : : "r"(value) : "memory");
}

static inline void enable_global_interrupts(void)
{
    __asm__ volatile ("csrs mstatus, %0" : : "r"(MSTATUS_MIE) : "memory");
}

static inline void disable_global_interrupts(void)
{
    __asm__ volatile ("csrc mstatus, %0" : : "r"(MSTATUS_MIE) : "memory");
}

static inline void wait_for_interrupt(void)
{
    // OpenRV64 currently implements WFI as a legal serializing hint. State
    // changes are still made exclusively by the interrupt handlers.
    __asm__ volatile ("wfi" : : : "memory");
}

static void timer_cancel(void)
{
    mmio_write64(CLINT_MTIMECMP, UINT64_MAX);
}

static void timer_arm(void)
{
    uint64_t now = mmio_read64(CLINT_MTIME);
    mmio_write64(CLINT_MTIMECMP, now + UART_TIMEOUT_TICKS);
}

static void uart_receive(void)
{
    while ((mmio_read8(UART_BASE + UART_LSR) & UART_LSR_DR) != 0u) {
        uint8_t byte = mmio_read8(UART_BASE + UART_RBR);

        if (line_ready != 0u) {
            continue;
        }

        if (byte == (uint8_t)'\n') {
            if ((rx_length != 0u) &&
                (rx_line[rx_length - 1u] == (uint8_t)'\r')) {
                rx_length--;
            }
            rx_line[rx_length] = 0u;
            line_ready = 1u;
            timer_cancel();
        } else if (rx_length < RX_CAPACITY) {
            rx_line[rx_length] = byte;
            rx_length++;
        }
    }
}

static void uart_transmit(void)
{
    unsigned int pushed = 0u;

    while ((tx_position < tx_length) &&
           (pushed < UART_FIFO_CAPACITY)) {
        mmio_write8(UART_BASE + UART_THR, tx_buffer[tx_position]);
        tx_position++;
        pushed++;
    }

    // A subsequent THRE interrupt proves the final batch has left the FIFO.
    if ((tx_position == tx_length) && (pushed == 0u)) {
        uint8_t ier = mmio_read8(UART_BASE + UART_IER);
        mmio_write8(UART_BASE + UART_IER,
                    (uint8_t)(ier & (uint8_t)~UART_IER_TX));
        tx_done = 1u;
    }
}

static void uart_interrupt(void)
{
    for (;;) {
        uint8_t iir = mmio_read8(UART_BASE + UART_IIR);

        if ((iir & UART_IIR_NONE) != 0u) {
            return;
        }

        switch (iir & UART_IIR_ID_MASK) {
        case UART_IIR_LINE:
            (void)mmio_read8(UART_BASE + UART_LSR);
            uart_receive();
            break;
        case UART_IIR_RX:
        case UART_IIR_TIMEOUT:
            uart_receive();
            break;
        case UART_IIR_THRE:
            uart_transmit();
            break;
        case UART_IIR_MODEM:
            (void)mmio_read8(UART_BASE + UART_MSR);
            break;
        default:
            return;
        }
    }
}

void uart_trap_handler(uint64_t mcause)
{
    uint64_t cause = mcause & ~MCAUSE_INTERRUPT;

    if ((mcause & MCAUSE_INTERRUPT) == 0u) {
        trap_fault = mcause + 1u;
        disable_global_interrupts();
        __asm__ volatile ("ebreak");
        return;
    }

    if (cause == MCAUSE_MTIMER) {
        timer_cancel();
        timed_out = 1u;
        return;
    }

    if (cause == MCAUSE_SEXTERNAL) {
        uint32_t claim = mmio_read32(PLIC_CLAIM);

        if (claim == PLIC_UART_ID) {
            uart_interrupt();
        }
        if (claim != 0u) {
            mmio_write32(PLIC_CLAIM, claim);
        }
        return;
    }

    trap_fault = mcause + 1u;
}

static void uart_init(void)
{
    // Disable UART interrupts while programming divisor 1 and 8N1 format.
    mmio_write8(UART_BASE + UART_IER, 0u);
    mmio_write8(UART_BASE + UART_LCR, 0x83u);
    mmio_write8(UART_BASE + UART_DLL, 1u);
    mmio_write8(UART_BASE + UART_DLM, 0u);
    mmio_write8(UART_BASE + UART_LCR, 0x03u);
    mmio_write8(UART_BASE + UART_FCR, 0x07u);
}

static void plic_init(void)
{
    mmio_write32(PLIC_UART_PRIORITY, 1u);
    mmio_write32(PLIC_ENABLE, UINT32_C(1) << PLIC_UART_ID);
    mmio_write32(PLIC_THRESHOLD, 0u);
}

static void start_transmit(const char *prefix)
{
    size_t output_length = 0u;
    size_t input_index = 0u;

    while ((prefix[output_length] != '\0') &&
           (output_length < TX_CAPACITY)) {
        tx_buffer[output_length] = (uint8_t)prefix[output_length];
        output_length++;
    }

    if (line_ready != 0u) {
        while ((input_index < rx_length) &&
               (output_length < (TX_CAPACITY - 1u))) {
            tx_buffer[output_length] = rx_line[input_index];
            output_length++;
            input_index++;
        }
    }

    if (output_length < TX_CAPACITY) {
        tx_buffer[output_length] = (uint8_t)'\n';
        output_length++;
    }

    tx_position = 0u;
    tx_length = output_length;
    tx_done = 0u;
    mmio_write8(UART_BASE + UART_IER,
                UART_IER_RX | UART_IER_LINE | UART_IER_TX);
}

int main(void)
{
    disable_global_interrupts();
    write_mtvec((uintptr_t)trap_entry);
    uart_init();
    plic_init();
    write_mie(MIE_MTIE | MIE_SEIE);
    timer_arm();
    mmio_write8(UART_BASE + UART_IER, UART_IER_RX | UART_IER_LINE);
    enable_global_interrupts();

    while ((line_ready == 0u) && (timed_out == 0u) &&
           (trap_fault == 0u)) {
        wait_for_interrupt();
    }

    if (trap_fault != 0u) {
        disable_global_interrupts();
        return 1;
    }

    if (line_ready != 0u) {
        start_transmit("hello ");
    } else {
        start_transmit("timeout");
    }

    while ((tx_done == 0u) && (trap_fault == 0u)) {
        wait_for_interrupt();
    }

    disable_global_interrupts();
    return (trap_fault == 0u) ? 0 : 1;
}
