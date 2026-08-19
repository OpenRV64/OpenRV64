# TODO

## Correctness

- [ ] Replace the temporary M-mode branch-predictor redirect suppression with
      context-safe target speculation. The tournament BTB currently tags only
      `PC[25:10]`, so S-mode kernel and M-mode firmware PCs with identical low
      26 bits can alias. Before re-enabling M-mode redirects, context-tag,
      partition, or flush target state and ensure malformed speculative
      physical targets become squashable access faults instead of reaching L2.
      Add a directed trap/return BTB-alias regression.
- [ ] Do not call SMP viable until four harts run concurrently on the full
      FPGA and extended user-mode and kernel-mode meat-grinder workloads pass.
      Directed simulation, OpenSBI HSM release, and a Linux prompt are
      necessary gates, not substitutes for that hardware stress.
- [ ] Implement lower-privilege WFI interception: honor `mstatus.TW` in S-mode
      and the bounded U-mode WFI rule. The current WFI sleep/wake path is
      correct for OpenSBI's M-mode HSM wait but does not raise the required
      lower-privilege illegal-instruction exception.
- [ ] Extend the directed four-hart MSIP/`SFENCE.VMA` shootdown test through
      the real OpenSBI SBI IPI and Linux `flush_tlb_*` paths, including target
      masks, completion acknowledgement, ASID reuse, and concurrent PTE
      update stress.

## General

- [ ] Store buffers
- [ ] Cache
- [ ] Evaluate disabling FAL completely. Compare the current mode-3,
      two-slot configuration against a true no-FAL control under the matched
      512-bit CoreMark and Linux profiles. The control must also suppress the
      mode-0 L1I two-path branch-prefetch fallback while leaving ordinary
      demand, carousel, and next-line fetching unchanged; include timing and
      area evidence as well as cycle counters.
- [ ] Complete the L1I/L1D decomposition begun under
      `rtl/core/cache/l1/`: move demand-MSHR mutation, waiter/fill-buffer
      ownership, L1D posted-store query/drain/completion state, and L1I/L1D
      prefetch policy out of the composition wrappers. Before moving state,
      replace testbench and Verilator hierarchical state probes with explicit
      debug/observability interfaces.
- [ ] Add and evaluate a native 256-bit ICX mode in which every 64-byte cache
      line transfer uses two fixed 256-bit data beats. Keep this distinct from
      the existing `burst_len` field, which denotes multiple consecutive cache
      lines. Define beat-index/last and response ownership through L1I/L1D,
      the line crossbar, coherent home/L2, and the memory bridge, then compare
      wiring/area and sustained bandwidth against the current 512-bit mode.
- [ ] Multi-hart
- [ ] Linux
- [ ] Complete selective translation invalidation: `satp` writes now flush the
      current-context micro-TLBs while retaining the ASID-tagged main TLB.
      Add VPN/ASID-selective `SFENCE.VMA` handling and directed Linux
      ASID-reuse/rollover coverage; the current fence implementation still
      conservatively flushes the complete local hierarchy.
- [ ] Replace the temporary L1D atomic admission hammer, which drains the
      entire posted-store queue before a locked read, with targeted ordering
      against the older stores required by the AMO ordering mode.
- [ ] Before enabling more than one hart, replace the disabled ICX `lock`
      mechanism with coherence-aware atomic ownership and forward-progress
      rules; the current single-hart path intentionally never asserts it.
      Wire the L1D `atomic_active` line into a probe retry/NACK/ACK protocol;
      the evictable `atomic_hot` prefetch directory is not correctness state.
- [ ] Quarantine or remove the first-generation scalar ICX compatibility stack
      (`hart_legacy_adapter`, scalar `crossbar`/`axi_master`, and
      `wrapper_{1h,2h,4h,nh}`) after its remaining useful tests are transferred
      to the native 512-bit ICX path.
- [ ] Rename the internal `OPENRV64_BUS_AXI` selector to
      `OPENRV64_BUS_ICX`; AXI is now only an external transport or the explicit
      cacheless-L1I fallback, not the selected internal core-memory protocol.
