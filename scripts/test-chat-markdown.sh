#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch_root="${JCODE_SCRATCH_DIR:-${TMPDIR:-/tmp}}"
build_dir="$(mktemp -d "$scratch_root/businessbar-markdown-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

swiftc \
    "$repo_root/BusinessBar/UI/Companion/MarkdownTextView.swift" \
    "$repo_root/BusinessBar/UI/Companion/MarkdownTextHostingView.swift" \
    "$repo_root/Tests/MarkdownRendering/main.swift" \
    -o "$build_dir/markdown-tests"
"$build_dir/markdown-tests" "$@"
