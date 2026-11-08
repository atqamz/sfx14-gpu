#!/usr/bin/env bash
# Run every suite; CI uses this entry point.
# SPDX-License-Identifier: MIT
set -uo pipefail

suite_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
status=0

for test_file in "$suite_dir"/test_*.sh; do
  printf '== %s\n' "${test_file##*/}"
  if ! "$test_file"; then
    status=1
  fi
done

exit "$status"
