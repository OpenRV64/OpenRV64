# OpenRV64 3P physical timing

## What was run, and when (UTC)

| Run | Command | Started | Finished | Primary artifacts |
|---|---|---|---|---|
| Whole-core functional-partition map/timing screen | `make yosys-resources-core-sky130` | 2026-07-21 00:28:33 | 2026-07-21 00:41:50 | `sim/yosys/core-sky130/partitioned-yosys.log` |
| RV64I and RV64M timing cuts | `make yosys-timing-alu LIBERTY=sim/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib ABC_CONSTR=synth/sky130/abc.constr` | 2026-07-21 00:42:03 | 2026-07-21 00:42:28 | `sim/yosys/alu/*.rpt` |
| Frontend replay/predecode timing cuts | `make yosys-timing-frontend-sky130` | 2026-07-21 00:42:33 | 2026-07-21 00:42:37 | `sim/yosys/frontend/*.rpt` |

All three runs used Git `1f46e483f34305a9be2c45f902a9e4c0b7015ee9`
with a dirty working tree. The runs therefore describe the live RTL snapshot,
not the clean commit alone.

| Setting | Value |
|---|---|
| Tool | Yosys 0.66 (`86f2ddebc-dirty`) with ABC |
| Cell library | `sky130_fd_sc_hd__tt_025C_1v80.lib`, TT, 25 C, 1.8 V |
| Library SHA-256 | `ec0e1067a35c8bf20b11e58d1e8ac53326067e4dac84a125cc1b917a3518d0d9` |
| Constraint SHA-256 | `7bc97e5a90f50e8b3f7f46984b55595886869c3b0b9b09b8f752a7dc6574714b` |
| Input driver | `sky130_fd_sc_hd__inv_2` |
| Output load | 10 fF |
| Wire load | None |

## Bottom line

The current RTL does **not** have a supportable whole-core frequency claim.
The pre-layout partition screen already exposes two severe single-cycle cones:

- **CSR/PMP: 118.448 ns**, from `pmpaddr_q[0][2]` to
  `pmp_instr_allow_o`, a reciprocal delay of only **8.4 MHz**;
- **EX1/RV64M: 68.319 ns**, from `div_dividend_q[63]` to
  `result_q[63]`, a reciprocal delay of only **14.6 MHz**.

Unless those are made multicycle with a correct architectural protocol or the
logic is restructured, they dominate. The frontend and normal RV64I ALU are not
the first timing problems.

## Functional-partition timing screen

ABC mapped the retained functional partitions during the area run. The table
reports the worst local path for each exclusive size category. A combined
category uses the slower of its retained modules: retirement queue versus
retirement control, and predictor versus direct-target adder.

The reciprocal column is `1 / delay` for triage. It is **not achieved core
frequency**.

| Functional block | Worst local delay | Reciprocal | Reported path |
|---|---:|---:|---|
| CSR/PMP | 118.448 ns | 8.4 MHz | `pmpaddr_q[0][2]` -> `pmp_instr_allow_o` |
| EX1 integer/M | 68.319 ns | 14.6 MHz | `div_dividend_q[63]` -> `result_q[63]` |
| LSU/MEM pipe | 12.978 ns | 77.1 MHz | `atomic_payload_q[42]` -> internal mux |
| EX0 integer/branch | 9.168 ns | 109.1 MHz | `complete_payload_q[157]` -> internal mux |
| Backend control/forwarding | 9.003 ns | 111.1 MHz | `allocation_meta[276]` -> `train_alloc_next_pc[63]` |
| Dispatch/hazards | 7.925 ns | 126.2 MHz | `retire_rd_addr_3p_i[4]` -> `write_busy_q[2]` |
| MMU + 256-bit AXI | 7.846 ns | 127.4 MHz | `fetch_state_q[1][1]` -> internal mux |
| Fetch/line buffers | 7.220 ns | 138.5 MHz | `consume_pc_q[7]` -> internal mux |
| Frontend/core control | 6.426 ns | 155.6 MHz | `backend_redirect` -> internal mux |
| Branch predictor | 4.835 ns | 206.8 MHz | `resolve_pc_i[3]` -> internal mux |
| Retirement | 4.719 ns | 211.9 MHz | `next_alloc_id_q[2]` -> internal mux |
| Decode | 2.213 ns | 451.8 MHz | `instr_i[24]` -> `rd_addr_o[3]` |
| Integer register file | 2.021 ns | 494.8 MHz | `read_addr_i[16]` -> `read_data_o[250]` |
| Trap/redirect vector | 0.945 ns | 1,058.1 MHz | `redirect_i` -> `vector_target_o[3]` |
| AXI wrapper/glue | no path | n/a | optimized away |

These paths are local to retained hierarchy. A cross-boundary path can be
longer, so this table is a problem locator, not full-core STA.

## Explicit timing cuts

The ALU and frontend harnesses expose combinational cuts. Their primary inputs
stand in for launching register outputs, and their primary outputs stand in for
capturing logic. They include mapped cell delay and the configured driver/load,
but no clock-to-Q, setup, uncertainty, or routed interconnect.

### RV64M

| Cut | Delay | Reciprocal | Critical path |
|---|---:|---:|---|
| RV64M pipeline | 67.873 ns | 14.7 MHz | `div_divisor_q[0]` -> `result_q[62]` |

The independent RV64M cut agrees with the EX1 partition result to within 0.7%,
so the divider path is not a hierarchy-reporting accident.

### Integrated and operation-specific RV64I ALU

| Cut | Delay | Reciprocal |
|---|---:|---:|
| Full RV64I ALU | 4.758 ns | 210.2 MHz |
| ADD | 4.591 ns | 217.8 MHz |
| AUIPC | 4.456 ns | 224.4 MHz |
| SUB | 3.426 ns | 291.9 MHz |
| ADDW | 2.969 ns | 336.8 MHz |
| SUBW | 2.911 ns | 343.5 MHz |
| SLT | 1.894 ns | 527.9 MHz |
| SLL | 1.691 ns | 591.5 MHz |
| SRL | 1.682 ns | 594.4 MHz |
| SLTU | 1.658 ns | 603.3 MHz |
| SRA | 1.528 ns | 654.5 MHz |
| SRLW | 1.353 ns | 739.2 MHz |
| SLLW | 1.341 ns | 745.6 MHz |
| SRAW | 1.281 ns | 780.5 MHz |
| OR | 0.245 ns | 4,085.8 MHz |
| XOR | 0.227 ns | 4,412.3 MHz |
| AND | 0.149 ns | 6,690.8 MHz |
| LUI | no combinational path | n/a |

The full ALU is slower than the isolated ADD because it includes operation
selection and its result mux. LUI optimizes to wiring and therefore has no ABC
combinational path to report.

### Frontend

| Cut | Delay | Reciprocal | Critical path |
|---|---:|---:|---|
| Full resident replay | 6.080 ns | 164.5 MHz | `if_id_pc_i[2]` -> `replay_instr_o[30]` |
| Resident replay lookup | 2.698 ns | 370.7 MHz | `target_pc_i[3]` -> `instr_o[1]` |
| Predecode offset | 0.690 ns | 1,450.1 MHz | `instr_i[4]` -> `immediate[2]` |

The full replay cut contains the direct-target add, resident tag lookup, line
selection, and replay output selection. It is materially slower than lookup
alone.

## Interpretation limits and next required run

This is pre-layout cell-delay characterization, not signoff STA. In particular:

- ABC reports `WireLoad = none`; interconnect is absent;
- functional hierarchy boundaries cut end-to-end paths;
- there is no SDC clock, generated clocks, false/multicycle path audit, or IO
  timing budget;
- setup/hold, clock-to-Q, skew, jitter, and uncertainty are absent;
- there is no placement, routing, extraction, CTS, congestion, or SI analysis.

The next meaningful frequency result requires a fully flattened or physically
partitioned whole-core netlist, explicit SDC constraints, SRAM/register-file
macros, and placed-and-routed STA. Until then, quoting 164, 210, or 800 MHz as
the core frequency would be wrong. The current unconstrained RTL timing screen
instead says to fix or correctly constrain PMP and RV64M first.
