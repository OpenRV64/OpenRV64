RiscV64 core and SoC supporting riscv64ima (no c). 16K 4-way L1I + 16K 8-way writethrough L1D, 256K 8-way SA shared L2.

Boots to linux under verilator, passes act4 compliance for ima too.

3 wide, speculative issue, in-order retire.

The main trick is that it's extremely parameterizable: You can pick your speculation windows, your branch predictor, different bus widths, etc.

Backnds to AXI4 (64-512b) or WB (64-512 which isn't compliant, best to use this for periphs, doesn't burst or outstanding now).

Next steps:

1. Multiprocessing, CCX is designed for 4 cores, atomics need much more testing/validation, as do shootdowns, etc.
2. Integrate fp unit
3. Have non-RVV vector units want to test in main design, currently they're in their own harness.
4. Performance, it seems pretty solid, close to an a53 at 1/3 the size. Haven't pushed it, but much of performance work was using coremarks to design the frontend, then simple things like streams for everything memory.
5. PD is a concern, timing isn't terrible (though mul is still bad), but mostly there are CAM structures and the forwarding network is unpleasant, need a better design here.
6. OOO, but this is a ways off.
7. This is actually first, ordered an Artix-7 100t, need to validate under a full distribution like debian, might have to recompile due to lack of -C.
8. We make it rain with prefetches, I have confidence gating in some branch predictors, but the whole algorithm needs tuning.
9. satp is a massive hammer, as is sfence.vma, need to do a better job on pruning vs absolute desolation.
10. l2 latency at 11 l2u is too aggressive, not viable in pd.

Why no -C: It really does muck up the frontend, variable length jumps, everything. I think I don't have a choice, but I like the frontend now, it's aesthetic I guess.

| Coremarks: Metric    | OpenRV64 3P, prefetch on | gem5 HPI proxy |
| -------------------- | -----------------------: | -------------: |
| Cycles               |                   65,572 |         71,443 |
| Retired instructions |                   52,547 |         58,695 |
| IPC                  |                   0.8014 |         0.8216 |
| ISA                  |                    RV64I |        AArch64 |
| Result               |                     PASS | PASS/reference |

| Kernel | Logical bytes | OpenRV64 cycles | OpenRV64 instr. | OpenRV64 IPC | OpenRV64 B/cycle | HPI cycles | HPI instr. | HPI IPC | HPI B/cycle | Cycle ratio |
| :----- | ------------: | --------------: | --------------: | -----------: | ---------------: | ---------: | ---------: | ------: | ----------: | ----------: |
| Copy   |       131,072 |          44,223 |          20,497 |       0.4635 |            2.964 |     73,584 |     20,485 |  0.2784 |       1.781 |       1.664 |
| Scale  |       131,072 |          49,484 |          40,977 |       0.8281 |            2.649 |     75,786 |     32,772 |  0.4324 |       1.730 |       1.532 |
| Add    |       196,608 |          83,911 |          43,027 |       0.5128 |            2.343 |    117,784 |     43,012 |  0.3652 |       1.669 |       1.404 |
| Triad  |       196,608 |          88,605 |          59,411 |       0.6705 |            2.219 |    118,286 |     51,204 |  0.4329 |       1.662 |       1.335 |

This is on a ddr3 model which is hopefully accurate, feel free to take a look under rtl/soc/memory/timing_ddr3.v
