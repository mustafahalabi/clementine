# Shared setup for the shell test suites. Source it from the repo root, after `swift build`:
#   source scripts/test-lib.sh
#   test_setup <name>        # sets WORK and F (= $WORK/fixtures), picks the tools, cleans up on exit
#
# Work dirs (/tmp/clementine-<name>.XXXXXX) are removed when the suite exits 0 and kept when it fails, so you can
# inspect the outputs (KEEP_WORK=1 keeps them always). Leftovers older than two days are pruned on every run.
#
# Tools: the CLI looks for ffmpeg/ffprobe/cwebp/img2webp in the Settings tools folder before Homebrew. If
# vendor/bin holds the tools that ship in the app (`make tools`), the suites point that setting at it through a
# scratch defaults suite (CLEMENTINE_DEFAULTS_SUITE, a debug-build override), so tests exercise the same ffmpeg
# that releases bundle. CLEMENTINE_TEST_TOOLS=<dir> picks another folder; CLEMENTINE_TEST_TOOLS=system uses
# whatever is on the usual paths (Homebrew). Fixtures are still made with the ffmpeg on PATH.

_test_suite_owned=""

# Creates a scratch defaults suite for this run (once) and exports it. Removed on exit.
test_defaults_suite() {
  [[ -n "$_test_suite_owned" ]] && return
  export CLEMENTINE_DEFAULTS_SUITE="app.clementine.tests.$$"
  _test_suite_owned=1
}

_test_cleanup() {
  local status=$?
  if [[ -n "$_test_suite_owned" ]]; then
    defaults delete "$CLEMENTINE_DEFAULTS_SUITE" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$CLEMENTINE_DEFAULTS_SUITE.plist"
  fi
  if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
    if [[ $status -eq 0 && -z "${KEEP_WORK:-}" ]]; then rm -rf "$WORK"; else echo "Work dir kept: $WORK"; fi
  fi
  return $status
}

test_setup() {
  local name="$1"
  # Prune work dirs from earlier runs that were kept (failures, interrupted runs).
  find /tmp/ -maxdepth 1 -type d -name "clementine-$name.*" -mtime +2 -exec rm -rf {} + 2>/dev/null
  WORK="$(mktemp -d "/tmp/clementine-$name.XXXXXX")"
  F="$WORK/fixtures"
  mkdir -p "$F"
  trap _test_cleanup EXIT

  # GitHub's macOS VMs print "IOServiceMatchingfailed for: AppleM2ScalerParavirtDriver" to stdout from the
  # graphics stack, which would read as an output path. Run the binary through a filter that drops it (stderr is
  # filtered too and comes out after stdout). The exit status is the binary's.
  if [[ -n "${BIN:-}" ]]; then
    cat > "$WORK/clementine" <<WRAP
#!/usr/bin/env bash
noise='^IOServiceMatchingfailed for: '
err="\$(mktemp "$WORK/stderr.XXXXXX")"
"$BIN" "\$@" 2>"\$err" | { grep -v "\$noise" || true; }
status=\${PIPESTATUS[0]}
grep -v "\$noise" "\$err" >&2; rm -f "\$err"
exit \$status
WRAP
    chmod +x "$WORK/clementine"
    BIN="$WORK/clementine"
  fi

  local tools="${CLEMENTINE_TEST_TOOLS:-}"
  if [[ -z "$tools" && -x vendor/bin/ffmpeg ]]; then tools="$PWD/vendor/bin"; fi
  if [[ -n "$tools" && "$tools" != system ]]; then
    [[ -x "$tools/ffmpeg" ]] || { echo "CLEMENTINE_TEST_TOOLS=$tools has no ffmpeg" >&2; exit 1; }
    test_defaults_suite
    defaults write "$CLEMENTINE_DEFAULTS_SUITE" toolsDirectory -string "$tools"
    echo "Clementine uses tools in $tools ($("$tools/ffmpeg" -hide_banner -version | head -1 | cut -d' ' -f1-3))"
  else
    echo "Clementine uses system tools ($(ffmpeg -hide_banner -version | head -1 | cut -d' ' -f1-3))"
  fi
}
