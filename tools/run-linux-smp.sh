#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export TZ=UTC

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../run/lib/common.sh
source "${repo_root}/run/lib/common.sh"
run_root=$(realpath -m \
    "${OPENRV64_SMP_RUN_ROOT:-${repo_root}/build/runs/linux-smp}")
record_makefile=scripts/make/linux-run-record.mk
sendify=${OPENRV64_SENDIFY:-/home/bill/bin/sendify.py}

usage() {
    cat <<'EOF'
Usage:
  tools/run-linux-smp.sh config CFG [overrides ...]
  tools/run-linux-smp.sh start --name NAME [options] [NAME=value ...]
  tools/run-linux-smp.sh status [RUN]
  tools/run-linux-smp.sh list
  tools/run-linux-smp.sh log [RUN] [LINES]
  tools/run-linux-smp.sh tail [RUN] [LINES]
  tools/run-linux-smp.sh attach [RUN]
  tools/run-linux-smp.sh path [RUN]
  tools/run-linux-smp.sh checkpoint [RUN]
  tools/run-linux-smp.sh command [RUN]
  tools/run-linux-smp.sh wait [RUN]
  tools/run-linux-smp.sh stop [RUN]

Start options:
  --harts 1|2|4             Active Linux harts (default: 4). One hart
                            builds only core 0 and ties off ICX ports 1-3.
  --name NAME               Required run label.
  --comment TEXT            Purpose; defaults to NAME.
  --threads N               Verilator runtime threads (default: 1).
  --image PATH              Linux Image (default: sw/linux/kernels/Image.zbb2).
  --kernel-elf PATH         Source-matched vmlinux for PC symbols. Its
                            arch/riscv/boot/Image must match --image.
  --zicclsm 0|1             DT ISA advertisement (default: 1).
  --max-cycles N            Simulation limit (default: 250000000).
  --checkpoint N            Save replay state at N; 0 disables it
                            (default: 25000000).
  --checkpoint-cycles N     Alias for --checkpoint.
  --checkpoint-exit         Exit after saving the requested checkpoint.
  --checkpoint-interval N   Save checkpoint-<cycle>.vls every N cycles.
  --checkpoint-stop-pc PC   Stop after a periodic checkpoint at hart-0 PC.
  --base-inputs DIR         Reuse a compatible managed run's firmware and
                            DTB for a fresh kernel-only run. Its simulator is
                            also reused unless --rebuild is specified.
  --simulator FILE          Use this compatible host executable for a fresh
                            run instead of rebuilding the configured model.
  --resume CHECKPOINT|RUN   Resume an exact managed checkpoint snapshot.
  --resume-simulator FILE   Use a model-compatible rebuilt host executable.
  --host-pc-trace           Record hart-0 retire/trap PCs after restore.
  --host-pc-sample-period N Sample the held hart-0 PC every N cycles and
                            build a function histogram without retaining the
                            full retire trace.
  --l1d-watch-vaddr ADDR    Trace this hart-0 virtual address through L1D.
  --l1d-watch-paddr ADDR    Seed its physical address for earlier events.
  --l1d-watch-value VALUE   Flag this aligned 64-bit value in line traffic.
  --l1d-watch-all-mshrs     Record every outgoing L1D/L2 MSHR transaction.
  --ticket-lock-paddr ADDR  Trace one physical ticket-lock line through the
                            core, L1D, and L2 into ticket-lock.log.
  --stop-cycles N           Stop when absolute cycle N is reached.
  --monitor-seconds N       Notification interval (default: 900).
  --timeout-seconds N       Whole-job wall timeout in seconds. The default is
                            259200 (72 hours); 0 disables it.
  --rebuild                 Force a source-matched rebuild with make -B.
  --foreground              Do not detach into tmux.
  -- PLUSARG ...            Additional simulator +arguments.

Make-style NAME=value arguments override DDR3, prefetch, memory, or build
settings. The command records the effective Make configuration, dirty-tree
patch, source hashes, snapshotted artifacts, simulator command, progress,
checkpoint, and final boot validation.

RUN may be a run ID, run directory, or "latest" (the default). One detached
tmux session owns build, simulation, monitoring, and final notification.

The canonical interface is run/run or an executable run/cfg/*.cfg file.
The config subcommand is retained so automation with an existing approval for
this backend can launch the same configuration-first interface.
EOF
}

die() {
    printf 'run-linux-smp.sh: %s\n' "$*" >&2
    exit 2
}

shell_join() {
    local output= quoted argument
    for argument in "$@"; do
        printf -v quoted '%q' "${argument}"
        [[ -z ${output} ]] || output+=' '
        output+=${quoted}
    done
    printf '%s' "${output}"
}

notify() {
    local message=$1
    local task=$2
    if [[ -x ${sendify} ]]; then
        "${sendify}" "${message}" "${task}" >/dev/null 2>&1 || true
    fi
}

slugify() {
    printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-' |
        sed 's/^-*//; s/-*$//'
}

resolve_run() {
    local requested=${1:-latest}
    local candidate

    if [[ ${requested} == latest ]]; then
        candidate=$(find "${run_root}" -mindepth 2 -maxdepth 2 \
            -name manager.env -printf '%T@ %h\n' 2>/dev/null |
            sort -nr | sed -n '1s/^[^ ]* //p')
        [[ -n ${candidate} ]] || die "no managed SMP runs found"
    elif [[ -d ${requested} ]]; then
        candidate=$(realpath -m "${requested}")
    else
        candidate=$(realpath -m "${run_root}/${requested}")
    fi

    case "${candidate}/" in
        "${run_root}/"*/) ;;
        *) die "run is outside ${run_root}: ${candidate}" ;;
    esac
    [[ -f ${candidate}/manager.env ]] ||
        die "not a managed SMP run: ${candidate}"
    printf '%s' "${candidate}"
}

resolve_checkpoint() {
    local requested=$1
    local candidate=
    local directory=

    if [[ -f ${requested} ]]; then
        candidate=$(realpath -m "${requested}")
    elif [[ -d ${requested} ]]; then
        directory=$(realpath -m "${requested}")
    elif [[ ${requested} == latest || -d ${run_root}/${requested} ]]; then
        directory=$(resolve_run "${requested}")
    else
        die "checkpoint or managed run not found: ${requested}"
    fi

    if [[ -n ${directory} ]]; then
        candidate=$(find "${directory}" -maxdepth 1 -type f \
            \( -name 'checkpoint-*.vls' -o -name resume.vls \) \
            -printf '%T@ %p\n' |
            sort -nr | sed -n '1s/^[^ ]* //p')
        [[ -n ${candidate} ]] || die "no checkpoint found: ${directory}"
    fi
    [[ -s ${candidate} ]] || die "checkpoint is empty: ${candidate}"
    directory=$(dirname "${candidate}")
    [[ -x ${directory}/inputs/opensbi_4h_checkpoint_tb ]] ||
        die "resume requires the source run's snapshotted simulator: ${directory}/inputs/opensbi_4h_checkpoint_tb"
    printf '%s' "${candidate}"
}

config_value() {
    local file=$1
    local key=$2
    awk -v key="${key}" '
        index($0, key "=") == 1 {
            print substr($0, length(key) + 2)
            exit
        }
    ' "${file}"
}

write_source_hashes() {
    local input_manifest=$1
    local hash_file=$2
    local input

    : >"${hash_file}"
    while IFS= read -r input; do
        [[ -n ${input} ]] || continue
        [[ ${input} != OPENRV64_LINUX_SMP_RUN_INPUTS_V1 ]] || continue
        if [[ -f ${input} ]]; then
            sha256sum -- "${input}" >>"${hash_file}"
        else
            printf 'MISSING  %s\n' "${input}" >>"${hash_file}"
        fi
    done <"${input_manifest}"
}

monitor_loop() {
    local directory=$1
    local interval=$2
    local task=$3
    local log=${directory}/run.log
    local latest

    while :; do
        sleep "${interval}"
        latest=$(rg 'OPENSBI_4H_PROGRESS|LINUX_SMP_ONLINE|CHECKPOINT SAVED|linux_panic=1|openrv64#|PASS:' \
            "${log}" 2>/dev/null | tail -1 || true)
        [[ -n ${latest} ]] ||
            latest="SMP run active; simulator output has no progress marker yet"
        notify "${latest}; ${directory}" "${task}"
    done
}

worker() {
    local directory
    directory=$(realpath -m "$1")
    [[ -f ${directory}/manager.env ]] || die "missing manager.env"
    # shellcheck disable=SC1090
    source "${directory}/manager.env"
    checkpoint_exit=${checkpoint_exit:-0}
    checkpoint_interval=${checkpoint_interval:-0}
    checkpoint_stop_pc=${checkpoint_stop_pc:-}
    resume_checkpoint=${resume_checkpoint:-}
    resume_simulator=${resume_simulator:-}
    base_inputs=${base_inputs:-}
    simulator_override=${simulator_override:-}
    kernel_elf=${kernel_elf:-}
    host_pc_trace=${host_pc_trace:-0}
    host_pc_sample_period=${host_pc_sample_period:-0}
    l1d_watch_vaddr=${l1d_watch_vaddr:-}
    l1d_watch_paddr=${l1d_watch_paddr:-}
    l1d_watch_value=${l1d_watch_value:-}
    l1d_watch_all_mshrs=${l1d_watch_all_mshrs:-0}
    ticket_lock_paddr=${ticket_lock_paddr:-}
    stop_cycles=${stop_cycles:-0}
    mapfile -t make_arguments <"${directory}/make-arguments.txt"
    local simulator_arguments=()
    if [[ -s ${directory}/simulator-arguments.txt ]]; then
        mapfile -t simulator_arguments \
            <"${directory}/simulator-arguments.txt"
    fi

    cd "${repo_root}"
    ulimit -c 0

    local build_log=${directory}/build.log
    local run_log=${directory}/run.log
    local status_file=${directory}/status
    local config_file=${directory}/effective-config.txt
    local source_manifest=${directory}/source-inputs.txt
    local source_hashes=${directory}/source-inputs.sha256
    local artifact_hashes=${directory}/artifacts.sha256
    local input_dir=${directory}/inputs
    local checkpoint=${directory}/checkpoint-${checkpoint_cycles}.vls
    local phase=setup
    local validation=not-run
    local sim_result=
    local monitor_pid=
    local heartbeat_pid=
    local host_pc_sampler_pid=
    local started_utc
    started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    heartbeat_loop() {
        local heartbeat=${directory}/heartbeat
        while :; do
            touch "${heartbeat}"
            sleep 10
        done
    }

    finish_worker() {
        local result=$?
        trap - EXIT
        if [[ -n ${monitor_pid} ]]; then
            kill "${monitor_pid}" 2>/dev/null || true
            wait "${monitor_pid}" 2>/dev/null || true
        fi
        if [[ -n ${heartbeat_pid} ]]; then
            kill "${heartbeat_pid}" 2>/dev/null || true
            wait "${heartbeat_pid}" 2>/dev/null || true
        fi
        if [[ -n ${host_pc_sampler_pid} ]]; then
            kill "${host_pc_sampler_pid}" 2>/dev/null || true
            wait "${host_pc_sampler_pid}" 2>/dev/null || true
        fi
        {
            printf 'run_id=%s\n' "${run_id}"
            printf 'phase=%s\n' "${phase}"
            printf 'exit_code=%s\n' "${result}"
            printf 'sim_exit_code=%s\n' "${sim_result}"
            printf 'validation=%s\n' "${validation}"
            printf 'finished_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'run_log=%s\n' "${run_log}"
        } >"${status_file}"
        notify "${run_id} finished: phase=${phase} exit=${result} validation=${validation}; ${run_log}" \
            "${task_name}"
        exit "${result}"
    }
    trap finish_worker EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    heartbeat_loop &
    heartbeat_pid=$!

    git rev-parse HEAD >"${directory}/git-head.txt"
    git status --short >"${directory}/git-status.txt"
    git diff --binary HEAD >"${directory}/worktree.patch"

    {
        printf 'OPENRV64_LINUX_SMP_BUILD_RECORD_V1\n'
        printf 'run_id=%s\n' "${run_id}"
        printf 'started_utc=%s\n' "${started_utc}"
        printf 'harts=%s\n' "${harts}"
        printf 'threads=%s\n' "${threads}"
        printf 'image=%s\n' "${image}"
        printf 'kernel_elf=%s\n' "${kernel_elf}"
        printf 'zicclsm=%s\n' "${zicclsm}"
        printf 'max_cycles=%s\n' "${max_cycles}"
        printf 'checkpoint_cycles=%s\n' "${checkpoint_cycles}"
        printf 'checkpoint_exit=%s\n' "${checkpoint_exit}"
        printf 'checkpoint_interval=%s\n' "${checkpoint_interval}"
        printf 'checkpoint_stop_pc=%s\n' "${checkpoint_stop_pc}"
        printf 'resume_checkpoint=%s\n' "${resume_checkpoint}"
        printf 'base_inputs=%s\n' "${base_inputs}"
        printf 'simulator_override=%s\n' "${simulator_override}"
        printf 'stop_cycles=%s\n' "${stop_cycles}"
        printf 'host_pc_sample_period=%s\n' "${host_pc_sample_period}"
        printf 'ticket_lock_paddr=%s\n' "${ticket_lock_paddr}"
        printf 'rebuild=%s\n' "${rebuild}"
        printf 'timeout_seconds=%s\n' "${timeout_seconds}"
        printf 'command=%s\n' "${recorded_command}"
    } >"${build_log}"

    local simulator artifact_dir linux_memh opensbi_target payload_words
    local resume_snapshot=
    if [[ -n ${resume_checkpoint} ]]; then
        phase=resume-snapshot
        local resume_source_dir
        local resume_source_inputs
        local resume_source_manager
        local resume_source_harts
        local resume_source_threads
        resume_source_dir=$(dirname "${resume_checkpoint}")
        resume_source_inputs=${resume_source_dir}/inputs
        resume_source_manager=${resume_source_dir}/manager.env
        [[ -f ${resume_source_manager} ]] ||
            die "resume source is missing manager.env: ${resume_source_dir}"
        resume_source_harts=$(config_value "${resume_source_manager}" harts)
        resume_source_threads=$(config_value "${resume_source_manager}" threads)
        [[ ${resume_source_harts} == "${harts}" ]] ||
            die "resume hart mismatch: checkpoint=${resume_source_harts} requested=${harts}"
        [[ ${resume_source_threads} == "${threads}" ]] ||
            die "resume thread mismatch: checkpoint=${resume_source_threads} requested=${threads}"
        [[ -f ${resume_source_dir}/effective-config.txt ]] ||
            die "resume source is missing effective-config.txt"

        cp --reflink=auto --preserve=mode,timestamps \
            "${resume_source_dir}/effective-config.txt" "${config_file}"
        if [[ -f ${resume_source_dir}/source-inputs.txt ]]; then
            cp --reflink=auto --preserve=mode,timestamps \
                "${resume_source_dir}/source-inputs.txt" "${source_manifest}"
        else
            printf 'RESUME_SOURCE=%s\n' "${resume_source_dir}" \
                >"${source_manifest}"
        fi
        if [[ -f ${resume_source_dir}/source-inputs.sha256 ]]; then
            cp --reflink=auto --preserve=mode,timestamps \
                "${resume_source_dir}/source-inputs.sha256" "${source_hashes}"
        else
            : >"${source_hashes}"
        fi

        mkdir -p "${input_dir}"
        local artifact
        for artifact in Image.smp \
            linux-image.memh trampoline.memh fw_jump.memh fw_jump.elf \
            openrv64-3p-dtb.memh openrv64-3p.dtb hsm-wfi-pc.txt; do
            [[ -f ${resume_source_inputs}/${artifact} ]] ||
                die "resume source input is missing: ${artifact}"
            cp --reflink=auto --preserve=mode,timestamps \
                "${resume_source_inputs}/${artifact}" \
                "${input_dir}/${artifact}"
        done
        # Symbol maps are derived artifacts.  Retain the ELF across resume,
        # but regenerate maps below for every new run instead of copying a
        # potentially stale map from the checkpoint source.
        if [[ -f ${resume_source_inputs}/vmlinux ]]; then
            cp --reflink=auto --preserve=mode,timestamps \
                "${resume_source_inputs}/vmlinux" \
                "${input_dir}/vmlinux"
        fi
        if [[ -n ${kernel_elf} ]]; then
            cp --reflink=auto --preserve=mode,timestamps \
                "${kernel_elf}" "${input_dir}/vmlinux"
            if ! rg -Fqx -- "${kernel_elf}" "${source_manifest}"; then
                printf '%s\n' "${kernel_elf}" >>"${source_manifest}"
            fi
            write_source_hashes "${source_manifest}" "${source_hashes}"
        fi
        if [[ -n ${resume_simulator} ]]; then
            cp --reflink=auto --preserve=mode,timestamps \
                "${resume_simulator}" \
                "${input_dir}/opensbi_4h_checkpoint_tb"
        else
            cp --reflink=auto --preserve=mode,timestamps \
                "${resume_source_inputs}/opensbi_4h_checkpoint_tb" \
                "${input_dir}/opensbi_4h_checkpoint_tb"
        fi
        simulator=${input_dir}/opensbi_4h_checkpoint_tb
        payload_words=$(config_value "${config_file}" LINUX_IMAGE_WORDS)
        [[ -n ${payload_words} ]] ||
            die "resume source is missing LINUX_IMAGE_WORDS"
        resume_snapshot=${directory}/resume.vls
        cp --reflink=auto --preserve=mode,timestamps \
            "${resume_checkpoint}" "${resume_snapshot}"
        riscv64-linux-gnu-nm -n --defined-only \
            "${input_dir}/fw_jump.elf" \
            >"${input_dir}/opensbi-symbols.map"
        if [[ -f ${input_dir}/vmlinux ]]; then
            riscv64-linux-gnu-nm -n --defined-only \
                "${input_dir}/vmlinux" \
                >"${input_dir}/linux-symbols.map"
        else
            printf '%s\n' \
                'Linux PC symbols unavailable: source-matched vmlinux was not supplied' \
                >>"${build_log}"
        fi
        sha256sum "${input_dir}"/* "${resume_snapshot}" \
            >"${artifact_hashes}"
        {
            printf 'resume_source_run=%s\n' "${resume_source_dir}"
            printf 'resume_source_checkpoint=%s\n' "${resume_checkpoint}"
            printf 'resume_snapshot=%s\n' "${resume_snapshot}"
            printf 'resume_simulator=%s\n' "${resume_simulator}"
        } >>"${build_log}"
    else
        local make_base=(env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL
            make --no-print-directory)
        local config_command=("${make_base[@]}" -f Makefile
            -f "${record_makefile}" "${make_arguments[@]}"
            openrv64-linux-smp-run-config)
        phase=config
        "${config_command[@]}" >"${config_file}" 2>&1

        simulator=$(config_value "${config_file}" \
            OPENSBI_4H_HELD_CHECKPOINT_VERILATOR_BUILD)
        payload_words=$(config_value "${config_file}" LINUX_IMAGE_WORDS)
        if [[ ${harts} == 1 ]]; then
            artifact_dir=$(config_value "${config_file}" \
                OPENSBI_1H_LINUX_ARTIFACT_DIR)
            linux_memh=$(config_value "${config_file}" \
                OPENSBI_1H_LINUX_IMAGE_MEMH)
            opensbi_target=opensbi-1h-linux-coherent
        elif [[ ${harts} == 2 ]]; then
            artifact_dir=$(config_value "${config_file}" \
                OPENSBI_2H_LINUX_ARTIFACT_DIR)
            linux_memh=$(config_value "${config_file}" \
                OPENSBI_2H_LINUX_IMAGE_MEMH)
            opensbi_target=opensbi-2h-linux-smp
        else
            artifact_dir=$(config_value "${config_file}" \
                OPENSBI_4H_LINUX_SMP_ARTIFACT_DIR)
            linux_memh=$(config_value "${config_file}" \
                OPENSBI_4H_LINUX_SMP_IMAGE_MEMH)
            opensbi_target=opensbi-4h-linux-smp
        fi
        [[ -n ${simulator} && -n ${artifact_dir} && -n ${linux_memh} &&
           -n ${payload_words} ]] ||
            die "incomplete effective Make configuration"

        "${make_base[@]}" -f Makefile -f "${record_makefile}" \
            "${make_arguments[@]}" openrv64-linux-smp-run-inputs \
            >"${source_manifest}" 2>&1
        if [[ -n ${base_inputs} ]]; then
            local base_artifact
            for base_artifact in trampoline.memh fw_jump.memh fw_jump.elf \
                openrv64-3p-dtb.memh openrv64-3p.dtb hsm-wfi-pc.txt; do
                printf '%s\n' "${base_inputs}/${base_artifact}" \
                    >>"${source_manifest}"
            done
            if ((rebuild == 0)); then
                printf '%s\n' \
                    "${base_inputs}/opensbi_4h_checkpoint_tb" \
                    >>"${source_manifest}"
            fi
        fi
        if [[ -n ${simulator_override} ]]; then
            printf '%s\n' "${simulator_override}" >>"${source_manifest}"
        fi
        if [[ -n ${kernel_elf} ]]; then
            printf '%s\n' "${kernel_elf}" >>"${source_manifest}"
        fi
        write_source_hashes "${source_manifest}" "${source_hashes}"

        phase=build
        local build_command=("${make_base[@]}" -j8)
        [[ ${rebuild} == 0 ]] || build_command+=(-B)
        build_command+=("${make_arguments[@]}")
        if [[ -z ${simulator_override} ]] &&
           [[ -z ${base_inputs} || ${rebuild} != 0 ]]; then
            build_command+=("${simulator}")
        fi
        if [[ -z ${base_inputs} ]]; then
            build_command+=("${opensbi_target}")
        fi
        printf 'build_command=%s\n' "$(shell_join "${build_command[@]}")" \
            >>"${build_log}"

        mkdir -p "${run_root}"
        exec 9>"${run_root}/build.lock"
        flock 9
        set +e
        "${build_command[@]}" 2>&1 | tee -a "${build_log}"
        local build_result=${PIPESTATUS[0]}
        set -e
        if ((build_result != 0)); then
            exit "${build_result}"
        fi

        if [[ -n ${base_inputs} ]]; then
            if ((rebuild == 0)); then
                simulator=${base_inputs}/opensbi_4h_checkpoint_tb
            fi
            artifact_dir=${base_inputs}
        elif [[ -n ${simulator_override} ]]; then
            simulator=${simulator_override}
        fi

        phase=snapshot
        mkdir -p "${input_dir}"
        cp --reflink=auto --preserve=mode,timestamps \
            "${simulator}" "${input_dir}/opensbi_4h_checkpoint_tb"
        cp --reflink=auto --preserve=mode,timestamps \
            "${image}" "${input_dir}/Image.smp"
        local linux_image_slot_bytes
        linux_image_slot_bytes=$(config_value "${config_file}" \
            LINUX_IMAGE_SLOT_BYTES)
        [[ -n ${linux_image_slot_bytes} ]] ||
            die "effective configuration lacks LINUX_IMAGE_SLOT_BYTES"
        python3 tools/bin2mem.py "${image}" \
            "${input_dir}/linux-image.memh" \
            --size "${linux_image_slot_bytes}" >>"${build_log}"
        local artifact
        for artifact in trampoline.memh fw_jump.memh fw_jump.elf \
            openrv64-3p-dtb.memh openrv64-3p.dtb hsm-wfi-pc.txt; do
            cp --reflink=auto --preserve=mode,timestamps \
                "${artifact_dir}/${artifact}" "${input_dir}/${artifact}"
        done
        if [[ -n ${kernel_elf} ]]; then
            cp --reflink=auto --preserve=mode,timestamps \
                "${kernel_elf}" "${input_dir}/vmlinux"
        fi
        riscv64-linux-gnu-nm -n --defined-only \
            "${input_dir}/fw_jump.elf" \
            >"${input_dir}/opensbi-symbols.map"
        if [[ -f ${input_dir}/vmlinux ]]; then
            riscv64-linux-gnu-nm -n --defined-only \
                "${input_dir}/vmlinux" \
                >"${input_dir}/linux-symbols.map"
        else
            printf '%s\n' \
                'Linux PC symbols unavailable: source-matched vmlinux was not supplied' \
                >>"${build_log}"
        fi
        sha256sum "${input_dir}"/* >"${artifact_hashes}"
        flock -u 9
        exec 9>&-
    fi

    local runner_source
    for runner_source in run/run run/lib/common.sh \
        tools/run-linux-smp.sh scripts/make/linux-run-record.mk; do
        if ! rg -Fqx -- "${runner_source}" "${source_manifest}"; then
            printf '%s\n' "${runner_source}" >>"${source_manifest}"
        fi
    done
    write_source_hashes "${source_manifest}" "${source_hashes}"
    local infrastructure_dir=${input_dir}/run-infrastructure
    for runner_source in run/run run/lib/common.sh \
        tools/run-linux-smp.sh scripts/make/linux-run-record.mk; do
        mkdir -p "${infrastructure_dir}/$(dirname "${runner_source}")"
        cp --reflink=auto --preserve=mode,timestamps \
            "${runner_source}" "${infrastructure_dir}/${runner_source}"
    done

    phase=run
    local run_command=("${input_dir}/opensbi_4h_checkpoint_tb"
        "+trampoline_memh=${input_dir}/trampoline.memh"
        "+firmware_memh=${input_dir}/fw_jump.memh"
        "+payload_memh=${input_dir}/linux-image.memh"
        "+payload_words=${payload_words}"
        "+fdt_memh=${input_dir}/openrv64-3p-dtb.memh"
        "+max_cycles=${max_cycles}")
    if [[ ${harts} == 1 ]]; then
        run_command+=(+opensbi_held +linux_mode
            +opensbi_active_harts=1 +gate_held_hart_clocks)
    else
        run_command+=(+opensbi_smp +linux_mode
            "+opensbi_active_harts=${harts}"
            "+opensbi_hsm_wfi_pc=$(sed -n '1p' "${input_dir}/hsm-wfi-pc.txt")")
        [[ ${harts} == 4 ]] || run_command+=(+gate_held_hart_clocks)
    fi
    if [[ -f ${input_dir}/linux-symbols.map ]]; then
        run_command+=("+linux_symbols=${input_dir}/linux-symbols.map")
    fi
    if [[ -f ${input_dir}/opensbi-symbols.map ]]; then
        run_command+=("+opensbi_symbols=${input_dir}/opensbi-symbols.map")
    fi
    if ((checkpoint_cycles > 0)); then
        run_command+=("+checkpoint=${checkpoint}"
            "+checkpoint_cycles=${checkpoint_cycles}")
        [[ ${checkpoint_exit} == 0 ]] || run_command+=(+checkpoint_exit)
    fi
    if ((checkpoint_interval > 0)); then
        run_command+=("+checkpoint_interval=${checkpoint_interval}"
            "+checkpoint_prefix=${directory}/checkpoint")
        if [[ -n ${checkpoint_stop_pc} ]]; then
            run_command+=("+checkpoint_stop_pc=${checkpoint_stop_pc}")
        fi
    fi
    if [[ -n ${resume_snapshot} ]]; then
        run_command+=("+restore=${resume_snapshot}"
            "+max_cycles_override=${max_cycles}")
    fi
    local host_pc_sample_fifo=
    local host_pc_sample_file=${directory}/host-pc-samples.tsv
    local host_pc_sample_state=${directory}/host-pc-sample.state
    local host_pc_histogram=${directory}/host-pc-function-histogram.tsv
    if ((host_pc_sample_period > 0)); then
        host_pc_sample_fifo=${directory}/host-pc-trace.fifo
        mkfifo "${host_pc_sample_fifo}"
        gawk -v "period=${host_pc_sample_period}" \
            -v "state_path=${host_pc_sample_state}" \
            -f "${repo_root}/tools/host-pc-sampler.awk" \
            <"${host_pc_sample_fifo}" >"${host_pc_sample_file}" &
        host_pc_sampler_pid=$!
        run_command+=("+host_pc_trace=${host_pc_sample_fifo}")
    elif ((host_pc_trace == 1)); then
        run_command+=("+host_pc_trace=${directory}/host-pc-trace.log")
    fi
    if [[ -n ${l1d_watch_vaddr} ]]; then
        run_command+=("+l1d_watch_vaddr=${l1d_watch_vaddr}"
            "+l1d_watch_trace=${directory}/l1d-watch.log")
        if [[ -n ${l1d_watch_paddr} ]]; then
            run_command+=("+l1d_watch_paddr=${l1d_watch_paddr}")
        fi
        if [[ -n ${l1d_watch_value} ]]; then
            run_command+=("+l1d_watch_value=${l1d_watch_value}")
        fi
        if ((l1d_watch_all_mshrs == 1)); then
            run_command+=(+l1d_watch_all_mshrs)
        fi
    fi
    if [[ -n ${ticket_lock_paddr} ]]; then
        run_command+=(
            "+ticket_lock_trace=${directory}/ticket-lock.log"
            "+ticket_lock_paddr=${ticket_lock_paddr}")
    fi
    if ((stop_cycles > 0)); then
        run_command+=("+stop_cycles=${stop_cycles}")
    fi
    run_command+=("${simulator_arguments[@]}")

    {
        printf 'OPENRV64_LINUX_SMP_RUN_RECORD_V1\n'
        printf 'run_id=%s\n' "${run_id}"
        printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'command=%s\n' "$(shell_join "${run_command[@]}")"
        printf 'effective_config=%s\n' "${config_file}"
        printf 'artifact_hashes=%s\n' "${artifact_hashes}"
    } >"${run_log}"

    monitor_loop "${directory}" "${monitor_seconds}" "${task_name}" &
    monitor_pid=$!
    set +e
    stdbuf -oL -eL "${run_command[@]}" 2>&1 | tee -a "${run_log}"
    sim_result=${PIPESTATUS[0]}
    set -e
    if [[ -n ${host_pc_sampler_pid} ]]; then
        wait "${host_pc_sampler_pid}"
        host_pc_sampler_pid=
        rm -f "${host_pc_sample_fifo}"
    fi

    if rg -q '%Fatal:|Assertion failed' "${run_log}"; then
        validation=fatal
    elif rg -q 'linux_panic=1|Kernel panic' "${run_log}"; then
        validation=panic
    elif ((sim_result == 0 && checkpoint_exit == 1)) &&
         rg -q 'CHECKPOINT SAVED' "${run_log}"; then
        validation=checkpoint
    elif ((sim_result == 0 && checkpoint_interval > 0)) &&
         rg -q 'PERIODIC CHECKPOINT STOP PC' "${run_log}"; then
        validation=checkpoint
    elif ((sim_result == 0 && stop_cycles > 0)) &&
         rg -q 'SIMULATION STOP cycle=' "${run_log}"; then
        validation=stopped
    elif grep -Fq 'openrv64# ' "${run_log}" &&
         rg -q 'PASS(:|[[:space:]])' "${run_log}"; then
        validation=pass
    elif ((sim_result != 0)); then
        validation=simulator-error
    else
        validation=incomplete
    fi

    if ((host_pc_sample_period > 0)); then
        if [[ ${validation} == stopped && -f ${host_pc_sample_state} ]]; then
            local next_sample last_pc last_event_cycle
            next_sample=$(sed -n 's/^next_sample=//p' \
                "${host_pc_sample_state}")
            last_pc=$(sed -n 's/^last_pc=//p' \
                "${host_pc_sample_state}")
            last_event_cycle=$(sed -n 's/^last_event_cycle=//p' \
                "${host_pc_sample_state}")
            while [[ -n ${last_pc} && ${next_sample} -le ${stop_cycles} ]]; do
                printf '%u\t%s\t%u\n' "${next_sample}" "${last_pc}" \
                    "${last_event_cycle}" >>"${host_pc_sample_file}"
                next_sample=$((next_sample + host_pc_sample_period))
            done
        fi
        perl "${repo_root}/tools/pc-sample-histogram.pl" \
            "${host_pc_sample_file}" \
            "${input_dir}/opensbi-symbols.map" \
            "${input_dir}/linux-symbols.map" \
            >"${host_pc_histogram}"
        {
            printf 'host_pc_samples=%s\n' "${host_pc_sample_file}"
            printf 'host_pc_histogram=%s\n' "${host_pc_histogram}"
        } >>"${run_log}"
    fi

    {
        printf 'sim_exit_code=%s\n' "${sim_result}"
        printf 'validation=%s\n' "${validation}"
        printf 'finished_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >>"${run_log}"
    if ((sim_result != 0)); then
        exit "${sim_result}"
    fi
    if [[ ${validation} == pass || ${validation} == checkpoint ||
          ${validation} == stopped ]]; then
        exit 0
    fi
    exit 1
}

start_run() {
    local harts=4
    local name=
    local comment=
    local threads=1
    local image=sw/linux/kernels/Image.zbb2
    local kernel_elf=
    local zicclsm=1
    local max_cycles=250000000
    local checkpoint_cycles=25000000
    local checkpoint_exit=0
    local checkpoint_interval=0
    local checkpoint_stop_pc=
    local resume_checkpoint=
    local resume_simulator=
    local base_inputs=
    local simulator_override=
    local host_pc_trace=0
    local host_pc_sample_period=0
    local l1d_watch_vaddr=
    local l1d_watch_paddr=
    local l1d_watch_value=
    local l1d_watch_all_mshrs=0
    local ticket_lock_paddr=
    local stop_cycles=0
    local monitor_seconds=900
    local timeout_seconds=${OPENRV64_RUN_TIMEOUT_SECONDS:-259200}
    local rebuild=0
    local foreground=0
    local original_arguments=(start "$@")
    local make_overrides=()
    local simulator_arguments=()

    while (($#)); do
        case "$1" in
            --harts) harts=${2:?}; shift 2 ;;
            --name) name=${2:?}; shift 2 ;;
            --comment) comment=${2:?}; shift 2 ;;
            --threads) threads=${2:?}; shift 2 ;;
            --image) image=${2:?}; shift 2 ;;
            --kernel-elf) kernel_elf=${2:?}; shift 2 ;;
            --zicclsm) zicclsm=${2:?}; shift 2 ;;
            --max-cycles) max_cycles=${2:?}; shift 2 ;;
            --checkpoint|--checkpoint-cycles)
                checkpoint_cycles=${2:?}; shift 2 ;;
            --checkpoint-exit) checkpoint_exit=1; shift ;;
            --checkpoint-interval)
                checkpoint_interval=${2:?}; shift 2 ;;
            --checkpoint-stop-pc)
                checkpoint_stop_pc=${2:?}; shift 2 ;;
            --base-inputs) base_inputs=${2:?}; shift 2 ;;
            --simulator) simulator_override=${2:?}; shift 2 ;;
            --resume) resume_checkpoint=${2:?}; shift 2 ;;
            --resume-simulator) resume_simulator=${2:?}; shift 2 ;;
            --host-pc-trace) host_pc_trace=1; shift ;;
            --host-pc-sample-period)
                host_pc_sample_period=${2:?}; shift 2 ;;
            --l1d-watch-vaddr) l1d_watch_vaddr=${2:?}; shift 2 ;;
            --l1d-watch-paddr) l1d_watch_paddr=${2:?}; shift 2 ;;
            --l1d-watch-value) l1d_watch_value=${2:?}; shift 2 ;;
            --l1d-watch-all-mshrs) l1d_watch_all_mshrs=1; shift ;;
            --ticket-lock-paddr) ticket_lock_paddr=${2:?}; shift 2 ;;
            --stop-cycles) stop_cycles=${2:?}; shift 2 ;;
            --monitor-seconds) monitor_seconds=${2:?}; shift 2 ;;
            --timeout-seconds) timeout_seconds=${2:?}; shift 2 ;;
            --rebuild) rebuild=1; shift ;;
            --foreground) foreground=1; shift ;;
            --) shift; simulator_arguments=("$@"); break ;;
            [A-Za-z_][A-Za-z0-9_]*=*) make_overrides+=("$1"); shift ;;
            *) die "unsupported start argument: $1" ;;
        esac
    done

    [[ ${harts} == 1 || ${harts} == 2 || ${harts} == 4 ]] ||
        die "--harts must be 1, 2, or 4"
    [[ -n ${name} ]] || die "start requires --name"
    [[ ${threads} =~ ^[1-9][0-9]*$ ]] || die "--threads must be positive"
    [[ ${zicclsm} == 0 || ${zicclsm} == 1 ]] ||
        die "--zicclsm must be 0 or 1"
    [[ ${max_cycles} =~ ^[1-9][0-9]*$ ]] ||
        die "--max-cycles must be positive"
    [[ ${checkpoint_cycles} =~ ^[0-9]+$ ]] ||
        die "--checkpoint must be nonnegative"
    [[ ${checkpoint_interval} =~ ^[0-9]+$ ]] ||
        die "--checkpoint-interval must be nonnegative"
    if [[ -n ${checkpoint_stop_pc} &&
          ! ${checkpoint_stop_pc} =~ ^(0[xX][0-9A-Fa-f]+|[0-9]+)$ ]]; then
        die "--checkpoint-stop-pc must be an integer"
    fi
    if [[ -n ${checkpoint_stop_pc} && ${checkpoint_interval} == 0 ]]; then
        die "--checkpoint-stop-pc requires --checkpoint-interval"
    fi
    [[ ${stop_cycles} =~ ^[0-9]+$ ]] ||
        die "--stop-cycles must be nonnegative"
    [[ ${host_pc_sample_period} =~ ^[0-9]+$ ]] ||
        die "--host-pc-sample-period must be nonnegative"
    if [[ -n ${ticket_lock_paddr} &&
          ! ${ticket_lock_paddr} =~ ^(0[xX][0-9A-Fa-f]+|[0-9]+)$ ]]; then
        die "--ticket-lock-paddr must be an integer"
    fi
    if ((host_pc_trace == 1 && host_pc_sample_period > 0)); then
        die "--host-pc-trace and --host-pc-sample-period are mutually exclusive"
    fi
    if ((checkpoint_exit == 1 && checkpoint_cycles == 0)); then
        die "--checkpoint-exit requires a nonzero --checkpoint"
    fi
    if [[ -n ${resume_simulator} && -z ${resume_checkpoint} ]]; then
        die "--resume-simulator requires --resume"
    fi
    if [[ -n ${simulator_override} && -n ${resume_checkpoint} ]]; then
        die "--simulator cannot be combined with --resume"
    fi
    if [[ -n ${base_inputs} && -n ${resume_checkpoint} ]]; then
        die "--base-inputs cannot be combined with --resume"
    fi
    if [[ -n ${base_inputs} && -n ${simulator_override} ]]; then
        die "--base-inputs and --simulator are mutually exclusive"
    fi
    if [[ -n ${l1d_watch_vaddr} &&
          ! ${l1d_watch_vaddr} =~ ^(0[xX][0-9A-Fa-f]+|[0-9]+)$ ]]; then
        die "--l1d-watch-vaddr must be an integer"
    fi
    if [[ -n ${l1d_watch_paddr} &&
          ! ${l1d_watch_paddr} =~ ^(0[xX][0-9A-Fa-f]+|[0-9]+)$ ]]; then
        die "--l1d-watch-paddr must be an integer"
    fi
    if [[ -n ${l1d_watch_paddr} && -z ${l1d_watch_vaddr} ]]; then
        die "--l1d-watch-paddr requires --l1d-watch-vaddr"
    fi
    if [[ -n ${l1d_watch_value} &&
          ! ${l1d_watch_value} =~ ^(0[xX][0-9A-Fa-f]+|[0-9]+)$ ]]; then
        die "--l1d-watch-value must be an integer"
    fi
    if [[ -n ${l1d_watch_value} && -z ${l1d_watch_vaddr} ]]; then
        die "--l1d-watch-value requires --l1d-watch-vaddr"
    fi
    if ((l1d_watch_all_mshrs == 1)) && [[ -z ${l1d_watch_vaddr} ]]; then
        die "--l1d-watch-all-mshrs requires --l1d-watch-vaddr"
    fi
    [[ ${monitor_seconds} =~ ^[1-9][0-9]*$ ]] ||
        die "--monitor-seconds must be positive"
    [[ ${timeout_seconds} =~ ^[0-9]+$ ]] ||
        die "--timeout-seconds must be nonnegative"
    [[ -f ${repo_root}/${image} || -f ${image} ]] ||
        die "Linux image does not exist: ${image}"
    for argument in "${simulator_arguments[@]}"; do
        [[ ${argument} == +* ]] ||
            die "simulator argument must start with +: ${argument}"
    done
    [[ -n ${comment} ]] || comment=${name}

    cd "${repo_root}"
    image=$(realpath -m "${image}")
    command -v riscv64-linux-gnu-nm >/dev/null 2>&1 ||
        die "riscv64-linux-gnu-nm is required for PC symbol maps"
    if [[ -n ${kernel_elf} ]]; then
        kernel_elf=$(realpath -m "${kernel_elf}")
        [[ -f ${kernel_elf} ]] ||
            die "kernel ELF does not exist: ${kernel_elf}"
        local kernel_build_image
        kernel_build_image=$(dirname "${kernel_elf}")/arch/riscv/boot/Image
        if [[ ! -f ${kernel_build_image} &&
              -f $(dirname "${kernel_elf}")/Image.smp ]]; then
            # Managed run snapshots retain the verified image beside vmlinux
            # rather than reproducing the kernel build-tree hierarchy.
            kernel_build_image=$(dirname "${kernel_elf}")/Image.smp
        fi
        [[ -f ${kernel_build_image} ]] ||
            die "kernel ELF lacks a source-matched Image: ${kernel_elf}"
        cmp -s "${image}" "${kernel_build_image}" ||
            die "kernel ELF Image does not match --image: ${kernel_elf}"
    fi
    if [[ -n ${resume_checkpoint} ]]; then
        resume_checkpoint=$(resolve_checkpoint "${resume_checkpoint}")
    fi
    if [[ -n ${resume_simulator} ]]; then
        resume_simulator=$(realpath -m "${resume_simulator}")
        [[ -x ${resume_simulator} ]] ||
            die "resume simulator is not executable: ${resume_simulator}"
    fi
    if [[ -n ${simulator_override} ]]; then
        simulator_override=$(realpath -m "${simulator_override}")
        [[ -x ${simulator_override} ]] ||
            die "simulator is not executable: ${simulator_override}"
    fi
    if [[ -n ${base_inputs} ]]; then
        base_inputs=$(realpath -m "${base_inputs}")
        [[ -d ${base_inputs} ]] ||
            die "base input directory does not exist: ${base_inputs}"
        local base_artifact
        for base_artifact in trampoline.memh fw_jump.memh fw_jump.elf \
            openrv64-3p-dtb.memh openrv64-3p.dtb hsm-wfi-pc.txt; do
            [[ -f ${base_inputs}/${base_artifact} ]] ||
                die "base input directory is missing: ${base_artifact}"
        done
        if ((rebuild == 0)); then
            [[ -x ${base_inputs}/opensbi_4h_checkpoint_tb ]] ||
                die "base simulator is not executable: ${base_inputs}/opensbi_4h_checkpoint_tb"
        fi
    fi
    local timestamp slug run_id directory tmux_session task_name
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    slug=$(slugify "${name}")
    [[ -n ${slug} ]] || die "--name has no filesystem-safe characters"
    run_id=${OPENRV64_SMP_RUN_ID:-"${timestamp}-${harts}h-${slug}"}
    [[ ${run_id} =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "run ID must match [A-Za-z0-9._-]+: ${run_id}"
    directory=${run_root}/${run_id}
    [[ ! -e ${directory} ]] || directory=${directory}-$$
    run_id=${directory##*/}
    tmux_session=${OPENRV64_SMP_TMUX_SESSION:-"openrv64-smp-${harts}h-${timestamp}"}
    task_name=${OPENRV64_SMP_TASK_NAME:-"linux-smp-${harts}h-${slug}"}
    [[ ${tmux_session} =~ ^[A-Za-z0-9_-]+$ ]] ||
        die "tmux session must match [A-Za-z0-9_-]+: ${tmux_session}"
    mkdir -p "${directory}"

    local core_instances=4
    [[ ${harts} != 1 ]] || core_instances=1
    local make_arguments=(
        "OPENSBI_4H_HELD_MEMORY_BYTES=268435456"
        "OPENSBI_4H_HELD_MEMORY_SIZE=0x10000000"
        "OPENSBI_4H_HELD_FDT_ADDR=0x8ff00000"
        "OPENSBI_4H_HELD_FDT_BASE=2414870528"
        "OPENSBI_4H_HELD_VERILATOR_THREADS=${threads}"
        "OPENSBI_4H_HELD_CORE_INSTANCES=${core_instances}"
        "OPENSBI_SMP_LINUX_IMAGE=${image}"
        "OPENSBI_SMP_LINUX_MEMORY_BYTES=268435456"
        "OPENSBI_SMP_LINUX_MEMORY_SIZE=0x10000000"
        "OPENSBI_SMP_LINUX_FDT_ADDR=0x8ff00000"
        "OPENSBI_SMP_LINUX_FDT_BASE=2414870528"
        "OPENSBI_SMP_LINUX_MAX_CYCLES=${max_cycles}"
        "OPENSBI_2H_LINUX_VERILATOR_THREADS=${threads}"
        "OPENSBI_4H_LINUX_VERILATOR_THREADS=${threads}"
        "OPENSBI_1H_LINUX_VERILATOR_THREADS=${threads}"
        "OPENSBI_3P_ADVERTISE_ZICCLSM=${zicclsm}"
        "LINUX_IMAGE=${image}"
    )
    make_arguments+=("${make_overrides[@]}")
    printf '%s\n' "${make_arguments[@]}" >"${directory}/make-arguments.txt"
    : >"${directory}/simulator-arguments.txt"
    if ((${#simulator_arguments[@]})); then
        printf '%s\n' "${simulator_arguments[@]}" \
            >"${directory}/simulator-arguments.txt"
    fi
    printf '%s\n' "${name}" >"${directory}/test-name.txt"
    printf '%s\n' "${comment}" >"${directory}/comment.txt"

    local recorded_command
    recorded_command=${OPENRV64_SMP_RECORDED_COMMAND:-}
    if [[ -z ${recorded_command} ]]; then
        recorded_command=$(shell_join tools/run-linux-smp.sh \
            "${original_arguments[@]}")
    fi
    local config_path=${OPENRV64_SMP_CONFIG_PATH:-}
    local config_snapshot=
    if [[ -n ${config_path} ]]; then
        config_path=$(realpath -m "${config_path}")
        [[ -f ${config_path} ]] || die "configuration not found: ${config_path}"
        config_snapshot=${directory}/run.cfg
        cp --reflink=auto --preserve=mode,timestamps \
            "${config_path}" "${config_snapshot}"
    fi
    {
        printf 'run_id=%q\n' "${run_id}"
        printf 'run_dir=%q\n' "${directory}"
        printf 'run_target=%q\n' linux-smp
        printf 'backend=%q\n' tools/run-linux-smp.sh
        printf 'harts=%q\n' "${harts}"
        printf 'threads=%q\n' "${threads}"
        printf 'image=%q\n' "${image}"
        printf 'kernel_elf=%q\n' "${kernel_elf}"
        printf 'zicclsm=%q\n' "${zicclsm}"
        printf 'max_cycles=%q\n' "${max_cycles}"
        printf 'checkpoint_cycles=%q\n' "${checkpoint_cycles}"
        printf 'checkpoint_exit=%q\n' "${checkpoint_exit}"
        printf 'checkpoint_interval=%q\n' "${checkpoint_interval}"
        printf 'checkpoint_stop_pc=%q\n' "${checkpoint_stop_pc}"
        printf 'resume_checkpoint=%q\n' "${resume_checkpoint}"
        printf 'resume_simulator=%q\n' "${resume_simulator}"
        printf 'base_inputs=%q\n' "${base_inputs}"
        printf 'simulator_override=%q\n' "${simulator_override}"
        printf 'host_pc_trace=%q\n' "${host_pc_trace}"
        printf 'host_pc_sample_period=%q\n' "${host_pc_sample_period}"
        printf 'l1d_watch_vaddr=%q\n' "${l1d_watch_vaddr}"
        printf 'l1d_watch_paddr=%q\n' "${l1d_watch_paddr}"
        printf 'l1d_watch_value=%q\n' "${l1d_watch_value}"
        printf 'l1d_watch_all_mshrs=%q\n' "${l1d_watch_all_mshrs}"
        printf 'ticket_lock_paddr=%q\n' "${ticket_lock_paddr}"
        printf 'stop_cycles=%q\n' "${stop_cycles}"
        printf 'monitor_seconds=%q\n' "${monitor_seconds}"
        printf 'rebuild=%q\n' "${rebuild}"
        printf 'timeout_seconds=%q\n' "${timeout_seconds}"
        printf 'tmux_session=%q\n' "${tmux_session}"
        printf 'task_name=%q\n' "${task_name}"
        printf 'recorded_command=%q\n' "${recorded_command}"
        printf 'config_path=%q\n' "${config_path}"
        printf 'config_snapshot=%q\n' "${config_snapshot}"
    } >"${directory}/manager.env"

    if ((foreground == 1)); then
        openrv64_run_with_timeout "${timeout_seconds}" "${directory}" \
            "${task_name}" "${repo_root}/tools/run-linux-smp.sh" \
            _worker "${directory}"
        return
    fi
    command -v tmux >/dev/null 2>&1 || die "tmux is not installed"
    local worker_command
    worker_command=$(shell_join env "OPENRV64_SMP_RUN_ROOT=${run_root}" \
        "${repo_root}/tools/run-linux-smp.sh" _timed_worker "${directory}")
    tmux new-session -d -s "${tmux_session}" -c "${repo_root}" \
        "${worker_command}"
    notify "Started ${harts}H Linux SMP run ${run_id}; ${directory}" \
        "${task_name}"
    printf 'run_id=%s\nrun_dir=%s\ntmux_session=%s\n' \
        "${run_id}" "${directory}" "${tmux_session}"
}

status_run() {
    local directory
    directory=$(resolve_run "${1:-latest}")
    # shellcheck disable=SC1090
    source "${directory}/manager.env"
    local state=lost
    if [[ -f ${directory}/status ]]; then
        state=finished
    elif tmux has-session -t "=${tmux_session}" 2>/dev/null ||
         [[ -n $(find "${directory}/heartbeat" -mmin -2 -print \
             2>/dev/null) ]]; then
        state=active
    fi
    printf 'run_id=%s\nstate=%s\nharts=%s\nthreads=%s\nrun_dir=%s\ntmux_session=%s\n' \
        "${run_id}" "${state}" "${harts}" "${threads}" "${directory}" \
        "${tmux_session}"
    [[ ! -f ${directory}/status ]] || sed -n 'p' "${directory}/status"
    local latest
    latest=$(rg 'OPENSBI_4H_PROGRESS|LINUX_SMP_ONLINE|CHECKPOINT SAVED|linux_panic=1|openrv64#|PASS:|%Fatal:' \
        "${directory}/run.log" 2>/dev/null | tail -1 || true)
    [[ -z ${latest} ]] || printf 'latest=%s\n' "${latest}"
}

list_runs() {
    local env_file directory state
    while IFS= read -r env_file; do
        directory=${env_file%/manager.env}
        # shellcheck disable=SC1090
        source "${env_file}"
        state=lost
        if [[ -f ${directory}/status ]]; then
            state=finished
        elif tmux has-session -t "=${tmux_session}" 2>/dev/null ||
             [[ -n $(find "${directory}/heartbeat" -mmin -2 -print \
                 2>/dev/null) ]]; then
            state=active
        fi
        printf '%-46s %-8s harts=%s threads=%s\n' \
            "${run_id}" "${state}" "${harts}" "${threads}"
    done < <(find "${run_root}" -mindepth 2 -maxdepth 2 \
        -name manager.env -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | sed 's/^[^ ]* //')
}

log_run() {
    local directory
    directory=$(resolve_run "${1:-latest}")
    local lines=${2:-80}
    [[ ${lines} =~ ^[1-9][0-9]*$ ]] || die "LINES must be positive"
    if [[ -f ${directory}/run.log ]]; then
        tail -n "${lines}" "${directory}/run.log"
    else
        tail -n "${lines}" "${directory}/build.log"
    fi
}

tail_run() {
    local directory
    directory=$(resolve_run "${1:-latest}")
    local lines=${2:-80}
    [[ ${lines} =~ ^[1-9][0-9]*$ ]] || die "LINES must be positive"
    local build_log=${directory}/build.log
    local run_log=${directory}/run.log

    if [[ -f ${build_log} ]]; then
        exec tail --retry -n "${lines}" -F "${build_log}" "${run_log}"
    fi
    exec tail --retry -n "${lines}" -F "${run_log}"
}

attach_run() {
    local directory
    directory=$(resolve_run "${1:-latest}")
    # shellcheck disable=SC1090
    source "${directory}/manager.env"
    if ! tmux has-session -t "=${tmux_session}" 2>/dev/null; then
        die "run is not active: ${run_id}"
    fi
    if [[ -n ${TMUX:-} ]]; then
        exec tmux switch-client -t "=${tmux_session}"
    fi
    exec tmux attach-session -t "=${tmux_session}"
}

path_run() {
    resolve_run "${1:-latest}"
    printf '\n'
}

checkpoint_run() {
    local directory
    directory=$(resolve_run "${1:-latest}")
    local found=0
    local checkpoint
    while IFS= read -r checkpoint; do
        found=1
        printf '%s %s bytes\n' "${checkpoint}" "$(stat -c %s "${checkpoint}")"
    done < <(find "${directory}" -maxdepth 1 -type f \
        \( -name 'checkpoint-*.vls' -o -name resume.vls \) \
        -print | sort)
    ((found == 1)) || die "no checkpoint found: ${directory}"
}

command_run() {
    local directory
    directory=$(resolve_run "${1:-latest}")
    # shellcheck disable=SC1090
    source "${directory}/manager.env"
    printf 'launch=%s\n' "${recorded_command}"
    if [[ -f ${directory}/run.log ]]; then
        sed -n 's/^command=/simulator=/p' "${directory}/run.log" | head -1
    fi
}

wait_run() {
    local directory
    directory=$(resolve_run "${1:-latest}")
    # shellcheck disable=SC1090
    source "${directory}/manager.env"
    while tmux has-session -t "=${tmux_session}" 2>/dev/null; do
        sleep 5
    done
    status_run "${directory}"
}

stop_run() {
    local directory
    directory=$(resolve_run "${1:-latest}")
    # shellcheck disable=SC1090
    source "${directory}/manager.env"
    if ! tmux has-session -t "=${tmux_session}" 2>/dev/null; then
        die "run is not active: ${run_id}"
    fi
    # send-keys resolves a target-pane, unlike has-session's target-session.
    # A leading '=' is consequently parsed as part of the pane name on tmux
    # versions without exact pane matching.  Select the session's current pane
    # explicitly instead.
    tmux send-keys -t "${tmux_session}:" C-c
    printf 'stop_requested=%s\n' "${run_id}"
}

main() {
    local command=${1:-}
    [[ -n ${command} ]] || { usage; exit 2; }
    shift || true
    case "${command}" in
        config) exec "${repo_root}/run/run" "$@" ;;
        start) start_run "$@" ;;
        status) status_run "$@" ;;
        list|ls) list_runs "$@" ;;
        log) log_run "$@" ;;
        tail|follow) tail_run "$@" ;;
        attach) attach_run "$@" ;;
        path) path_run "$@" ;;
        checkpoint) checkpoint_run "$@" ;;
        command) command_run "$@" ;;
        wait) wait_run "$@" ;;
        stop) stop_run "$@" ;;
        _worker) worker "$@" ;;
        _timed_worker)
            openrv64_run_load_manager "$1"
            openrv64_run_with_timeout "${timeout_seconds:-259200}" "$1" \
                "${task_name:-linux-smp}" \
                "${repo_root}/tools/run-linux-smp.sh" _worker "$1"
            ;;
        -h|--help|help) usage ;;
        *) die "unknown command: ${command}" ;;
    esac
}

main "$@"
