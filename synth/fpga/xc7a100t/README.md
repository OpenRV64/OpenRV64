# MYIR MYD-J7A100T FPGA target

This directory currently contains a clean board footprint, not a functional
OpenRV64 FPGA system.

Target device: `XC7A100T-2FGG484I` (`xc7a100tfgg484-2`).

`myd_j7a100t.xdc` independently restates package-pin and voltage facts for the
200 MHz input clock, reset, 32-bit DDR3, USB-UART, four-bit microSD, and both
copper Ethernet PHYs.  The copper ports are RGMII.  They are not SGMII, XGMII,
or the board's separate SFP+ transceiver interfaces.

`openrv64_myd_j7a100t_top.sv` is a safe pad-shell draft.  It loops UART RX back
to TX, tri-states microSD and MDIO, holds both PHYs in reset, and holds DDR3 in
reset.  It exists to validate the footprint before controller integration; it
must not be treated as a functional bitstream.

## Provenance and generated IP boundary

The constraint file is repository-owned CERN-OHL-P-2.0 source.  It contains no
MYIR HDL and no AMD/Xilinx-generated IP.  Package assignments are factual data
verified from MYIR's freely downloadable `MYC-J7A100T Pinouts Description`
version 1.0 (2024-04-17) and the user-supplied `07_ddr_test.zip` DDR example.

Do not check generated MIG RTL, checkpoints, or implementation products into
the repository.  Generate them into the ignored `build/` directory.  MIG must
provide its own internal PHY placement and timing constraints in addition to
the board package assignments in `myd_j7a100t.xdc`.

The RGMII package pins and 125 MHz receive clocks are constrained.  RGMII
input/output delays are intentionally not guessed: the final values depend on
the unidentified PHY model, PCB delays, and whether its RGMII-ID delay mode is
strapped or programmed.  The final design is not timing-complete until those
facts are known and corresponding min/max delays are added.

The current pin and electrical-standard check is:

```sh
/home/bill/bin/vivado -mode batch -nolog -nojournal \
  -source synth/fpga/xc7a100t/check_io.tcl
```
