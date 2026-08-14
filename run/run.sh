#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility entry point. All launch and control behavior lives in run/run.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "${script_dir}/run" "$@"
