#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""双车道静态门禁：普通搜索不得写 XBS plaza；禁止全局 XBS rows/cell hook。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CEXPORTS = ROOT / "LegadoBridge" / "Sources" / "LegadoBridgeHooks" / "LegadoBridgeCExports.m"

# 全局 sOrig* 别名（非 ByClass 后缀扩展名，如 sOrigNumberOfRowsGlobal）。
_SORIG_ALIAS = re.compile(
    r"\bsOrig(?:NumberOfRows|CellForRow|HeightForRow)(?!ByClass)\w+",
)

# Native XBS pass-through must use only the current class's captured IMP.
# Shared Forward/true-plain slots are for non-XBS compatibility paths and
# must never be reachable from the native plaza helper.
_DIRECT_CROSS_CLASS_IN_HOOK = re.compile(
    r"\b(?:sTruePlain(?:NumberOfRows|CellForRow)|sOrigCatalog(?:NumberOfRows|CellForRow))\b",
)


def _fail(msg: str) -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    return 1


def _extract_static_function(text: str, name: str) -> str | None:
    """提取 static C 函数体（不含外层花括号）。"""
    pattern = rf"static\s+[\w\s*]+{re.escape(name)}\s*\([^)]*\)\s*\{{"
    match = re.search(pattern, text)
    if not match:
        return None
    start = match.end()
    depth = 1
    index = start
    while index < len(text) and depth > 0:
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        if depth == 0:
            return text[start:index]
        index += 1
    return None


def _extract_function(text: str, name: str) -> str | None:
    """Extract either a static or exported C function body."""
    pattern = rf"(?:static\s+)?[\w\s*]+{re.escape(name)}\s*\([^)]*\)\s*\{{"
    match = re.search(pattern, text)
    if not match:
        return None
    start = match.end()
    depth = 1
    index = start
    while index < len(text) and depth > 0:
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        if depth == 0:
            return text[start:index]
        index += 1
    return None


def _extract_braced_block(text: str, header: str) -> str | None:
    """Extract the body of the first control block whose header is exact text."""
    start = text.find(header)
    if start < 0:
        return None
    brace = text.find("{", start + len(header))
    if brace < 0:
        return None
    depth = 1
    index = brace + 1
    while index < len(text) and depth > 0:
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        if depth == 0:
            return text[brace + 1 : index]
        index += 1
    return None


def _first_index(text: str, *needles: str) -> int:
    """Return the first position of any needle, or -1."""
    positions = [text.find(needle) for needle in needles]
    positions = [position for position in positions if position >= 0]
    return min(positions) if positions else -1


def _check_install_writes_byclass(text: str) -> str | None:
    install_fn = _extract_static_function(text, "LBInstallHookOnClassOnly")
    if not install_fn:
        return "LBInstallHookOnClassOnly not found"
    for sym in (
        "LBStoreOrigIMP(sOrigNumberOfRowsByClass",
        "LBStoreOrigIMP(sOrigCellForRowByClass",
        "LBStoreOrigIMP(sOrigHeightForRowByClass",
    ):
        if sym not in install_fn:
            return f"LBInstallHookOnClassOnly missing ByClass store: {sym}"
    return None


def _check_hook_byclass_before_forward(text: str) -> list[str]:
    errors: list[str] = []
    helper = _extract_static_function(text, "LBNativePlazaIMP")
    if not helper:
        errors.append("LBNativePlazaIMP not found")
    else:
        if "LBStoredOrigIMP(dict, cls)" not in helper:
            errors.append("LBNativePlazaIMP missing current-class ByClass lookup")
        if "LBForwardTableRowsIMP()" in helper or "LBForwardTableCellIMP()" in helper:
            errors.append("LBNativePlazaIMP must not fall back to cross-class Forward IMP")
        if "sTruePlain" in helper or "sOrigCatalog" in helper:
            errors.append("LBNativePlazaIMP must not call shared native/cat IMP")
        if "return (native && native != hook) ? native : NULL;" not in helper:
            errors.append("LBNativePlazaIMP must fail closed when current class has no orig IMP")
        if _DIRECT_CROSS_CLASS_IN_HOOK.search(helper):
            errors.append("LBNativePlazaIMP must not call sTruePlain*/sOrigCatalog* directly")
    rows_fn = _extract_static_function(text, "LBHookedNumberOfRows")
    if not rows_fn:
        errors.append("LBHookedNumberOfRows not found")
    else:
        if "LBNativePlazaIMP(sOrigNumberOfRowsByClass" not in rows_fn:
            errors.append(
                "LBHookedNumberOfRows must resolve orig via LBNativePlazaIMP"
            )
        if _DIRECT_CROSS_CLASS_IN_HOOK.search(rows_fn):
            errors.append(
                "LBHookedNumberOfRows must not call sTruePlain*/sOrigCatalog* directly — "
                "use ByClass or LBForwardTableRowsIMP()"
            )

    cell_fn = _extract_static_function(text, "LBHookedCellForRow")
    if not cell_fn:
        errors.append("LBHookedCellForRow not found")
    else:
        if "LBNativePlazaIMP(sOrigCellForRowByClass" not in cell_fn:
            errors.append(
                "LBHookedCellForRow must resolve orig via LBNativePlazaIMP"
            )
        if _DIRECT_CROSS_CLASS_IN_HOOK.search(cell_fn):
            errors.append(
                "LBHookedCellForRow must not call sTruePlain*/sOrigCatalog* directly — "
                "use ByClass or LBForwardTableCellIMP()"
            )
    return errors


def main() -> int:
    if not CEXPORTS.is_file():
        return _fail(f"missing {CEXPORTS}")

    text = CEXPORTS.read_text(encoding="utf-8", errors="replace")

    # P0-B: LBInstallSearchUIAppearFlush must not install rows/cell on XBS plaza classes.
    install_block = re.search(
        r"void LBInstallSearchUIAppearFlush\(void\) \{(.*?)^\}",
        text,
        re.S | re.M,
    )
    if not install_block:
        return _fail("LBInstallSearchUIAppearFlush not found")
    body = install_block.group(1)
    for bad in ("BookListCon", "BookWorldHomeCon", "BookStoreBaseCon", "ShudanHomeCon"):
        if bad in body and "LBHookedNumberOfRows" in body:
            return _fail(f"LBInstallSearchUIAppearFlush still hooks XBS plaza class {bad}")

    # CatalogUI startup is allowed to guard BookSearch/Catalog only.  It must
    # never permanently swizzle a native XBS plaza didSelect implementation.
    catalog_ui = _extract_braced_block(text, "void LBInstallCatalogUIAppearFlush(void)")
    if not catalog_ui:
        return _fail("LBInstallCatalogUIAppearFlush not found")
    for bad in ("BookListCon", "BookWorldHomeCon", "BookStoreBaseCon", "ShudanHomeCon"):
        if bad in catalog_ui:
            return _fail(f"LBInstallCatalogUIAppearFlush still names native XBS class {bad}")

    # Ordinary search must be an exact BookSearch lane, not a generic
    # SearchController/searchBar/arrSearchItems heuristic.
    search_fn = _extract_static_function(text, "LBVCLooksLikeBookSearch")
    if not search_fn or "LBIsExactBookSearchClass([vc class])" not in search_fn:
        return _fail("LBVCLooksLikeBookSearch missing exact BookSearch class guard")
    if any(needle in search_fn for needle in ("SearchController", "arrSearchItems", "searchBar")):
        return _fail("LBVCLooksLikeBookSearch still accepts generic search controller state")

    # P0-A: ordinary search must not target discoverHosts.
    if re.search(
        r"else if \(discoverHosts\.count > 0\)\s*\{\s*\[targets addObjectsFromArray:discoverHosts\]",
        text,
    ):
        return _fail("ordinary search still merges discoverHosts into targets")

    # P0-A: LBMergeBookIntoSearchVC must guard non-BookSearch / native XBS plaza.
    merge_fn = re.search(
        r"static void LBMergeBookIntoSearchVC\(.*?\n\}",
        text,
        re.S,
    )
    if not merge_fn:
        return _fail("LBMergeBookIntoSearchVC not found")
    merge = merge_fn.group(0)
    for needle in (
        "LBVCLooksLikeBookSearch(vc)",
        "LBIsDiscoverNativeXBSMode() && LBClassNameIsXBSPlazaHost(NSStringFromClass([vc class]))",
    ):
        if needle not in merge:
            return _fail(f"LBMergeBookIntoSearchVC missing guard: {needle}")

    # P0-B: the rows==0 emergency rebind is Legado-only.  It may rely on the
    # surrounding !nativeXBS block, but must never be moved outside it.
    non_xbs_block = _extract_braced_block(merge, "if (!nativeXBS)")
    rows_zero_fallback = "if (arrN > 0 && rows == 0)"
    if not non_xbs_block or rows_zero_fallback not in non_xbs_block:
        return _fail("rows==0 dataSource rebind fallback is not enclosed by !nativeXBS")

    # P1: separate explore vs ordinary pending buffers.
    if "sPendingExploreBooks" not in text or "sPendingSearchBooks" not in text:
        return _fail("explore/ordinary pending buffers not separated")

    # P0-B: forbid cross-class global sOrig* IMP slots (per-class ByClass only).
    for sym in ("sOrigNumberOfRows", "sOrigCellForRow", "sOrigHeightForRow"):
        if re.search(rf"\b{sym}\b(?!\s*ByClass)", text):
            return _fail(f"global {sym} still present — use {sym}ByClass per-class map only")
    alias = _SORIG_ALIAS.search(text)
    if alias:
        return _fail(
            f"global sOrig* alias still present ({alias.group(0)}) — use *ByClass per-class map only"
        )
    for required in (
        "sOrigNumberOfRowsByClass",
        "sOrigCellForRowByClass",
        "sOrigHeightForRowByClass",
    ):
        if required not in text:
            return _fail(f"missing per-class orig map {required}")
    if "LBStoredOrigIMP(sOrigNumberOfRowsByClass" not in text:
        return _fail("LBHookedNumberOfRows must resolve orig via sOrigNumberOfRowsByClass")
    if "LBStoredOrigIMP(sOrigCellForRowByClass" not in text:
        return _fail("LBHookedCellForRow must resolve orig via sOrigCellForRowByClass")
    if "LBStoredOrigIMP(sOrigHeightForRowByClass" not in text:
        return _fail("LBHookedHeightForRow must resolve orig via sOrigHeightForRowByClass")

    install_err = _check_install_writes_byclass(text)
    if install_err:
        return _fail(install_err)

    for hook_err in _check_hook_byclass_before_forward(text):
        return _fail(hook_err)

    # A stale hook must still fail-open to the target class's native IMP while
    # XBS discovery is active.  This is a pass-through contract, not an arrN
    # or synthetic-cell fallback.
    for fn_name in ("LBHookedNumberOfRows", "LBHookedCellForRow", "LBHookedHeightForRow"):
        fn = _extract_static_function(text, fn_name)
        if not fn or "LBIsDiscoverNativeXBSMode()" not in fn:
            return _fail(f"{fn_name} missing native XBS pass-through guard")
        class_guard = "LBClassNameIsXBSPlazaHost" if fn_name == "LBHookedHeightForRow" else "plazaHost"
        if class_guard not in fn:
            return _fail(f"{fn_name} missing native XBS pass-through guard")
    did_select = _extract_static_function(text, "LBHookedPlazaDidSelect")
    if not did_select or "LBStoredOrigIMP(sOrigPlazaDidSelectByClass" not in did_select:
        return _fail("LBHookedPlazaDidSelect missing per-class native IMP lookup")
    native_did_select = did_select.split("@try", 1)[0]
    if "sTruePlainDidSelect" in native_did_select:
        return _fail("native XBS didSelect must not fall back to cross-class global IMP")

    # Captured explore publication must reject malformed books before permit
    # issuance.  Empty arrays remain valid; a malformed callback may only
    # discard an exact-token old bundle and must never touch a newer bundle.
    capture_fn = _extract_static_function(text, "LBApplySearchResultsToUIWithCapturedTokenInternal")
    if not capture_fn:
        return _fail("captured explore apply function not found")
    permit_pos = _first_index(capture_fn, "LBSharedRouterRequestPublishPermit")
    books_guard = "if (![books isKindOfClass:[NSArray class]])"
    books_guard_pos = capture_fn.find(books_guard)
    malformed_books = _extract_braced_block(capture_fn, books_guard)
    if books_guard_pos < 0 or permit_pos < 0 or books_guard_pos > permit_pos or not malformed_books:
        return _fail("captured explore must reject malformed books before requesting permit")
    if "LBDiscardExplorePendingBundleMatchingToken" not in malformed_books or "return;" not in malformed_books:
        return _fail("malformed books must stop after exact-token stale-bundle cleanup")
    for mutation in (
        "LBSharedRouterRequestPublishPermit", "sPendingExploreBooks =",
        "sPendingExploreKeyword =", "sPendingExploreToken =",
        "sPrevalidatedExplorePermit =", "sPendingExploreFirstPage =",
        "sPendingExploreCacheHit =",
    ):
        if mutation in malformed_books:
            return _fail(f"malformed books path must not issue/mutate: {mutation}")
    if re.search(r"\bbooks\s*\.\s*count\b|\[\s*books\s+count\s*\]", capture_fn[:permit_pos]):
        return _fail("empty books array must remain a valid publication")
    matching_discard = _extract_static_function(text, "LBDiscardExplorePendingBundleMatchingToken")
    exact_discard = "if ([token isKindOfClass:[NSDictionary class]] && [sPendingExploreToken isEqual:token]) LBDiscardExplorePendingBundle();"
    if not matching_discard or exact_discard not in matching_discard:
        return _fail("malformed callback cleanup must discard only the exact-token old bundle")
    pending_pos = _first_index(
        capture_fn,
        "sPendingExploreBooks removeAllObjects",
        "sPendingExploreBooks =",
        "sPendingExploreKeyword =",
        "sPendingExploreToken =",
    )
    if pending_pos < 0 or permit_pos > pending_pos:
        return _fail("captured explore permit is not obtained before pending mutation")
    if re.search(r"\bLBDiscardExplorePendingBundle\s*\(", capture_fn):
        return _fail("captured explore rejection still discards pending state")
    if "LBSharedRouterRequestCacheHitPublishPermit" in capture_fn:
        return _fail("captured explore path still exposes untyped cache permit")

    apply_fn = _extract_braced_block(text, "void LBApplySearchResultsToUI(NSArray *books, NSString *keyword)")
    if not apply_fn:
        return _fail("LBApplySearchResultsToUI not found")
    apply_permit = _first_index(
        apply_fn,
        "LBResolveExplorePermit",
        "LBSharedRouterRequestPublishPermit",
        "LBSharedRouterRequestCacheHitPublishPermit",
    )
    apply_pending = _first_index(
        apply_fn,
        "sPendingExploreBooks ?:",
        "sPendingExploreBooks =",
        "sPendingExploreKeyword =",
        "sPendingExploreToken =",
    )
    if apply_permit < 0 or apply_pending < 0 or apply_permit > apply_pending:
        return _fail("explore apply mutates pending state before permit")
    if apply_fn.count("LBDiscardExplorePendingBundle") < 5:
        return _fail("explore host/target/owner/exception failures must discard one-shot state")
    if "if (exploreMode) LBDiscardExplorePendingBundle();" not in apply_fn:
        return _fail("explore apply exception path must discard one-shot state")
    resolve_fn = _extract_static_function(text, "LBResolveExplorePermit")
    if not resolve_fn:
        return _fail("LBResolveExplorePermit missing")
    if "LBSharedRouterRequestPublishPermit" in resolve_fn or "LBSharedRouterRequestCacheHitPublishPermit" in resolve_fn:
        return _fail("LBResolveExplorePermit must consume only its prevalidated permit")
    consume_pos = resolve_fn.find("sPrevalidatedExplorePermit = nil")
    match_pos = _first_index(resolve_fn, "LBPermitMatchesExploreCapture")
    if consume_pos < 0 or match_pos < 0 or consume_pos > match_pos:
        return _fail("LBResolveExplorePermit must consume permit before validation")

    # Cache publication is intentionally disabled until a typed nonce/mode is
    # emitted by the coordinator; the ABI stub must not call into the router.
    cache_apply = _extract_function(text, "LBApplySearchResultsToUIWithCapturedCacheToken")
    if not cache_apply or "cacheTypedNonce" not in cache_apply or "LBApplySearchResultsToUIWithCapturedTokenInternal" in cache_apply:
        return _fail("untyped cache entrypoint must fail closed")
    cache_router = _extract_function(text, "LBSharedRouterRequestCacheHitPublishPermit")
    if not cache_router or "cacheTypedNonceUnavailable" not in cache_router or "objc_msgSend" in cache_router:
        return _fail("cache permit router must fail closed without typed nonce")

    # Network publication must validate mode, identity, and requestSequence;
    # cacheHit is not a substitute for a typed transport mode.
    request_fn = _extract_static_function(text, "LBPermitMatchesExploreRequest")
    capture_match_fn = _extract_static_function(text, "LBPermitMatchesExploreCapture")
    for fn_name, fn in (("LBPermitMatchesExploreRequest", request_fn), ("LBPermitMatchesExploreCapture", capture_match_fn)):
        if not fn:
            return _fail(f"{fn_name} missing")
        for needle in ("requestSequence", "cacheHit", "LBPermitModeIsNetwork", "sourceKind", "canonicalID", "exactSourceUrl", "snapshotID", "nodeID", "ownerControllerIdentity", "definitionFingerprint", "runtimeEpoch", "page"):
            if needle not in fn:
                return _fail(f"{fn_name} missing strict {needle} check")
        if "isEqual:captured[key]" not in fn:
            return _fail(f"{fn_name} must compare every token identity field exactly")

    # Explore clear must reset books, lane keyword, flags, token and permit.
    discard_fn = _extract_static_function(text, "LBDiscardExplorePendingBundle")
    if not discard_fn:
        return _fail("LBDiscardExplorePendingBundle missing")
    for needle in ("sPendingExploreBooks", "sPendingExploreKeyword", "sPendingExploreToken", "sPrevalidatedExplorePermit", "sPendingExploreFirstPage", "sPendingExploreCacheHit"):
        if needle not in discard_fn:
            return _fail(f"explore discard missing {needle}")
    for clear_name in ("LBClearDiscoverExplorePendingOnly", "LBClearDiscoverExploreBooks"):
        clear_fn = _extract_function(text, clear_name)
        if not clear_fn or "LBDiscardExplorePendingBundle" not in clear_fn:
            return _fail(f"{clear_name} must clear the complete explore bundle")

    # Flush must use lane-specific keywords, never a shared keyword to choose
    # which buffer is consumed.
    flush_fn = _extract_static_function(text, "LBFlushPendingSearchUI")
    if not flush_fn or "sPendingExploreKeyword" not in flush_fn or "sPendingSearchKeyword" not in flush_fn:
        return _fail("flush lane state is not separated")
    if "LBDiscardExplorePendingBundle" not in flush_fn:
        return _fail("flush must discard invalid explore token/permit state")
    if "NSString *kw" in flush_fn or "BOOL exploreMode = LBKeywordIsExploreMode(kw)" in flush_fn:
        return _fail("flush must not derive lane from a shared keyword")
    for mutation in ("LBSetDiscoverTabActive(YES)", "LBEnsureNativeDiscoverHostPresented()", "LBInstallPlazaListTableHooks"):
        position = apply_fn.find(mutation)
        if position >= 0 and position < apply_permit:
            return _fail(f"explore apply performs {mutation} before permit")

    print("PASS dual-lane gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
