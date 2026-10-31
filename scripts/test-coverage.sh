#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

output="$repo/.build/coverage/$(uuidgen)"
with_xctest=false
report_only=false
skip_build=false
runner_flags=()
while (($#)); do
    case "$1" in
        --output-dir)
            output="${2:?--output-dir requires a directory}"
            shift 2
            ;;
        --with-xctest)
            with_xctest=true
            shift
            ;;
        --report-only)
            report_only=true
            shift
            ;;
        --no-build)
            skip_build=true
            runner_flags+=(--no-build)
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if $skip_build && ! $report_only; then
    echo "--no-build is diagnostic only and requires --report-only" >&2
    exit 2
fi

if $with_xctest; then
    developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
    if [[ "$developer_dir" == */CommandLineTools ]]; then
        echo "--with-xctest requires full Xcode, not Command Line Tools" >&2
        exit 2
    fi
fi

mkdir -p "$output"
output="$(cd "$output" && pwd)"
if [[ -e "$output/run/manifest.json" || -e "$output/summary.json" ]]; then
    echo "Use a fresh output directory to avoid mixing coverage from different source revisions" >&2
    exit 2
fi

preserve_evidence() {
    local exit_status=$?
    trap - EXIT
    if ! PYTHONDONTWRITEBYTECODE=1 python3 - "$output" "$repo" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

output, repo = map(Path, sys.argv[1:])
manifest_path = output / "run/manifest.json"
if manifest_path.is_file():
    manifest = json.loads(manifest_path.read_text())
    run = Path(manifest["run_directory"]).resolve()
    run.relative_to((output / "run").resolve())
    binary = Path(manifest["app_binary"]).resolve()
    binary.relative_to((repo / ".build").resolve())
    evidence = output / "evidence"
    evidence.mkdir(exist_ok=True)
    shutil.copyfile(binary, evidence / "BusinessBar")
    profile = output / "merged.profdata"
    if not profile.is_file():
        profile = Path(manifest["profile"])
        profile.resolve().relative_to(run)
    if profile.is_file():
        shutil.copyfile(profile, evidence / "merged.profdata")
    (evidence / "source-sha256.json").write_text(json.dumps(manifest["source_sha256"], indent=2) + "\n")
    identity = {
        "git_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "app_binary_sha256": hashlib.sha256((evidence / "BusinessBar").read_bytes()).hexdigest(),
        "runner_app_binary_sha256": manifest.get("app_binary_sha256"),
        "object_list_sha256": manifest.get("object_list_sha256"),
    }
    (evidence / "build-identity.json").write_text(json.dumps(identity, indent=2) + "\n")
    if identity["app_binary_sha256"] != identity["runner_app_binary_sha256"]:
        raise RuntimeError("Application binary changed after the coverage run")
PY
    then
        echo "Failed to retain coverage evidence" >&2
        if ((exit_status == 0)); then exit_status=1; fi
    fi
    exit "$exit_status"
}
trap preserve_evidence EXIT

PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-coverage-gate.py
export BUSINESSBAR_COVERAGE_SUITE=all
bash scripts/run-coverage-scenarios.sh --output-dir "$output/run" ${runner_flags[@]+"${runner_flags[@]}"}

if $with_xctest; then
    mkdir -p "$output/xctest/home" "$output/xctest/tmp" "$output/xctest/profiles"
    PYTHONDONTWRITEBYTECODE=1 python3 - "$output" <<'PY'
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
manifest = json.loads((output / "run/manifest.json").read_text())
profiles = Path(manifest["app_binary"]).parent / "codecov"
(output / "xctest/preexisting-profiles.json").write_text(json.dumps([str(path.resolve()) for path in profiles.glob("*.profraw")]) + "\n")
PY
    touch "$output/xctest/started"
    home="$output/xctest/home"
    flags=($(bash scripts/swift-clt-plugins.sh flags))
    env HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$output/xctest/tmp/" \
        BUSINESSBAR_COVERAGE_HOME="$home" BUSINESSBAR_COVERAGE_SUITE=all \
        BUSINESSBAR_XCTEST_RUN_RECORD="$output/xctest/process.json" \
        LLVM_PROFILE_FILE="$output/xctest/profiles/%p-%m.profraw" \
        swift test --no-parallel --enable-code-coverage "${flags[@]}"
fi

PYTHONDONTWRITEBYTECODE=1 python3 - "$output" "$report_only" <<'PY'
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

output = Path(sys.argv[1])
manifest = json.loads((output / "run/manifest.json").read_text())
spec = importlib.util.spec_from_file_location("coverage_gate", Path("scripts/check-coverage.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
gate.validate_run_manifest(manifest, Path.cwd(), allow_diagnostic=sys.argv[2] == "true")
gate.validate_binary(manifest, Path(manifest["app_binary"]))
profiles = [Path(path) for path in manifest["profiles"]]
marker = output / "xctest/started"
if marker.exists():
    started = marker.stat().st_mtime_ns
    record = json.loads((output / "xctest/process.json").read_text())
    if Path(record.get("home", "")).resolve() != (output / "xctest/home").resolve():
        sys.exit("XCTest process did not use the owned fixture home")
    preexisting = json.loads((output / "xctest/preexisting-profiles.json").read_text())
    profiles.extend(gate.xctest_profiles(record, Path(manifest["app_binary"]).parent, started, preexisting))
profiles = sorted(set(profiles))
if not profiles or any(not path.is_file() or path.stat().st_size == 0 for path in profiles):
    sys.exit("Missing or empty test profiles")
subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", *map(str, profiles), "-o", str(output / "merged.profdata")], check=True)
(output / "profiles.json").write_text(json.dumps([str(path) for path in profiles], indent=2) + "\n")
with (output / "app-binary.txt").open("w") as handle:
    handle.write(manifest["app_binary"] + "\n")
PY

gate_flags=()
if $report_only; then
    gate_flags+=(--report-only)
fi
python3 scripts/check-coverage.py \
    --binary "$(cat "$output/app-binary.txt")" \
    --profile "$output/merged.profdata" \
    --run-manifest "$output/run/manifest.json" \
    --output-dir "$output" ${gate_flags[@]+"${gate_flags[@]}"}
