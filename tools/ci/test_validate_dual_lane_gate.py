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


def _mutate_static_body(mod, text: str, name: str, old: str, new: str) -> str:
    body = mod._extract_static_function(text, name)
    if body is None:
        body = mod._extract_function(text, name)
    if body is None or old not in body:
        raise AssertionError(f"fixture marker missing in {name}: {old!r}")
    mutated = body.replace(old, new, 1)
    return text.replace(body, mutated, 1)


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
        polluted = text.replace(
            "LBStoredOrigIMP(sOrigNumberOfRowsByClass, [self class])",
            "((IMP)0)",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_hook_direct_trueplain_in_rows(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "IMP native = LBStoredOrigIMP(dict, cls);",
            "IMP native = sTruePlainNumberOfRows;",
            1,
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_hook_cell_without_byclass(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "LBNativePlazaIMP(sOrigCellForRowByClass",
            "LBNativePlazaIMP(((IMP)0)",
            1,
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_rows_zero_rebind_outside_native_xbs_guard(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "if (!nativeXBS) {\n            @try",
            "if (YES) {\n            @try",
            1,
        )
        self.assertNotEqual(text, polluted, "fixture must remove the enclosing XBS guard")
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_catalog_ui_xbs_did_select_startup_hook(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        marker = 'for (NSString *cn in @[@"BookSearchController", @"BookSearchVCBase1", @"BookSearchVCBase2"])'
        polluted = text.replace(
            marker,
            'for (NSString *cn in @[@"BookSearchController", @"BookSearchVCBase1", @"BookSearchVCBase2", @"BookListCon"])',
            1,
        )
        self.assertNotEqual(text, polluted, "fixture must add an XBS CatalogUI target")
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_generic_search_vc_heuristic(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "return LBIsExactBookSearchClass([vc class]);",
            "if ([NSStringFromClass([vc class]) containsString:@\"SearchController\"]) return YES;\n    return LBIsExactBookSearchClass([vc class]);",
            1,
        )
        self.assertNotEqual(text, polluted, "fixture must restore generic search heuristic")
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_explore_pending_write_before_permit(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "NSDictionary *permit = LBSharedRouterRequestPublishPermit(capturedToken, isFirstPage);",
            "sPendingExploreToken = [capturedToken copy];\n    NSDictionary *permit = isCacheHit ? LBSharedRouterRequestCacheHitPublishPermit(capturedToken) : LBSharedRouterRequestPublishPermit(capturedToken, isFirstPage);",
            1,
        )
        self.assertNotEqual(text, polluted, "fixture must move a pending write before permit")
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_explore_rejection_discard_side_effect(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text.replace(
            "NSDictionary *permit = LBSharedRouterRequestPublishPermit(capturedToken, isFirstPage);",
            "LBDiscardExplorePendingBundle();\n    NSDictionary *permit = isCacheHit ? LBSharedRouterRequestCacheHitPublishPermit(capturedToken) : LBSharedRouterRequestPublishPermit(capturedToken, isFirstPage);",
            1,
        )
        self.assertNotEqual(text, polluted, "fixture must add rejection side effect")
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_cache_callback_reactivation(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBApplySearchResultsToUIWithCapturedCacheToken",
            "(void)books; (void)keyword; (void)capturedToken; return;",
            "LBApplySearchResultsToUIWithCapturedTokenInternal(books, keyword, capturedToken, YES, YES);",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_cache_router_dispatch(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBSharedRouterRequestCacheHitPublishPermit",
            "(void)token;",
            "(void)token; objc_msgSend;",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_resolve_permit_reissue(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBResolveExplorePermit",
            "NSDictionary *permit = [sPrevalidatedExplorePermit copy];",
            "NSDictionary *reissued = LBSharedRouterRequestPublishPermit(token, firstPage);\n    NSDictionary *permit = [sPrevalidatedExplorePermit copy];",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_reusable_prevalidated_permit(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBResolveExplorePermit",
            "sPrevalidatedExplorePermit = nil;",
            "/* permit slot intentionally left reusable */",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_mode_agnostic_request_match(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBPermitMatchesExploreRequest",
            "LBPermitModeIsNetwork(permit, captured)",
            "YES",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_request_sequence_omission(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = text
        for _ in range(6):
            polluted = _mutate_static_body(
                mod, polluted, "LBPermitMatchesExploreRequest",
                "requestSequence",
                "sequenceGap",
            )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_non_exact_token_identity_comparison(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBPermitMatchesExploreCapture",
            "isEqual:captured[key]",
            "isEqual:@YES",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_shared_keyword_flush(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBFlushPendingSearchUI",
            "sPendingExploreKeyword",
            "sPendingSearchKeyword",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_flush_without_invalid_bundle_discard(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBFlushPendingSearchUI",
            "LBDiscardExplorePendingBundle();",
            "/* invalid explore bundle ignored */",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_clear_pending_only_without_bundle_clear(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBClearDiscoverExplorePendingOnly",
            "LBDiscardExplorePendingBundle();",
            "/* stale explore permit survives */",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_clear_books_without_bundle_clear(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBClearDiscoverExploreBooks",
            "LBDiscardExplorePendingBundle();",
            "/* stale explore permit survives */",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_exception_path_without_discard(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBApplySearchResultsToUI",
            "if (exploreMode) LBDiscardExplorePendingBundle();",
            "if (exploreMode) return;",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_native_helper_cross_class_fallback(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBNativePlazaIMP",
            "return (native && native != hook) ? native : NULL;",
            "return LBForwardTableRowsIMP();",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_native_did_select_global_fallback(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBHookedPlazaDidSelect",
            "return;",
            "else if (sTruePlainDidSelect) return;\n        return;",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_capture_cache_permit_call(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBApplySearchResultsToUIWithCapturedTokenInternal",
            "NSDictionary *permit = LBSharedRouterRequestPublishPermit(capturedToken, isFirstPage);",
            "LBSharedRouterRequestCacheHitPublishPermit(capturedToken);\n    NSDictionary *permit = LBSharedRouterRequestPublishPermit(capturedToken, isFirstPage);",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_malformed_books_guard_after_permit(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBApplySearchResultsToUIWithCapturedTokenInternal",
            "if (![books isKindOfClass:[NSArray class]]) {",
            "LBSharedRouterRequestPublishPermit(capturedToken, isFirstPage);\n    if (![books isKindOfClass:[NSArray class]]) {",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_malformed_books_pending_write(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBApplySearchResultsToUIWithCapturedTokenInternal",
            "if (![books isKindOfClass:[NSArray class]]) {",
            "if (![books isKindOfClass:[NSArray class]]) {\n        sPrevalidatedExplorePermit = @{};",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_malformed_cleanup_of_newer_bundle(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBDiscardExplorePendingBundleMatchingToken",
            "if ([token isKindOfClass:[NSDictionary class]] && [sPendingExploreToken isEqual:token]) LBDiscardExplorePendingBundle();",
            "if (sPendingExploreToken) LBDiscardExplorePendingBundle();",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)

    def test_rejects_empty_books_array_as_malformed(self):
        mod = _load_gate()
        text = mod.CEXPORTS.read_text(encoding="utf-8", errors="replace")
        polluted = _mutate_static_body(
            mod, text, "LBApplySearchResultsToUIWithCapturedTokenInternal",
            "NSDictionary *permit = LBSharedRouterRequestPublishPermit(capturedToken, isFirstPage);",
            "if (books.count == 0) return;\n    NSDictionary *permit = LBSharedRouterRequestPublishPermit(capturedToken, isFirstPage);",
        )
        with _gate_on_text(mod, polluted) as code:
            self.assertNotEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
