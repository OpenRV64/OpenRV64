#!/usr/bin/env bash
set -euo pipefail

# Recreate the Cortex-A53-class comparison rig used for the CoreMark-derived
# loop. QEMU validates the exact AArch64 instruction path; gem5 HPI supplies
# the 2-wide in-order timing model and full Minor pipeline trace.
#
# This is intentionally an occasional-use helper. The first gem5 build is
# large (roughly 5-7 GiB) and can take several minutes; later runs reuse it.
#
# Useful overrides:
#   GEM5_ROOT=/path/to/gem5       checkout and build location
#   GEM5_JOBS=16                  parallel gem5 build jobs
#   GEM5_SCONS_ROOT=/path/to/venv private SCons virtual environment
#   A53_RUN_QEMU=0                skip the functional QEMU run
#   A53_RUN_GEM5=0                skip the gem5 timing run
#   A53_GEM5_DEBUG_FLAGS=...      gem5 flags; add MinorExecute for issue detail
#   A53_GEM5_OUTDIR=...           timing output directory

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

gem5_commit=51edbbb9cfd37e92e9901aea2caa4a8f20eda005
gem5_url=https://github.com/gem5/gem5.git
gem5_root=${GEM5_ROOT:-/tmp/openrv64-gem5}
scons_root=${GEM5_SCONS_ROOT:-"${gem5_root}-scons"}
run_qemu=${A53_RUN_QEMU:-1}
run_gem5=${A53_RUN_GEM5:-1}
gem5_debug_flags=${A53_GEM5_DEBUG_FLAGS:-MinorTrace}
gem5_outdir=${A53_GEM5_OUTDIR:-sim/a53/gem5-hpi}

if [[ "${gem5_outdir}" = /* ]]; then
    gem5_output_path=${gem5_outdir}
else
    gem5_output_path=${repo_root}/${gem5_outdir}
fi

detected_jobs=$(nproc)
if (( detected_jobs > 32 )); then
    detected_jobs=32
fi
gem5_jobs=${GEM5_JOBS:-${detected_jobs}}

for tool in git make python3 nproc aarch64-linux-gnu-gcc \
            aarch64-linux-gnu-objcopy aarch64-linux-gnu-objdump \
            qemu-system-aarch64; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "run-a53-proxy.sh: missing required tool: ${tool}" >&2
        exit 2
    fi
done

if [[ "${run_qemu}" == 1 ]]; then
    make -C "${repo_root}" sim-coremark-loop-a53-qemu
elif [[ "${run_qemu}" != 0 ]]; then
    echo "run-a53-proxy.sh: A53_RUN_QEMU must be 0 or 1" >&2
    exit 2
fi

if [[ "${run_gem5}" == 0 ]]; then
    exit 0
elif [[ "${run_gem5}" != 1 ]]; then
    echo "run-a53-proxy.sh: A53_RUN_GEM5 must be 0 or 1" >&2
    exit 2
fi

need_build=0
if [[ ! -d "${gem5_root}/.git" ]]; then
    if [[ -e "${gem5_root}" ]]; then
        echo "run-a53-proxy.sh: ${gem5_root} exists but is not a git checkout" >&2
        exit 2
    fi

    mkdir -p "${gem5_root}"
    git -C "${gem5_root}" init
    git -C "${gem5_root}" remote add origin "${gem5_url}"
    git -C "${gem5_root}" fetch --depth 1 origin "${gem5_commit}"
    git -C "${gem5_root}" checkout --detach FETCH_HEAD
    need_build=1
else
    if [[ -n "$(git -C "${gem5_root}" status --short)" ]]; then
        echo "run-a53-proxy.sh: refusing to alter dirty checkout ${gem5_root}" >&2
        exit 2
    fi

    actual_commit=$(git -C "${gem5_root}" rev-parse HEAD)
    if [[ "${actual_commit}" != "${gem5_commit}" ]]; then
        if ! git -C "${gem5_root}" cat-file -e "${gem5_commit}^{commit}"; then
            git -C "${gem5_root}" fetch --depth 1 origin "${gem5_commit}"
        fi
        git -C "${gem5_root}" checkout --detach "${gem5_commit}"
        need_build=1
    fi
fi

actual_commit=$(git -C "${gem5_root}" rev-parse HEAD)
if [[ "${actual_commit}" != "${gem5_commit}" ]]; then
    echo "run-a53-proxy.sh: gem5 checkout is ${actual_commit}, expected ${gem5_commit}" >&2
    exit 2
fi

gem5_binary=${gem5_root}/build/ARM/gem5.opt
if [[ ! -x "${gem5_binary}" ]]; then
    need_build=1
fi

if [[ "${need_build}" == 1 ]]; then
    scons_python=${scons_root}/bin/python
    if [[ ! -x "${scons_python}" ]]; then
        python3 -m venv "${scons_root}"
    fi
    if ! "${scons_python}" -c 'import SCons' >/dev/null 2>&1; then
        "${scons_python}" -m pip install 'scons==4.10.1'
    fi

    (
        cd "${gem5_root}"
        "${scons_python}" -m SCons build/ARM/gem5.opt -j"${gem5_jobs}"
    )
fi

make -C "${repo_root}" sim-coremark-loop-a53-gem5 \
    GEM5_ROOT="${gem5_root}" \
    A53_GEM5_DEBUG_FLAGS="${gem5_debug_flags}" \
    A53_GEM5_OUTDIR="${gem5_outdir}"

echo "A53 proxy complete"
echo "  QEMU report  ${repo_root}/sim/a53/coremark-loop-a53-qemu-report.txt"
echo "  HPI report   ${gem5_output_path}/report.txt"
echo "  HPI trace    ${gem5_output_path}/minor-trace.log"
