/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (C) 2013 Regents of the University of California
 */

#ifdef OPENRV64_MEMCPY_BENCH
/*
 * Keep the copied Linux routine directly buildable in the freestanding
 * OpenRV64 benchmark.  These definitions reproduce only the assembler
 * interface supplied by the kernel headers; the function body below remains
 * source-identical to arch/riscv/lib/memcpy.S.
 */
#define SZREG 8
#define REG_L ld
#define REG_S sd
#define SYM_FUNC_START(name) \
	.globl name; \
	.type name, @function; \
name:
#define SYM_FUNC_END(name) \
	.size name, .-name
#define SYM_FUNC_ALIAS_WEAK(alias, name) \
	.weak alias; \
	.set alias, name
#define SYM_FUNC_ALIAS(alias, name) \
	.globl alias; \
	.set alias, name
#else
#include <linux/linkage.h>
#include <asm/asm.h>
#include <asm/jump_label.h>
#endif

/* void *memcpy(void *, const void *, size_t) */
SYM_FUNC_START(__memcpy)
	move t6, a0  /* Preserve return value */

	/* Defer to byte-oriented copy for small sizes */
	sltiu a3, a2, 128
	bnez a3, 4f
	/* Slow misaligned accesses require matching low-order bits. */
	andi a3, t6, SZREG-1
	andi a4, a1, SZREG-1
	beq a3, a4, 1f

#if defined(CONFIG_RISCV_PROBE_UNALIGNED_ACCESS) && !defined(__RISCV_PURGATORY)
#ifdef CONFIG_JUMP_LABEL
	STATIC_BRANCH_FALSE fast_unaligned_access_speed_key, 4f, 1
#else
	la a5, fast_unaligned_access_speed_key
	lw a5, 0(a5)
	beqz a5, 4f
#endif
#elif !defined(CONFIG_HAVE_EFFICIENT_UNALIGNED_ACCESS)
	j 4f
#endif

1:
	beqz a3, 2f  /* Skip if already aligned */
	/*
	 * Round to nearest double word-aligned address
	 * greater than or equal to start address
	 */
	andi a3, t6, ~(SZREG-1)
	addi a3, a3, SZREG
	/* Handle initial misalignment */
	sub a4, a3, t6
8:
	lb a5, 0(a1)
	addi a1, a1, 1
	sb a5, 0(t6)
	addi t6, t6, 1
	bltu t6, a3, 8b
	sub a2, a2, a4  /* Update count */

2:
	andi a4, a2, ~((16*SZREG)-1)
	beqz a4, 4f
	add a3, a1, a4
3:
	REG_L a4,       0(a1)
	REG_L a5,   SZREG(a1)
	REG_L a6, 2*SZREG(a1)
	REG_L a7, 3*SZREG(a1)
	REG_L t0, 4*SZREG(a1)
	REG_L t1, 5*SZREG(a1)
	REG_L t2, 6*SZREG(a1)
	REG_L t3, 7*SZREG(a1)
	REG_L t4, 8*SZREG(a1)
	REG_L t5, 9*SZREG(a1)
	REG_S a4,       0(t6)
	REG_S a5,   SZREG(t6)
	REG_S a6, 2*SZREG(t6)
	REG_S a7, 3*SZREG(t6)
	REG_S t0, 4*SZREG(t6)
	REG_S t1, 5*SZREG(t6)
	REG_S t2, 6*SZREG(t6)
	REG_S t3, 7*SZREG(t6)
	REG_S t4, 8*SZREG(t6)
	REG_S t5, 9*SZREG(t6)
	REG_L a4, 10*SZREG(a1)
	REG_L a5, 11*SZREG(a1)
	REG_L a6, 12*SZREG(a1)
	REG_L a7, 13*SZREG(a1)
	REG_L t0, 14*SZREG(a1)
	REG_L t1, 15*SZREG(a1)
	addi a1, a1, 16*SZREG
	REG_S a4, 10*SZREG(t6)
	REG_S a5, 11*SZREG(t6)
	REG_S a6, 12*SZREG(t6)
	REG_S a7, 13*SZREG(t6)
	REG_S t0, 14*SZREG(t6)
	REG_S t1, 15*SZREG(t6)
	addi t6, t6, 16*SZREG
	bltu a1, a3, 3b
	andi a2, a2, (16*SZREG)-1  /* Update count */

4:
	/* Handle trailing misalignment */
	beqz a2, 6f

	/*
	 * Avoid alignment fixups or byte copies when native misaligned word
	 * accesses were measured to be faster. The remaining range is known
	 * to contain at least one full word, so these accesses cannot stray
	 * outside the caller-provided buffers.
	 */
	sltiu a4, a2, SZREG
	bnez a4, 5f
#if defined(CONFIG_RISCV_PROBE_UNALIGNED_ACCESS) && !defined(__RISCV_PURGATORY)
#ifdef CONFIG_JUMP_LABEL
	STATIC_BRANCH_FALSE fast_unaligned_access_speed_key, 7f, 1
#else
	la a5, fast_unaligned_access_speed_key
	lw a5, 0(a5)
	beqz a5, 7f
#endif
#elif !defined(CONFIG_HAVE_EFFICIENT_UNALIGNED_ACCESS)
	j 7f
#endif

	andi a4, a2, ~(SZREG-1)
	add a3, a1, a4
9:
	REG_L a5, 0(a1)
	addi a1, a1, SZREG
	REG_S a5, 0(t6)
	addi t6, t6, SZREG
	bltu a1, a3, 9b
	sub a2, a2, a4
	beqz a2, 6f

5:
	add a3, a1, a2
	j 10f

7:
	add a3, a1, a2
	/* Use word-oriented copy if co-aligned to word boundary */
	or a5, a1, t6
	or a5, a5, a3
	andi a5, a5, 3
	bnez a5, 10f
11:
	lw a4, 0(a1)
	addi a1, a1, 4
	sw a4, 0(t6)
	addi t6, t6, 4
	bltu a1, a3, 11b

	ret

10:
	lb a4, 0(a1)
	addi a1, a1, 1
	sb a4, 0(t6)
	addi t6, t6, 1
	bltu a1, a3, 10b
6:
	ret
SYM_FUNC_END(__memcpy)
SYM_FUNC_ALIAS_WEAK(memcpy, __memcpy)
SYM_FUNC_ALIAS(__pi_memcpy, __memcpy)
SYM_FUNC_ALIAS(__pi___memcpy, __memcpy)
