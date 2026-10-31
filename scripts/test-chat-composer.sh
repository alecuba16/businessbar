#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
scratch_root="${JCODE_SCRATCH_DIR:-${TMPDIR:-/tmp}}"
build_dir="$(mktemp -d "$scratch_root/businessbar-composer-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

swiftc \
    "$repo_root/BusinessBar/UI/Companion/ComposerTextView.swift" \
    "$repo_root/Tests/ComposerMarkers/main.swift" \
    -o "$build_dir/composer-tests"
"$build_dir/composer-tests" "$@" &
test_pid=$!
( sleep 10; kill -TERM "$test_pid" 2>/dev/null || true ) &
watchdog_pid=$!
result=0
wait "$test_pid" || result=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
exit "$result"
