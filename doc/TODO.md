# TODO

## Correctness

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
- [ ] Complete the L1I/L1D decomposition begun under
      `rtl/core/cache/l1/`: move demand-MSHR mutation, waiter/fill-buffer
      ownership, L1D posted-store query/drain/completion state, and L1I/L1D
      prefetch policy out of the composition wrappers. Before moving state,
      replace testbench and Verilator hierarchical state probes with explicit
      debug/observability interfaces.
- [ ] Add and evaluate a native 256-bit CCX mode in which every 64-byte cache
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
- [ ] Before enabling more than one hart, replace the disabled CCX `lock`
      mechanism with coherence-aware atomic ownership and forward-progress
      rules; the current single-hart path intentionally never asserts it.
      Wire the L1D `atomic_active` line into a probe retry/NACK/ACK protocol;
      the evictable `atomic_hot` prefetch directory is not correctness state.
- [ ] Quarantine or remove the first-generation scalar CCX compatibility stack
      (`hart_legacy_adapter`, scalar `crossbar`/`axi_master`, and
      `wrapper_{1h,2h,4h,nh}`) after its remaining useful tests are transferred
      to the native 512-bit CCX path.
- [ ] Rename the internal `OPENRV64_BUS_AXI` selector to
      `OPENRV64_BUS_CCX`; AXI is now only an external transport or the explicit
      cacheless-L1I fallback, not the selected internal core-memory protocol.
