# TODO

- [ ] Store buffers
- [ ] Cache
- [ ] Multi-hart
- [ ] Linux
- [ ] Quarantine or remove the first-generation scalar CCX compatibility stack
      (`hart_legacy_adapter`, scalar `crossbar`/`axi_master`, and
      `wrapper_{1h,2h,4h,nh}`) after its remaining useful tests are transferred
      to the native 512-bit CCX path.
- [ ] Rename the internal `OPENRV64_BUS_AXI` selector to
      `OPENRV64_BUS_CCX`; AXI is now only an external transport or the explicit
      cacheless-L1I fallback, not the selected internal core-memory protocol.
