#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Forensics 稳定性：阅读页连续 10 次 legado://debugDump?phase=stability。"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.ios_mcp_client import McpClient

BUNDLE = "com.appbox.StandarReader"
MCP = "http://192.168.1.6:8090"
OUT = ROOT / "fixtures" / "_devkit" / "forensics_stability.json"


def tap_by_text(c: McpClient, text: str) -> bool:
    r = c.call("tap_element", {"text": text, "index": 0}, timeout=30)
    if not isinstance(r, dict) or not r.get("tapped"):
        return False
    el = r.get("element") or {}
    rect = el.get("rect") or {}
    x = rect.get("x", 0) + rect.get("width", 0) / 2
    y = rect.get("y", 0) + rect.get("height", 0) / 2
    if x > 1 and y > 1:
        c.call("tap_screen", {"x": int(x), "y": int(y)})
    return True


def tap_book_on_shelf(c: McpClient) -> bool:
    """点书架内置样例书（文本_小说示例）。"""
    markers = ("小说示例", "文本|小说", "使用示例")
    for m in markers:
        if tap_by_text(c, m):
            time.sleep(3)
            return True
    return False


def open_first_chapter(c: McpClient) -> bool:
    for m in ("使用示例", "第一章", "第1章", "新•使用示例"):
        if tap_by_text(c, m):
            time.sleep(4)
            return True
    return False


def main() -> int:
    c = McpClient(MCP, BUNDLE)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(2)
    if not tap_book_on_shelf(c):
        print(json.dumps({"error": "no_book_tapped"}, ensure_ascii=False))
        return 2
    open_first_chapter(c)
    time.sleep(5)

    results: list[dict] = []
    for i in range(10):
        c.call("open_url", {"url": f"legado://debugDump?phase=stability_{i}"})
        time.sleep(2)
        dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=120000)
        manifest = c.read_sandbox_text("reader-build-manifest.json", max_bytes=4096)
        ok = "forensics dump v2" in dump or "object graph" in dump
        has_reader = "TextReadVC3" in dump and ("count=1" in dump or "txtLen=" in dump or "Attr len=" in dump)
        results.append({
            "i": i,
            "ok_schema": ok,
            "has_reader_signal": has_reader,
            "dump_len": len(dump),
            "dump_head": dump[:200],
        })
        time.sleep(0.5)

    crash = c.read_sandbox_text("legado_debug_crash.txt", max_bytes=8000)
    report = {
        "results": results,
        "all_ok": all(r["ok_schema"] for r in results),
        "all_reader": all(r["has_reader_signal"] for r in results),
        "crash_len": len(crash),
        "manifest_head": manifest[:300] if manifest else "",
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["all_ok"] and not crash else 1


if __name__ == "__main__":
    raise SystemExit(main())
