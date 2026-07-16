#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真机 forensics 验收：书架→阅读→objc_invoke dump×10。"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient

BUNDLE = "com.appbox.StandarReader"
OUT = ROOT / "fixtures" / "_devkit" / "forensics_accept.json"


def tap_rect_center(c: McpClient, text: str) -> bool:
    r = c.call("tap_element", {"text": text, "index": 0}, timeout=30)
    if not isinstance(r, dict) or not r.get("tapped"):
        return False
    rect = (r.get("element") or {}).get("rect") or {}
    x = int(rect.get("x", 0) + rect.get("width", 0) / 2)
    y = int(rect.get("y", 0) + rect.get("height", 0) / 2)
    if x > 1 and y > 1:
        c.call("tap_screen", {"x": x, "y": y})
        return True
    return False


def main() -> int:
    c = McpClient("http://192.168.1.6:8090", BUNDLE)
    c.call("wake_and_home")
    time.sleep(1)
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(2)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(5)
    tap_rect_center(c, "小说示例")
    time.sleep(2)
    tap_rect_center(c, "使用示例")
    time.sleep(8)
    stack = c.get_vc_stack()
    results = []
    for i in range(10):
        inv = c.call(
            "objc_invoke",
            {
                "bundle_id": BUNDLE,
                "class": "LBDebugPanel",
                "selector": "lb_debugDumpAction",
                "is_class_method": True,
            },
            timeout=60,
        )
        time.sleep(4)
        dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=400000)
        results.append({
            "i": i,
            "invoke": inv,
            "len": len(dump),
            "v2": "forensics dump v2" in dump,
            "textread": "TextReadVC3" in dump and "count=1" in dump or "count=2" in dump,
            "nonempty": any(k in dump for k in ("Attr len=", "NSString len=", "NSAttributedString len=")),
            "head": dump[:200],
        })
    crash = c.read_sandbox_text("legado_debug_crash.txt", max_bytes=6000)
    manifest = c.read_build_manifest() or {}
    report = {
        "vc_stack": stack,
        "manifest_git": manifest.get("git_commit"),
        "manifest_debug_sha": (manifest.get("legado_debug_sha256") or "")[:8],
        "results": results,
        "all_v2": all(r["v2"] for r in results),
        "all_reader": all(r["textread"] for r in results),
        "all_nonempty": all(r["nonempty"] for r in results),
        "crash_has_new": "SIGSEGV" in crash[-2000:] if crash else False,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    ok = report["all_v2"] and report["all_reader"] and not report["crash_has_new"]
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
