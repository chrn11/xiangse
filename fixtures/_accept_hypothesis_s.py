#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 S 验收。"""
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
IPA = (
    ROOT
    / "dist-ci-run-29564617019"
    / "Reader-Forensics-IPAs"
    / "dist"
    / "StandarReader-legado-debug.ipa"
)
OUT = ROOT / "fixtures" / "_accept_hypothesis_s.json"


def main() -> int:
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "sha": "cf54785",
        "ipa": str(IPA),
    }
    up = c.upload_file(IPA, filename=IPA.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    report["install"] = c.call("install_app", {"path": dp}, timeout=600)
    time.sleep(3)
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
        ):
            try:
                c.call("run_command", {"command": f"rm -f '{doc}/{n}'", "timeout_sec": 10})
            except Exception:
                pass
    c.call("wake_and_home")
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(2)
    c.call("open_url", {"url": f"legado://import/bookSource?src={MOCK}/legado-local-mock.runtime.json"})
    time.sleep(2)
    c.call("open_url", {"url": f"legado://nativeRead?bookUrl={MOCK}/book/doupo.html&sourceUrl={MOCK}&idx=0"})
    time.sleep(4)
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=hypothesis_s"})
    except McpError:
        pass
    time.sleep(1)
    trace = c.read_sandbox_text("legado_openreader_trace.txt")
    state = c.read_sandbox_text("legado_loadcurcp_state.txt")
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=196608)
    try:
        xy = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000})
    except McpError as e:
        xy = {"passed": False, "error": str(e)}
    blob = trace + "\n" + state

    def rt(ln: str) -> bool:
        return ("before" in ln or "after" in ln) and " enc=" not in ln

    qf = [ln for ln in dump.splitlines() if rt(ln) and "lpNetWorkDelegateQueryFinish" in ln]
    tip = [ln for ln in dump.splitlines() if rt(ln) and "resetLoadCpTip" in ln]
    dr = [ln for ln in dump.splitlines() if rt(ln) and "divisionResponse:cpTitle:cpIndex:" in ln]
    hits = [
        ln
        for ln in blob.splitlines()
        if any(k in ln for k in ("hypothesis_S", "hypothesis_R gates", "invoke_orig_OK", "pageStatus"))
    ]
    native = bool(qf or dr)
    counts = {}
    for k in ("TextReadTV", "ReadPageModel", "TextReadVC3"):
        m = re.search(rf"{k} count=(\d+)", dump)
        counts[k] = int(m.group(1)) if m else 0
    verdict = "PASS" if native or (xy and xy.get("passed")) else "FAIL_NEED_NEXT"
    report.update(
        {
            "verdict": verdict,
            "xiaoyan": xy,
            "native": native,
            "qf": qf[-3:],
            "dr": dr[-3:],
            "resetLoadCpTip": tip[-8:],
            "hits": hits[-25:],
            "counts": counts,
        }
    )
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("verdict=", verdict)
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
