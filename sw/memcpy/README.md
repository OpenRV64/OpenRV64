# memcpy benchmarks

This directory intentionally contains only the project's own bare-metal memcpy
benchmarks. The copy of Linux's RISC-V `memcpy.S` was removed on 2026-08-07
because it is GPL-2.0-only and should not be distributed as though it were
covered by the repository's CERN-OHL-P-2.0 license.

Comparisons against Linux should build the implementation from a separate Linux
source checkout under its GPL-2.0-only terms. Do not copy it into this directory.
