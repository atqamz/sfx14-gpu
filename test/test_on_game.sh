#!/usr/bin/env bash
# on and game: module loading, persistence flags, clock cap and VF offset.
# SPDX-License-Identifier: MIT
set -uo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

new_env
set_pm Disabled
add_module nvidia_drm
add_module nvidia
sfx on
assert_status 0 "on succeeds with loaded modules"
assert_file_contains "$LOG" "nvidia-smi -pm 1" "on enables persistence"
assert_file_not_contains "$LOG" "modprobe" "on skips modprobe when modules are loaded"
assert_contains "dGPU active" "on reports the active GPU"

new_env
sfx on
assert_status 0 "on loads missing modules"
assert_file_contains "$LOG" "modprobe nvidia_drm nvidia" "on modprobes both modules"
assert_file_contains "$LOG" "nvidia-smi -pm 1" "on enables persistence after modprobe"

new_env
add_module nvidia_drm
add_module nvidia
sfx on --no-persist
assert_status 0 "on --no-persist succeeds"
assert_file_not_contains "$LOG" "nvidia-smi -pm 1" "on --no-persist leaves persistence alone"
assert_contains "persistence left off" "on --no-persist explains the consequence"

new_env
sfx on --dry-run
assert_status 0 "on --dry-run exits zero"
assert_contains "would run: modprobe nvidia_drm nvidia" "on --dry-run prints the modprobe plan"
assert_contains "would run:" "on --dry-run prints the nvidia-smi plan"
assert_contains "-pm 1" "on --dry-run prints persistence"
assert_file_empty "$LOG" "on --dry-run runs nothing"

new_env
set_runtime active
sfx game on
assert_status 0 "game on succeeds"
assert_file_contains "$LOG" "nvidia-smi -pm 1" "game on enables persistence"
assert_file_contains "$LOG" "nvidia-smi -lgc 210,1540" "game on pins the clock range"
assert_not_contains "GPC VF offset" "game on skips the VF offset when pynvml is absent"

new_env
set_runtime active
fake_python_ok
sfx game on
assert_status 0 "game on succeeds with pynvml"
assert_contains "GPC VF offset: +200 MHz" "game on reports the VF offset"
assert_file_contains "$LOG" "nvmlDeviceSetGpcClkVfOffset" "game on calls the NVML VF offset"

new_env
set_runtime active
sfx game off
assert_status 0 "game off succeeds"
assert_file_contains "$LOG" "nvidia-smi -rgc" "game off resets the clock cap"
assert_file_contains "$LOG" "nvidia-smi -pm 0" "game off disables persistence"

new_env
sfx game on --dry-run
assert_status 0 "game on --dry-run exits zero"
assert_contains "would run:" "game on --dry-run prints the plan"
assert_contains "210,1540" "game on --dry-run prints the clock range"
assert_file_empty "$LOG" "game on --dry-run runs nothing"

finish
