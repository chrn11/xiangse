#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 B2 验收：最早 seed + ivar 取证 pageContainerA。"""
from __future__ import annotations

import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.ios_mcp_client import McpClient, McpError

MCP = "http://192.168.1.6:8090"
MOCK = "http://192.168.1.4:8765"
BUNDLE = "com.appbox.StandarReader"
OUT = ROOT / "fixtures" / "_accept_hypothesis_b2.json"
IPA = ROOT / "dist-ci-run-29586820783" / "dist" / "StandarReader-legado-debug.ipa"


def clear_all(c: McpClient) -> None:
    paths = c.app_paths()
    doc = paths.get("documents", "")
    for p in c.open_once_candidates(paths):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10})
        except Exception:
            pass
    if doc:
        for n in (
            "legado_openreader_trace.txt",
            "legado_loadcurcp_state.txt",
            "legado_catalog_openreader.txt",
            "legado_debug_dump.txt",
            "legado_native_open_once.txt",
        ):
            try:
                c.call("run_command", {"command": f"rm -f '{doc}/{n}'", "timeout_sec": 10})
            except Exception:
                pass


def main() -> int:
    if not IPA.is_file():
        print(f"IPA missing: {IPA}", file=sys.stderr)
        return 2

    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report: dict = {
        "sha": "ce626c9",
        "ipa": str(IPA),
        "steps": [],
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    up = c.upload_file(IPA, filename=IPA.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    report["install"] = c.call("install_app", {"path": dp}, timeout=600)
    report["steps"].append("install")
    time.sleep(3)

    clear_all(c)
    c.call("wake_and_home")
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(2)
    clear_all(c)
    c.call(
        "open_url",
        {"url": f"legado://import/bookSource?src={MOCK}/legado-local-mock.runtime.json"},
    )
    time.sleep(2)
    c.call(
        "open_url",
        {
            "url": (
                f"legado://nativeRead?bookUrl={MOCK}/book/doupo.html"
                f"&sourceUrl={MOCK}&idx=0"
            )
        },
    )
    report["steps"].append("nativeRead")
    time.sleep(6)

    trace = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=300000)
    state = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=100000)
    blob = (trace or "") + "\n" + (state or "")

    b2 = [ln for ln in blob.splitlines() if "hypothesis_B2" in ln]
    report["b2_lines"] = b2
    report["seed_lines"] = [ln for ln in b2 if "seed" in ln]
    report["probe_lines"] = [ln for ln in b2 if "probe" in ln or "container_first_seen" in ln]
    report["invoke_ok"] = [ln for ln in blob.splitlines() if "invoke_orig_OK" in ln]
    report["onreset_ok"] = [ln for ln in blob.splitlines() if "onReset" in ln and "ORIG_OK" in ln]

    first = next((ln for ln in b2 if "container_first_seen" in ln), "")
    m = re.search(r"class=([^ ]+).*byte@bd8=0x([0-9a-fA-F]+)", first)
    report["pageContainerA_class"] = m.group(1) if m else None
    report["byte_bd8"] = m.group(2) if m else None

    after_orig = [
        ln
        for ln in b2
        if "after_ORIG" in ln or "after_loadView" in ln or "viewDidLoad_after" in ln
    ]
    report["after_orig_probe"] = after_orig[-5:] if after_orig else []

    try:
        cr = c.call("get_crash_logs", timeout=30)
        report["crash"] = str(cr)[:500]
    except Exception as exc:
        report["crash"] = str(exc)

    snaps = []
    for cp in (1.0, 3.0, 5.0):
        time.sleep(1.5)
        try:
            ui = c.call("get_ui_elements", {"limit": 30}, timeout=30)
            texts = [
                e.get("text", "")
                for e in (ui.get("elements") or [])
                if e.get("text")
            ][:10]
        except Exception as exc:
            texts = [str(exc)]
        snaps.append({"t": cp, "texts": texts})
    report["snaps"] = snaps

    on_shelf = any("书架" in t or "空列表" in t for s in snaps for t in s["texts"])
    scroll_ok = any("TextRScrollContainer" in ln for ln in b2)
    page_bad = any("TextRPageContainer" in ln for ln in b2)
    report["springboard_or_shelf"] = on_shelf

    if scroll_ok and not page_bad and not on_shelf:
        report["verdict"] = "PASS_B2"
    elif page_bad:
        report["verdict"] = "FAIL_B2_STILL_PAGE"
    elif on_shelf:
        report["verdict"] = "FAIL_SPRINGBOARD_OR_SHELF"
    else:
        report["verdict"] = "PARTIAL"

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["verdict"] == "PASS_B2" else 1


if __name__ == "__main__":
    raise SystemExit(main())
