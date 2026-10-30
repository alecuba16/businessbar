#!/usr/bin/env python3
"""Gate actual whole-app coverage, including zero-hit production files."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


MINIMUM_PERCENT = 90
# These declarations have no executable mappings in the instrumented app.
DECLARATION_ONLY = {
    "BusinessBar/App/Constants.swift",
    "BusinessBarCore/Constants.swift",
    "BusinessBarCore/Core/Meeting/EventStoreProtocol.swift",
}


class CoverageError(Exception):
    pass


def production_paths(repo):
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "BusinessBar", "BusinessBarCore"],
        cwd=repo, check=True, stdout=subprocess.PIPE,
    )
    paths = {
        str(Path(path).as_posix())
        for path in result.stdout.decode().split("\0")
        if path.endswith(".swift")
    }
    for root in (repo / "BusinessBar", repo / "BusinessBarCore"):
        paths.update(path.relative_to(repo).as_posix() for path in root.rglob("*.swift") if path.is_file())
    if not paths:
        raise CoverageError("No production Swift sources found")
    return paths


def validate_run_manifest(manifest, repo, allow_diagnostic=False):
    complete = (
        manifest.get("diagnostic_only") is False
        and manifest.get("built") is True
        and manifest.get("selection") == "all"
        and manifest.get("isolation_only") is False
        and manifest.get("suite") == "all"
    )
    if not complete and not allow_diagnostic:
        raise CoverageError("Diagnostic or incomplete runner output cannot satisfy the coverage gate")
    fingerprints = manifest.get("source_sha256")
    sources = production_paths(repo)
    if not isinstance(fingerprints, dict) or set(fingerprints) != sources:
        raise CoverageError("Runner fingerprints do not match the complete production source inventory")
    for path, expected in fingerprints.items():
        if hashlib.sha256((repo / path).read_bytes()).hexdigest() != expected:
            raise CoverageError("Production source changed during test execution: " + path)


def relative_source(filename, repo):
    path = Path(filename)
    if not path.is_absolute():
        path = repo / path
    try:
        return path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        return None


def llvm_files(export, repo, sources):
    files = {}
    for entry in export.get("data", []):
        for file in entry.get("files", []):
            name = relative_source(file["filename"], repo)
            if name not in sources:
                if name and name.startswith(("BusinessBar/", "BusinessBarCore/")) and name.endswith(".swift"):
                    raise CoverageError(f"Production mapping missing from source inventory: {name}")
                continue
            if name in files:
                raise CoverageError(f"Duplicate production mapping for {name}")
            files[name] = file["summary"]
    missing = sources - files.keys() - DECLARATION_ONLY
    if missing:
        raise CoverageError("Missing production mappings: " + ", ".join(sorted(missing)))
    if not files:
        raise CoverageError("The executable has no production coverage mappings")
    return files


def lcov_lines(text, repo, sources):
    files = {}
    current = None
    for line in text.splitlines():
        if line.startswith("SF:"):
            name = relative_source(line[3:], repo)
            current = name if name in sources else None
            if current is not None:
                files.setdefault(current, {})
        elif line.startswith("DA:") and current is not None:
            fields = line[3:].split(",")
            number, count = int(fields[0]), int(fields[1])
            if number <= 0 or count < 0:
                raise CoverageError(f"Invalid line entry in {current}: {line}")
            files[current][number] = max(count, files[current].get(number, 0))
        elif line == "end_of_record":
            current = None
    return files


def total_metric(covered, count):
    if count <= 0 or not 0 <= covered <= count:
        raise CoverageError(f"Invalid executable-line totals: {covered}/{count}")
    return {
        "covered": covered,
        "count": count,
        "percent": covered * 100 / count,
        "passed": covered * 100 > MINIMUM_PERCENT * count,
    }


def assess(export, lcov, repo, sources):
    mapped = llvm_files(export, repo, sources)
    unique = lcov_lines(lcov, repo, sources)
    missing = mapped.keys() - unique.keys()
    if missing:
        raise CoverageError("Missing LCOV records: " + ", ".join(sorted(missing)))
    rows = []
    for name in sorted(sources):
        summary = mapped.get(name)
        entries = unique.get(name, {})
        if summary is None:
            rows.append({"path": name, "mapping": "declaration-only", "llvm_lines": None, "unique_lines": None})
            continue
        lines = summary["lines"]
        if not 0 <= lines["covered"] <= lines["count"]:
            raise CoverageError(f"Invalid line totals for {name}")
        if lines["count"] and not entries:
            raise CoverageError(f"Empty LCOV executable-line mapping: {name}")
        rows.append({
            "path": name,
            "mapping": "instrumented",
            "llvm_lines": {"covered": lines["covered"], "count": lines["count"]},
            "unique_lines": {"covered": sum(count > 0 for count in entries.values()), "count": len(entries)},
        })
    metrics = {}
    for key in ("llvm_lines", "unique_lines"):
        covered = sum(row[key]["covered"] for row in rows if row[key] is not None)
        count = sum(row[key]["count"] for row in rows if row[key] is not None)
        metrics[key] = total_metric(covered, count)
    return {
        "minimum_percent_exclusive": MINIMUM_PERCENT,
        "production_source_count": len(sources),
        "instrumented_source_count": len(mapped),
        "metrics": metrics,
        "passed": all(metric["passed"] for metric in metrics.values()),
        "files": rows,
    }


def export_coverage(binary, profile, output):
    for name, arguments in (
        ("coverage.json", ["--summary-only"]),
        ("coverage.lcov", ["--format=lcov"]),
    ):
        with (output / name).open("w") as handle:
            result = subprocess.run(
                ["xcrun", "llvm-cov", "export", str(binary), f"-instr-profile={profile}", *arguments],
                check=True, stdout=handle, stderr=subprocess.PIPE, text=True,
            )
            if result.stderr.strip():
                raise CoverageError("llvm-cov emitted diagnostics: " + result.stderr.strip())
    return json.loads((output / "coverage.json").read_text()), (output / "coverage.lcov").read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--report-only", action="store_true", help="Measure without treating a low percentage as success")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    try:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        sources = production_paths(repo)
        export, lcov = export_coverage(args.binary.resolve(), args.profile.resolve(), args.output_dir)
        result = assess(export, lcov, repo, sources)
        (args.output_dir / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
        print(f"Production inventory: {result['production_source_count']} sources, {result['instrumented_source_count']} instrumented")
        for name, metric in result["metrics"].items():
            print(f"{name}: {metric['covered']}/{metric['count']} ({metric['percent']:.4f}%), required >{MINIMUM_PERCENT}%")
        print("PASS: whole-app coverage gate" if result["passed"] else "FAIL: whole-app coverage gate")
        return 0 if result["passed"] or args.report_only else 1
    except (CoverageError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
