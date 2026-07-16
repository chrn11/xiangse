#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 J 验收：onFinish 入参修正 + legado-debug dump。"""
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
OUT = ROOT / "fixtures" / "_accept_hypothesis_j.json"

# 由 integrator 在 CI 完成后填入；占位供本地覆盖
EXPECTED_SHA = ""
EXPECTED_RUN = ""
IPA = ROOT / "dist-ci-j" / "dist" / "StandarReader-legado-bridge-debug.ipa"


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def read_bridge_manifest_plist(c: McpClient) -> dict:
    paths = c.app_paths()
    bundle = paths.get("bundle_path") or paths.get("bundle", "")
    if not bundle:
        return {}
    path = f"{bundle.rstrip('/')}/legado-bridge-manifest.plist"
    text = c.read_file_at(path, max_bytes=4096)
    if not text.strip():
        return {}
    m = re.search(r"<key>BuiltAt</key>\s*<string>([^<]+)</string>", text)
    if m:
        return {"BuiltAt": m.group(1), "raw": text[:200]}
    return {"raw": text[:200]}


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
            "legado_catalog_openreader.txt",
            "legado_debug_dump.txt",
            "legado_debug_dump_ready.txt",
            "reader-build-manifest.json",
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


def extract_on_finish_arg(trace_text: str) -> str:
    for ln in reversed(trace_text.splitlines()):
        if "onFinish_arg=" in ln:
            idx = ln.find("onFinish_arg=")
            return ln[idx + len("onFinish_arg=") :].strip()
    return ""


def extract_kick_traces(trace_text: str) -> dict:
    lines = trace_text.splitlines()
    keys = (
        "division_kick_sync_begin",
        "queryFinish_OK",
        "division_force_continue",
        "divisionText_OK",
        "divisionResponse_OK",
        "onFinish_OK",
        "onFinish_MISS",
        "onFinish_arg",
        "division_kick_sync_end",
    )
    out: dict[str, list[str]] = {k: [] for k in keys}
    for ln in lines:
        for k in keys:
            if k in ln:
                out[k].append(ln.strip())
    return out


def evaluate(trace_text: str, marker_text: str, dump_text: str, xiaoyan: dict | None) -> dict:
    traces = extract_kick_traces(trace_text)
    counts = parse_dump_counts(dump_text)
    pm = counts.get("ReadPageModel", 0)
    tv = counts.get("TextReadTV", 0)
    on_finish_arg = extract_on_finish_arg(trace_text)
    nsarraym_exc = "NSArrayM length" in marker_text or "NSArrayM length" in trace_text
    has_on_finish = bool(traces["onFinish_OK"])
    has_force = bool(traces["division_force_continue"])
    xiaoyan_ok = bool(xiaoyan and xiaoyan.get("passed"))
    dump_ok = pm >= 1 or (tv >= 1 and ("萧炎" in dump_text or "斗气" in dump_text))
    render_ok = xiaoyan_ok or dump_ok

    if nsarraym_exc:
        verdict = "FAIL_REVERT_J"
        reason = "仍有 NSArrayM length 异常"
    elif not on_finish_arg and has_on_finish:
        verdict = "FAIL"
        reason = "onFinish_OK 但缺 onFinish_arg 日志"
    elif render_ok and has_on_finish and on_finish_arg and not on_finish_arg.startswith("REJECT"):
        verdict = "PASS"
        reason = "onFinish_arg 正确且有 pageModel/萧炎"
    elif has_on_finish and on_finish_arg and not render_ok:
        verdict = "PARTIAL_HANDOFF_K"
        reason = "onFinish_arg 已修正仍无对象，交 K"
    elif has_force and not render_ok:
        verdict = "FAIL_REVERT_J"
        reason = "force_continue 后仍无渲染"
    else:
        verdict = "FAIL"
        reason = "未命中 kick 链或无渲染证据"

    return {
        "verdict": verdict,
        "reason": reason,
        "onFinish_arg": on_finish_arg,
        "nsarraym_exc": nsarraym_exc,
        "dump_counts": counts,
        "xiaoyan_passed": xiaoyan_ok,
        "render_ok": render_ok,
        "kick_traces": {k: v[-3:] for k, v in traces.items() if v},
    }


def resolve_ipa() -> Path:
    if IPA.is_file():
        return IPA
    for cand in sorted(ROOT.glob("dist-ci-*/dist/StandarReader-legado-bridge-debug.ipa"), reverse=True):
        return cand
    raise FileNotFoundError("未找到 StandarReader-legado-bridge-debug.ipa")


def main() -> int:
    ipa = resolve_ipa()
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report: dict = {"timestamp": ts(), "ipa": str(ipa), "steps": []}

    up = c.upload_file(ipa, filename=ipa.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    ins = c.call("install_app", {"path": dp}, timeout=600)
    report["install_result"] = ins
    report["steps"].append("install")
    time.sleep(3)
    manifest = read_bridge_manifest_plist(c)
    report["bridge_manifest"] = manifest
    report["built_at"] = manifest.get("BuiltAt", "")

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
    time.sleep(2.5)
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=hypothesis_j"})
        report["steps"].append("debugDump")
    except McpError as exc:
        report["debug_dump_error"] = str(exc)
    report["dump_elapsed_sec"] = round(time.time() - t0, 2)

    time.sleep(1)
    trace_text = c.read_sandbox_text("legado_openreader_trace.txt")
    marker_text = c.read_sandbox_text("legado_catalog_openreader.txt")
    dump_text = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=131072)
    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000})
    except McpError as exc:
        xiaoyan = {"passed": False, "error": str(exc)}

    report.update(evaluate(trace_text, marker_text, dump_text, xiaoyan))
    report["trace_kick_section"] = [
        ln
        for ln in trace_text.splitlines()
        if any(
            k in ln
            for k in (
                "division_kick",
                "division_force_continue",
                "onFinish_arg",
                "onFinish_OK",
                "queryFinish",
            )
        )
    ][-40:]
    report["marker_tail"] = marker_text[-1500:]
    report["dump_tail"] = dump_text[-4000:]

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if report["verdict"] == "PASS":
        return 0
    if report["verdict"] == "PARTIAL_HANDOFF_K":
        return 5
    if report["verdict"] == "FAIL_REVERT_J":
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
