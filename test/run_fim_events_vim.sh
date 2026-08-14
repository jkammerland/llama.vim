#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

exec vim -Nu NONE -i NONE -n -es -S "${test_dir}/fim_events.vim"
