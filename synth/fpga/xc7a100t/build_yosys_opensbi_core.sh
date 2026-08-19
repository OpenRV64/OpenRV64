#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
yosys_bin=${YOSYS:-yosys}
output_dir=${OUT_DIR:-$repo_root/build/fpga/xc7a100t/opensbi-smoke}
output_edif=${OUTPUT_EDIF:-$output_dir/openrv64_fpga_core.edif}
output_json=${OUTPUT_JSON:-$output_dir/openrv64_fpga_core.json}
output_stub=${OUTPUT_STUB:-$output_dir/openrv64_fpga_core_stub.v}
output_log=${OUTPUT_LOG:-$output_dir/yosys-core.log}
rv64m_source=${RV64M_SOURCE:-rtl/core/exec/alu/rv64-m-fpga.v}

if ! yosys_bin=$(command -v "$yosys_bin"); then
    echo "error: Yosys executable not found: ${YOSYS:-yosys}" >&2
    exit 2
fi

mkdir -p "$output_dir"

if [[ ! -s "$repo_root/$rv64m_source" ]]; then
    echo "error: FPGA RV64M source not found: $rv64m_source" >&2
    exit 2
fi

mapfile -t rtl_sources < <(
    cd "$repo_root"
    make RV64M_EXEC_SRC="$rv64m_source" -pn 2>/dev/null |
        awk '/^(CORE_SRCS|PLATFORM_SRCS) :=/ {
            for (i = 3; i <= NF; i++)
                if (!seen[$i]++ && $i !~ /\/debug\/stub[.]v$/)
                    print $i
        }'
)

if (( ${#rtl_sources[@]} == 0 )); then
    echo "error: could not extract RTL sources from the make database" >&2
    exit 2
fi

source_list=""
for source in "${rtl_sources[@]}"; do
    source_list+=" \"$repo_root/$source\""
done

# This is the exact core profile instantiated by opensbi_system.sv.  The
# generated top has no parameters so Vivado can consume it as an EDIF cell.
flow="read_verilog -sv -defer -DSYNTHESIS -I$repo_root/rtl$source_list; \
chparam -set RESET_VECTOR 4096 \
        -set BACKEND_CONFIG 0 \
        -set BUS_CONFIG 0 \
        -set RETIRE_DEPTH 16 \
        -set PHYS_REG_COUNT 31 \
        -set STORE_QUEUE_DEPTH 4 \
        -set ENABLE_ISSUE_WINDOW 0 \
        -set ENABLE_SPECULATION_WINDOW 0 \
        -set ENABLE_ZICCLSM 1 \
        -set ENABLE_RV64M 1 \
        -set ENABLE_RV64ZBB 0 \
        -set ENABLE_RV64A 1 \
        -set ENABLE_FORWARDING 1 \
        -set ENABLE_LOAD_FORWARDING 0 \
        -set PMP_ACTIVE_ENTRIES 4 \
        -set FPGA_GPR_LUTRAM 1 \
        -set L1D_CACHEABLE_BASE 2147483648 \
        -set L1D_CACHEABLE_SIZE 268435456 \
        -set GENBUS_TLB_ENTRIES 4 \
        -set PTW_PTE_CACHE_ENTRIES 0 \
        -set ENABLE_TRACE 0 \
        -set ENABLE_PREDECODE_TARGETS 0 \
        -set BP_TYPE 5 \
        -set BP_RAS_ENABLE 0 \
        -set BP_RAS_DEPTH 8 \
        -set BP_BIMODAL_ENTRIES 32 \
        -set BP_BIMODAL_COUNTER_BITS 3 \
        -set BP_BIMODAL_UPDATE_DEPTH 4 \
        openrv64_top; \
hierarchy -check -top openrv64_top; \
rename openrv64_top openrv64_fpga_core; \
synth_xilinx -family xc7 -top openrv64_fpga_core -flatten -noiopad -noclkbuf; \
delete t:\$scopeinfo; \
hierarchy -check -top openrv64_fpga_core; \
check -noinit; \
write_edif -pvector bra \"$output_edif\"; \
write_json \"$output_json\"; \
blackbox openrv64_fpga_core; \
setattr -mod -set black_box 1 =openrv64_fpga_core; \
select =openrv64_fpga_core; \
write_verilog -blackboxes -selected \"$output_stub\""

cd "$repo_root"
"$yosys_bin" -q -l "$output_log" -p "$flow"

test -s "$output_edif"
test -s "$output_json"
test -s "$output_stub"
if [[ "$rv64m_source" == */rv64-m-fpga.v ]]; then
    dsp_count=$(grep -c '"type": "DSP48E1"' "$output_json" || true)
    if (( dsp_count == 0 )); then
        echo "error: FPGA RV64M multiplier did not map to DSP48E1 cells" >&2
        exit 1
    fi
    printf 'OpenRV64 FPGA RV64M DSP48E1 cells: %d\n' "$dsp_count"
fi
gpr_lutram_count=$(grep -c '"type": "RAM32M"' "$output_json" || true)
if (( gpr_lutram_count == 0 )); then
    echo "error: FPGA GPR did not map to RAM32M cells" >&2
    exit 1
fi
printf 'OpenRV64 FPGA GPR RAM32M cells: %d\n' "$gpr_lutram_count"
printf 'OpenRV64 FPGA core EDIF: %s\n' "$output_edif"
