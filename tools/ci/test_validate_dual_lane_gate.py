#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""validate_dual_lane_gate.py 单测。"""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "tools" / "ci" / "validate_dual_lane_gate.py"


def _load_gate():
    spec = importlib.util.spec_from_file_location("validate_dual_lane_gate", GATE_PATH)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class DualLaneGateTests(unittest.TestCase):
    def test_current_tree_passes(self):
        mod = _load_gate()
        self.assertEqual(mod.main(), 0)

    def test_rejects_global_sorig_symbols(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "sOrigNumberOfRowsByClass",
            "sOrigNumberOfRows;\nstatic NSMutableDictionary *sOrigNumberOfRowsByClass",
            1,
        )
        tmp = mod.CEXPORTS.with_suffix(".m.gate_test_tmp")
        try:
            tmp.write_text(polluted, encoding="utf-8")
            orig = mod.CEXPORTS
            mod.CEXPORTS = tmp
            self.assertNotEqual(mod.main(), 0)
        finally:
            mod.CEXPORTS = orig
            if tmp.exists():
                tmp.unlink()


if __name__ == "__main__":
    unittest.main()
