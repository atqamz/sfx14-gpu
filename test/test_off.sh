#!/usr/bin/env bash
# off: safety refusals, persistence handling, polling and dry-run.
# SPDX-License-Identifier: MIT
set -uo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

new_env
sfx off
assert_status 0 "off succeeds on an already suspended GPU"
assert_contains "already suspended (D3cold)" "off reports the already-off state"
assert_file_empty "$LOG" "off does not call nvidia-smi when already off"

new_env
sfx off --force
assert_status 0 "off --force skips the already-off check"
assert_file_contains "$LOG" "nvidia-smi -pm 0" "off --force sends -pm 0"
assert_contains "dGPU suspended (D3cold)" "off --force reports suspension"

new_env
set_runtime active
set_pm Enabled
EXTRA_ENV=(SFX14_FAKE_PM0_SUSPENDS=1)
sfx off
assert_status 0 "off succeeds when persistence was the only holder"
assert_file_contains "$LOG" "nvidia-smi -pm 0" "off disables persistence mode"
assert_contains "dGPU suspended (D3cold)" "off reports the polled suspension"
assert_eq "Disabled" "$(cat "$ENV_ROOT/pm")" "off leaves persistence disabled"

new_env
set_runtime active
add_client 4242 cuda-app /dev/nvidia0
sfx off
assert_status 1 "off refuses while a client holds the GPU"
assert_contains "refusing" "off explains the refusal"
assert_contains "pid 4242 (cuda-app)" "off names the holding client"
assert_contains "never kills" "off states that it never kills processes"
assert_file_not_contains "$LOG" "nvidia-smi -pm 0" "off does not touch persistence after refusing"

new_env
set_runtime active
add_client 4242 cuda-app /dev/nvidia0
sfx off --force
assert_status 1 "off --force does not skip client safety"
assert_contains "refusing" "off --force still refuses a live client"
assert_file_not_contains "$LOG" "nvidia-smi -pm 0" "off --force does not touch persistence after refusing"

new_env
set_runtime active
add_compositor 111 Hyprland
sfx off
assert_status 1 "off refuses while an unconfigured compositor holds the GPU"
assert_contains "refusing" "off explains the compositor refusal"
assert_contains "AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card" "off gives the stable compositor next step"
assert_file_not_contains "$LOG" "nvidia-smi -pm 0" "off does not touch persistence after a compositor refusal"

new_env
set_runtime active
add_compositor 111 Hyprland /dev/dri/by-path/pci-0000:00:02.0-card
EXTRA_ENV=(SFX14_FAKE_PM0_SUSPENDS=1)
sfx off
assert_status 0 "off proceeds when the compositor already ignores the dGPU"
assert_file_contains "$LOG" "nvidia-smi -pm 0" "off disables persistence with a configured compositor"

new_env
rm "$SYS/class/drm/card0/device"
rmdir "$SYS/class/drm/card0"
mkdir -p "$SYS/class/drm/card2"
ln -s "../../../bus/pci/devices/0000:00:02.0" "$SYS/class/drm/card2/device"
set_runtime active
add_compositor 111 Hyprland
sfx off
assert_status 1 "off refuses an unconfigured compositor with shifted card numbers"
assert_contains "AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card" "off derives the stable iGPU path with shifted card numbers"
assert_not_contains "AQ_DRM_DEVICES=/dev/dri/card" "off never recommends a numeric card node"

new_env
set_runtime active
set_pm Enabled
POLL_TIMEOUT=1
sfx off
assert_status 1 "off fails when the GPU stays active"
assert_contains "still active after 1s" "off reports the poll timeout"
assert_contains "persistence" "off names the remaining persistence holder"
assert_contains "Next steps:" "off prints next steps"
assert_file_contains "$LOG" "nvidia-smi -pm 0" "off attempted to disable persistence"

new_env
set_runtime active
POLL_TIMEOUT=1.5
sfx off
assert_status 1 "off rejects a fractional poll timeout"
assert_contains "SFX14_POLL_TIMEOUT must be a whole number of seconds" "off explains the bad poll timeout"
assert_file_empty "$LOG" "off runs nothing with a bad poll timeout"

new_env
set_runtime active
sfx off --dry-run
assert_status 0 "off --dry-run exits zero"
assert_contains "would run:" "off --dry-run prints the plan"
assert_contains "-pm 0" "off --dry-run prints -pm 0"
assert_file_empty "$LOG" "off --dry-run runs nothing"

finish
