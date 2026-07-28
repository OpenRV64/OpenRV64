# MYIR MIG configuration

`mig_a_vendor.prj` is copied unchanged from:

```text
07_ddr_test.zip
07_ddr_test/ddr_test.srcs/sources_1/ip/mig_7series_0/mig_a.prj
```

The archive SHA-256 is
`669caabbc0937433ee831ec8827fd0bfe023ed57e8513740601a89cbb9c3ea36`.
The unchanged project-file SHA-256 is
`8eb409ddb209a620ed9553bd69bf07fd75ba8fa05860ea43a06e66d91b072dfc`.

The reference project targets `xc7a100tfgg484-1`, but the MYC-J7A100T
module is populated with `XC7A100T-2FGG484I`. Vivado refuses to regenerate
MIG when those speed grades differ. `mig_a_xc7a100t_2.prj` changes only:

```xml
<TargetFPGA>xc7a100t-fgg484/-1</TargetFPGA>
```

to:

```xml
<TargetFPGA>xc7a100t-fgg484/-2</TargetFPGA>
```

All memory geometry, timing, voltage, native-interface, and package-pin
settings remain byte-for-byte identical. The derived-file SHA-256 is
`086ce7a33e09f418ea6fd50c0a06a5c36b35d2bd8e5e7a3dec0d5ecb025f063d`.

Vivado 2026.1 creates a fresh `mig_7series` 4.2 instance from the derived
project file under the ignored target `build/` directory.
