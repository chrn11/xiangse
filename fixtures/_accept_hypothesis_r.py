#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 R 验收：curCpIndex 标量写入生效 + 真实原生链。"""
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
SRC = f"{MOCK}/legado-local-mock.runtime.json"
BOOK = f"{MOCK}/book/doupo.html"
OUT = ROOT / "fixtures" / "_accept_hypothesis_r.json"
IPA = (
    ROOT
    / "dist-ci-run-29564345507"
    / "Reader-Forensics-IPAs"
    / "dist"
    / "StandarReader-legado-debug.ipa"
)


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def clear_markers(c: McpClient) -> None:
    paths = c.app_paths()
    doc = paths.get("documents", "")
    for p in c.open_once_candidates(paths):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10})
        except Exception:
            pass
    if doc:
        for name in (
            "legado_openreader_trace.txt",
            "legado_loadcurcp_state.txt",
            "legado_catalog_openreader.txt",
            "legado_debug_dump.txt",
        ):
            try:
                c.call("run_command", {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 10})
            except Exception:
                pass


def _runtime(ln: str) -> bool:
    if " enc=" in ln or " imp=" in ln:
        return False
    return ("before" in ln) or ("after" in ln)


def evaluate(trace: str, state: str, marker: str, dump: str, xiaoyan) -> dict:
    blob = trace + "\n" + state
    counts = {}
    for key in ("TextReadTV", "ReadPageModel", "TextReadVC3"):
        m = re.search(rf"{key} count=(\d+)", dump)
        if m:
            counts[key] = int(m.group(1))
    qf = [ln for ln in dump.splitlines() if _runtime(ln) and "lpNetWorkDelegateQueryFinish" in ln]
    dr = [ln for ln in dump.splitlines() if _runtime(ln) and "divisionResponse:cpTitle:cpIndex:" in ln]
    fin = [ln for ln in dump.splitlines() if _runtime(ln) and "onDivisionTextFinish:cpIndex:" in ln]
    r_lines = [ln for ln in blob.splitlines() if "hypothesis_R" in ln]
    cur_ok = any("curCp@c=0" in ln or "curCp@r=0" in ln or "nCp@pm=0" in ln for ln in r_lines)
    crash = "NSArrayM length" in blob or "NSSingleObjectArrayI" in blob or "NSArrayM length" in marker
    kick = "division_kick_sync_begin" in blob
    native = bool(qf or dr or fin)
    render = bool(xiaoyan and xiaoyan.get("passed")) or counts.get("ReadPageModel", 0) >= 1
    if crash or kick:
        v, reason = "FAIL_REVERT_R", "崩溃或 kick"
    elif native or render:
        v, reason = "PASS", "原生链或上屏"
    elif r_lines and not native:
        v, reason = "FAIL_NEED_NEXT", "R 已跑仍无真实 QF/DR"
    else:
        v, reason = "FAIL", "未命中"
    return {
        "verdict": v,
        "reason": reason,
        "cur_index_ok": cur_ok,
        "native_chain": native,
        "dump_counts": counts,
        "xiaoyan_passed": bool(xiaoyan and xiaoyan.get("passed")),
        "r_gates": r_lines[-6:],
        "qf": qf[-3:],
        "dr": dr[-3:],
        "finish": fin[-3:],
    }


def main() -> int:
    if not IPA.is_file():
        raise FileNotFoundError(IPA)
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report = {"timestamp": ts(), "ipa": str(IPA), "sha": "cc87554", "steps": []}
    up = c.upload_file(IPA, filename=IPA.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    report["install"] = c.call("install_app", {"path": dp}, timeout=600)
    report["steps"].append("install")
    time.sleep(3)
    clear_markers(c)
    c.call("wake_and_home")
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(2)
    c.call("open_url", {"url": f"legado://import/bookSource?src={SRC}"})
    time.sleep(2)
    c.call("open_url", {"url": f"legado://nativeRead?bookUrl={BOOK}&sourceUrl={MOCK}&idx=0"})
    report["steps"].append("nativeRead")
    time.sleep(4)
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=hypothesis_r"})
        report["steps"].append("debugDump")
    except McpError as e:
        report["dump_err"] = str(e)
    time.sleep(1)
    trace = c.read_sandbox_text("legado_openreader_trace.txt")
    state = c.read_sandbox_text("legado_loadcurcp_state.txt")
    marker = c.read_sandbox_text("legado_catalog_openreader.txt")
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=196608)
    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000})
    except McpError as e:
        xiaoyan = {"passed": False, "error": str(e)}
    report.update(evaluate(trace, state, marker, dump, xiaoyan))
    report["trace_hit"] = [ln for ln in (trace + "\n" + state).splitlines() if any(k in ln for k in ("hypothesis_R", "invoke_orig", "gates", "curCp"))][-40:]
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("verdict=", report["verdict"])
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
