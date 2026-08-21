#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
yosys_bin=${YOSYS:-yosys}
output_dir=${OUT_DIR:-$repo_root/build/fpga/xc7a100t/opensbi-smoke}
project_dir=${PROJECT_DIR:-$output_dir/project}
system_stub=${SYSTEM_STUB:-$output_dir/openrv64_fpga_opensbi_system_stub.v}
mig_stub=${MIG_STUB:-$project_dir/generated-ip/mig_7series_0/mig_7series_0_stub.v}
output_edif=${OUTPUT_EDIF:-$output_dir/openrv64_myd_j7a100t_opensbi_top.edif}
output_json=${OUTPUT_JSON:-$output_dir/openrv64_myd_j7a100t_opensbi_top.json}
output_log=${OUTPUT_LOG:-$output_dir/yosys-board.log}

if ! yosys_bin=$(command -v "$yosys_bin"); then
    echo "error: Yosys executable not found: ${YOSYS:-yosys}" >&2
    exit 2
fi
for stub in "$system_stub" "$mig_stub"; do
    if [[ ! -s "$stub" ]]; then
        echo "error: required board partition stub not found: $stub" >&2
        exit 2
    fi
done

mkdir -p "$output_dir"

flow="read_verilog -lib -specify +/xilinx/cells_sim.v; \
read_verilog -lib +/xilinx/cells_xtra.v; \
read_verilog -sv -defer -DSYNTHESIS -DOPENRV64_FPGA_SYSTEM_NETLIST \
    \"$system_stub\" \"$mig_stub\" \
    \"$script_dir/rgmii_io.sv\" \
    \"$script_dir/openrv64_myd_j7a100t_opensbi_top.sv\"; \
hierarchy -check -top openrv64_myd_j7a100t_opensbi_top; \
synth_xilinx -family xc7 -top openrv64_myd_j7a100t_opensbi_top -flatten \
    -noiopad -noclkbuf; \
delete t:\$scopeinfo; \
hierarchy -check -top openrv64_myd_j7a100t_opensbi_top; \
check -noinit; \
write_edif -pvector bra \"$output_edif\"; \
write_json \"$output_json\""

cd "$repo_root"
"$yosys_bin" -q -l "$output_log" -p "$flow"

test -s "$output_edif"
test -s "$output_json"
printf 'OpenRV64 FPGA board EDIF: %s\n' "$output_edif"
