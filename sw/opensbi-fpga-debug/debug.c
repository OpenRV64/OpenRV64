// SPDX-License-Identifier: BSD-2-Clause
//
// OpenRV64 FPGA machine-mode snapshot support for OpenSBI v1.9.

#include <libfdt.h>
#include <platform_override.h>
#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/riscv_io.h>
#include <sbi/sbi_error.h>
#include <sbi/sbi_irqchip.h>
#include <sbi/sbi_scratch.h>
#include <sbi/sbi_string.h>
#include <sbi/sbi_trap.h>
#include <sbi_utils/fdt/fdt_driver.h>
#include <sbi_utils/irqchip/plic.h>

#define OPENRV64_PLIC_BASE                 0x0c000000UL
#define OPENRV64_PLIC_SIZE                 0x04000000UL
#define OPENRV64_PLIC_SOURCES              33
#define OPENRV64_PLIC_M_CONTEXT            0
#define OPENRV64_PLIC_S_CONTEXT            1
#define OPENRV64_DEBUG_HWIRQ                32

#define PLIC_PRIORITY_BASE                 0x000000UL
#define PLIC_ENABLE_BASE                   0x002000UL
#define PLIC_ENABLE_STRIDE                 0x000080UL
#define PLIC_CONTEXT_BASE                  0x200000UL
#define PLIC_CONTEXT_STRIDE                0x001000UL
#define PLIC_CONTEXT_THRESHOLD             0x000000UL
#define PLIC_CONTEXT_CLAIM                 0x000004UL

#define OPENRV64_SNAPSHOT_BASE             0x0c300000UL
#define OPENRV64_SNAPSHOT_STATUS           0x0ff0UL
#define OPENRV64_SNAPSHOT_CONTROL          0x0ff8UL
#define OPENRV64_SNAPSHOT_RESUME_PENDING   (1UL << 0)
#define OPENRV64_SNAPSHOT_CONTROL_ACK      (1UL << 0)

#define OPENRV64_DEBUG_STUB_BASE           0x0c304000UL
#define OPENRV64_DEBUG_STUB_SIZE           0x00004000UL
#define OPENRV64_DEBUG_STUB_USABLE_SIZE    0x00003ff0UL
#define OPENRV64_DEBUG_STUB_DESC_MAGIC     0x00003ff0UL
#define OPENRV64_DEBUG_STUB_DESC_META      0x00003ff8UL
#define OPENRV64_DEBUG_STUB_MAGIC          0x4f52563653545542UL
#define OPENRV64_DEBUG_STUB_ABI_VERSION    1UL

#define OPENRV64_SNAPSHOT_MAGIC            0x4f525636534e4150UL
#define OPENRV64_SNAPSHOT_VERSION          2UL
#define OPENRV64_SNAPSHOT_STATE_CAPTURING  1UL
#define OPENRV64_SNAPSHOT_STATE_COMPLETE   2UL
#define OPENRV64_SNAPSHOT_STATE_RESUMING   3UL

#define OPENRV64_STUB_STATE_ABSENT          0UL
#define OPENRV64_STUB_STATE_INVALID         1UL
#define OPENRV64_STUB_STATE_RUNNING         2UL
#define OPENRV64_STUB_STATE_RETURNED        3UL

enum openrv64_snapshot_word {
	SNAP_MAGIC = 0,
	SNAP_VERSION,
	SNAP_STATE,
	SNAP_HWIRQ,
	SNAP_MCYCLE,
	SNAP_MINSTRET,
	SNAP_MCAUSE,
	SNAP_MTVAL,
	SNAP_MTVAL2,
	SNAP_MTINST,
	SNAP_MEPC,
	SNAP_MSTATUS,
	SNAP_SATP,
	SNAP_MIE,
	SNAP_MIP,
	SNAP_SSTATUS,
	SNAP_SEPC,
	SNAP_SCAUSE,
	SNAP_STVAL,
	SNAP_MHARTID,
	SNAP_GPR0,
	SNAP_STUB_STATE = SNAP_GPR0 + 32,
	SNAP_STUB_ENTRY,
	SNAP_STUB_PAYLOAD_BYTES,
	SNAP_STUB_RESULT,
	SNAP_STUB_MAGIC,
	SNAP_WORDS_USED,
};

typedef unsigned long (*openrv64_debug_stub_fn)(
	volatile unsigned long *snapshot, unsigned long snapshot_bytes,
	volatile unsigned long *workspace, unsigned long workspace_bytes,
	unsigned long hwirq);

static unsigned char plic_storage[PLIC_DATA_SIZE(1)]
	__attribute__((aligned(sizeof(unsigned long))));
static struct plic_data *openrv64_plic =
	(struct plic_data *)(void *)plic_storage;

static inline volatile u32 *plic_reg(u32 offset)
{
	return (volatile u32 *)(OPENRV64_PLIC_BASE + offset);
}

static inline u32 plic_context_offset(u32 context, u32 offset)
{
	return PLIC_CONTEXT_BASE + context * PLIC_CONTEXT_STRIDE + offset;
}

static int openrv64_plic_process(struct sbi_irqchip_device *chip)
{
	u32 hwirq;

	(void)chip;
	hwirq = readl(plic_reg(plic_context_offset(
		OPENRV64_PLIC_M_CONTEXT, PLIC_CONTEXT_CLAIM)));
	if (!hwirq)
		return 0;

	return sbi_irqchip_process_hwirq(&openrv64_plic->irqchip, hwirq);
}

static int openrv64_plic_hwirq_setup(struct sbi_irqchip_device *chip,
				     u32 hwirq, u32 flags)
{
	(void)chip;
	if (flags != SBI_HWIRQ_FLAGS_LEVEL_HIGH)
		return SBI_ENOTSUPP;
	if (!hwirq || hwirq > OPENRV64_PLIC_SOURCES)
		return SBI_EINVAL;

	writel(1, plic_reg(PLIC_PRIORITY_BASE + 4 * hwirq));
	return 0;
}

static void openrv64_plic_hwirq_eoi(struct sbi_irqchip_device *chip,
				    u32 hwirq)
{
	(void)chip;
	writel(hwirq, plic_reg(plic_context_offset(
		OPENRV64_PLIC_M_CONTEXT, PLIC_CONTEXT_CLAIM)));
}

static void openrv64_plic_hwirq_mask(struct sbi_irqchip_device *chip,
				     u32 hwirq)
{
	volatile u32 *enable;
	u32 value;

	(void)chip;
	enable = plic_reg(PLIC_ENABLE_BASE +
		OPENRV64_PLIC_M_CONTEXT * PLIC_ENABLE_STRIDE +
		(hwirq / 32) * sizeof(u32));
	value = readl(enable);
	value &= ~(1U << (hwirq % 32));
	writel(value, enable);
}

static void openrv64_plic_hwirq_unmask(struct sbi_irqchip_device *chip,
				       u32 hwirq)
{
	volatile u32 *enable;
	u32 value;

	(void)chip;
	enable = plic_reg(PLIC_ENABLE_BASE +
		OPENRV64_PLIC_M_CONTEXT * PLIC_ENABLE_STRIDE +
		(hwirq / 32) * sizeof(u32));
	value = readl(enable);
	value |= 1U << (hwirq % 32);
	writel(value, enable);
	writel(0, plic_reg(plic_context_offset(
		OPENRV64_PLIC_M_CONTEXT, PLIC_CONTEXT_THRESHOLD)));
}

static int openrv64_debug_irq(u32 hwirq, void *priv)
{
	struct sbi_trap_context *tcntx;
	struct sbi_scratch *scratch;
	volatile unsigned long *snapshot;
	volatile unsigned long *workspace;
	openrv64_debug_stub_fn stub;
	unsigned long descriptor_magic;
	unsigned long descriptor_meta;
	unsigned long payload_bytes;
	unsigned long entry_offset;
	unsigned long abi_version;
	u32 i;

	(void)priv;
	if (hwirq != OPENRV64_DEBUG_HWIRQ)
		return SBI_EINVAL;

	scratch = sbi_scratch_thishart_ptr();
	tcntx = sbi_trap_get_context(scratch);
	if (!tcntx)
		return SBI_EFAIL;

	snapshot = (volatile unsigned long *)OPENRV64_SNAPSHOT_BASE;
	snapshot[SNAP_MAGIC] = OPENRV64_SNAPSHOT_MAGIC;
	snapshot[SNAP_VERSION] = OPENRV64_SNAPSHOT_VERSION;
	snapshot[SNAP_STATE] = OPENRV64_SNAPSHOT_STATE_CAPTURING;
	snapshot[SNAP_HWIRQ] = hwirq;
	snapshot[SNAP_MCYCLE] = csr_read(CSR_MCYCLE);
	snapshot[SNAP_MINSTRET] = csr_read(CSR_MINSTRET);
	snapshot[SNAP_MCAUSE] = tcntx->trap.cause;
	snapshot[SNAP_MTVAL] = tcntx->trap.tval;
	snapshot[SNAP_MTVAL2] = tcntx->trap.tval2;
	snapshot[SNAP_MTINST] = tcntx->trap.tinst;
	snapshot[SNAP_MEPC] = tcntx->regs.mepc;
	snapshot[SNAP_MSTATUS] = tcntx->regs.mstatus;
	snapshot[SNAP_SATP] = csr_read(CSR_SATP);
	snapshot[SNAP_MIE] = csr_read(CSR_MIE);
	snapshot[SNAP_MIP] = csr_read(CSR_MIP);
	snapshot[SNAP_SSTATUS] = csr_read(CSR_SSTATUS);
	snapshot[SNAP_SEPC] = csr_read(CSR_SEPC);
	snapshot[SNAP_SCAUSE] = csr_read(CSR_SCAUSE);
	snapshot[SNAP_STVAL] = csr_read(CSR_STVAL);
	snapshot[SNAP_MHARTID] = csr_read(CSR_MHARTID);
	for (i = 0; i < 32; i++)
		snapshot[SNAP_GPR0 + i] = tcntx->regs.gprs[i];

	workspace = (volatile unsigned long *)OPENRV64_DEBUG_STUB_BASE;
	descriptor_magic = *(volatile unsigned long *)(
		OPENRV64_DEBUG_STUB_BASE + OPENRV64_DEBUG_STUB_DESC_MAGIC);
	descriptor_meta = *(volatile unsigned long *)(
		OPENRV64_DEBUG_STUB_BASE + OPENRV64_DEBUG_STUB_DESC_META);
	payload_bytes = descriptor_meta >> 32;
	abi_version = (descriptor_meta >> 16) & 0xffffUL;
	entry_offset = descriptor_meta & 0xffffUL;

	snapshot[SNAP_STUB_STATE] = OPENRV64_STUB_STATE_ABSENT;
	snapshot[SNAP_STUB_ENTRY] = entry_offset;
	snapshot[SNAP_STUB_PAYLOAD_BYTES] = payload_bytes;
	snapshot[SNAP_STUB_RESULT] = 0;
	snapshot[SNAP_STUB_MAGIC] = descriptor_magic;

	if (descriptor_magic == OPENRV64_DEBUG_STUB_MAGIC) {
		if (abi_version != OPENRV64_DEBUG_STUB_ABI_VERSION ||
		    !payload_bytes ||
		    payload_bytes > OPENRV64_DEBUG_STUB_USABLE_SIZE ||
		    entry_offset >= payload_bytes || (entry_offset & 3UL)) {
			snapshot[SNAP_STUB_STATE] = OPENRV64_STUB_STATE_INVALID;
		} else {
			/*
			 * JTAG writes the descriptor magic last. Re-read it after
			 * ordering the descriptor loads so a concurrent invalidation
			 * cannot dispatch a partially replaced image.
			 */
			asm volatile("fence r,r" ::: "memory");
			descriptor_magic = *(volatile unsigned long *)(
				OPENRV64_DEBUG_STUB_BASE +
				OPENRV64_DEBUG_STUB_DESC_MAGIC);
			if (descriptor_magic != OPENRV64_DEBUG_STUB_MAGIC) {
				snapshot[SNAP_STUB_STATE] =
					OPENRV64_STUB_STATE_INVALID;
			} else {
				snapshot[SNAP_STUB_STATE] =
					OPENRV64_STUB_STATE_RUNNING;
				asm volatile("fence rw,rw\n\tfence.i" ::: "memory");
				stub = (openrv64_debug_stub_fn)(
					OPENRV64_DEBUG_STUB_BASE + entry_offset);
				snapshot[SNAP_STUB_RESULT] = stub(
					snapshot, OPENRV64_SNAPSHOT_STATUS,
					workspace, OPENRV64_DEBUG_STUB_USABLE_SIZE,
					hwirq);
				snapshot[SNAP_STUB_STATE] =
					OPENRV64_STUB_STATE_RETURNED;
			}
		}
	}

	asm volatile("fence w,w" ::: "memory");
	snapshot[SNAP_STATE] = OPENRV64_SNAPSHOT_STATE_COMPLETE;
	asm volatile("fence w,w" ::: "memory");

	while (!(readl((volatile void *)(OPENRV64_SNAPSHOT_BASE +
					 OPENRV64_SNAPSHOT_STATUS)) &
		 OPENRV64_SNAPSHOT_RESUME_PENDING))
		asm volatile("nop");

	snapshot[SNAP_STATE] = OPENRV64_SNAPSHOT_STATE_RESUMING;
	asm volatile("fence w,w" ::: "memory");
	writel(OPENRV64_SNAPSHOT_CONTROL_ACK,
	       (volatile void *)(OPENRV64_SNAPSHOT_BASE +
				 OPENRV64_SNAPSHOT_CONTROL));
	return 0;
}

static int openrv64_debug_irqchip_init(void)
{
	struct sbi_irqchip_device *chip;

	sbi_memset(openrv64_plic, 0, sizeof(plic_storage));
	openrv64_plic->unique_id = 0;
	openrv64_plic->addr = OPENRV64_PLIC_BASE;
	openrv64_plic->size = OPENRV64_PLIC_SIZE;
	openrv64_plic->num_src = OPENRV64_PLIC_SOURCES;
	openrv64_plic->context_map[0][PLIC_M_CONTEXT] =
		OPENRV64_PLIC_M_CONTEXT;
	openrv64_plic->context_map[0][PLIC_S_CONTEXT] =
		OPENRV64_PLIC_S_CONTEXT;

	chip = &openrv64_plic->irqchip;
	chip->process_hwirqs = openrv64_plic_process;
	chip->hwirq_setup = openrv64_plic_hwirq_setup;
	chip->hwirq_eoi = openrv64_plic_hwirq_eoi;
	chip->hwirq_mask = openrv64_plic_hwirq_mask;
	chip->hwirq_unmask = openrv64_plic_hwirq_unmask;

	return plic_cold_irqchip_init(openrv64_plic);
}

static int openrv64_debug_final_init(bool cold_boot)
{
	int rc;

	if (cold_boot) {
		rc = sbi_irqchip_register_handler(&openrv64_plic->irqchip,
			OPENRV64_DEBUG_HWIRQ, 1, SBI_HWIRQ_FLAGS_LEVEL_HIGH,
			openrv64_debug_irq, NULL);
		if (rc)
			return rc;
	}

	return generic_final_init(cold_boot);
}

/*
 * OpenSBI's generic sbi_exit() path deliberately clears MIE.MEIE after the
 * irqchip has finished boot-time work.  This debug platform is different:
 * source 32 remains an OpenSBI-owned machine interrupt while the payload is
 * running.  final_exit runs after sbi_irqchip_exit(), so restore only MEIE;
 * the PLIC handler, affinity, priority, and enable programmed in final_init
 * remain live.
 */
static void openrv64_debug_final_exit(void)
{
	csr_set(CSR_MIE, MIP_MEIP);
}

static int openrv64_debug_platform_init(const void *fdt, int nodeoff,
					const struct fdt_match *match)
{
	(void)fdt;
	(void)nodeoff;
	(void)match;
	generic_platform_ops.irqchip_init = openrv64_debug_irqchip_init;
	generic_platform_ops.final_init = openrv64_debug_final_init;
	generic_platform_ops.final_exit = openrv64_debug_final_exit;
	return 0;
}

static const struct fdt_match openrv64_debug_match[] = {
	{ .compatible = "openrv64,fpga-debug" },
	{ },
};

const struct fdt_driver openrv64_fpga_debug = {
	.match_table = openrv64_debug_match,
	.init = openrv64_debug_platform_init,
};
