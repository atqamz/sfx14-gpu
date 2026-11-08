#!/usr/bin/env bash
# Shared harness: builds a fake sysfs, /proc and NVIDIA tooling for each test.
# SPDX-License-Identifier: MIT
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SFX_BIN=$REPO_ROOT/bin/sfx14-gpu

TESTS_RUN=0
TESTS_FAILED=0
OUTPUT=""
STATUS=0
ENV_ROOT=""
BDF=""
SYS=""
PROC=""
BIN=""
LOG=""
EXTRA_ENV=()
POLL_TIMEOUT=0
POLL_INTERVAL=0.01
CLIENT_FD=3

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok   %s\n' "$1"
}

fail() {
  local name=$1 detail=${2:-}
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL %s\n' "$name"
  if [ -n "$detail" ]; then
    printf '     %s\n' "$detail"
  fi
  if [ -n "$OUTPUT" ]; then
    printf '     output: %s\n' "${OUTPUT//$'\n'/$'\n'             }"
  fi
}

assert_eq() {
  local expected=$1 actual=$2 name=$3
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    fail "$name" "expected [$expected], got [$actual]"
  fi
}

assert_contains() {
  local needle=$1 name=$2
  if [[ $OUTPUT == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "missing [$needle]"
  fi
}

assert_not_contains() {
  local needle=$1 name=$2
  if [[ $OUTPUT != *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "unexpected [$needle]"
  fi
}

assert_status() {
  local expected=$1 name=$2
  if [ "$STATUS" -eq "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expected exit $expected, got $STATUS"
  fi
}

assert_file_contains() {
  local file=$1 needle=$2 name=$3
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    pass "$name"
  else
    fail "$name" "missing [$needle] in $file"
  fi
}

assert_file_not_contains() {
  local file=$1 needle=$2 name=$3
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    fail "$name" "unexpected [$needle] in $file"
  else
    pass "$name"
  fi
}

assert_file_empty() {
  local file=$1 name=$2
  if [ ! -s "$file" ]; then
    pass "$name"
  else
    fail "$name" "$file is not empty: $(tr '\n' ';' < "$file")"
  fi
}

# Print a dotted path from the last status --json output; lists use numeric keys.
json_get() {
  local expr=$1
  printf '%s' "$OUTPUT" | python3 -c '
import json, sys

value = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif value is None:
    print("null")
else:
    print(value)
' "$expr"
}

cleanup() {
  if [ -n "${ENV_ROOT:-}" ]; then
    case $ENV_ROOT in
      "${TMPDIR:-/tmp}"/sfx14-test.*) rm -rf "$ENV_ROOT" ;;
    esac
  fi
  ENV_ROOT=""
}

finish() {
  cleanup
  printf '%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}

make_fakes() {
  cat > "$BIN/lspci" <<'EOF'
#!/usr/bin/env bash
cat "$SFX14_FAKE_ROOT/lspci"
EOF

  cat > "$BIN/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
root=${SFX14_FAKE_ROOT:?}
bdf=$(cat "$root/bdf")
state=$SFX14_SYSFS/bus/pci/devices/$bdf/power/runtime_status
printf 'nvidia-smi %s\n' "$*" >> "$root/calls.log"

case ${1:-} in
  --query-gpu=*)
    if [ "$(cat "$state" 2>/dev/null)" = suspended ]; then
      echo "Unable to determine the device handle for GPU $bdf: GPU is lost." >&2
      exit 6
    fi
    IFS=, read -ra fields <<< "${1#--query-gpu=}"
    out=()
    for field in "${fields[@]}"; do
      case $field in
        persistence_mode) out+=("$(cat "$root/pm")") ;;
        clocks.gr) out+=("${SFX14_FAKE_GR:-210 MHz}") ;;
        clocks.mem) out+=("${SFX14_FAKE_MEM:-405 MHz}") ;;
        power.draw) out+=("${SFX14_FAKE_POWER:-4.90 W}") ;;
        *) out+=(N/A) ;;
      esac
    done
    IFS=', '
    echo "${out[*]}"
    ;;
  -pm)
    case ${2:-} in
      0)
        printf 'Disabled\n' > "$root/pm"
        if [ "${SFX14_FAKE_PM0_SUSPENDS:-0}" = 1 ]; then
          printf 'suspended\n' > "$state"
        fi
        ;;
      1)
        printf 'Enabled\n' > "$root/pm"
        printf 'active\n' > "$state"
        ;;
      *)
        echo "unexpected -pm argument" >&2
        exit 2
        ;;
    esac
    ;;
  -lgc|-rgc) ;;
  *)
    echo "unexpected nvidia-smi arguments: $*" >&2
    exit 2
    ;;
esac
EOF

  cat > "$BIN/modprobe" <<'EOF'
#!/usr/bin/env bash
root=${SFX14_FAKE_ROOT:?}
printf 'modprobe %s\n' "$*" >> "$root/calls.log"
mkdir -p "$SFX14_SYSFS/module/nvidia_drm" "$SFX14_SYSFS/module/nvidia"
EOF

  cat > "$BIN/python" <<'EOF'
#!/usr/bin/env bash
root=${SFX14_FAKE_ROOT:?}
printf 'python %s\n' "$*" >> "$root/calls.log"
exit 1
EOF

  chmod +x "$BIN/lspci" "$BIN/nvidia-smi" "$BIN/modprobe" "$BIN/python"
}

new_env() {
  cleanup
  BDF=${1:-0000:01:00.0}
  ENV_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sfx14-test.XXXXXX")
  SYS=$ENV_ROOT/sys
  PROC=$ENV_ROOT/proc
  BIN=$ENV_ROOT/bin
  LOG=$ENV_ROOT/calls.log
  mkdir -p "$SYS/bus/pci/devices/$BDF/power" "$SYS/bus/pci/devices/0000:00:02.0" \
    "$SYS/class/drm/card0" "$SYS/class/drm/card1" "$PROC" "$BIN"
  : > "$LOG"
  printf '%s\n' "$BDF" > "$ENV_ROOT/bdf"
  printf 'auto\n' > "$SYS/bus/pci/devices/$BDF/power/control"
  printf 'suspended\n' > "$SYS/bus/pci/devices/$BDF/power/runtime_status"
  printf 'Disabled\n' > "$ENV_ROOT/pm"
  printf '0x8086\n' > "$SYS/bus/pci/devices/0000:00:02.0/vendor"
  ln -s "../../../bus/pci/devices/$BDF" "$SYS/class/drm/card1/device"
  ln -s "../../../bus/pci/devices/0000:00:02.0" "$SYS/class/drm/card0/device"
  make_fakes
  set_lspci_default
  EXTRA_ENV=()
  POLL_TIMEOUT=0
  POLL_INTERVAL=0.01
  CLIENT_FD=3
}

set_lspci_default() {
  {
    printf '0000:00:02.0 0300: 8086:7d55 (rev 08)\n'
    printf '%s 0300: 10de:28a1 (rev a1)\n' "$BDF"
    printf '0000:01:00.1 0403: 10de:22be (rev a1)\n'
  } > "$ENV_ROOT/lspci"
}

set_runtime() {
  printf '%s\n' "$1" > "$SYS/bus/pci/devices/$BDF/power/runtime_status"
}

set_pm() {
  printf '%s\n' "$1" > "$ENV_ROOT/pm"
}

add_client() {
  local pid=$1 comm=$2 dev=$3
  mkdir -p "$PROC/$pid/fd"
  printf '%s\n' "$comm" > "$PROC/$pid/comm"
  ln -s "$dev" "$PROC/$pid/fd/$CLIENT_FD"
  CLIENT_FD=$((CLIENT_FD + 1))
}

add_compositor() {
  local pid=$1 comm=$2 aq=${3:-} node=${4:-}
  mkdir -p "$PROC/$pid/fd"
  printf '%s\n' "$comm" > "$PROC/$pid/comm"
  if [ -n "$aq" ]; then
    printf 'AQ_DRM_DEVICES=%s\0' "$aq" > "$PROC/$pid/environ"
  fi
  if [ -n "$node" ]; then
    ln -s "$node" "$PROC/$pid/fd/9"
  fi
}

add_proc_power() {
  local dir=$PROC/driver/nvidia/gpus/$BDF
  mkdir -p "$dir"
  {
    printf 'Runtime D3 status:          Enabled (fine-grained)\n'
    printf 'Video Memory:               Active\n'
  } > "$dir/power"
  printf 'Model: \t\t NVIDIA GeForce RTX 4050 Laptop GPU\n' > "$dir/information"
}

add_module() {
  mkdir -p "$SYS/module/$1"
}

fake_python_ok() {
  cat > "$BIN/python" <<'EOF'
#!/usr/bin/env bash
root=${SFX14_FAKE_ROOT:?}
printf 'python %s\n' "$*" >> "$root/calls.log"
exit 0
EOF
  chmod +x "$BIN/python"
}

sfx() {
  OUTPUT=$(env \
    SFX14_SYSFS="$SYS" \
    SFX14_PROC="$PROC" \
    SFX14_NVIDIA_SMI="$BIN/nvidia-smi" \
    SFX14_LSPCI="$BIN/lspci" \
    SFX14_MODPROBE="$BIN/modprobe" \
    SFX14_PYTHON="$BIN/python" \
    SFX14_POLL_TIMEOUT="$POLL_TIMEOUT" \
    SFX14_POLL_INTERVAL="$POLL_INTERVAL" \
    SFX14_FAKE_ROOT="$ENV_ROOT" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    "$SFX_BIN" "$@" 2>&1)
  STATUS=$?
}
