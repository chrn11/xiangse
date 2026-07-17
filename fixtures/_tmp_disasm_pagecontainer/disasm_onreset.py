#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""完整反汇编 TextReadVC3#onResetContentNotify 及相邻方法。"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from disasm_pagecontainer import (  # noqa: E402
    build_maps,
    disasm_imp,
    lief,
)

IMAGE_BASE = 0x100000000
TARGETS = [
    (0x10000b578, "TextReadVC3_onResetContentNotify"),
    (0x10000b5f8, "TextReadVC3_onFilterContentNotify"),
]


def main() -> None:
    bin_path = Path("analysis/unpacked/Payload/StandarReader.app/StandarReader")
    raw = bin_path.read_bytes()
    binary = lief.parse(str(bin_path))
    sel_va, selref, classref = build_maps(binary, raw)

    # 搜索 selref 中 onResetContentNotify: 是否存在于二进制
    colon_sels = {k: v for k, v in selref.items() if "onReset" in v}
    print("=== onReset* selrefs ===")
    for va, name in sorted(colon_sels.items(), key=lambda x: x[1]):
        print(f"  {hex(va)}: {name}")

    for imp_va, label in TARGETS:
        result = disasm_imp(binary, raw, sel_va, selref, classref, imp_va, max_insns=1200)
        msgs = [s for s in result["steps"] if "msgSend" in s]
        print(f"\n=== {label} IMP {hex(imp_va)} ret {result['ret']} insns={result['insn_count']} ===")
        for m in msgs:
            ms = m["msgSend"]
            sel = ms.get("selector") or "?"
            recv = ms.get("receiver") or "self"
            print(f"  {m['addr']}: [{recv}] {sel}")
        print("branches:")
        for b in result["branches"]:
            print(f"  {b['at']} {b['kind']} {b['op']} -> {b.get('target')}")

        out = Path(f"analysis/reader-forensics/_tmp_{label}.json")
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
