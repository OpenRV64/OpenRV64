# CSR TODO

## Implementation-policy controls

- [ ] Define machine-mode implementation-policy CSR control for safety versus
      performance behavior that is currently fixed at build time. The first
      concrete policy bit should control strict device/uncached-write ordering,
      with strict mode as the reset default: drain older memory operations to
      the coherent point before issuing the write, wait for the non-posted
      device completion, and prevent younger memory operations from passing it.
      Do not implement this as an unconditional full L2 drain, dirty writeback,
      or system-wide fence. Specify CSR privilege, WARL behavior, reset and
      context-switch expectations, then audit other suitable policy features
      for inclusion without making architectural correctness optional.
