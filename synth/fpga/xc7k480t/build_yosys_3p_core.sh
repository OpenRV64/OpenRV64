#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
yosys_bin=${YOSYS:-yosys}
output_dir=${OUT_DIR:-$repo_root/build/fpga/xc7k480t/core-3p}
output_edif=${OUTPUT_EDIF:-$output_dir/openrv64_core_3p.edif}
output_json=${OUTPUT_JSON:-$output_dir/openrv64_core_3p.json}
output_stub=${OUTPUT_STUB:-$output_dir/openrv64_core_3p_stub.v}
output_log=${OUTPUT_LOG:-$output_dir/yosys-3p-core.log}
rv64m_source=${RV64M_SOURCE:-rtl/core/exec/alu/rv64-m-fpga.v}

# Match the repository's full single-hart OpenSBI/Linux 3P profile. These are
# explicit so a utilization result cannot silently change with simulator
# defaults.
retire_depth=${RETIRE_DEPTH:-32}
issue_window_depth=${ISSUE_WINDOW_DEPTH:-$retire_depth}
phys_reg_count=${PHYS_REG_COUNT:-31}
rename_mode=${RENAME_MODE:-0}
banked_gpr=${BANKED_GPR:-0}
fpga_gpr_lutram=${FPGA_GPR_LUTRAM:-0}
issue_window=${ISSUE_WINDOW:-1}
speculation_window=${SPECULATION_WINDOW:-1}
branch_completion_forward_mask=${BRANCH_COMPLETION_FORWARD_MASK:-1}
relax_waw=${RELAX_WAW:-1}
store_queue_depth=${STORE_QUEUE_DEPTH:-4}
l1i_cache_bytes=${L1I_CACHE_BYTES:-16384}
l1d_cache_bytes=${L1D_CACHE_BYTES:-16384}
enable_l1i=${ENABLE_L1I:-1}
enable_l1d=${ENABLE_L1D:-1}
l1d_retired_store_mshr_canonical=${L1D_RETIRED_STORE_MSHR_CANONICAL:-0}
l2_tlb_entries=${L2_TLB_ENTRIES:-256}
l2_tlb_ways=${L2_TLB_WAYS:-4}
ptw_pte_cache_entries=${PTW_PTE_CACHE_ENTRIES:-64}
bp_type=${BP_TYPE:-8}

if ! yosys_bin=$(command -v "$yosys_bin"); then
    echo "error: Yosys executable not found: ${YOSYS:-yosys}" >&2
    exit 2
fi
if [[ ! -s "$repo_root/$rv64m_source" ]]; then
    echo "error: FPGA RV64M source not found: $rv64m_source" >&2
    exit 2
fi

mkdir -p "$output_dir"

printf 'OPENRV64 XC7K480T 3P YOSYS CONFIG retire=%s scheduler=%s phys=%s rename=%s banked_gpr=%s gpr_lutram=%s l1i=%s l1d=%s\n' \
    "$retire_depth" "$issue_window_depth" "$phys_reg_count" \
    "$rename_mode" "$banked_gpr" "$fpga_gpr_lutram" \
    "$enable_l1i" "$enable_l1d"

mapfile -t rtl_sources < <(
    cd "$repo_root"
    make RV64M_EXEC_SRC="$rv64m_source" -pn 2>/dev/null |
        awk '/^CORE_3P_AXI_SRCS :=/ {
            for (i = 3; i <= NF; i++)
                if (!seen[$i]++ && $i !~ /\/debug\/stub[.]v$/)
                    print $i
        }'
)

if (( ${#rtl_sources[@]} == 0 )); then
    echo "error: could not extract CORE_3P_AXI_SRCS from make" >&2
    exit 2
fi

source_list=" \"$repo_root/rtl/openrv64_top_3p.v\""
for source in "${rtl_sources[@]}"; do
    source_list+=" \"$repo_root/$source\""
done

# Preserve the architectural RTL hierarchy.  Flattening the complete 3P core
# creates one extremely large ABC network and also turns cross-module
# ready/valid cycles into a single optimizer SCC.  Individual component
# reports may flatten below their explicitly selected module boundary.
flow="read_verilog -sv -defer -DSYNTHESIS -I$repo_root/rtl$source_list; \
chparam -set RESET_VECTOR 2147483648 \
        -set ENABLE_RV64M 1 \
        -set ENABLE_RV64ZBB 1 \
        -set HPM_COUNTERS 8 \
        -set RETIRE_DEPTH $retire_depth \
        -set ISSUE_WINDOW_DEPTH $issue_window_depth \
        -set PHYS_REG_COUNT $phys_reg_count \
        -set RENAME_MODE $rename_mode \
        -set BANKED_GPR $banked_gpr \
        -set FPGA_GPR_LUTRAM $fpga_gpr_lutram \
        -set COMPLETION_FORWARD_MASK 0 \
        -set BRANCH_COMPLETION_FORWARD_MASK $branch_completion_forward_mask \
        -set ENABLE_FULL_FORWARDING 0 \
        -set RELAX_WAW $relax_waw \
        -set RELAX_HAZARDS 0 \
        -set FREE_BRANCHES 0 \
        -set ENABLE_EQ_BRANCH_PAIRING 1 \
        -set ENABLE_ISSUE_WINDOW $issue_window \
        -set ENABLE_SPECULATION_WINDOW $speculation_window \
        -set ENABLE_POSTED_STORES 1 \
        -set ENABLE_ZICCLSM 1 \
        -set STORE_QUEUE_DEPTH $store_queue_depth \
        -set ENABLE_RV64A 1 \
        -set ENABLE_L1I $enable_l1i \
        -set ENABLE_L1D $enable_l1d \
        -set L1I_CACHE_BYTES $l1i_cache_bytes \
        -set L1D_CACHE_BYTES $l1d_cache_bytes \
        -set L1D_RETIRED_STORE_MSHR_CANONICAL $l1d_retired_store_mshr_canonical \
        -set L2_TLB_ENTRIES $l2_tlb_entries \
        -set L2_TLB_WAYS $l2_tlb_ways \
        -set PTW_PTE_CACHE_ENTRIES $ptw_pte_cache_entries \
        -set ENABLE_TRACE 0 \
        -set ENABLE_PREDECODE_TARGETS 1 \
        -set ENABLE_FETCH_CAROUSEL 1 \
        -set ENABLE_FETCH_ALT_LOOKASIDE 3 \
        -set ENABLE_FETCH_ALT_CONFIDENCE_GATE 1 \
        -set BP_TYPE $bp_type \
        -set BP_RAS_ENABLE 1 \
        -set BP_RAS_DEPTH 8 \
        -set BP_BIMODAL_ENTRIES 32 \
        -set BP_BIMODAL_COUNTER_BITS 3 \
        -set BP_BIMODAL_UPDATE_DEPTH 4 \
        -set BP_GSHARE_ENTRIES 256 \
        -set BP_GSHARE_COUNTER_BITS 3 \
        -set BP_BTB_ENTRIES 256 \
        -set BP_BTB_TAG_BITS 16 \
        -set BP_INFLIGHT_DEPTH 16 \
        openrv64_top_3p; \
hierarchy -check -top openrv64_top_3p; \
rename openrv64_top_3p openrv64_xc7k480t_core_3p; \
	synth_xilinx -family xc7 -top openrv64_xc7k480t_core_3p -noiopad -noclkbuf; \
delete t:\$scopeinfo; \
hierarchy -check -top openrv64_xc7k480t_core_3p; \
check -noinit; \
stat -tech xilinx; \
write_edif -pvector bra \"$output_edif\"; \
write_json \"$output_json\"; \
blackbox openrv64_xc7k480t_core_3p; \
setattr -mod -set black_box 1 =openrv64_xc7k480t_core_3p; \
select =openrv64_xc7k480t_core_3p; \
write_verilog -blackboxes -selected \"$output_stub\""

cd "$repo_root"
"$yosys_bin" -l "$output_log" -p "$flow"

test -s "$output_edif"
test -s "$output_json"
test -s "$output_stub"

dsp_count=$(grep -c '"type": "DSP48E1"' "$output_json" || true)
if (( dsp_count == 0 )); then
    echo "error: full 3P RV64M multiplier did not map to DSP48E1" >&2
    exit 1
fi

printf 'OPENRV64 XC7K480T 3P YOSYS PASS edif=%s json=%s dsp48e1=%d\n' \
    "$output_edif" "$output_json" "$dsp_count"
