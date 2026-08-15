#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
yosys_bin=${YOSYS:-yosys}
output_dir=${OUT_DIR:-$repo_root/build/fpga/xc7a100t/opensbi-smoke}
image_dir=${IMAGE_DIR:-$output_dir/images}
output_edif=${OUTPUT_EDIF:-$output_dir/openrv64_fpga_loader_fixed.edif}
output_json=${OUTPUT_JSON:-$output_dir/openrv64_fpga_loader_fixed.json}
output_stub=${OUTPUT_STUB:-$output_dir/openrv64_fpga_loader_fixed_stub.v}
output_log=${OUTPUT_LOG:-$output_dir/yosys-loader.log}

if ! yosys_bin=$(command -v "$yosys_bin"); then
    echo "error: Yosys executable not found: ${YOSYS:-yosys}" >&2
    exit 2
fi

for image in trampoline-fpga.mem fw_jump-fpga-head.mem \
             fw_jump-fpga-tail.mem payload-fpga.mem openrv64-dtb-fpga.mem; do
    if [[ ! -s "$image_dir/$image" ]]; then
        echo "error: boot image not found: $image_dir/$image" >&2
        exit 2
    fi
done

count_words() {
    awk 'NF { count++ } END { print count + 0 }' "$1"
}

trampoline_words=$(count_words "$image_dir/trampoline-fpga.mem")
firmware_head_words=$(count_words "$image_dir/fw_jump-fpga-head.mem")
firmware_tail_words=$(count_words "$image_dir/fw_jump-fpga-tail.mem")
firmware_words=$((firmware_head_words + firmware_tail_words))
payload_words=$(count_words "$image_dir/payload-fpga.mem")
fdt_words=$(count_words "$image_dir/openrv64-dtb-fpga.mem")

for count in "$trampoline_words" "$firmware_words" "$payload_words" \
             "$fdt_words"; do
    if [[ "$count" -le 0 ]]; then
        echo "error: boot image contains no words" >&2
        exit 2
    fi
done

mkdir -p "$output_dir"

flow="read_verilog -sv -defer -DSYNTHESIS \
    \"$script_dir/ddr3_boot_loader.sv\"; \
chparam -set TRAMPOLINE_INIT_FILE \
        \"$image_dir/trampoline-fpga.mem\" \
        -set FIRMWARE_INIT_FILE \
        \"$image_dir/fw_jump-fpga-head.mem\" \
        -set FIRMWARE_TAIL_INIT_FILE \
        \"$image_dir/fw_jump-fpga-tail.mem\" \
        -set PAYLOAD_INIT_FILE \
        \"$image_dir/payload-fpga.mem\" \
        -set FDT_INIT_FILE \
        \"$image_dir/openrv64-dtb-fpga.mem\" \
        -set TRAMPOLINE_WORDS $trampoline_words \
        -set FIRMWARE_WORDS $firmware_words \
        -set PAYLOAD_WORDS $payload_words \
        -set FDT_WORDS $fdt_words \
        openrv64_fpga_ddr3_boot_loader; \
hierarchy -check -top openrv64_fpga_ddr3_boot_loader; \
rename openrv64_fpga_ddr3_boot_loader openrv64_fpga_loader_fixed; \
synth_xilinx -family xc7 -top openrv64_fpga_loader_fixed -flatten \
    -noiopad -noclkbuf; \
delete t:\$scopeinfo; \
hierarchy -check -top openrv64_fpga_loader_fixed; \
check -noinit; \
write_edif -pvector bra \"$output_edif\"; \
write_json \"$output_json\"; \
blackbox openrv64_fpga_loader_fixed; \
setattr -mod -set black_box 1 =openrv64_fpga_loader_fixed; \
select =openrv64_fpga_loader_fixed; \
write_verilog -blackboxes -selected \"$output_stub\""

cd "$repo_root"
"$yosys_bin" -q -l "$output_log" -p "$flow"

test -s "$output_edif"
test -s "$output_json"
test -s "$output_stub"
printf 'OpenRV64 FPGA loader EDIF: %s\n' "$output_edif"
