#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
    echo "usage: $0 RUN_ID BUCKET_CYCLES" >&2
    exit 2
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
run_id=$1
bucket_cycles=$2
[[ ${run_id} =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "unsafe run ID: ${run_id}" >&2
    exit 2
}
[[ ${bucket_cycles} =~ ^[1-9][0-9]*$ ]] || {
    echo "BUCKET_CYCLES must be a positive integer" >&2
    exit 2
}

run_dir=${repo}/run/log/${run_id}
[[ -d ${run_dir} ]] || {
    echo "run does not exist: ${run_id}" >&2
    exit 1
}
state_file=${run_dir}/host-pc-function-histogram-${bucket_cycles}-cycle.state
output=${run_dir}/host-pc-function-histogram-${bucket_cycles}-cycle.tsv

printf 'state=waiting-for-run\n' >"${state_file}"
set +e
${repo}/run/run wait "${run_id}"
wait_result=$?
set -e
status=$(${repo}/run/run status "${run_id}")
if ((wait_result != 0)) || ! grep -q '^validation=pass$' <<<"${status}"; then
    printf 'state=primary-run-failed\n' >"${state_file}"
    /home/bill/bin/sendify.py \
        "${run_id} ended without PASS; bucketed PC histogram was not generated." \
        "openrv64-linux-pc-bucket-histogram"
    exit 1
fi

printf 'state=building\n' >"${state_file}"
perl "${repo}/tools/pc-sample-bucket-histogram.pl" \
    "${run_dir}/host-pc-samples.tsv" "${bucket_cycles}" \
    "${run_dir}/inputs/opensbi-symbols.map" \
    "${run_dir}/inputs/linux-symbols.map" >"${output}"

samples=$(awk '$1 ~ /^[0-9]+$/ { ++n } END { print n + 0 }' \
    "${run_dir}/host-pc-samples.tsv")
buckets=$(awk -F '\t' '$1 ~ /^[0-9]+$/ { seen[$1] = 1 } END {
    for (bucket in seen) ++n; print n + 0
}' "${output}")
printf 'state=complete\nsamples=%s\nbuckets=%s\noutput=%s\n' \
    "${samples}" "${buckets}" "${output}" >"${state_file}"
/home/bill/bin/sendify.py \
    "${run_id} passed; ${samples} PC samples grouped into ${buckets} buckets of ${bucket_cycles} cycles: ${output}" \
    "openrv64-linux-pc-bucket-histogram"
