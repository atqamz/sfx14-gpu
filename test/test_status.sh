#!/usr/bin/env bash
# status: suspended, active with holders, /proc details, JSON shape.
# SPDX-License-Identifier: MIT
set -uo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

new_env
add_proc_power
sfx status
assert_status 0 "status exits zero when suspended"
assert_contains "runtime_status: suspended" "status reads runtime_status"
assert_contains "dGPU suspended (D3cold)" "status gives the suspended verdict"
assert_contains "Runtime D3:" "status shows the NVIDIA runtime D3 line"
assert_contains "Enabled (fine-grained)" "status shows fine-grained D3"
assert_contains "video memory:   Active" "status shows video memory"
assert_contains "persistence:    unavailable" "status says persistence is unavailable"
assert_contains "compositor:     none" "status reports no compositor"
assert_not_contains "held by" "suspended verdict lists no holders"

sfx status --json
assert_status 0 "status --json exits zero"
assert_eq "0000:01:00.0" "$(json_get bdf)" "json carries the BDF"
assert_eq "NVIDIA GeForce RTX 4050 Laptop GPU" "$(json_get gpu)" "json carries the GPU model"
assert_eq "suspended" "$(json_get runtime_status)" "json carries runtime_status"
assert_eq "suspended" "$(json_get verdict)" "json carries the verdict"
assert_eq "[]" "$(json_get clients)" "json has no clients"
assert_eq "null" "$(json_get clocks.graphics)" "json has no clocks while suspended"
assert_eq "null" "$(json_get persistence_mode)" "json uses null for unreadable persistence"

new_env
set_runtime active
set_pm Enabled
add_client 4242 cuda-app /dev/nvidia0
add_compositor 111 Hyprland /dev/dri/by-path/pci-0000:00:02.0-card
sfx status
assert_status 0 "status exits zero when active"
assert_contains "runtime_status: active" "status reads the active state"
assert_contains "persistence:    Enabled" "status reads persistence mode"
assert_contains "dGPU active — held by" "status gives the active verdict"
assert_contains "client 4242 (cuda-app) (/dev/nvidia0)" "status names the holding client"
assert_contains "persistence mode" "status lists persistence as a holder"
assert_contains "AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card" "status shows the compositor override"

new_env
set_runtime active
set_pm Disabled
add_compositor 111 Hyprland "" /dev/dri/card1
sfx status
assert_status 0 "status exits zero with a compositor holder"
assert_contains "compositor Hyprland (pid 111)" "status names the holding compositor"
assert_contains "dGPU active — held by" "status gives the active verdict with a compositor"

new_env
set_runtime active
set_pm Enabled
add_client 4242 cuda-app /dev/nvidia0
sfx status --json
assert_status 0 "status --json exits zero when active"
assert_eq "4242" "$(json_get clients.0.pid)" "json carries the client pid"
assert_eq "cuda-app" "$(json_get clients.0.name)" "json carries the client name"
assert_eq "/dev/nvidia0" "$(json_get clients.0.device)" "json carries the client device"
assert_eq "210 MHz" "$(json_get clocks.graphics)" "json carries the graphics clock"
assert_eq "client 4242 (cuda-app) (/dev/nvidia0)" "$(json_get held_by.0)" "json carries the held-by list"

new_env
set_runtime active
mkdir -p "$PROC/9999/fd"
printf 'hidden\n' > "$PROC/9999/comm"
chmod 000 "$PROC/9999/fd"
sfx status
assert_status 0 "status survives an uninspectable /proc entry"
assert_contains "dGPU active — held by unknown" "status reports unknown holders"
if [ "$(id -u)" -ne 0 ]; then
  assert_contains "1 process(es) could not be inspected" "status counts uninspectable processes"
  assert_contains "run as root for /proc details" "status suggests root when not root"
else
  assert_not_contains "run as root for /proc details" "status omits the root hint when root"
fi
chmod 755 "$PROC/9999/fd"

finish
