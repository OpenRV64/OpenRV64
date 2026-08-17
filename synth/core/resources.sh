#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
source_root_arg=${SOURCE_ROOT:-$repo_root}
if [[ "$source_root_arg" == /* ]]; then
    source_root=$source_root_arg
else
    source_root="$repo_root/$source_root_arg"
fi
source_root=$(cd -- "$source_root" && pwd)

yosys_bin=${YOSYS:-yosys}
out_dir_arg=${OUT_DIR:-sim/yosys/core-sky130}
liberty=${LIBERTY:-sim/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib}
abc_constr=${ABC_CONSTR:-synth/sky130/abc.constr}
max_resource_jobs=32

if [[ -n ${RESOURCE_JOBS:-} ]]; then
    resource_jobs=$RESOURCE_JOBS
else
    resource_jobs=$(nproc)
fi
if [[ ! $resource_jobs =~ ^[1-9][0-9]*$ ]]; then
    echo "error: RESOURCE_JOBS must be a positive integer: $resource_jobs" >&2
    exit 2
fi
if (( resource_jobs > max_resource_jobs )); then
    resource_jobs=$max_resource_jobs
fi

if ! yosys_bin=$(command -v "$yosys_bin"); then
    echo "error: Yosys executable not found: ${YOSYS:-yosys}" >&2
    exit 2
fi

for path_var in liberty abc_constr; do
    path=${!path_var}
    if [[ "$path" != /* ]]; then
        printf -v "$path_var" '%s/%s' "$repo_root" "$path"
    fi
done

if [[ ! -f "$liberty" ]]; then
    echo "error: Liberty file does not exist: $liberty" >&2
    exit 2
fi
if [[ ! -f "$abc_constr" ]]; then
    echo "error: ABC constraint file does not exist: $abc_constr" >&2
    exit 2
fi

if [[ "$out_dir_arg" == /* ]]; then
    out_dir=$out_dir_arg
else
    out_dir="$repo_root/$out_dir_arg"
fi
mkdir -p "$out_dir"

mapfile -t core_sources < <(
    cd "$source_root"
    rg --files rtl/core -g '*.v' \
        -g '!rtl/core/exec/vec/**' \
        -g '!rtl/core/regs/rv64-i-vec.v' |
        sort
)
mapfile -t cache_sources < <(
    cd "$source_root"
    rg --files rtl/cache/l1 -g '*.v' | sort
)
source_args=("$source_root/rtl/openrv64_top_3p.v")
for source in "${core_sources[@]}" "${cache_sources[@]}"; do
    source_args+=("$source_root/$source")
done
source_list=$(printf ' "%s"' "${source_args[@]}")

# Current real-branch 3P profile used for the 32x3 bimodal CoreMark run.
# FREE_BRANCHES is an oracle experiment and is deliberately excluded here.
# Trace is disabled because trace-only counters are not deployable core logic.
# The issue-window experiment and the unintegrated FPU are excluded.
elaborate="read_verilog -sv -DSYNTHESIS -I$source_root/rtl$source_list; \
chparam -set ENABLE_RV64M 1 \
        -set RETIRE_DEPTH 8 \
        -set COMPLETION_FORWARD_MASK 0 \
        -set ENABLE_FULL_FORWARDING 1 \
        -set RELAX_WAW 1 \
        -set RELAX_HAZARDS 1 \
        -set FREE_BRANCHES 0 \
        -set ENABLE_ISSUE_WINDOW 0 \
        -set ENABLE_POSTED_STORES 1 \
        -set ENABLE_RV64A 1 \
        -set ENABLE_L1I 1 \
        -set ENABLE_L1D 1 \
        -set ENABLE_TRACE 0 \
        -set ENABLE_PREDECODE_TARGETS 1 \
        -set BP_TYPE 5 \
        -set BP_RAS_ENABLE 1 \
        -set BP_RAS_DEPTH 8 \
        -set BP_BIMODAL_ENTRIES 32 \
        -set BP_BIMODAL_COUNTER_BITS 3 \
        -set BP_BIMODAL_UPDATE_DEPTH 4 \
        openrv64_top_3p; \
hierarchy -check -top openrv64_top_3p;"

# Preserve inferred memories as $mem_v2 cells.  This repository does not ship
# an SRAM macro library, so lowering them with the default `memory` pass would
# silently implement the L1 data arrays as flip-flops and muxes.
pre_abc_flow="proc; flatten -noscopeinfo; opt; memory -nomap; opt; techmap; opt; \
dfflibmap -liberty \"$liberty\";"
abc_flow="abc -liberty \"$liberty\" -constr \"$abc_constr\"; clean -purge;"
map_flow="$pre_abc_flow $abc_flow"

# A fully flattened core produces a roughly 105 MiB BLIF. ABC's default global
# FRAIG/DCH recipe is impractically slow at that size, and its fast recipe's
# buffer-sizing pass fails on a fanout-free node in this netlist. The flat
# cross-check therefore stops after strash/dretime/map. Functional partitions
# retain the normal constrained script above.
flat_map_flow="proc; flatten -noscopeinfo; opt; memory -nomap; opt; techmap; opt; \
dfflibmap -liberty \"$liberty\"; \
abc -script +strash,dretime,map -liberty \"$liberty\" \
    -constr \"$abc_constr\"; \
clean -purge;"

# Keep only reporting boundaries; logic inside every block is flattened.
partition_boundaries="\
setattr -set keep_hierarchy 1 */c:u_core; \
setattr -set keep_hierarchy 1 */c:u_backend; \
setattr -set keep_hierarchy 1 */c:g_fetch_axi.u_fetch; \
setattr -set keep_hierarchy 1 */c:u_bp; \
setattr -set keep_hierarchy 1 */c:u_bp_target; \
setattr -set keep_hierarchy 1 */c:g_decode*.u_decode; \
setattr -set keep_hierarchy 1 */c:u_csrs; \
setattr -set keep_hierarchy 1 */c:u_vector; \
setattr -set keep_hierarchy 1 */t:*openrv64_core_bus*; \
setattr -set keep_hierarchy 1 */t:*openrv64_core_mtl*; \
setattr -set keep_hierarchy 1 */t:*openrv64_core_icx_bus*; \
setattr -set keep_hierarchy 1 */t:*openrv64_bus_tlb*; \
setattr -set keep_hierarchy 1 */t:*openrv64_bus_ptw*; \
setattr -set keep_hierarchy 1 */t:*openrv64_l1d_icx*; \
setattr -set keep_hierarchy 1 */t:*openrv64_l1i_icx*; \
setattr -set keep_hierarchy 1 */c:u_dispatch; \
setattr -set keep_hierarchy 1 */c:u_gpr; \
setattr -set keep_hierarchy 1 */c:u_ex0; \
setattr -set keep_hierarchy 1 */c:u_ex1; \
setattr -set keep_hierarchy 1 */c:u_mem0; \
setattr -set keep_hierarchy 1 */c:u_mem1; \
setattr -set keep_hierarchy 1 */c:u_retire_queue; \
setattr -set keep_hierarchy 1 */c:u_retire_records; \
setattr -set keep_hierarchy 1 */c:u_retire; \
select -clear;"

partition_stat="$out_dir/partitioned-stat.json"
partition_pre_stat="$out_dir/partitioned-pre-abc-stat.json"
partition_hierarchy="$out_dir/partitioned-hierarchy.rpt"
partition_memories="$out_dir/partitioned-memories.rpt"
partition_log="$out_dir/partitioned-yosys.log"
partition_checkpoint="$out_dir/partitioned-pre-abc.il"
partition_workers="$out_dir/partitioned-workers"
flat_stat="$out_dir/flat-stat.json"
flat_log="$out_dir/flat-yosys.log"

echo "[1/3] Mapping functional partitions against Sky130 HD..."
if [[ ${ONLY_FLAT:-0} == 1 ]]; then
    echo "      skipped by ONLY_FLAT=1"
elif (( resource_jobs > 1 )); then
    echo "      preparing one pre-ABC checkpoint"
    "$yosys_bin" -Q -l "$partition_log" -p "$elaborate $partition_boundaries \
        $pre_abc_flow \
        tee -o \"$partition_pre_stat\" stat -liberty \"$liberty\" -json; \
        tee -o \"$partition_hierarchy\" dump */a:keep_hierarchy=1; \
        tee -o \"$partition_memories\" dump -m */t:\$mem_v2; \
        write_rtlil \"$partition_checkpoint\"; \
        read_liberty -lib \"$liberty\"; check;" >/dev/null
    python3 "$script_dir/parallel_map.py" \
        --yosys "$yosys_bin" \
        --checkpoint "$partition_checkpoint" \
        --pre-stat "$partition_pre_stat" \
        --hierarchy "$partition_hierarchy" \
        --liberty "$liberty" \
        --constraint "$abc_constr" \
        --out-stat "$partition_stat" \
        --worker-dir "$partition_workers" \
        --jobs "$resource_jobs"
else
    echo "      RESOURCE_JOBS=1: using serial Yosys/ABC mapping"
    "$yosys_bin" -Q -l "$partition_log" -p "$elaborate $partition_boundaries \
        $map_flow \
        tee -o \"$partition_stat\" stat -liberty \"$liberty\" -json; \
        tee -o \"$partition_hierarchy\" dump */a:keep_hierarchy=1; \
        tee -o \"$partition_memories\" dump -m */t:\$mem_v2; \
        read_liberty -lib \"$liberty\"; check;" >/dev/null
fi

echo "[2/3] Flat whole-core cross-check..."
if [[ ${RUN_FLAT:-0} != 1 && ${ONLY_FLAT:-0} != 1 ]]; then
    echo "      skipped (set RUN_FLAT=1 to attempt the experimental flat flow)"
elif [[ ${REUSE_FLAT:-0} == 1 && -s "$flat_stat" ]]; then
    echo "      reusing existing flat attempt: ${flat_stat#$repo_root/}"
else
    "$yosys_bin" -Q -l "$flat_log" -p "$elaborate $flat_map_flow \
        tee -o \"$flat_stat\" stat -liberty \"$liberty\" -json; \
        read_liberty -lib \"$liberty\"; check;" >/dev/null
fi

echo "[3/3] Building exclusive area table..."
summary_args=(
    --partition-stat "$partition_stat"
    --hierarchy "$partition_hierarchy"
    --memories "$partition_memories"
    --out-dir "$out_dir"
)
if [[ -s "$flat_stat" ]]; then
    summary_args+=(--flat-stat "$flat_stat")
fi
python3 "$script_dir/summarize_resources.py" \
    "${summary_args[@]}"

echo "report: ${out_dir#$repo_root/}/resources.md"
