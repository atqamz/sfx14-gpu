#!/usr/bin/env bash
# DRM scan: connectors are not cards, the iGPU is the Intel vendor, and the
# recommended AQ_DRM_DEVICES path is the stable by-path link.
# SPDX-License-Identifier: MIT
set -uo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

new_env
set_runtime active
mkdir -p "$SYS/class/drm/card0-HDMI-A-1" "$SYS/class/drm/card0-eDP-1"
ln -s ../card0 "$SYS/class/drm/card0-HDMI-A-1/device"
ln -s ../card0 "$SYS/class/drm/card0-eDP-1/device"
add_compositor 111 Hyprland
sfx off
assert_status 1 "off refuses with connectors present"
assert_contains "AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card" "connectors do not replace the iGPU card"
assert_not_contains "card0-HDMI" "off never recommends a connector node"

new_env
rm "$SYS/class/drm/card0/device"
rmdir "$SYS/class/drm/card0"
mkdir -p "$SYS/class/drm/card2"
ln -s "../../../bus/pci/devices/0000:00:02.0" "$SYS/class/drm/card2/device"
mkdir -p "$SYS/class/drm/card2-eDP-1"
ln -s ../card2 "$SYS/class/drm/card2-eDP-1/device"
set_runtime active
add_compositor 111 Hyprland
sfx off
assert_status 1 "off refuses with a shifted iGPU card number"
assert_contains "AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card" "the by-path link survives shifted numbering"
assert_not_contains "AQ_DRM_DEVICES=/dev/dri/card2" "off does not recommend the shifted numeric node"

new_env
rm "$SYS/class/drm/card0/device"
rmdir "$SYS/class/drm/card0"
mkdir -p "$SYS/class/drm/card1-HDMI-A-1"
ln -s ../card1 "$SYS/class/drm/card1-HDMI-A-1/device"
sfx status
assert_status 1 "status fails clearly without an Intel iGPU"
assert_contains "no Intel iGPU (vendor 8086)" "status explains the missing Intel iGPU"

finish
