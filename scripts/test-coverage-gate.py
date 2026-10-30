#!/usr/bin/env python3
"""Negative controls for the whole-production coverage gate."""

import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("coverage_gate", Path(__file__).with_name("check-coverage.py"))
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class CoverageGateTests(unittest.TestCase):
    repo = Path("/fixture/repo")
    source = "BusinessBar/App/BusinessBarApp.swift"

    def export(self, covered=91, count=100, sources=None):
        return {"data": [{"files": [
            {"filename": str(self.repo / source), "summary": {"lines": {"covered": covered, "count": count}}}
            for source in (sources or [self.source])
        ]}]}

    def lcov(self, covered=91, count=100, source=None):
        return "\n".join([
            "SF:" + str(self.repo / (source or self.source)),
            *(f"DA:{line},{int(line <= covered)}" for line in range(1, count + 1)),
            "end_of_record",
        ])

    def assess(self, covered=91, unique_covered=None, sources=None):
        return GATE.assess(
            self.export(covered), self.lcov(covered if unique_covered is None else unique_covered),
            self.repo, sources or {self.source},
        )

    def test_strictly_above_ninety_passes(self):
        self.assertTrue(self.assess()["passed"])

    def test_exactly_ninety_fails(self):
        self.assertFalse(self.assess(90)["passed"])

    def test_rounded_percentage_cannot_pass(self):
        self.assertFalse(GATE.total_metric(90000, 100001)["passed"])

    def test_zero_hit_file_is_retained(self):
        result = self.assess(0)
        self.assertEqual(result["metrics"]["llvm_lines"]["count"], 100)
        self.assertFalse(result["passed"])

    def test_missing_production_file_is_an_error(self):
        with self.assertRaisesRegex(GATE.CoverageError, "Missing production mappings"):
            self.assess(sources={self.source, "BusinessBar/UI/Uncovered.swift"})

    def test_entry_point_is_not_silently_excluded(self):
        with self.assertRaises(GATE.CoverageError):
            GATE.assess({"data": []}, "", self.repo, {self.source})

    def test_declaration_only_file_is_listed_not_counted_as_covered(self):
        declaration = "BusinessBarCore/Core/Meeting/EventStoreProtocol.swift"
        result = self.assess(sources={self.source, declaration})
        self.assertEqual(result["production_source_count"], 2)
        self.assertEqual(result["instrumented_source_count"], 1)
        self.assertIsNone(next(row for row in result["files"] if row["path"] == declaration)["llvm_lines"])

    def test_declaration_with_mapping_is_counted(self):
        source = "BusinessBarCore/Constants.swift"
        result = GATE.assess(self.export(sources=[source]), self.lcov(source=source), self.repo, {source})
        self.assertEqual(result["instrumented_source_count"], 1)

    def test_unique_line_gate_is_independent(self):
        self.assertFalse(self.assess(91, unique_covered=90)["passed"])

    def test_llvm_line_gate_is_independent(self):
        self.assertFalse(self.assess(90, unique_covered=91)["passed"])

    def test_duplicate_lcov_records_cannot_inflate_denominator(self):
        text = self.lcov(0) + "\n" + self.lcov(91)
        result = GATE.assess(self.export(), text, self.repo, {self.source})
        self.assertEqual(result["metrics"]["unique_lines"]["count"], 100)
        self.assertEqual(result["metrics"]["unique_lines"]["covered"], 91)

    def test_duplicate_summary_is_rejected(self):
        with self.assertRaisesRegex(GATE.CoverageError, "Duplicate"):
            GATE.assess(self.export(sources=[self.source, self.source]), self.lcov(), self.repo, {self.source})

    def test_dependencies_do_not_enter_production_denominator(self):
        export = self.export(sources=[self.source, ".build/checkouts/Dependency/Source.swift"])
        result = GATE.assess(export, self.lcov(), self.repo, {self.source})
        self.assertEqual(result["instrumented_source_count"], 1)

    def test_missing_lcov_is_rejected(self):
        with self.assertRaisesRegex(GATE.CoverageError, "Missing LCOV"):
            GATE.assess(self.export(), "", self.repo, {self.source})

    def test_empty_lcov_is_rejected(self):
        with self.assertRaisesRegex(GATE.CoverageError, "Empty LCOV"):
            GATE.assess(self.export(), "SF:" + str(self.repo / self.source), self.repo, {self.source})

    def test_invalid_totals_are_rejected(self):
        for covered, count in [(1, 0), (-1, 10), (11, 10)]:
            with self.assertRaises(GATE.CoverageError):
                GATE.total_metric(covered, count)

    def test_invalid_lcov_line_is_rejected(self):
        for entry in ["DA:0,1", "DA:1,-1"]:
            with self.assertRaises(GATE.CoverageError):
                GATE.lcov_lines("SF:" + str(self.repo / self.source) + "\n" + entry, self.repo, {self.source})

    def test_untracked_production_sources_are_not_omitted(self):
        with tempfile.TemporaryDirectory(prefix="businessbar-coverage-gate-") as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (repo / "BusinessBar").mkdir()
            (repo / "Tests").mkdir()
            (repo / "BusinessBar/Untracked.swift").write_text("func uncovered() {}\n")
            (repo / ".gitignore").write_text("BusinessBar/Ignored.swift\n")
            (repo / "BusinessBar/Ignored.swift").write_text("func alsoUncovered() {}\n")
            (repo / "Tests/Fixture.swift").write_text("func fixture() {}\n")
            self.assertEqual(GATE.production_paths(repo), {"BusinessBar/Untracked.swift", "BusinessBar/Ignored.swift"})

    def test_source_inventory_cannot_be_empty(self):
        with mock.patch.object(GATE.subprocess, "run", return_value=mock.Mock(stdout=b"")):
            with self.assertRaisesRegex(GATE.CoverageError, "No production Swift"):
                GATE.production_paths(self.repo)

    def test_mismatched_profile_warning_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="businessbar-coverage-gate-") as directory:
            with mock.patch.object(GATE.subprocess, "run", return_value=mock.Mock(stderr="warning: functions have mismatched data")):
                with self.assertRaisesRegex(GATE.CoverageError, "mismatched data"):
                    GATE.export_coverage(Path("app"), Path("profile"), Path(directory))

    def manifest(self, repo):
        source = repo / self.source
        source.parent.mkdir(parents=True)
        source.write_text("func production() {}\n")
        return {
            "diagnostic_only": False, "built": True, "selection": "all",
            "isolation_only": False, "suite": "all",
            "source_sha256": {self.source: hashlib.sha256(source.read_bytes()).hexdigest()},
        }

    def test_complete_current_manifest_passes(self):
        with tempfile.TemporaryDirectory(prefix="businessbar-coverage-gate-") as directory:
            repo = Path(directory)
            manifest = self.manifest(repo)
            with mock.patch.object(GATE, "production_paths", return_value={self.source}):
                GATE.validate_run_manifest(manifest, repo)

    def test_missing_provenance_fields_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix="businessbar-coverage-gate-") as directory:
            repo = Path(directory)
            manifest = self.manifest(repo)
            for key in ["diagnostic_only", "built", "selection", "isolation_only", "suite"]:
                incomplete = {name: value for name, value in manifest.items() if name != key}
                with self.assertRaisesRegex(GATE.CoverageError, "incomplete"):
                    GATE.validate_run_manifest(incomplete, repo)

    def test_diagnostic_run_never_satisfies_gate(self):
        with tempfile.TemporaryDirectory(prefix="businessbar-coverage-gate-") as directory:
            repo = Path(directory)
            manifest = self.manifest(repo)
            manifest.update(built=False, diagnostic_only=True)
            with mock.patch.object(GATE, "production_paths", return_value={self.source}):
                with self.assertRaisesRegex(GATE.CoverageError, "Diagnostic"):
                    GATE.validate_run_manifest(manifest, repo)
                GATE.validate_run_manifest(manifest, repo, allow_diagnostic=True)

    def test_partial_or_new_source_fingerprints_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="businessbar-coverage-gate-") as directory:
            repo = Path(directory)
            manifest = self.manifest(repo)
            with mock.patch.object(GATE, "production_paths", return_value={self.source, "BusinessBar/New.swift"}):
                with self.assertRaisesRegex(GATE.CoverageError, "complete production"):
                    GATE.validate_run_manifest(manifest, repo)

    def test_changed_sources_invalidate_profile_provenance(self):
        with tempfile.TemporaryDirectory(prefix="businessbar-coverage-gate-") as directory:
            repo = Path(directory)
            manifest = self.manifest(repo)
            (repo / self.source).write_text("func changedProduction() {}\n")
            with mock.patch.object(GATE, "production_paths", return_value={self.source}):
                with self.assertRaisesRegex(GATE.CoverageError, "source changed"):
                    GATE.validate_run_manifest(manifest, repo)

    def test_uninventoried_production_mapping_is_rejected(self):
        with self.assertRaisesRegex(GATE.CoverageError, "missing from source inventory"):
            GATE.assess(self.export(sources=[self.source, "BusinessBar/Hidden.swift"]), self.lcov(), self.repo, {self.source})


if __name__ == "__main__":
    unittest.main()
