#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""validate_hooks_gate.py 单测：含 TC-02 setDicBook 禁止模式。"""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "tools" / "ci" / "validate_hooks_gate.py"


def _load_gate():
    spec = importlib.util.spec_from_file_location("validate_hooks_gate", GATE_PATH)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class TestValidateHooksGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = _load_gate()

    def test_clean_sources_pass(self):
        sources = {
            "LBReadingHooks.m": "// no banned patterns\nvoid LBSetDicBook_Invoke(void) {}\n",
            "LBHookSiteRegistry.m": "LBHookSiteRegistryInstallSetDicBook();\n",
        }
        self.assertEqual(self.gate.scan_hooks(sources), [])

    def test_global_lborig_setdicbook_fails(self):
        sources = {
            "LBReadingHooks.m": "static void (*LBOrig_setDicBook)(id, SEL, id) = NULL;\n",
        }
        errs = self.gate.scan_hooks(sources)
        self.assertTrue(any("LBOrig_setDicBook" in e for e in errs), errs)

    def test_setter_msgsend_self_fails(self):
        sources = {
            "LBReadingHooks.m": "objc_msgSend(self, @selector(setDicBook:), book);\n",
        }
        errs = self.gate.scan_hooks(sources)
        self.assertTrue(any("objc_msgSend" in e for e in errs), errs)

    def test_dynamic_self_original_fails(self):
        sources = {
            "LBHookSiteRegistry.m": "IMP p = LBHookSiteRegistryPreviousIMP([self class], sel);\n",
        }
        errs = self.gate.scan_hooks(sources)
        self.assertTrue(any("动态 self" in e for e in errs), errs)

    def test_replacement_as_previous_fails(self):
        sources = {
            "LBHookSiteRegistry.m": "capturedPrevious = LBHookSiteRegistryReplacementIMP(owner, sel);\n",
        }
        errs = self.gate.scan_hooks(sources)
        self.assertTrue(any("replacement" in e.lower() for e in errs), errs)

    def test_real_tree_currently_passes(self):
        errs = self.gate.scan_hooks()
        self.assertEqual(errs, [], errs)


if __name__ == "__main__":
    # 确保可从任意 cwd 运行
    sys.path.insert(0, str(GATE_PATH.parent))
    unittest.main()
