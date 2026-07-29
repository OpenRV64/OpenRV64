# Unaligned-access verification

## Sv39 Zicclsm page-fault coverage

Status: incomplete.

The 3P Zicclsm engine translates and accesses each naturally aligned
component separately. A page-crossing misaligned access can therefore fault
on its first component or after one or more components have completed. Both
loads and stores require directed coverage.

Current coverage is not sufficient:

- `tb_exec_top_3p.sv` covers a mocked translation page fault on the later
  component of an `LW` beginning at `0x7fff`. It checks load-page-fault and
  `tval=0x8000`.
- There is no equivalent first-component fault or misaligned-store fault.
- `tb_ptw_context.sv` exercises a real Sv39 PTW, but instantiates the default
  1P backend and uses an aligned load. It does not exercise Zicclsm.
- `tb_backend_3p.sv` covers aligned store page/access faults through a mocked
  translation response, not page-crossing Zicclsm behavior.
- Successful Linux and memcpy runs exercise misaligned data movement, not
  directed fault behavior.

### Required directed matrix

Add a full-hierarchy test using the 3P backend, `ENABLE_ZICCLSM=1`, real Sv39
page tables, and two adjacent 4 KiB virtual pages. Do not substitute injected
translation responses for the PTW in this test.

| Operation | Faulting component/page | Required trap |
| --- | --- | --- |
| Misaligned load | First component, low page | Load page fault; `tval` is the original effective address |
| Misaligned load | Later component, high page | Load page fault; `tval` is the first address of the failing component |
| Misaligned store | First component, low page | Store page fault; `tval` is the original effective address |
| Misaligned store | Later component, high page | Store page fault; `tval` is the first address of the failing component |

For each case, check:

- exact exception cause, `tval`, faulting PC, instruction, and retirement
  metadata;
- no architectural retirement or destination-register write on a faulting
  load;
- no physical data request for a component whose translation faulted;
- no memory modification when the first store component faults;
- for a later store fault, the exact bytes written by completed earlier
  components and no writes from the faulting or subsequent components;
- no stale completion, tag leak, deadlock, or unintended request after trap
  entry and pipeline flush; and
- successful instruction retry after mapping the missing page and executing
  the required `SFENCE.VMA`.

Use at least `LW` and `LD` crossings with offsets that produce different
component partitions. Include a case in which the adjacent pages map to
non-contiguous physical pages; the component engine must translate each
virtual component independently.

### Additional fault coverage

- [ ] Repeat the load/store and first/later-component matrix for a translated
      physical/PMP access fault.
- [ ] Exercise readable-but-not-writable and invalid-leaf PTEs so store page
      faults are not represented only by an absent mapping.
- [ ] Delay PTW and memory responses independently to cover backpressure at
      both component boundaries.
- [ ] Retain the mocked execution-level test as a fast unit regression, but
      add a separate target such as `sim-zicclsm-sv39` for the real PTW path.

Acceptance requires the directed 3P Sv39 test to pass independently and as
part of the normal simulation regression.
