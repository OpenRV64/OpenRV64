# Linux-shaped spinlock Sv39 microbenchmark

This benchmark measures the uncontended RISC-V ticket-spinlock path used by
the source-matched Linux kernel.  It exists to interpret whole-boot PC samples
in `_raw_spin_lock`, `_raw_spin_unlock`, and their IRQ-save variants; it is not
a replacement for the four-hart contended ticket-lock correctness test.

The payload runs in supervisor mode under Sv39 through the normal L1D, ICX,
L2, AXI, and timed banked-DDR3 hierarchy.  Its Linux-shaped functions preserve
the emitted kernel fast-path structure:

- preemption-count update;
- `amoadd.w.aqrl` on the packed owner/next ticket word;
- owner/next comparison and the inactive `cpu_relax()` slow loop;
- `mmiowb` nesting update through a per-CPU-offset dependency;
- protected counter load, increment, and store;
- `fence rw,w` followed by the low-halfword owner store;
- reschedule-flag check; and
- `sstatus` save/restore for the IRQ-save pair.

Every case checks the final packed ticket, protected counter, preemption count,
`mmiowb` state, and interrupt-enable state.  The working set is warmed and the
test is deliberately single-hart: the profiled Linux boot held harts 1-3 in
reset, so contention cannot explain those samples.

Run the managed, provenance-capturing cases with:

```sh
run/run run/cfg/linux-spinlock-sv39-rd32.cfg
run/run run/cfg/linux-spinlock-sv39-rd16.cfg
run/run run/cfg/linux-spinlock-sv39-rd32-noprefetch.cfg
```

## 2026-08-17 result

Both 1,024-iteration cases passed with identical payload ELF hash
`bfd2d16eb210d024d2361786185e1c8cc31d7a1cc10c8605d8675b04c3eaecab`.
The configuration used BP8, fetch mode 3, carousel enabled, issue/speculation
windows enabled, posted stores, relaxed L2 fence acknowledgment, L1D prefetch,
and timed DDR3.

| Case | Instructions/pair | RD16 cycles/pair | RD32 cycles/pair |
| --- | ---: | ---: | ---: |
| Protected increment without lock | 5.001 | 4.080 | 4.087 |
| Bare ticket acquire/increment/release | 24.001 | 116.016 | 119.993 |
| Linux-shaped raw pair | 62.001 | 170.021 | 171.817 |
| Linux-shaped IRQ-save pair | 68.001 | 182.024 | 185.016 |

RD32 was 3.43% slower for the bare ticket pair, 1.06% slower for the raw pair,
and 1.64% slower for the IRQ-save pair.  This is a serialized atomic/ordering
path; additional issue-window capacity does not help it.

Across measured cases and warmups, both configurations completed 3,264 of
3,264 atomics.  The atomic unit was active for 152,292 cycles at RD32, or
46.66 cycles per uncontended cache-hot AMO.  The L1D also recorded 18,526
lock-barrier wait cycles and 32,582 store-block cycles.  These counters explain
why an uncontended Linux raw-lock pair is expensive on this implementation.

The enabled L1D prefetcher issued 17,417 prefetch events but recorded only one
useful fill.  A source-identical RD32 control with prefetch disabled produced
exactly the same four per-case cycle and instruction totals.  Atomic-active
time changed from 152,292 to 152,290 cycles, and lock-barrier wait time remained
18,526 cycles.  The prefetch counter therefore reflects internal activity, but
prefetch is not causing the measured spinlock cost.

## Relation to the Linux PC histogram

The coprime whole-boot profile attributes 5.351% of samples to the four raw
spinlock functions.  The previously quoted 9.4% combined those samples with
approximately 4.1% in write-side rwsem functions and should not be called a
spinlock percentage.

Within `_raw_spin_lock`, 2,171 of 3,234 samples land on the instruction
immediately before `amoadd.w.aqrl`.  The debug PC therefore attributes an
in-flight atomic stall one instruction early.  That is a line-level attribution
artifact, but the function-level residence is consistent with the measured
46.66-cycle AMO and roughly 170-cycle raw-lock pair.  The microbenchmark makes
the residence plausible; it does not measure the number of Linux lock calls.
