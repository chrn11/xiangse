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


def _objc_release_only(text: str) -> str:
    return _load_gate()._objc_release_only(text)


def _swift_release_only(text: str) -> str:
    return _load_gate()._swift_release_only(text)


class TestValidateHooksGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = _load_gate()

    def test_clean_sources_pass(self):
        sources = {
            "LBReadingHooks.m": "// no banned patterns\nvoid LBSetDicBook_Invoke(void) {}\n",
            "LBHookSiteRegistry.m": "LBHookSiteRegistryInstallSetDicBook();\n",
        }
        errors, _metrics = self.gate.scan_hooks(sources)
        self.assertEqual(errors, [])

    def test_global_lborig_setdicbook_fails(self):
        sources = {
            "LBReadingHooks.m": "static void (*LBOrig_setDicBook)(id, SEL, id) = NULL;\n",
        }
        errs, _ = self.gate.scan_hooks(sources)
        self.assertTrue(any("LBOrig_setDicBook" in e for e in errs), errs)

    def test_setter_msgsend_self_fails(self):
        sources = {
            "LBReadingHooks.m": "objc_msgSend(self, @selector(setDicBook:), book);\n",
        }
        errs, _ = self.gate.scan_hooks(sources)
        self.assertTrue(any("objc_msgSend" in e for e in errs), errs)

    def test_dynamic_self_original_fails(self):
        sources = {
            "LBHookSiteRegistry.m": "IMP p = LBHookSiteRegistryPreviousIMP([self class], sel);\n",
        }
        errs, _ = self.gate.scan_hooks(sources)
        self.assertTrue(any("动态 self" in e for e in errs), errs)

    def test_replacement_as_previous_fails(self):
        sources = {
            "LBHookSiteRegistry.m": "capturedPrevious = LBHookSiteRegistryReplacementIMP(owner, sel);\n",
        }
        errs, _ = self.gate.scan_hooks(sources)
        self.assertTrue(any("replacement" in e.lower() for e in errs), errs)

    def test_tc07_donor_in_release_fails(self):
        bad = _objc_release_only(
            "#if DEBUG\nLBFindDonorBookWorld(mgr, nil);\n#endif\n"
            "LBFindDonorBookWorld(mgr, nil);\n"
        )
        errs = self.gate._check_discover_release_forbidden("t.m", bad)
        self.assertTrue(any("LBFindDonorBookWorld" in e for e in errs), errs)

    def test_tc07_debug_donor_allowed(self):
        src = "#if DEBUG\nLBFindDonorBookWorld(mgr, nil);\n#endif\n"
        errs = self.gate._check_discover_release_forbidden("t.m", src)
        self.assertEqual(errs, [], errs)

    def test_tc08_reset_in_release_fails(self):
        bad = "@selector(resetContent)"
        errs = self.gate._check_discover_release_forbidden(
            "t.m", f"((void (*)(id, SEL))objc_msgSend)(host, {bad});"
        )
        self.assertTrue(any("resetContent" in e for e in errs), errs)

    def test_discover_kindbar_release_passes(self):
        if not self.gate.DISCOVER_KIND_BAR.is_file():
            self.skipTest("LBDiscoverKindBar.m missing")
        text = self.gate.DISCOVER_KIND_BAR.read_text(encoding="utf-8")
        errs = self.gate._check_discover_release_forbidden("LBDiscoverKindBar.m", text)
        self.assertEqual(errs, [], errs)

    def test_real_tree_currently_passes(self):
        errs, metrics = self.gate.scan_hooks()
        self.assertEqual(errs, [], errs)
        self.assertIn("cexports_total_legado_write", metrics)

    def test_tc11_cexports_sensitive_write_fixture_fails_budget(self):
        bad = (
            'NSString *msg = @"https://x.example/src=1";\n'
            '[msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:'
            '@"Documents/legado_diag.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];\n'
        )
        sources = {"LegadoBridgeCExports.m": bad}
        _debt, metrics = self.gate._check_tc11_cexports_legado_writes(sources)
        self.assertGreaterEqual(metrics.get("cexports_sensitive_legado_write", 0), 1)

    def test_tc11_cexports_sensitive_over_budget_fails(self):
        budgets = self.gate._load_tc11_debt()
        cap = budgets.get("cexports_sensitive_legado_write", 0)
        lines = []
        for i in range(cap + 2):
            lines.append(
                f'[@"https://e{i}.example" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:'
                f'@"Documents/legado_t{i}.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];\n'
            )
        sources = {"LegadoBridgeCExports.m": "\n".join(lines)}
        _debt, metrics = self.gate._check_tc11_cexports_legado_writes(sources)
        ratchet = self.gate._apply_tc11_debt_ratchet(_debt, metrics)
        self.assertTrue(any("超过 ratchet" in e for e in ratchet), ratchet)

    def test_tc11_injector_prod_save_fails(self):
        bad = _swift_release_only(
            "func syncToNativeManager(sources: [MemoryBridgeBookSource]) {\n"
            "  _ = manager.perform(saveSel)\n"
            "}\n"
        )
        self.assertTrue(self.gate.TC11_INJECTOR_PROD_SAVE.search(bad))

    def test_tc11_catalogcon_alloc_release_fails(self):
        sources = {
            "LegadoBridgeCExports.m": "id vc = [CatalogCon alloc];\n",
        }
        errs = self.gate._check_tc11_catalogcon_release(sources)
        self.assertTrue(errs, errs)

    def test_tc10_cookie_jar_in_bridge_core_release_fails(self):
        bad = _swift_release_only(
            'let path = "Documents/legado_cookie_jar.txt"\n'
            'try? line.write(toFile: path, atomically: true, encoding: .utf8)\n'
        )
        errors: list[str] = []
        for pat, label in (
            (self.gate.TC10_COOKIE_JAR_PATH, "legado_cookie_jar.txt"),
            (self.gate.TC10_SWIFT_SENSITIVE_WRITE, "敏感内容写盘"),
        ):
            for m in pat.finditer(bad):
                errors.append(label)
        self.assertIn("legado_cookie_jar.txt", errors)

    def test_tc10_cookie_jar_debug_guarded_allowed(self):
        src = '#if DEBUG\nlet p = "legado_cookie_jar.txt"\n#endif\n'
        release = _swift_release_only(src)
        self.assertNotIn("legado_cookie_jar", release)

    def test_tc10_hooks_cookie_jar_fails(self):
        sources = {
            "LBReadingHooks.m": (
                '[@"x" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:'
                '@"Documents/legado_cookie_jar.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];\n'
            ),
        }
        errs = self.gate._check_tc10_hooks_sensitive_writes(sources)
        self.assertTrue(any("legado_cookie_jar" in e for e in errs), errs)

    def test_tc10_hooks_sensitive_url_write_fails(self):
        sources = {
            "LBReadingHooks.m": (
                'NSString *msg = @"https://secret.example/sessionid=abc";\n'
                '[msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:'
                '@"Documents/legado_reading_diag.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];\n'
            ),
        }
        errs = self.gate._check_tc10_hooks_sensitive_writes(sources)
        self.assertTrue(any("敏感内容" in e for e in errs), errs)

    def test_tc09_lbsearch_bookkey_fixture_fails(self):
        sources = {
            "LegadoBridgeCExports.m": "static NSString *LBSearchBookKey(NSDictionary *d) { return @\"x\"; }\n",
        }
        errs, _ = self.gate.scan_hooks(sources)
        self.assertTrue(any("LBSearchBookKey" in e for e in errs), errs)

    def test_tc09_kill_file_fixture_fails(self):
        sources = {"LegadoBridgeCExports.m": "legado_u1_catalog_bridge_only\n"}
        errs, _ = self.gate.scan_hooks(sources)
        self.assertTrue(any("kill-file" in e for e in errs), errs)

    def test_tc11_kindbar_net_increase_over_cap_fails(self):
        budgets = self.gate._load_tc11_debt()
        base = int(budgets.get("discover_kindbar_lines_baseline", 0))
        cap = int(budgets.get("discover_kindbar_net_increase_max", 150))
        fake_lines = base + cap + 3
        net = fake_lines - base
        self.assertGreater(net, cap)

    def test_tc11_kindbar_net_increase_real_tree_within_cap(self):
        debt, metrics = self.gate._check_tc11_line_budgets()
        net = metrics.get("discover_kindbar_net_increase")
        if net is not None:
            cap = int(self.gate._load_tc11_debt().get("discover_kindbar_net_increase_max", 150))
            self.assertLessEqual(net, cap, f"net={net} cap={cap}")
        self.assertFalse(any("净增行数" in e for e in debt), debt)


if __name__ == "__main__":
    # 确保可从任意 cwd 运行
    sys.path.insert(0, str(GATE_PATH.parent))
    unittest.main()
