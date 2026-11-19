#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
binary=$(mktemp)
trap 'rm -f -- "$binary"' EXIT
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic candle_logic_test.cpp -o "$binary"
"$binary"
