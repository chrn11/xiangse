#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""双车道静态门禁：普通搜索不得写 XBS plaza；禁止全局 XBS rows/cell hook。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CEXPORTS = ROOT / "LegadoBridge" / "Sources" / "LegadoBridgeHooks" / "LegadoBridgeCExports.m"


def _fail(msg: str) -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    return 1


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

    print("PASS dual-lane gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
