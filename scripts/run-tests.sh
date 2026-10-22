#!/usr/bin/env bash
# Runs every headless suite (or the ones named), even after one fails, then prints a summary and exits 1 if any
# suite failed. Used by `make test`.
# Usage: scripts/run-tests.sh [smoke-test edge-test …]
set -uo pipefail
cd "$(dirname "$0")/.."

SUITES=("$@")
[[ ${#SUITES[@]} -gt 0 ]] || SUITES=(smoke-test edge-test stress-test test-image-editor test-waveform test-pdf-metadata test-productivity test-presets-files test-lifecycle)

swift build -q || exit 1   # once up front, so the suites' own builds are no-ops

LOGS="$(mktemp -d /tmp/clementine-run-tests.XXXXXX)"
trap 'rm -rf "$LOGS"' EXIT
results=(); failed=0
for suite in "${SUITES[@]}"; do
  suite="${suite%.sh}"
  echo; echo "━━ $suite"
  start=$SECONDS
  scripts/"$suite".sh 2>&1 | tee "$LOGS/$suite.log"
  status=${PIPESTATUS[0]}
  # Suites end with "N passed, M failed" (stress: "Passed N, failed M").
  counts="$(grep -Eo '^([0-9]+ passed, [0-9]+ failed|Passed [0-9]+, failed [0-9]+)' "$LOGS/$suite.log" | tail -1)"
  [[ $status -eq 0 ]] && mark="ok  " || { mark="FAIL"; failed=$((failed + 1)); }
  results+=("$(printf '%s  %-20s %-24s %4ss' "$mark" "$suite" "${counts:-(no count, exit $status)}" $((SECONDS - start)))")
done

echo; echo "━━ Summary"
printf '%s\n' "${results[@]}"
total="$(cat "$LOGS"/*.log | grep -Eo '^([0-9]+ passed|Passed [0-9]+)' | grep -Eo '[0-9]+' | paste -sd+ - | bc)"
echo "${total:-0} checks passed; $failed of ${#SUITES[@]} suites failed."
[[ $failed -eq 0 ]]
