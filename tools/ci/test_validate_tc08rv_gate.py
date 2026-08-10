# -*- coding: utf-8 -*-
"""TC-08RV transitive-dependency gate tests; no device/network access."""
from __future__ import annotations

import copy
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ci.validate_tc08rv_gate import (  # noqa: E402
    EXPECTED_CASES,
    REQUIRED_ARTIFACTS_BY_CASE,
    validate_tc08rv_report,
)


def _passing_report(artifact_root: Path) -> dict:
    cases = {}
    for case_id in EXPECTED_CASES:
        case_dir = artifact_root / case_id.replace(".", "_")
        case_dir.mkdir(parents=True, exist_ok=True)
        records = []
        for name in REQUIRED_ARTIFACTS_BY_CASE[case_id]:
            path = case_dir / name
            path.write_bytes(b"evidence")
            records.append({"path": str(path.relative_to(artifact_root))})
        cases[case_id] = {
            "case_id": case_id,
            "status": "passed",
            "passed": True,
            "assertions": {"ok": True},
            "missing_artifacts": [],
            "artifactPaths": records,
            "evidence": {},
        }
    cases["XBS.three_channels"]["evidence"] = {
        channel: {
            "activeDiscovery": True,
            "visibleBookIdentities": [f"book-{channel}"],
            "requestSource": "source://xbs",
        }
        for channel in ("male", "female", "publication")
    }
    cases["XBS.tag_switch"].update(
        assertions={"list_changes": True, "contentGeneration_increments": True},
        evidence={
            "selectedTag": "都市",
            "expectedTag": "都市",
            "before": {"contentGeneration": 1},
            "after": {"contentGeneration": 2},
        },
    )
    cases["XBS.pagination_append_dedupe"].update(
        assertions={"appended": True, "deduped": True},
        evidence={
            "before": {"page": 1, "requestSequence": 10, "bookIdentities": ["a", "b"]},
            "after": {"page": 2, "requestSequence": 11, "bookIdentities": ["a", "b", "c"]},
        },
    )
    cases["XBS.search"].update(
        assertions={"results_bound_to_xbs_identity": True, "open_detail_native": True},
        evidence={"stack": ["BookDetailVC"]},
    )
    for case_id in EXPECTED_CASES:
        if case_id.startswith("Legado."):
            if case_id == "Legado.cache_miss_native_loading":
                cases[case_id].update(
                    assertions={"native_loading": True, "no_prior_source_rows": True},
                    evidence={
                        "currentSource": "source://legado",
                        "nativeLoading": True,
                        "books": 0,
                        "previousSourceRows": 0,
                    },
                )
            else:
                cases[case_id].update(
                    assertions={"legado": True},
                    evidence={"currentSource": "source://legado", "bookIdentities": ["legado-book"]},
                )
        elif case_id == "Nav.discover_book_to_detail":
            cases[case_id].update(
                assertions={"native_detail_not_catalog": True},
                evidence={"stack": ["BookDetailVC"], "picked": "book-1"},
            )
        elif case_id == "Nav.detail_catalog_reader":
            cases[case_id].update(
                assertions={"native_detail_catalog_reader": True},
                evidence={"stack": ["BookDetailVC", "CatalogCon", "TextReadVC3"]},
            )
    ipa_path = artifact_root / "ipa" / "candidate.ipa"
    ipa_path.parent.mkdir(parents=True, exist_ok=True)
    ipa_path.write_bytes(b"synthetic ipa bytes")
    ipa_sha = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
    return {
        "schemaVersion": 1,
        "cardID": "TC-08RV",
        "runID": "synthetic-strict-green",
        "verdict": "passed",
        "nextCardAllowed": True,
        "deviceTouched": True,
        "deviceTouchedNote": "clone_only com.example.xbs.clone",
        "realBundleTouched": False,
        "cloneBundleId": "com.example.xbs.clone",
        "cloneBundleFrozen": True,
        "realBundleId": "com.example.xbs.real",
        "vanillaBundleId": "com.example.xbs.vanilla",
        "containerIsolation": {
            "isolated": True,
            "cloneDataContainer": "container-clone-123",
            "realDataContainer": "container-real-456",
            "vanillaDataContainer": "container-vanilla-789",
        },
        "currentHead": "a" * 40,
        "baseCommit": "a" * 40,
        "buildIdentity": {
            "commit": "a" * 40,
            "ipaSha256": ipa_sha,
            "ipaPath": str(ipa_path),
        },
        "summary": {
            "verdict": "passed",
            "counts": {"passed": 22, "failed": 0, "blocked": 0, "not_run": 0, "total": 22},
            "passed": list(EXPECTED_CASES),
            "performance": {
                "sampleSizeRequired": 20,
                "sampleSizeObtained": 20,
                "samplesMs": list(range(20)),
                "p95Ms": 19,
                "p95Pass": True,
            },
        },
        "caseResults": cases,
    }


class TC08RVGateTests(unittest.TestCase):
    def test_exact_strict_green_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(validate_tc08rv_report(_passing_report(Path(tmp)), artifact_root=Path(tmp)), [])

    def test_partial_report_is_rejected_as_a_whole(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = _passing_report(Path(tmp))
            report["verdict"] = "failed"
            report["summary"]["counts"]["passed"] = 15
            report["summary"]["counts"]["failed"] = 2
            report["summary"]["counts"]["blocked"] = 5
            report["summary"]["passed"] = list(EXPECTED_CASES[:15])
            report["caseResults"][EXPECTED_CASES[-1]]["status"] = "blocked"
            report["caseResults"][EXPECTED_CASES[-1]]["passed"] = False
            errors = validate_tc08rv_report(report, artifact_root=Path(tmp))
        self.assertTrue(any("only exact passed" in e for e in errors))
        self.assertTrue(any("summary.counts.passed" in e for e in errors))
        self.assertTrue(any(EXPECTED_CASES[-1] in e for e in errors))

    def test_next_card_false_and_review_remediation_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = _passing_report(Path(tmp))
            report["nextCardAllowed"] = False
            review = {"nextCardAllowed": False, "activeCard": "TC-08RV-remediation", "errors": []}
            errors = validate_tc08rv_report(report, review=review, artifact_root=Path(tmp))
        self.assertTrue(any("continuous A4" in e for e in errors))

    def test_continuous_a4_authorization_allows_next_card_flag_false(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = _passing_report(Path(tmp))
            report["nextCardAllowed"] = False
            receipt_path = Path(tmp) / "authorization-receipt.json"
            receipt_path.write_text(
                json.dumps(
                    {
                        "authorizationID": "auth-test",
                        "maxLevel": "A4",
                        "chain": ["TC-08RV", "TC-10", "TC-11", "TC-12", "TC-13"],
                    }
                ),
                encoding="utf-8",
            )
            review = {
                "nextCardAllowed": False,
                "activeCard": "TC-11",
                "review_status": "continuous_execution_authorized",
                "continuous_authorization_id": "auth-test",
                "continuous_authorization_max_level": "A4",
                "chain": ["TC-08RV", "TC-10", "TC-11", "TC-12", "TC-13"],
                "authorization_receipt_path": str(receipt_path),
                "errors": [],
            }
            errors = validate_tc08rv_report(report, review=review, artifact_root=Path(tmp))
        self.assertEqual(errors, [])

    def test_clone_identity_is_frozen_and_isolated_without_tc12_hardcode(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = _passing_report(Path(tmp))
            self.assertEqual(
                validate_tc08rv_report(
                    report,
                    expected_clone_bundle="com.example.xbs.clone",
                    artifact_root=Path(tmp),
                ),
                [],
            )
            report["cloneBundleId"] = report["realBundleId"]
            errors = validate_tc08rv_report(report, artifact_root=Path(tmp))
        self.assertTrue(any("overlaps protected" in e for e in errors))

    def test_cache_miss_allows_zero_books_but_requires_native_loading_and_isolation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = _passing_report(Path(tmp))
            report["caseResults"]["Legado.cache_miss_native_loading"]["evidence"]["books"] = 0
            report["caseResults"]["Legado.cache_miss_native_loading"]["evidence"]["nativeLoading"] = True
            errors = validate_tc08rv_report(report, artifact_root=Path(tmp))
            self.assertEqual(errors, [])
            report["caseResults"]["Legado.cache_miss_native_loading"]["evidence"]["nativeLoading"] = False
            errors = validate_tc08rv_report(report, artifact_root=Path(tmp))
        self.assertTrue(any("native loading" in e for e in errors))

    def test_detail_catalog_reader_accepts_native_catalog_but_requires_order(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = _passing_report(Path(tmp))
            report["caseResults"]["Nav.detail_catalog_reader"]["evidence"]["stack"] = [
                "BookDetailVC",
                "CatalogCon",
                "TextReadVC3",
            ]
            self.assertEqual(validate_tc08rv_report(report, artifact_root=Path(tmp)), [])
            report["caseResults"]["Nav.detail_catalog_reader"]["evidence"]["stack"] = [
                "BookDetailVC",
                "LegadoBridgeCatalog",
                "TextReadVC3",
            ]
            errors = validate_tc08rv_report(report, artifact_root=Path(tmp))
        self.assertTrue(any("Bridge controller" in e for e in errors))

    def test_artifact_path_traversal_and_absolute_escape_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = _passing_report(root)
            report["caseResults"]["XBS.search"]["artifactPaths"][0]["path"] = "../shared.png"
            errors = validate_tc08rv_report(report, artifact_root=root)
            self.assertTrue(any("escapes artifactRoot" in e or "not case-scoped" in e for e in errors))

    def test_shared_artifact_path_cannot_satisfy_two_cases(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = _passing_report(root)
            source = report["caseResults"]["XBS.search"]["artifactPaths"][0]["path"]
            report["caseResults"]["Legado.search"]["artifactPaths"][0]["path"] = source
            errors = validate_tc08rv_report(report, artifact_root=root)
        self.assertTrue(any("reused by" in e for e in errors))

    def test_declared_artifact_hash_must_match_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = _passing_report(root)
            report["caseResults"]["XBS.search"]["artifactPaths"][0]["sha256"] = "0" * 64
            errors = validate_tc08rv_report(report, artifact_root=root)
        self.assertTrue(any("SHA-256 mismatch" in e for e in errors))

    def test_ipa_path_must_exist_and_match_sha(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = _passing_report(root)
            report["buildIdentity"]["ipaPath"] = str(root / "missing.ipa")
            errors = validate_tc08rv_report(report, artifact_root=root)
            self.assertTrue(any("ipaPath missing" in e for e in errors))
            report = _passing_report(root)
            report["buildIdentity"]["ipaSha256"] = "0" * 64
            errors = validate_tc08rv_report(report, artifact_root=root)
        self.assertTrue(any("ipaPath SHA-256 mismatch" in e for e in errors))

    def test_authorization_receipt_missing_or_mismatched_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = _passing_report(root)
            report["nextCardAllowed"] = False
            review = {
                "review_status": "continuous_execution_authorized",
                "continuous_authorization_id": "auth-test",
                "continuous_authorization_max_level": "A4",
                "activeCard": "TC-11",
                "chain": ["TC-08RV", "TC-11", "TC-12"],
                "authorization_receipt_path": str(root / "missing-receipt.json"),
                "errors": [],
            }
            errors = validate_tc08rv_report(report, review=review, artifact_root=root)
            self.assertTrue(any("receipt missing" in e for e in errors))
            receipt = root / "receipt.json"
            receipt.write_text(
                json.dumps({"authorizationID": "other", "maxLevel": "A4", "chain": ["TC-08RV"]}),
                encoding="utf-8",
            )
            review["authorization_receipt_path"] = str(receipt)
            errors = validate_tc08rv_report(report, review=review, artifact_root=root)
        self.assertTrue(any("receipt ID mismatch" in e for e in errors))

    def test_commit_binding_is_required_when_expected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = _passing_report(Path(tmp))
            errors = validate_tc08rv_report(report, expected_commit="c" * 40, artifact_root=Path(tmp))
        self.assertTrue(any("commit mismatch" in e for e in errors))

    def test_case_set_cannot_be_shrunk_or_extended(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = _passing_report(Path(tmp))
            report["caseResults"].pop(EXPECTED_CASES[0])
            report["caseResults"]["invented.case"] = copy.deepcopy(next(iter(report["caseResults"].values())))
            errors = validate_tc08rv_report(report, artifact_root=Path(tmp))
        self.assertTrue(any("caseResults set mismatch" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
