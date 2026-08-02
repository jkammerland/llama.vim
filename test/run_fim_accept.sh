#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec nvim --clean -u NONE -i NONE -n --headless -S "${test_dir}/fim_accept.vim"
