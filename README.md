RiscV64 core and SoC supporting riscv64ima (no c). 16K 4-way L1I + 16K 8-way writethrough L1D, 256K 8-way SA shared L2.

Boots to linux under verilator.

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

Why no -C: It really does muck up the frontend, variable length jumps, everything. I think I don't have a choice, but I like the frontend now, it's aesthetic I guess.

Blatant self-promotion:

   Metric          OpenRV64 D4    A53-class HPI GEM3
  ──────────────  ─────────────  ───────────────
   Cycles               63,661          118,286
  ──────────────  ─────────────  ───────────────
   Instructions         59,411           51,204
  ──────────────  ─────────────  ───────────────
   IPC                  0.9332           0.4329
  ──────────────  ─────────────  ───────────────
   Bytes/cycle           3.088            1.662

That being said, timed ddr slowed down coremarks, need to open up the l1i fetch unit again.
