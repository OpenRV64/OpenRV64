# MYIR MYD-J7A100T FPGA target

This directory contains the OpenRV64 board boundary for the MYIR
MYD-J7A100T carrier and MYC-J7A100T SoM.

## Board facts

- FPGA marking: `XC7A100T-2FGG484I`
- Vivado part: `xc7a100tfgg484-2`
- Differential 200 MHz oscillator: `sys_clk_p/n`, positive pin `R4`,
  `DIFF_SSTL15`
- Active-low board reset: `rst_n`, pin `P17`, `LVCMOS33`
- USB-UART receive at the FPGA: `uart_rx_i`, pin `R18`, `LVCMOS33`
- USB-UART transmit from the FPGA: `uart_tx_o`, pin `T18`, `LVCMOS33`

Clock, reset, and DDR3 data come from MYIR's `07_ddr_test.zip` reference
project. UART data comes from `MYC-J7A100T-PinList-V1.0.xlsx`, version 1.0
dated 2024-04-17. `board-pins.csv` records the non-DDR board footprint.
MIG's generated XDC owns the complete DDR3 package-pin map.

The supplied archive has SHA-256
`669caabbc0937433ee831ec8827fd0bfe023ed57e8513740601a89cbb9c3ea36`.
See `vendor/mig_7series_0/README.md` for the exact MIG-file provenance and
the one required speed-grade edit.

## DDR3 configuration

Vivado 2026.1 regenerates Xilinx `mig_7series` 4.2 from MYIR's project:

- two `MT41J128M16XX-125` components;
- 32-bit DDR3 data bus;
- 512 MiB total capacity;
- 800 MT/s memory interface;
- 200 MHz MIG system-clock input;
- 100 MHz, 256-bit native application interface;
- ECC disabled.

The board top uses one clock wizard/MMCM to generate the 200 MHz MIG input
and a conservative default 10 MHz core clock from R4. A toggle-handshake rate bridge
crosses scalar and PTW traffic between the 10 MHz core and 100 MHz MIG UI
domains. Both clocks come from the same clock wizard and remain statically
related: Vivado times every bundled-data and control crossing in both
directions; there is no asynchronous-clock waiver. The platform remains in
reset until MIG reports successful calibration.

The adapter implements:

- blocking aligned 64-bit scalar reads and byte-masked writes;
- one outstanding scalar request per clock domain;
- 64-byte PTW ICX reads, assembled from two 256-bit MIG reads;
- one outstanding PTW request per clock domain;
- PTW fences after all older adapter traffic has drained.

ICX write-data traffic is not implemented. That is sufficient for the
current 1P core because its external ICX client is the page-table walker,
which emits reads and fences. The external-memory seam deliberately rejects
the 3P platform configuration.

This instantiates the real vendor MIG controller/PHY, not the repository's
behavioral DDR timing model. Seven-series MIG is generated controller logic
using dedicated FPGA clocking, I/O delay, and SerDes resources; it is not a
monolithic hardened DDR controller block.

## CPU profile and boot boundary

The target is the 1P RV64MA core with the BP6 gshare-plus-BTB predictor.
The 4 KiB reset ROM waits indirectly for DDR calibration because the entire
platform is held in reset, then its existing reset sequence jumps from
`0x1000` to `0x8000_0000`. The default `MTIME_DIVISOR=10` produces a 1 MHz
timebase from the 10 MHz core clock.

This is not yet a Linux-bootable image. DDR3 is volatile and the design has
no path that loads OpenSBI, a device tree, kernel, or initramfs into DDR
before the ROM jumps there. The next required block is a loader: for example,
a ROM UART loader, QSPI/SD boot stage, or JTAG-to-memory path combined with a
way to hold the CPU in reset. A successful bitstream build does not prove
physical DDR calibration on a board.

## Verified implementation

The Vivado 2026.1 route completed on `xc7a100tfgg484-2` with:

- 62,646 of 62,646 routable nets fully routed and no routing errors;
- WNS `+0.561 ns`, WHS `+0.045 ns`, and no failing timing endpoints;
- clean, timed 10 MHz core to 100 MHz UI crossings in both directions;
- 39,901 LUTs (62.94%), 30,999 registers (24.45%), no block RAM, and no
  DSPs.

Bitstream DRC has no errors. Its five warnings and the two CDC warnings are
inside the generated MIG hierarchy. The remaining missing-I/O-delay
methodology warning is for the asynchronous board-reset input, not an
unconstrained internal endpoint.

## Build and tests

Generated IP, checkpoints, reports, and the bitstream are written under the
ignored `build/` directory.

```sh
# RTL elaboration with generated-IP stubs
/home/bill/bin/vivado -mode batch -nolog -nojournal \
  -source synth/fpga/xc7a100t/build.tcl -tclargs rtl

# Full synthesis with the real generated IP
/home/bill/bin/vivado -mode batch -nolog -nojournal \
  -source synth/fpga/xc7a100t/build.tcl -tclargs synth

# Route an existing post-synthesis checkpoint and write the bitstream
/home/bill/bin/vivado -mode batch -nolog -nojournal \
  -source synth/fpga/xc7a100t/implement.tcl

# Or run synthesis through bitstream generation in one process
/home/bill/bin/vivado -mode batch -nolog -nojournal \
  -source synth/fpga/xc7a100t/build.tcl -tclargs bitstream
```

An optional second argument selects another core clock, such as 40 MHz:

```sh
/home/bill/bin/vivado -mode batch -nolog -nojournal \
  -source synth/fpga/xc7a100t/build.tcl -tclargs bitstream 40
```

The focused CDC/native-interface test is:

```sh
iverilog -g2012 -I rtl -s tb_mig_native_memory_cdc \
  -o /tmp/openrv64_mig_cdc_tb.vvp \
  synth/fpga/xc7a100t/mig_native_memory.sv \
  synth/fpga/xc7a100t/mig_native_memory_cdc.sv \
  synth/fpga/xc7a100t/tb_mig_native_memory_cdc.sv
vvp /tmp/openrv64_mig_cdc_tb.vvp
```
