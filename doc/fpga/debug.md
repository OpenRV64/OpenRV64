# FPGA diagnostic debug path

Status date: 2026-08-25 UTC

## Scope

The FPGA debug path is a first-party bring-up aid for the single-hart, one-pipe
MYD-J7A100T image. It can:

- trigger on completed external-memory transactions, a writeback-stage PC, an
  absolute core cycle, or a cycle delay measured from a PC match;
- retain a hardware hit record and raise PLIC source 32;
- let an OpenSBI M-mode handler save the architectural trap context;
- upload and execute a small M-mode probe from dual-port block RAM;
- read the scalar DDR bridge cache, a passive retirement ring, and a rolling
  platform-UART TX log through JTAG; and
- resume the interrupted hart or reset the complete board design.

This is not a RISC-V Debug Transport Module or Debug Module. It does not
implement DMI, `dmcontrol`, `dmstatus`, abstract commands, program-buffer
access, standard halt/resume, single-step, or an OpenOCD target. The transport
is a private Xilinx `BSCANE2` USER1 register, and stopping the hart is an
ordinary machine-external interrupt followed by an OpenSBI wait loop. Do not
describe it as architectural external debug.

The path is also not non-intrusive. Interrupt entry advances beyond the
hardware trigger point, OpenSBI changes machine state while handling the
interrupt, and the optional all-instruction serializer deliberately changes
core execution. The hardware hit record, retirement history, and OpenSBI trap
snapshot answer different questions and must not be conflated.

## Data and control flow

```text
XSDB host tool
    |
    | 960-bit Xilinx USER1 scan, protocol version 17
    v
openrv64_fpga_jtag_snoop                 JTAG/DRCK domain
    | trigger configuration and commands
    | request/acknowledgement toggles
    v
core-clock trigger logic -------------------------------+
    |                                                    |
    | fixed hardware hit record                          | indexed readback
    | level interrupt                                    | cache/snapshot/stub/
    v                                                    | trace/UART memories
external_irq_i[28] -> PLIC source 32 -> M-context MEIP   |
    |                                                    |
    v                                                    |
OpenSBI openrv64_debug_irq()                             |
    | write trap context to snapshot BRAM                |
    | optionally call uploaded M-mode stub               |
    | wait for JTAG resume                               |
    v                                                    |
snapshot CONTROL ack -> clear hardware hit/IRQ <---------+
```

There are three relevant clock domains:

- `BSCANE2` DRCK and Update-DR operate in the external JTAG domain. The
  constraints model them as independent 10 MHz clocks and declare them
  asynchronous to functional clocks.
- Trigger detection, snapshot/stub control, retirement capture, and the UART
  ring operate in the core/platform clock domain.
- Scalar DDR cache readback crosses into the 100 MHz MIG UI domain.

Multi-bit JTAG command bundles are held stable by the JTAG-side registers while
toggle requests cross through synchronizers. Indexed memory operations return
an acknowledgement toggle, result index, and data. The host rejects a result
whose source, index, or request/acknowledgement state does not match. This is a
manually paced diagnostic CDC protocol, not a general asynchronous bus.

## Enablement and platform integration

`openrv64_platform.FPGA_DEBUG_ENABLE` controls the SoC-side memories, PLIC
machine context, and debug ports. When it is zero, the PLIC retains its original
S-mode-only context and the debug outputs are tied off. The FPGA OpenSBI system
currently sets it to one and connects the USER1 probe unconditionally.

The current FPGA path is limited to one hart. `tools/build-opensbi.sh` and
`tools/make-fpga-sd-image.py` reject `OPENRV64_FPGA_DEBUG=1` or `--fpga-debug`
with a hart count other than one.

The FPGA-debug DT has:

- root compatible strings `"openrv64,fpga-debug"` and
  `"openrv64,platform"`;
- PLIC context 0 connected to hart 0 machine-external interrupt 11; and
- PLIC context 1 connected to hart 0 supervisor-external interrupt 9.

The dedicated trigger occupies external interrupt vector bit 28, which maps to
architectural PLIC source ID 32. The RTL PLIC contains 33 sources because the
Ethernet source remains source 33. The OpenSBI overlay registers source 32 as
an active-high level interrupt owned by M mode. Linux continues to use the
S-mode context.

Two debug regions are intercepted inside the existing PLIC top-level decode:

| Physical range | Size | Function | CPU access | JTAG access |
| --- | ---: | --- | --- | --- |
| `0x0c30_0000..0x0c30_0fff` | 4 KiB | M-mode snapshot | 64-bit read/write plus status/control | 512 indexed 64-bit reads |
| `0x0c30_4000..0x0c30_7fff` | 16 KiB | Executable M-mode workspace | instruction/data read; byte writes only while the trigger is asserted | 2,048 indexed 64-bit reads/writes |

These are vendor diagnostic subregions, not architectural PLIC registers. The
rolling UART and retirement memories are not CPU-mapped.

## Trigger and hit-record semantics

`openrv64_fpga_jtag_snoop` retains the first matching event while armed. A hit
sets `hit_valid`, freezes the fixed hit record, and holds `debug_irq_o` high
until software acknowledges the trigger or JTAG explicitly clears it.

### Memory trigger

A memory trigger observes a completed transaction on the shared scalar/PTW
path after scalar-versus-PTW arbitration. This point includes transactions
served by the DDR bridge cache as well as transactions that miss and reach MIG.
It is not an MMIO-bus trigger and it is not a retirement trigger.

The match is:

```text
(physical_address & mask) == (configured_address & mask)
```

The host can independently select reads, writes, scalar traffic, and PTW
traffic. The default host mask ignores the low three address bits. The hit
record contains the completed physical address, read data, write data, byte
strobes, error flag, selected source, write direction, hardware PC/instruction
observation, and core cycle.

### PC trigger

The PC comparator uses `dbg_pc`, which is registered with the 1P core's current
WB payload together with its instruction and exact forwarded `rs1` and `rs2`
values. A PC hit records those two operand values in the fields otherwise used
for memory read and write data.

This is a WB observation, not an architectural breakpoint. Without the
diagnostic serializer, the payload can be observed before or while retirement
is backpressured. The later OpenSBI `mepc` is the interrupt boundary after the
trigger and need not equal the hit PC.

### Cycle triggers

An absolute cycle trigger fires when the free-running probe counter equals the
configured target. `trigger-cycle` reads the live counter and arms a target at
a requested delta, with a minimum host-side delta of 10,000 cycles.

USER1 version 17 also supports PC-relative delayed sampling. With PC and cycle
matching enabled together, the first PC match is only an epoch marker. It does
not interrupt. The hardware raises the interrupt after the configured number
of additional core cycles. The eventual hit PC/instruction are whatever the
WB probe carries at that delayed cycle.

`sample-pc-delay` arms this mode, resets the board, waits for the hit, and then
requires a fresh, stable, `COMPLETE` snapshot whose `mcycle` is at or after the
hardware hit. This avoids accepting a completed snapshot left in BRAM from a
previous reset generation.

## Interrupt, snapshot, and resume lifecycle

The debug interrupt is a level request. The hardware holds it until the
OpenSBI handler acknowledges through the snapshot control register.

1. The trigger freezes the hardware hit record and asserts external interrupt
   vector bit 28.
2. The platform synchronizes the level, PLIC source 32 becomes pending, and
   context 0 raises MEIP.
3. OpenSBI claims source 32 and calls `openrv64_debug_irq()`.
4. The handler writes snapshot state `CAPTURING`, the trap frame, CSRs, and
   GPRs to snapshot BRAM.
5. If a valid stub descriptor is present, the handler executes the stub before
   marking the snapshot complete.
6. The handler writes snapshot state `COMPLETE` and spins until JTAG toggles
   resume.
7. The handler writes `RESUMING`, writes bit 0 of snapshot `CONTROL`, and
   returns. That control write clears resume-pending and pulses the hardware
   trigger acknowledgement. The hit level falls, and normal PLIC completion
   can finish.

Snapshot MMIO registers are:

| Address | Access | Meaning |
| --- | --- | --- |
| `0x0c30_0ff0` | read | bit 0 resume pending; bit 1 trigger active |
| `0x0c30_0ff8` | write | bit 0 acknowledges resume and the active trigger |

The BRAM words written by snapshot format version 2 are:

| Word(s) | Meaning |
| ---: | --- |
| 0 | magic `0x4f525636534e4150` (`ORV6SNAP`) |
| 1 | snapshot version, currently 2 |
| 2 | state: 1 capturing, 2 complete, 3 resuming |
| 3 | hardware IRQ, expected 32 |
| 4..5 | `mcycle`, `minstret` |
| 6..11 | `mcause`, `mtval`, `mtval2`, `mtinst`, `mepc`, `mstatus` |
| 12..19 | `satp`, `mie`, `mip`, `sstatus`, `sepc`, `scause`, `stval`, `mhartid` |
| 20..51 | `x0` through `x31` from the OpenSBI trap context |
| 52..56 | stub state, entry offset, payload bytes, return value, descriptor magic |

The snapshot is a copy. Editing it through any available path does not modify
the live trap context that OpenSBI will resume. There is no timeout in the wait
loop; forgetting `resume` deliberately leaves the hart in M mode.

`resume` disarms and clears the existing trigger. `resume-pc` performs resume,
clear, and PC re-arm in one Update-DR transaction so repeated PC observations
do not have an unarmed interval between separate host commands.

## Executable M-mode workspace

The workspace is a true dual-port `2048 x 64` block RAM. JTAG can read or write
complete words without CPU cooperation. The CPU can fetch and read throughout
the region. CPU data writes are accepted only while the synchronized debug
trigger is asserted because the unified platform bus has no privilege
sideband; this prevents ordinary S-mode execution from replacing a future
M-mode probe.

The last two words form a commit descriptor:

| Word | Byte offset | Meaning |
| ---: | ---: | --- |
| 2046 | `0x3ff0` | magic `0x4f52563653545542` (`ORV6STUB`) |
| 2047 | `0x3ff8` | payload bytes `[63:32]`, ABI version `[31:16]`, entry offset `[15:0]` |

`load-stub` accepts 1 through 16,368 raw bytes. It invalidates the magic word,
uploads the payload, zero-pads the final partial word, writes metadata, writes
the magic last, and reads the descriptor back. OpenSBI re-reads the committed
magic after a load fence and executes only ABI version 1 with a four-byte-
aligned entry inside the payload.

ABI version 1 is an RV64 LP64 function call:

```c
unsigned long stub(volatile unsigned long *snapshot, /* a0, 0x0c300000 */
                   unsigned long snapshot_bytes,     /* a1, 0x0ff0 */
                   volatile unsigned long *workspace,/* a2, 0x0c304000 */
                   unsigned long workspace_bytes,    /* a3, 0x3ff0 */
                   unsigned long hwirq);              /* a4, 32 */
```

Code must be linked at `0x0c30_4000` or be position-independent. A returning
stub must preserve the standard callee-saved registers and the active OpenSBI
stack. Its return value is recorded in snapshot word 55. A non-returning stub
intentionally takes ownership of the hart.

There is no exception sandbox. An illegal instruction, bad M-mode access,
stack corruption, nested trap, or ABI violation can strand OpenSBI or reset the
machine. Do not modify the workspace over JTAG while the CPU is executing from
it. Space after the committed payload can be used for bulk result data, but it
is the probe's responsibility not to overwrite itself or the descriptor.

The repository supplies three freestanding examples:

- `tools/fpga-debug-ping.S`: return the constant `0x51`;
- `tools/fpga-debug-dtb-probe.S`: inspect Linux DT data through MPRV and an
  explicit page-table walk; and
- `tools/fpga-debug-strcmp-probe.S`: compare the MPRV and software-walk views
  of the strings involved in the FPGA bring-up failure.

The corresponding Python readers decode result data left in the workspace.
They are targeted diagnostics, not a stable general probe API beyond the ABI
above.

## Passive retirement history

When core trace output is retained in the synthesized core, a separate
`256 x 64` ring records one packed word per retired instruction:

| Bits | Meaning |
| ---: | --- |
| 63:32 | low 32 bits of retired PC |
| 31 | architectural destination write valid |
| 30:26 | destination register |
| 25:0 | low 26 bits of destination value |

The ring exposes the 64-bit total retirement count at trace index 256 and the
next write index in bits 7:0 plus frozen state in bit 8 at index 257. The host
uses those values to return the newest requested records in chronological
order.

This format is deliberately lossy. It cannot reconstruct a full PC or a full
register result and is not an architectural trace stream. Capture stops when
the synchronized trigger level reaches the platform, so a small CDC/interrupt
tail can exist after the original hardware match.

The split FPGA flow must build the core DCP with
`FPGA_OPENSBI_ENABLE_TRACE=1`. Setting trace only in the surrounding platform
cannot restore ports already constant-folded from a core DCP.

## Optional all-instruction serialization

`DEBUG_SERIALIZE_ALL_1P` is a diagnostic core parameter. When enabled, it:

- permits one instruction to issue, then blocks younger issue until that
  instruction retires and its accepted WB payload has left the stage;
- disables speculative taken prediction and uses resolved control flow; and
- retains a resolved redirect until the serial owner has vacated WB.

The mode creates an empty pipeline boundary between instructions, which makes
WB PC/operand sampling and short retirement histories easier to interpret. It
also changes throughput, predictor behavior, redirect timing, and overlap. A
failure seen only with serialization, or hidden by serialization, must not be
presented as normal-core behavior.

For a split FPGA build, set
`FPGA_OPENSBI_DEBUG_SERIALIZE_ALL_1P=1` while building the core DCP. The
surrounding system cannot change this property in an already generated DCP.

## Rolling UART TX capture

The UART trace is a 16 KiB circular buffer with a 64-bit producer byte count.
It records `tx_pop`: the byte that actually begins transmission through the
platform NS16550. It does not record RX and does not record the separate
pre-core FPGA boot-status transmitter selected before `boot_release`.

Bytes are accumulated into 64-bit words so BRAM writes do not depend on byte-
enable inference. A JTAG request reads four aligned words and returns one
32-byte burst. The RTL merges the current partial staging word into a burst, so
the newest one through seven bytes do not have to wait for a complete BRAM
word.

The ring retains the newest `min(total_bytes, 16384)` bytes. `dump-uart`
reconstructs chronological order and rejects the dump if the producer count
changes during collection; enter the debug interrupt or otherwise stop console
output before taking a full consistent dump. `follow-uart` tolerates ongoing
production, reports counter resets, reports the exact number of bytes lost if
the producer laps the reader, and can stop on a text marker.

## Scalar DDR cache readback

The USER1 readback mux can inspect any of the 1,024 direct-mapped, 32-byte
scalar DDR cache lines in `openrv64_fpga_mig_scalar_bridge`. A read returns one
of four 64-bit data lanes or the stored tag plus the valid bit. For a valid tag,
the host reconstructs the physical line address as:

```text
0x8000_0000 + (tag << 15) + (index << 5)
```

This port is observational. It does not fill, invalidate, or otherwise maintain
the cache, and it is not coherent with any independent MIG writer.

## Host tool

Set the hardware-server URL explicitly. The wrapper uses AMD XSDB from the
Vivado 2026.1 installation and defaults to a 1 MHz JTAG frequency; the accepted
range is 1 Hz through 10 MHz.

```sh
export FPGA_HW_SERVER_URL=TCP:<hw-server-host>:3121
tools/fpga-jtag-snoop status
```

The common commands are:

| Operation | Commands |
| --- | --- |
| Inspect/control | `status`, `wait-hit [seconds]`, `clear`, `resume`, `reset` |
| Arm trigger | `arm-mem`, `arm-pc`, `arm-pc-delay`, `arm-cycle`, `trigger-cycle` |
| Repeated PC work | `resume-pc`, `walk-pc-add-range`, `walk-pc-reg-ne`, `walk-pc-reg-eq`, `sample-pc-delay` |
| Read hardware | `read-cache`, `read-snapshot`, `dump-snapshot`, `dump-retire-trace` |
| Manage probe | `read-stub`, `write-stub`, `dump-stub`, `load-stub`, `clear-stub` |
| Read UART | `read-uart`, `read-uart-lane`, `dump-uart`, `follow-uart` |

Run the command without valid arguments to print exact argument ranges. The
thin `tools/fpga-jtag-uart-tail` wrapper invokes `follow-uart` directly.

### PC snapshot example

```sh
tools/fpga-jtag-snoop arm-pc 0xffffffff803e5194
tools/fpga-jtag-snoop wait-hit 300
tools/fpga-jtag-snoop read-snapshot 2
tools/fpga-jtag-snoop dump-retire-trace 64
tools/fpga-jtag-snoop dump-snapshot
tools/fpga-jtag-snoop resume
```

Do not accept snapshot word 2 until it is 2 (`COMPLETE`). `wait-hit` proves
only that the hardware trigger fired; OpenSBI snapshot entry occurs later.

### Uploaded probe example

```sh
run/run run/cfg/fpga-debug-dtb-probe-build.cfg
tools/fpga-jtag-snoop load-stub \
  build/fpga/xc7a100t/debug-dtb-probe/dtb-probe.bin 0
tools/fpga-jtag-snoop arm-pc <target-pc>
tools/fpga-jtag-snoop wait-hit 300
tools/fpga-jtag-snoop dump-snapshot
run/run run/cfg/fpga-debug-dtb-probe-read-hw.cfg
tools/fpga-jtag-snoop resume
```

Upload only while no stub is executing. `load-stub` commits the descriptor;
the stub runs on the next debug interrupt, not during upload.

### UART examples

```sh
tools/fpga-jtag-snoop read-uart 0
tools/fpga-jtag-snoop dump-uart build/fpga/uart-console.bin
tools/fpga-jtag-uart-tail --from retained
tools/fpga-jtag-uart-tail --from new \
  --until 'SBI HSM extension detected' --timeout-seconds 300
tools/fpga-jtag-uart-tail --from 3848
```

`--from retained` starts at the oldest byte still in the ring, `--from new`
starts at the current producer position, and a number is an absolute producer
byte position.

### Reset behavior

`reset` is a full design reset, not a core-only reset. It clears the 200 MHz
reset-hold counter, reruns MIG calibration and the boot loader, and then
releases the SoC. FPGA configuration and JTAG-domain trigger configuration
remain intact. The intended reset-trigger sequence is therefore:

```sh
tools/fpga-jtag-snoop arm-pc <pc>
tools/fpga-jtag-snoop reset
tools/fpga-jtag-snoop wait-hit 300
```

## USER1 protocol version 17

The transport is a 960-bit USER1 data register with command signature
`0x4f525636` (`ORV6`). A capture-only scan shifts zero into the register and
cannot execute a command; state changes only when Update-DR sees the signature.
TAP Test-Logic-Reset does not clear persistent command state because XSDB
commonly enters that state before a raw scan. FPGA configuration GSR supplies
the initial values.

Host software should use `tools/fpga-jtag-snoop` rather than constructing raw
scans. The current command fields are documented here for RTL/tool maintenance:

| Command bit(s) | Meaning |
| ---: | --- |
| 31:0 | signature `ORV6` |
| 32..40 | arm, read, write, scalar, PTW, PC, cycle, resume, clear |
| 41..47 | cache read, snapshot read, stub read, stub write, UART read, reset, retirement-trace read |
| 127:64, 191:128 | memory address and mask |
| 255:192, 319:256 | PC address and mask |
| 383:320 | absolute cycle target or PC-relative delay |
| 409:400 | cache index |
| 411:410 | cache or UART data lane |
| 412 | cache tag select |
| 424:416 | snapshot index |
| 426:416 | shared stub/UART/trace index |
| 511:448 | stub write data |

Important status fields are:

| Status bit(s) | Meaning |
| ---: | --- |
| 31:0, 39:32 | signature and protocol version |
| 40..48 | armed, resume pending, hit valid, scalar/PTW/PC/cycle reason, write, error |
| 49..59 | active match configuration, cache lane/tag, PC-delay-started |
| 127:64..383:320 | configured memory/PC targets and masks, cycle target |
| 447:384 | hit cycle; UART burst word 0 when UART readback is selected |
| 511:448 | hit PC; UART burst word 1 when UART readback is selected |
| 575:512 | hit memory address; UART burst word 2 when UART readback is selected |
| 639:576 | hit read data or PC `rs1`; UART burst word 3 when selected |
| 703:640 | hit write data or PC `rs2` |
| 711:704 | hit write strobes |
| 783:720, 815:784 | live cycle and hit instruction |
| 817:816 | readback source: cache, snapshot, stub/trace, or UART |
| 818..831 | request toggle, acknowledgement toggle, cache valid, result index |
| 895:832 | selected 64-bit read result |
| 959:896 | UART total-byte count when UART readback is selected |

For UART bursts, XSDB integer expressions truncate above 64 bits. The Tcl tool
therefore captures the 960-bit result as raw hexadecimal text and extracts all
four words without wide-integer arithmetic.

## Build and validation

Use managed run configurations so commands, source state, configuration, and
results remain together under `run/log/<run-id>/`.

Focused RTL and BRAM mapping:

```sh
run/run run/cfg/fpga-jtag-snoop-directed.cfg
run/run run/cfg/fpga-jtag-readback-directed.cfg
run/run run/cfg/fpga-debug-snapshot-synth.cfg
```

The directed group covers PLIC M/S contexts, USER1 commands and triggers,
snapshot resume/acknowledgement, stub write gating and readback, retirement
records, UART partial/wrapped bursts, the UART observation tap, scalar-memory
CDC, and execution from the workspace by the 1P core. The synthesis checks
require the memories to map to XC7 block RAM; the current stub result is five
`RAMB36E1` blocks, four for the 16 KiB workspace and one for retirement history,
and the UART ring is four `RAMB36E1` blocks.

Build the matching OpenSBI/DT and SD image with:

```sh
run/run run/cfg/fpga-debug-sd-image.cfg
```

The OpenSBI check requires the debug handler and final-exit hook in the ELF and
the M/S PLIC context mapping in the generated DTS. `FPGA_SD_DEBUG=1` is required
when constructing the raw SD image; a normal OpenSBI image does not contain the
handler merely because the RTL includes USER1.

### Recorded source-matched v17 result

The current routed diagnostic artifact is:

- bitstream:
  `build/fpga/xc7a100t/experiments/1p-serialize-all-pc-delay-jtag-v17-20mhz/openrv64_myd_j7a100t_sd_boot.bit`;
- size: 3,826,012 bytes;
- SHA-256:
  `c11d8bba58523161633908a6bd65e8bd748ccf97ca6ca5eec4df629e9b8cc613`;
- core: one-pipe, all-instruction serialization enabled, retirement trace
  enabled, BP type 2, 20 MHz;
- post-route setup WNS `+0.114 ns` and hold WHS `+0.028 ns`;
- 64,802 of 64,802 routable nets routed, with zero routing errors; and
- 35,133 slice LUTs, 20,939 slice registers, 13,953 slices, 29 block-RAM
  tiles, and 16 DSPs.

The managed build finished PASS, the bitstream timing check passed, remote
programming reported FPGA startup HIGH, and USER1 reported protocol version 17.
On the physical board, a source-matched `sample-pc-delay` run used PC
`0xffffffff803e5194` as an epoch, triggered exactly 3,000,000 core cycles later,
and obtained a fresh snapshot with state 2, hardware IRQ 32, and snapshot
`mcycle` after the hardware hit. Evidence is under:

```text
run/log/fpga-jtag-snoop-directed-20260825T103346Z/
run/log/fpga-debug-snapshot-synth-20260825T013727Z/
run/log/fpga-serialize-all-pc-delay-jtag-v17-20mhz-20260825T103533Z/
run/log/fpga-program-serialize-all-pc-delay-jtag-v17-20mhz-20260825T104728Z/
run/log/fpga-jtag-serialize-all-v17-pc-delay-sample-hw-20260825T180130Z/
```

That is physical proof of the programmed v17 transport, delayed trigger,
machine-interrupt path, snapshot readback, and resume-wait state on the
exercised single-hart image. It is not a Linux boot PASS, architectural debug
compliance, multi-hart validation, CDC signoff, or proof that every USER1
command has been exercised on that exact bitstream.

Historical FPGA artifact and boot results remain in `doc/fpga/smoke-test.md`
and `doc/fpga/linux-boot.md`. Do not transfer a result from one bitstream or SD
image to another without source and artifact matching.

## Implementation inventory

| Area | Files |
| --- | --- |
| USER1 transport and constraints | `synth/fpga/xc7a100t/jtag_snoop.sv`, `synth/fpga/xc7a100t/jtag_snoop.xdc` |
| FPGA integration | `synth/fpga/xc7a100t/opensbi_system.sv`, `synth/fpga/xc7a100t/openrv64_myd_j7a100t_opensbi_top.sv`, `synth/fpga/xc7a100t/mig_scalar_bridge.sv` |
| SoC memories and PLIC routing | `rtl/soc/debug/*.sv`, `rtl/soc/platform.sv`, `rtl/soc/bus/mem_map.v`, `rtl/plic/plic.v` |
| Core WB operands and serializer | `rtl/core/rv64_top.v`, `rtl/openrv64_top.sv`, `rtl/core/exec/exec_top_1p.v`, `rtl/core/dispatch/dispatch_1p.v` |
| UART observation | `rtl/periph/uart/uart.v`, `rtl/soc/debug/uart_trace_mem.sv` |
| OpenSBI integration | `sw/opensbi-fpga-debug/debug.c`, `sw/opensbi-fpga-debug/objects.mk`, `sw/opensbi.dts`, `tools/build-opensbi.sh` |
| Host access and probes | `tools/fpga-jtag-snoop`, `tools/fpga-jtag-snoop.tcl`, `tools/fpga-jtag-uart-tail`, `tools/fpga-debug-*` |
| Directed tests | `tb/tb_fpga_jtag_snoop.sv`, `tb/tb_fpga_debug_snapshot.sv`, `tb/tb_fpga_debug_stub.sv`, `tb/tb_fpga_uart_trace.sv`, `tb/tb_fpga_debug_exec.sv` |
| Managed workflows | `run/cfg/fpga-jtag-*.cfg`, `run/cfg/fpga-debug-*.cfg`, `scripts/make/opensbi.mk`, `scripts/make/platform-builds.mk` |

## Known limitations

- Only the single-hart, one-pipe FPGA configuration is supported. The 3P top
  currently drives the new debug operand outputs to zero.
- Triggered stopping is interrupt-latent and requires functional PLIC, MEIP,
  OpenSBI, snapshot MMIO, and DDR-backed OpenSBI stack state. It cannot debug a
  failure before those pieces operate.
- The fixed hit record is one deep. A second event is discarded until clear or
  acknowledgement.
- A PC match observes the registered WB probe, not a standard precise
  breakpoint or guaranteed retirement boundary.
- The retirement ring is lossy and freezes only after the synchronized trigger
  reaches it.
- The snapshot is not writable live context, and the uploaded stub has no fault
  containment.
- UART capture covers only the platform UART after `boot_release`; full dumps
  require a stable producer count.
- JTAG-domain trigger state survives the debug reset command. Use `clear` when
  that persistence is not wanted.
- Full reset does not reconfigure FPGA SRAM. Programming another bitstream or a
  power/configuration event does.
- The path provides diagnostic evidence. It does not establish RISC-V Debug
  Specification compliance, secure-debug authentication, production DFT,
  side-channel closure, or CDC signoff.
