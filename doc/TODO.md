# TODO

- [ ] Store buffers
- [ ] Cache
- [ ] Multi-hart
- [ ] Linux
- [ ] Relax translation invalidation for Linux address-space switches: stop
      treating every retiring `satp` write as a global shootdown, preserve
      ASID-tagged L1/L2 TLB entries across `mm` switches, and implement the
      required ASID-reuse/rollover invalidation plus `SFENCE.VMA` address/ASID
      selection. Until then, retain the conservative global barrier.
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
