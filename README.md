OpenRV64 is a 64-bit RISC-V core and SoC supporting RV64IMA (without C); its build flows use conventional `riscv64-*` toolchains. It has a 16 KiB 4-way L1I, 16 KiB 8-way write-through L1D, and 256 KiB 8-way shared L2.

It boots Linux under Verilator.

3 wide, speculative issue, in-order retire.

The main trick is that it's extremely parameterizable: You can pick your speculation windows, your branch predictor, different bus widths, etc.

Backnds to AXI4 (64-512b) or WB (64-512 which isn't compliant, best to use this for periphs, doesn't burst or outstanding now).

Next steps:

1. Multiprocessing, ICX is designed for 4 cores, atomics need much more testing/validation, as do shootdowns, etc. #update now boots linux and passes test suite with 2/4 harts
2. Integrate fp unit - in progress
3. Have non-RVV vector units want to test in main design, currently they're in their own harness.
4. Performance results are promising in cycle-model comparisons, but they are not silicon benchmarks. See `doc/performance/current.md`.
5. PD is the biggest concern, timing isn't terrible (though mul is still bad), but mostly there are CAM structures and the forwarding network is unpleasant, need a better design here.
6. OOO, but this is a ways off.
7. We make it rain with prefetches, I have confidence gating in some branch predictors, but the whole algorithm needs tuning.
8. satp still drains and restarts translation state but preserves the tagged main TLB; sfence.vma remains a global local-hart hammer and needs selective invalidation.
9. l2 latency at 11 l2u is too aggressive, not viable in pd - Update: This is being fixed, both on the L1D side and the ICX->L2 side.
10. 0 DFT whatsoever, we need that.

Why no -C: It really does muck up the frontend, variable length jumps, everything. I think I don't have a choice, but I like the frontend now, it's aesthetic I guess. - Update: -C is coming, trying to minimize the frontend impact.
