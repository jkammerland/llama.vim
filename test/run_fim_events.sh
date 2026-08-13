#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

exec nvim --clean -u NONE -i NONE -n --headless -S "${test_dir}/fim_events.vim"
