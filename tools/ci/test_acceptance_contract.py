# -*- coding: utf-8 -*-
"""acceptance-contract 失败矩阵单元测试（无需真机）。"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ci.acceptance_contract import (  # noqa: E402
    STANDAR_READER_BUNDLE,
    SPRINGBOARD_BUNDLE,
    evaluate_acceptance,
    format_rejection_cli,
    is_dump_stale,
    manifest_identity_block,
    ocr_needle_in_body_region,
)
from tools.ci.validate_hooks_gate import scan_hooks  # noqa: E402


def _good_manifest(**overrides):
    base = {
        "schema_version": 1,
        "variant": "legado-debug",
        "git_commit": "d3253403e294875a8e6b2606d82aa5a76ac702f9",
        "github_run_id": "12345",
        "base_ipa_sha256": "a" * 64,
        "app_binary_sha256": "b" * 64,
        "legado_bridge_sha256": "c" * 64,
        "legado_debug_sha256": "d" * 64,
        "built_at_utc": "2026-07-16T10:00:00Z",
    }
    base.update(overrides)
    return base


def _passing_trace() -> str:
    return "\n".join(
        [
            "goStart preferNativeFull",
            "contentInject phase=finish paths=showContent,setPageModelTV@textViewL,tvHasNeedleStrict nativePaged=1",
        ]
    )


def _passing_dump() -> str:
    return "\n".join(
        [
            "=== legado debug dump 2026-07-16T11:00:00Z ===",
            "vcStack:",
            "  UINavigationController",
            "  TextReadVC3",
            "readerHost=TextReadTV",
            "pageModel: ReadPageModel len=1200",
            "ctFrame=1 txtLen=800",
        ]
    )


def _baseline_inputs(**overrides):
    base = {
        "front_bundle": STANDAR_READER_BUNDLE,
        "vc_stack": ["UINavigationController", "TextReadVC3", "TextRPageContainer"],
        "ui_texts": ["第一章"],
        "ocr_texts": [],
        "ocr_result": {
            "texts": [
                {"text": "萧炎", "rect": {"x": 0.2, "y": 0.35, "width": 0.1, "height": 0.04}},
            ],
            "screen": {"width": 390, "height": 844},
        },
        "xiaoyan_assert": {"passed": True},
        "trace_text": _passing_trace(),
        "marker_text": "",
        "dump_text": _passing_dump(),
        "crash_text": "",
        "open_once_present": False,
        "overlay_tag_present": False,
        "manifest": _good_manifest(),
        "install_state": {
            "installed_at_utc": "2026-07-16T10:00:00Z",
            "manifest": _good_manifest(),
        },
        "expected_variant": "legado-debug",
        "expected_run": "12345",
        "expected_sha": "b" * 64,
        "mock_reachable": True,
    }
    base.update(overrides)
    return base


class AcceptanceMatrixTests(unittest.TestCase):
    def test_baseline_strict_pass(self) -> None:
        r = evaluate_acceptance(**_baseline_inputs())
        self.assertTrue(r.passed, r.fail_reasons)

    def test_springboard_rejected(self) -> None:
        r = evaluate_acceptance(**_baseline_inputs(front_bundle=SPRINGBOARD_BUNDLE, vc_stack=[]))
        self.assertFalse(r.passed)
        self.assertIn("frontmost_not_standar_reader", r.fail_reasons)

    def test_empty_bookshelf_rejected(self) -> None:
        r = evaluate_acceptance(
            **_baseline_inputs(
                ui_texts=["书架"],
                ocr_result={"texts": [], "screen": {"width": 390, "height": 844}},
                xiaoyan_assert={"passed": False},
                vc_stack=["UINavigationController", "BookShelfController"],
            )
        )
        self.assertFalse(r.passed)
        self.assertTrue(
            any(x in r.fail_reasons for x in ("screen_empty_bookshelf", "vc_stack_missing_native_reader"))
        )

    def test_debug_panel_rejected(self) -> None:
        r = evaluate_acceptance(
            **_baseline_inputs(ui_texts=["LegadoBridgeDebug 面板", "Dump"])
        )
        self.assertFalse(r.passed)
        self.assertIn("screen_debug_panel", r.fail_reasons)

    def test_overlay_xiaoyan_rejected(self) -> None:
        r = evaluate_acceptance(
            **_baseline_inputs(
                trace_text="goStart preferNativeFull\ncontentInject overlay92011",
                overlay_tag_present=True,
            )
        )
        self.assertFalse(r.passed)
        self.assertIn("overlay_92011_present", r.fail_reasons)

    def test_probe_only_no_ocr_rejected(self) -> None:
        r = evaluate_acceptance(
            **_baseline_inputs(
                trace_text="goStart preferNativeFull\ntvHasNeedleProbeOnly",
                ocr_result={"texts": [], "screen": {"width": 390, "height": 844}},
                xiaoyan_assert={"passed": True},
            )
        )
        self.assertFalse(r.passed)
        self.assertIn("ocr_body_needle_missing", r.fail_reasons)

    def test_stale_dump_rejected(self) -> None:
        r = evaluate_acceptance(
            **_baseline_inputs(
                dump_text="=== legado debug dump 2026-07-16T08:00:00Z ===\npageModel: nil\n",
            )
        )
        self.assertFalse(r.passed)
        self.assertIn("stale_dump", r.fail_reasons)

    def test_signal_after_text_rejected(self) -> None:
        r = evaluate_acceptance(
            **_baseline_inputs(
                trace_text=_passing_trace() + "\nSIGNAL sig=6",
                marker_text="SIGNAL sig=6",
            )
        )
        self.assertFalse(r.passed)
        self.assertIn("has_signal", r.fail_reasons)

    def test_wrong_sha_rejected(self) -> None:
        ident = manifest_identity_block(
            _good_manifest(),
            expected_sha="f" * 64,
        )
        self.assertFalse(ident["ok"])
        r = evaluate_acceptance(**_baseline_inputs(expected_sha="f" * 64))
        self.assertFalse(r.passed)
        self.assertIn("manifest_identity_failed", r.fail_reasons)

    def test_wrong_run_rejected(self) -> None:
        r = evaluate_acceptance(**_baseline_inputs(expected_run="99999"))
        self.assertFalse(r.passed)

    def test_wrong_variant_rejected(self) -> None:
        r = evaluate_acceptance(**_baseline_inputs(expected_variant="baseline-debug"))
        self.assertFalse(r.passed)

    def test_prefer_native_full_zero_rejected(self) -> None:
        r = evaluate_acceptance(**_baseline_inputs(trace_text="nativePaged=1 tvHasNeedleStrict"))
        self.assertFalse(r.passed)
        self.assertTrue(any("preferNativeFull_count=0" in x for x in r.fail_reasons))

    def test_prefer_native_full_twice_rejected(self) -> None:
        trace = "goStart preferNativeFull\ngoStart preferNativeFull\nnativePaged=1 tvHasNeedleStrict"
        r = evaluate_acceptance(**_baseline_inputs(trace_text=trace))
        self.assertFalse(r.passed)
        self.assertTrue(
            any("preferNativeFull_count=" in x for x in r.fail_reasons),
            r.fail_reasons,
        )

    def test_open_once_rejected(self) -> None:
        r = evaluate_acceptance(**_baseline_inputs(open_once_present=True))
        self.assertFalse(r.passed)
        self.assertIn("open_once_still_present", r.fail_reasons)

    def test_manifest_missing_rejected(self) -> None:
        r = evaluate_acceptance(**_baseline_inputs(manifest=None, manifest_missing=True))
        self.assertFalse(r.passed)
        self.assertIn("manifest_identity_failed", r.fail_reasons)

    def test_ocr_body_region(self) -> None:
        hit = ocr_needle_in_body_region(
            {
                "texts": [{"text": "萧炎", "rect": {"x": 0.2, "y": 0.35, "width": 0.1, "height": 0.04}}],
                "screen": {"width": 100, "height": 200},
            }
        )
        self.assertTrue(hit["passed"])
        miss = ocr_needle_in_body_region(
            {
                "texts": [{"text": "萧炎", "rect": {"x": 0.1, "y": 0.02, "width": 0.1, "height": 0.03}}],
                "screen": {"width": 100, "height": 200},
            }
        )
        self.assertFalse(miss["passed"])

    def test_stale_dump_helper(self) -> None:
        self.assertTrue(
            is_dump_stale(
                "=== legado debug dump 2026-07-16T08:00:00Z ===\n",
                {"installed_at_utc": "2026-07-16T10:00:00Z", "manifest": {}},
            )
        )

    def test_rejection_cli_example(self) -> None:
        r = evaluate_acceptance(**_baseline_inputs(front_bundle=SPRINGBOARD_BUNDLE))
        out = format_rejection_cli(r)
        self.assertIn("REJECTED", out)
        self.assertIn("frontmost_not_standar_reader", out)


class HooksGateTests(unittest.TestCase):
    def test_production_hooks_scan_passes(self) -> None:
        errors = scan_hooks()
        self.assertEqual(errors, [], errors)

    def test_gate_catches_un_guarded_overlay(self) -> None:
        bad = {
            "Fake.m": """
            void foo(id readerVC) {
                UIView *overlay = [[UITextView alloc] init];
                overlay.tag = 92011;
                [okPaths addObject:@"overlay92011"];
            }
            """
        }
        errors = scan_hooks(bad)
        self.assertTrue(any("overlay92011" in e for e in errors))

    def test_gate_catches_reader_ivar_write(self) -> None:
        bad = {"Fake.m": 'LBForceSetIvar(readerVC, @"textViewL", tv);'}
        errors = scan_hooks(bad)
        self.assertTrue(any("textViewL" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
