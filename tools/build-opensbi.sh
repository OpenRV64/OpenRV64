#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_root=${OPENSBI_BUILD_DIR:-"${repo_root}/build/opensbi"}
source_dir=${OPENSBI_SOURCE_DIR:-"${build_root}/src"}
output_dir="${build_root}/out"
artifact_dir="${build_root}/artifacts"
defconfig_name=openrv64_defconfig
defconfig_path="${source_dir}/platform/generic/configs/${defconfig_name}"

opensbi_ref=${OPENSBI_REF:-v1.9}
opensbi_v19_commit=cbf9f6734dd85a982c63e3cb5db7ffe09da839ca
opensbi_url=https://github.com/riscv-software-src/opensbi.git
opensbi_cross=${OPENSBI_CROSS_COMPILE:-riscv64-linux-gnu-}
opensbi_debug=${OPENSBI_DEBUG:-}
bare_cross=${RISCV_BARE_CROSS_COMPILE:-riscv64-elf-}
jobs=${OPENSBI_JOBS:-$(nproc)}

trampoline_addr=0x80000000
firmware_addr=0x80100000
payload_addr=0x80200000
fdt_addr=${OPENSBI_FDT_ADDR:-0x8ff00000}
memory_size=${OPENSBI_MEMORY_SIZE:-0x10000000}
zicclsm=${OPENRV64_ZICCLSM:-1}

if [[ "${zicclsm}" != 0 && "${zicclsm}" != 1 ]]; then
    echo "build-opensbi.sh: OPENRV64_ZICCLSM must be 0 or 1" >&2
    exit 2
fi
zicclsm_cpp_args=()
if [[ "${zicclsm}" == 1 ]]; then
    zicclsm_cpp_args=(-DOPENRV64_ZICCLSM)
fi

for tool in git make dtc python3 awk \
            "${opensbi_cross}gcc" "${opensbi_cross}objcopy" \
            "${opensbi_cross}readelf" \
            "${bare_cross}gcc" "${bare_cross}objcopy"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "build-opensbi.sh: missing required tool: ${tool}" >&2
        exit 2
    fi
done

mkdir -p "${build_root}" "${artifact_dir}"

if [[ ! -d "${source_dir}/.git" ]]; then
    git clone --depth 1 --branch "${opensbi_ref}" \
        "${opensbi_url}" "${source_dir}"
else
    rm -f "${defconfig_path}"
    if [[ -n "$(git -C "${source_dir}" status --short)" ]]; then
        echo "build-opensbi.sh: refusing to replace changes in ${source_dir}" >&2
        exit 2
    fi
    git -C "${source_dir}" checkout --detach "${opensbi_ref}" >/dev/null
fi

cp "${repo_root}/sw/opensbi_defconfig" "${defconfig_path}"
trap 'rm -f "${defconfig_path}"' EXIT

actual_commit=$(git -C "${source_dir}" rev-parse HEAD)
if [[ "${opensbi_ref}" == v1.9 && \
      "${actual_commit}" != "${opensbi_v19_commit}" ]]; then
    echo "build-opensbi.sh: v1.9 resolved to unexpected commit ${actual_commit}" >&2
    exit 2
fi

"${bare_cross}gcc" -E -P -x assembler-with-cpp \
    -DOPENRV64_MEMORY_SIZE="${memory_size}" \
    -o "${artifact_dir}/openrv64.dts" \
    "${repo_root}/sw/opensbi.dts"
dtc -I dts -O dtb -o "${artifact_dir}/openrv64.dtb" \
    "${artifact_dir}/openrv64.dts"
"${bare_cross}gcc" -E -P -x assembler-with-cpp \
    -DOPENRV64_MEMORY_SIZE="${memory_size}" \
    "${zicclsm_cpp_args[@]}" \
    -o "${artifact_dir}/openrv64-3p.dts" \
    "${repo_root}/sw/opensbi.dts"
dtc -I dts -O dtb -o "${artifact_dir}/openrv64-3p.dtb" \
    "${artifact_dir}/openrv64-3p.dts"

"${bare_cross}gcc" -march=rv64ima_zicsr_zifencei -mabi=lp64 \
    -mcmodel=medany -mno-relax -nostdlib -nostartfiles \
    -DOPENRV64_FDT_ADDR="${fdt_addr}" \
    -Wl,--build-id=none -T "${repo_root}/sw/opensbi_trampoline.ld" \
    -o "${artifact_dir}/trampoline.elf" \
    "${repo_root}/sw/opensbi_trampoline.S"
"${bare_cross}objcopy" -O binary \
    "${artifact_dir}/trampoline.elf" "${artifact_dir}/trampoline.bin"

"${bare_cross}gcc" -march=rv64ima_zicsr_zifencei -mabi=lp64 \
    -mcmodel=medany -mno-relax -nostdlib -nostartfiles \
    -Wl,--build-id=none -T "${repo_root}/sw/opensbi_payload.ld" \
    -o "${artifact_dir}/payload.elf" \
    "${repo_root}/sw/opensbi_payload.S"
"${bare_cross}objcopy" -O binary \
    "${artifact_dir}/payload.elf" "${artifact_dir}/payload.bin"

# OpenSBI's dependencies do not track changes to firmware address variables,
# and its clean target leaves generated linker scripts behind.  Force every
# generated input to be refreshed so address changes cannot reuse stale links.
make -C "${source_dir}" -B -j"${jobs}" \
    O="${output_dir}" \
    PLATFORM=generic \
    PLATFORM_DEFCONFIG="${defconfig_name}" \
    CROSS_COMPILE="${opensbi_cross}" \
    PLATFORM_RISCV_XLEN=64 \
    PLATFORM_RISCV_ISA=rv64ima_zicsr_zifencei \
    PLATFORM_RISCV_ABI=lp64 \
    DEBUG="${opensbi_debug}" \
    FW_TEXT_START="${firmware_addr}" \
    FW_JUMP_ADDR="${payload_addr}" \
    FW_JUMP_FDT_ADDR="${fdt_addr}"

firmware_dir="${output_dir}/platform/generic/firmware"
install -m 0644 "${firmware_dir}/fw_jump.bin" \
    "${artifact_dir}/fw_jump.bin"
install -m 0644 "${firmware_dir}/fw_jump.elf" \
    "${artifact_dir}/fw_jump.elf"

linked_entry=$("${opensbi_cross}readelf" -h \
    "${artifact_dir}/fw_jump.elf" |
    awk '/Entry point address:/ { print $4 }')
if [[ "${linked_entry}" != "${firmware_addr}" ]]; then
    echo "build-opensbi.sh: fw_jump entry ${linked_entry}, expected ${firmware_addr}" >&2
    exit 2
fi

# Fixed-size fragments keep readmemh loads bounded without generating a full
# 256 MiB textual image. bin2mem also rejects an artifact that outgrows its slot.
python3 "${repo_root}/tools/bin2mem.py" \
    "${artifact_dir}/trampoline.bin" "${artifact_dir}/trampoline.memh" \
    --size 0x10000
python3 "${repo_root}/tools/bin2mem.py" \
    "${artifact_dir}/fw_jump.bin" "${artifact_dir}/fw_jump.memh" \
    --size 0x100000
python3 "${repo_root}/tools/bin2mem.py" \
    "${artifact_dir}/payload.bin" "${artifact_dir}/payload.memh" \
    --size 0x10000
python3 "${repo_root}/tools/bin2mem.py" \
    "${artifact_dir}/openrv64.dtb" "${artifact_dir}/openrv64-dtb.memh" \
    --size 0x10000
python3 "${repo_root}/tools/bin2mem.py" \
    "${artifact_dir}/openrv64-3p.dtb" \
    "${artifact_dir}/openrv64-3p-dtb.memh" \
    --size 0x10000

# The fixed 3P baseline attaches a native 256-bit AXI RAM.  Emit matching
# 32-byte lines as separate bounded fragments so its testbench can place each
# stage at the same addresses without constructing a sparse 256 MiB image.
python3 "${repo_root}/tools/bin2mem.py" \
    "${artifact_dir}/trampoline.bin" "${artifact_dir}/trampoline-axi.memh" \
    --size 0x10000 --word-bytes 32
python3 "${repo_root}/tools/bin2mem.py" \
    "${artifact_dir}/fw_jump.bin" "${artifact_dir}/fw_jump-axi.memh" \
    --size 0x100000 --word-bytes 32
python3 "${repo_root}/tools/bin2mem.py" \
    "${artifact_dir}/payload.bin" "${artifact_dir}/payload-axi.memh" \
    --size 0x10000 --word-bytes 32
python3 "${repo_root}/tools/bin2mem.py" \
    "${artifact_dir}/openrv64-3p.dtb" \
    "${artifact_dir}/openrv64-3p-dtb-axi.memh" \
    --size 0x10000 --word-bytes 32

echo "OpenSBI ${opensbi_ref} (${actual_commit})"
echo "  trampoline ${trampoline_addr} -> firmware ${firmware_addr}"
echo "  payload    ${payload_addr}"
echo "  FDT        ${fdt_addr}"
echo "  memory     ${memory_size}"
echo "  artifacts  ${artifact_dir}"
