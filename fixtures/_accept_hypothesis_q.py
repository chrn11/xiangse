#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 Q 验收：arrCatalog/curCpIndex 前置 + 真实原生链（非 method-map 行）。"""
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
OUT = ROOT / "fixtures" / "_accept_hypothesis_q.json"
EXPECTED_SHA = "e37d036"
IPA_DEFAULT = (
    ROOT
    / "dist-ci-run-29564102712"
    / "Reader-Forensics-IPAs"
    / "dist"
    / "StandarReader-legado-debug.ipa"
)


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def clear_markers(c: McpClient) -> list[str]:
    paths = c.app_paths()
    doc = paths.get("documents", "")
    deleted = []
    for p in c.open_once_candidates(paths):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10})
            deleted.append(p)
        except Exception:
            pass
    if doc:
        for name in (
            "legado_openreader_trace.txt",
            "legado_loadcurcp_state.txt",
            "legado_catalog_openreader.txt",
            "legado_debug_dump.txt",
            "legado_debug_dump_ready.txt",
        ):
            try:
                c.call("run_command", {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 10})
            except Exception:
                pass
    return deleted


def parse_dump_counts(dump_text: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for key in ("TextReadTV", "ReadPageModel", "TextRPageContainer", "TextReadVC3"):
        m = re.search(rf'"{key}"\s*:\s*\{{[^}}]*"count"\s*:\s*(\d+)', dump_text)
        if m:
            counts[key] = int(m.group(1))
        else:
            m2 = re.search(rf"{key} count=(\d+)", dump_text)
            if m2:
                counts[key] = int(m2.group(1))
    return counts


def _is_runtime_observer_line(ln: str) -> bool:
    if " enc=" in ln or " imp=" in ln:
        return False
    return ("before" in ln) or ("after" in ln) or ("observer" in ln.lower())


def extract_native_forensics(dump_text: str) -> dict:
    native_dr, native_finish, native_qf = [], [], []
    for ln in dump_text.splitlines():
        if not _is_runtime_observer_line(ln):
            continue
        if "divisionResponse:cpTitle:cpIndex:" in ln:
            native_dr.append(ln.strip())
        elif "onDivisionTextFinish:cpIndex:" in ln:
            native_finish.append(ln.strip())
        elif "lpNetWorkDelegateQueryFinish" in ln:
            native_qf.append(ln.strip())
    return {
        "native_divisionResponse": native_dr[-5:],
        "native_onFinish": native_finish[-5:],
        "native_queryFinish": native_qf[-5:],
        "has_native_dr": bool(native_dr),
        "has_native_finish": bool(native_finish),
        "has_native_qf": bool(native_qf),
    }


def extract_traces(blob: str) -> dict:
    keys = (
        "hypothesis_Q",
        "hypothesis_P",
        "hypothesis_O kick_disabled",
        "invoke_orig_OK",
        "seed_arrCatalog",
        "division_kick_sync_begin",
        "NSArrayM length",
        "NSSingleObjectArrayI",
    )
    out: dict[str, list[str]] = {k: [] for k in keys}
    for ln in blob.splitlines():
        for k in keys:
            if k in ln:
                out[k].append(ln.strip())
    return out


def evaluate(trace_text: str, state_text: str, marker_text: str, dump_text: str, xiaoyan: dict | None) -> dict:
    blob = trace_text + "\n" + state_text
    traces = extract_traces(blob)
    forensics = extract_native_forensics(dump_text)
    counts = parse_dump_counts(dump_text)
    pm = counts.get("ReadPageModel", 0)
    tv = counts.get("TextReadTV", 0)
    nsarraym_exc = any(
        k in marker_text or k in blob
        for k in ("NSArrayM length", "NSSingleObjectArrayI")
    )
    has_kick = bool(traces["division_kick_sync_begin"])
    has_q = bool(traces["hypothesis_Q"])
    native_chain = forensics["has_native_dr"] or forensics["has_native_finish"] or forensics["has_native_qf"]
    xiaoyan_ok = bool(xiaoyan and xiaoyan.get("passed"))
    dump_ok = pm >= 1 or (tv >= 1 and ("萧炎" in dump_text or "斗气" in dump_text))
    render_ok = xiaoyan_ok or dump_ok

    if nsarraym_exc or has_kick:
        verdict, reason = "FAIL_REVERT_Q", "崩溃或 kick 回潮"
    elif render_ok or native_chain:
        verdict, reason = "PASS", "无崩溃且原生链/上屏证据"
    elif has_q and not render_ok and not native_chain:
        verdict, reason = "FAIL_NEED_NEXT", "Q 已执行仍无真实 QF/DR/pm"
    else:
        verdict, reason = "FAIL", "未命中验收条件"

    return {
        "verdict": verdict,
        "reason": reason,
        "has_hypothesis_q": has_q,
        "has_kick": has_kick,
        "native_chain": native_chain,
        "forensics": forensics,
        "nsarraym_exc": nsarraym_exc,
        "dump_counts": counts,
        "xiaoyan_passed": xiaoyan_ok,
        "render_ok": render_ok,
        "q_traces": {k: v[-4:] for k, v in traces.items() if v},
    }


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", type=Path, default=IPA_DEFAULT)
    args = parser.parse_args()
    ipa = args.ipa
    if not ipa.is_file():
        raise FileNotFoundError(ipa)

    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report: dict = {
        "timestamp": ts(),
        "ipa": str(ipa),
        "expected_sha": EXPECTED_SHA,
        "ci_run": "29564102712",
        "steps": [],
    }

    up = c.upload_file(ipa, filename=ipa.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    report["install_result"] = c.call("install_app", {"path": dp}, timeout=600)
    report["steps"].append("install")
    time.sleep(3)

    deleted = clear_markers(c)
    report["steps"].append(f"reset_deleted={len(deleted)}")
    c.call("wake_and_home")
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    report["steps"].append("launch")
    time.sleep(2)
    c.call("open_url", {"url": f"legado://import/bookSource?src={SRC}"})
    report["steps"].append("import_source")
    time.sleep(2)

    t0 = time.time()
    c.call("open_url", {"url": f"legado://nativeRead?bookUrl={BOOK}&sourceUrl={MOCK}&idx=0"})
    report["steps"].append("nativeRead")
    time.sleep(3.5)
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=hypothesis_q"})
        report["steps"].append("debugDump")
    except McpError as exc:
        report["debug_dump_error"] = str(exc)
    report["dump_elapsed_sec"] = round(time.time() - t0, 2)
    time.sleep(1)

    trace_text = c.read_sandbox_text("legado_openreader_trace.txt")
    state_text = c.read_sandbox_text("legado_loadcurcp_state.txt")
    marker_text = c.read_sandbox_text("legado_catalog_openreader.txt")
    dump_text = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=196608)
    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000})
    except McpError as exc:
        xiaoyan = {"passed": False, "error": str(exc)}

    report.update(evaluate(trace_text, state_text, marker_text, dump_text, xiaoyan))
    report["trace_section"] = [
        ln
        for ln in (trace_text + "\n" + state_text).splitlines()
        if any(k in ln for k in ("hypothesis_Q", "hypothesis_P", "invoke_orig", "arrCatalog", "gates", "NSArrayM"))
    ][-80:]
    report["dump_tail"] = dump_text[-5000:]
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    slim = {k: report[k] for k in report if k != "dump_tail"}
    print(json.dumps(slim, ensure_ascii=False, indent=2))
    print("verdict=", report["verdict"], "reason=", report["reason"])
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
