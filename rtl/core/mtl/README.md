# Memory transaction layer

`openrv64_core_mtl` is the architectural memory-policy boundary for the native
cache path. It owns:

- Bare/Sv39 address translation and tagged translation responses;
- L1 ITLB/DTLB, shared L2 TLB, and blocking PTW coordination;
- post-translation PMP arbitration and access-fault generation;
- translation cancellation, replay, and stale-fill suppression;
- SATP/SFENCE invalidation and the ordered PTW/L1D fence handshake; and
- physical transaction admission into L1I and L1D.

The MTL composes the existing L1I and L1D modules but does not own their cache
arrays, miss machinery, or prefetch algorithms. The residual AXI signals exist
only for the explicit cacheless-L1I configuration.

Source layout:

- `mtl.v` owns transaction capture, translation sequencing, PMP arbitration,
  invalidation, and cache composition;
- `tlb.v` and `micro_tlb.v` implement the side-local translation lookasides;
- `tlb_l2.v` implements the shared indexed translation cache; and
- `ptw.v` implements the blocking Sv39 walker and its physical PTE client.

The translation helper modules retain their `openrv64_bus_*` names for source
compatibility. Their ownership and source location are MTL; a later naming-only
change would add review noise without improving the boundary.

`rtl/core/bus/icx_bus.v` is below this boundary. It receives only physical
commands from L1I, L1D, and PTW and performs native ICX arbitration, write-data
forwarding, and response routing. It must not acquire privilege, translation,
PMP, PMA, or architectural-fence policy.

## Required invariants

- PMP is checked after translation and before a physical cache/fabric launch.
- A PMP denial completes locally as an access fault and emits no physical
  request.
- PTW PTE reads are physical S-mode reads and receive their own PMP check.
- Page faults and physical access faults remain distinct through completion.
- SATP/SFENCE invalidation suppresses same-cycle stale TLB/PTW fills.
- A shootdown fence waits until older posted L1D stores can no longer race the
  page-table visibility boundary.
- Cancelled speculative loads may discard their result; accepted stores and
  atomic phases remain irrevocable and must drain.
