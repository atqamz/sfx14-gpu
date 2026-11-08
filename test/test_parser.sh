#!/usr/bin/env bash
# Parser and CLI surface: find the NVIDIA BDF, reject missing GPUs.
# SPDX-License-Identifier: MIT
set -uo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

new_env
sfx status
assert_status 0 "status exits zero on hybrid graphics"
assert_contains "0000:01:00.0" "status selects the NVIDIA BDF"
assert_not_contains "GPU:            0000:00:02.0" "status ignores the Intel GPU"

new_env 0000:02:00.0
printf '0000:00:02.0 0300: 8086:7d55\n0000:02:00.0 0302: 10de:28a1\n' > "$ENV_ROOT/lspci"
sfx status --json
assert_status 0 "status accepts a 0302 3D controller"
assert_eq "0000:02:00.0" "$(json_get bdf)" "json reports the 0302 BDF"

new_env
printf '0000:00:02.0 0300: 8086:7d55\n' > "$ENV_ROOT/lspci"
sfx status
assert_status 1 "status fails without an NVIDIA GPU"
assert_contains "no NVIDIA GPU" "status explains the missing GPU"

sfx --version
assert_status 0 "--version exits zero"
assert_contains "sfx14-gpu 0.1.0" "--version prints the version"

sfx help
assert_status 0 "help exits zero"
assert_contains "usage: sfx14-gpu" "help prints usage"

finish
