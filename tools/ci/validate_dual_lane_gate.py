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

# hook 路径必须先 ByClass 再 Forward；禁止在 hook 内直接调共享槽。
_ROWS_BYCLASS_BEFORE_FORWARD = re.compile(
    r"LBStoredOrigIMP\s*\(\s*sOrigNumberOfRowsByClass\s*,.*?"
    r"LBForwardTableRowsIMP\s*\(\s*\)",
    re.S,
)
_CELL_BYCLASS_BEFORE_FORWARD = re.compile(
    r"LBStoredOrigIMP\s*\(\s*sOrigCellForRowByClass\s*,.*?"
    r"LBForwardTableCellIMP\s*\(\s*\)",
    re.S,
)
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
    rows_fn = _extract_static_function(text, "LBHookedNumberOfRows")
    if not rows_fn:
        errors.append("LBHookedNumberOfRows not found")
    else:
        if "LBStoredOrigIMP(sOrigNumberOfRowsByClass" not in rows_fn:
            errors.append(
                "LBHookedNumberOfRows must resolve orig via sOrigNumberOfRowsByClass before Forward"
            )
        elif not _ROWS_BYCLASS_BEFORE_FORWARD.search(rows_fn):
            errors.append(
                "LBHookedNumberOfRows missing ByClass→Forward miss path "
                "(LBStoredOrigIMP(sOrigNumberOfRowsByClass … LBForwardTableRowsIMP())"
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
        if "LBStoredOrigIMP(sOrigCellForRowByClass" not in cell_fn:
            errors.append(
                "LBHookedCellForRow must resolve orig via sOrigCellForRowByClass before Forward"
            )
        elif not _CELL_BYCLASS_BEFORE_FORWARD.search(cell_fn):
            errors.append(
                "LBHookedCellForRow missing ByClass→Forward miss path "
                "(LBStoredOrigIMP(sOrigCellForRowByClass … LBForwardTableCellIMP())"
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

    print("PASS dual-lane gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
