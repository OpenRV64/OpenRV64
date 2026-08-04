#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
output=${1:-"$repo_root/sim/pdk/nangate45/NangateOpenCellLibrary_typical.lib"}
curl_bin=${CURL:-curl}

revision=f255c15b3dd4362a704b6af9f617b4091bdd4e6a
url="https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/$revision/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib"
expected_sha256=8d540a4d4cf6d09d27c87ad067857a9c0c2eeb023ab7a56e058cd3113db4e9b1

verify_liberty() {
    printf '%s  %s\n' "$expected_sha256" "$1" | sha256sum -c -
}

if [[ -f "$output" ]]; then
    verify_liberty "$output"
    exit 0
fi

mkdir -p "$(dirname -- "$output")"
temporary="$output.tmp.$$"
trap 'rm -f -- "$temporary"' EXIT

"$curl_bin" -L --fail --silent --show-error -o "$temporary" "$url"
verify_liberty "$temporary"
mv -- "$temporary" "$output"
trap - EXIT

