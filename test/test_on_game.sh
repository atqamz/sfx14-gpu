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
add_module nvidia_drm
add_module nvidia
set_runtime suspended
EXTRA_ENV=(SFX14_FAKE_PM1_STAYS_SUSPENDED=1)
sfx on
assert_status 1 "on fails when persistence does not wake the dGPU"
assert_contains "dGPU not active after" "on reports the unverified state"
assert_contains "persistence is enabled" "on reports what it did change"

new_env
sfx on
assert_status 0 "on loads missing modules"
assert_file_contains "$LOG" "modprobe nvidia_drm nvidia" "on modprobes both modules"
assert_file_contains "$LOG" "nvidia-smi -pm 1" "on enables persistence after modprobe"

new_env
add_module nvidia_drm
add_module nvidia
set_runtime suspended
sfx on --no-persist
assert_status 0 "on --no-persist succeeds"
assert_file_not_contains "$LOG" "nvidia-smi -pm 1" "on --no-persist leaves persistence alone"
assert_file_contains "$LOG" "nvidia-smi -q" "on --no-persist performs a read-only wake"
assert_eq "active" "$(cat "$SYS/bus/pci/devices/$BDF/power/runtime_status")" "on --no-persist actually wakes the dGPU"
assert_contains "dGPU active; persistence left off" "on --no-persist reports the observed state"

new_env
add_module nvidia_drm
add_module nvidia
set_runtime suspended
EXTRA_ENV=(SFX14_FAKE_QUERY_STAYS_SUSPENDED=1)
sfx on --no-persist
assert_status 0 "on --no-persist does not lie when the dGPU stays suspended"
assert_file_contains "$LOG" "nvidia-smi -q" "on --no-persist still performs the wake read"
assert_contains "dGPU still suspended" "on --no-persist reports the real suspended state"
assert_contains "persistence left off" "on --no-persist explains what it left off"
assert_contains "client that opens /dev/nvidia*" "on --no-persist says a client will wake the dGPU"
assert_not_contains "dGPU active" "on --no-persist never claims a suspended dGPU is active"

new_env
add_module nvidia_drm
add_module nvidia
sfx on --no-persist --dry-run
assert_status 0 "on --no-persist --dry-run exits zero"
assert_contains "nvidia-smi -q (read-only wake)" "on --no-persist --dry-run prints the wake read"
assert_file_empty "$LOG" "on --no-persist --dry-run runs nothing"

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
set_runtime suspended
sfx game off
assert_status 0 "game off succeeds on a suspended dGPU"
assert_contains "skipping -rgc" "game off explains the skipped clock reset"
assert_file_not_contains "$LOG" "nvidia-smi -rgc" "game off skips -rgc while suspended"
assert_file_contains "$LOG" "nvidia-smi -pm 0" "game off still clears persistence while suspended"
assert_contains "persistence off" "game off reports persistence off"

new_env
sfx game on --dry-run
assert_status 0 "game on --dry-run exits zero"
assert_contains "would run:" "game on --dry-run prints the plan"
assert_contains "210,1540" "game on --dry-run prints the clock range"
assert_file_empty "$LOG" "game on --dry-run runs nothing"

finish
