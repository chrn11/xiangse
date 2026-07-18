#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 AB：拉取最新 StandarReader crash ips / syslog。"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient

BUNDLE = "com.appbox.StandarReader"
MCP = "http://192.168.1.6:8090"
OUT_DIR = ROOT / "analysis" / "reader-forensics"
OUT = OUT_DIR / "hypothesis-AB-crash-pull.json"


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    out: dict = {"mcp": MCP, "bundle": BUNDLE}

    crashes = None
    for args in ({"limit": 10}, {"limit": 10, "process": "StandarReader"}):
        try:
            crashes = c.call("get_crash_logs", args, timeout=45)
            out["crash_args"] = args
            break
        except Exception as exc:
            crashes = {"error": str(exc), "args": args}
    out["crashes"] = crashes

    # 若有 ips 列表，读最新几条全文
    crash_bodies = []
    items = []
    if isinstance(crashes, dict):
        items = crashes.get("logs") or crashes.get("files") or crashes.get("items") or []
        if not items and isinstance(crashes.get("content"), list):
            items = crashes["content"]
    elif isinstance(crashes, list):
        items = crashes

    for item in (items or [])[:5]:
        name = None
        path = None
        if isinstance(item, str):
            name = item
            path = item
        elif isinstance(item, dict):
            name = item.get("name") or item.get("filename") or item.get("path")
            path = item.get("path") or name
        if not name:
            continue
        body = None
        for tool, args in (
            ("read_crash_log", {"name": name}),
            ("read_crash_log", {"path": path}),
            ("read_crash_log", {"filename": name}),
            ("read_file", {"path": path}),
        ):
            try:
                body = c.call(tool, args, timeout=40)
                break
            except Exception as exc:
                body = {"error": str(exc), "tool": tool, "args": args}
        crash_bodies.append({"name": name, "path": path, "body": body})
    out["crash_bodies"] = crash_bodies

    slog = None
    for args in (
        {"limit": 120, "process": "StandarReader"},
        {"limit": 80},
    ):
        try:
            slog = c.call("get_syslog", args, timeout=40)
            out["syslog_args"] = args
            break
        except Exception as exc:
            slog = {"error": str(exc), "args": args}
    out["syslog"] = slog
    out["frontmost"] = c.call("get_frontmost_app", timeout=15)
    try:
        out["app_info"] = c.call("get_app_info", {"bundle_id": BUNDLE}, timeout=30)
    except Exception as exc:
        out["app_info"] = {"error": str(exc)}

    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({
        "out": str(OUT),
        "crash_n": len(items) if isinstance(items, list) else None,
        "bodies_n": len(crash_bodies),
        "frontmost": out.get("frontmost"),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
