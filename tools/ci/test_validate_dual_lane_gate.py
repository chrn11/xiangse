#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""validate_dual_lane_gate.py 单测。"""
from __future__ import annotations

import importlib.util
import re
import sys
import unittest
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "tools" / "ci" / "validate_dual_lane_gate.py"


def _load_gate():
    spec = importlib.util.spec_from_file_location("validate_dual_lane_gate", GATE_PATH)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


@contextmanager
def _gate_on_text(mod, text: str):
    tmp = mod.CEXPORTS.with_suffix(".m.gate_test_tmp")
    orig = mod.CEXPORTS
    try:
        tmp.write_text(text, encoding="utf-8")
        mod.CEXPORTS = tmp
        yield mod.main()
    finally:
        mod.CEXPORTS = orig
        if tmp.exists():
            tmp.unlink()


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
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_sorig_alias_symbol(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "static IMP sTruePlainNumberOfRows = NULL;",
            "static IMP sOrigNumberOfRowsGlobal = NULL;\nstatic IMP sTruePlainNumberOfRows = NULL;",
            1,
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_install_without_byclass_store(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "LBStoreOrigIMP(sOrigNumberOfRowsByClass, targetCls, current);",
            "// adversarial: skip rows ByClass store",
            1,
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_hook_rows_without_byclass(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = re.sub(
            r"IMP classOrig = LBStoredOrigIMP\(sOrigNumberOfRowsByClass, \[self class\]\);\s*"
            r"if \(classOrig\) \{\s*"
            r"orig = \(\(NSInteger \(\*\)\(id, SEL, UITableView \*, NSInteger\)\)classOrig\)"
            r"\(self, _cmd, tv, section\);\s*"
            r"\} else \{\s*"
            r"IMP fwd = LBForwardTableRowsIMP\(\);",
            "IMP fwd = LBForwardTableRowsIMP();",
            text,
            count=1,
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_hook_direct_trueplain_in_rows(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "IMP fwd = LBForwardTableRowsIMP();",
            "if (sTruePlainNumberOfRows) { orig = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))sTruePlainNumberOfRows)(self, _cmd, tv, section); } IMP fwd = LBForwardTableRowsIMP();",
            1,
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_hook_cell_without_byclass(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = re.sub(
            r"LBStoredOrigIMP\(\s*sOrigCellForRowByClass[^)]*\)",
            "((IMP)0)",
            text,
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
