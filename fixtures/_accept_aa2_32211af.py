# -*- coding: utf-8 -*-
"""强制用 32211af IPA 验收 AA2（dontFormat / 禁 bounce）。"""
from __future__ import annotations

import json
import os
import shutil
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient, McpError

MCP = "http://192.168.1.6:8090"
MOCK = "http://192.168.1.4:8765"
BUNDLE = "com.appbox.StandarReader"
SHA = "32211af"
CI_RUN = "29641224325"
IPA = ROOT / "dist-ci" / SHA / "dist" / "StandarReader-legado-bridge-debug.ipa"
OUT = ROOT / "fixtures" / "_accept_route_b.json"


def runtime_line(ln: str) -> bool:
    if " enc=" in ln or " imp=" in ln:
        return False
    return ("before" in ln) or ("after" in ln)


def main() -> int:
    if not IPA.is_file():
        raise FileNotFoundError(IPA)
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report: dict = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "sha": SHA,
        "ipa": str(IPA),
        "ci_run": CI_RUN,
        "role": "aa2-device-accept",
        "steps": [],
    }
    print("upload+install", IPA, flush=True)
    up = c.upload_file(IPA, filename=IPA.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    report["install"] = c.call("install_app", {"path": dp}, timeout=600)
    report["steps"].append("install")
    time.sleep(3)
    manifest = c.read_build_manifest() or {}
    report["build_manifest"] = {
        k: manifest.get(k)
        for k in ("git_commit", "github_run_id", "variant", "built_at_utc")
        if manifest.get(k)
    }
    print("manifest", report["build_manifest"], flush=True)

    doc = (c.app_paths() or {}).get("documents", "")
    for n in (
        "legado_openreader_trace.txt",
        "legado_loadcurcp_state.txt",
        "legado_debug_dump.txt",
        "legado_ab_probe.txt",
    ):
        try:
            c.call("run_command", {"command": f"rm -f '{doc}/{n}'", "timeout_sec": 8}, timeout=15)
        except Exception:
            pass

    c.call("wake_and_home")
    try:
        c.call("kill_app", {"bundle_id": BUNDLE})
    except Exception:
        pass
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(2)
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
    time.sleep(16)
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=aa2_accept"})
        time.sleep(2)
    except McpError as exc:
        report["dump_err"] = str(exc)

    state = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=200000) or ""
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=200000) or ""
    ab = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=50000) or ""
    fm = {}
    try:
        fm = c.call("frontmost_app", {}) or {}
    except Exception as exc:
        report["frontmost_err"] = str(exc)

    qf = [
        ln
        for ln in dump.splitlines()
        if runtime_line(ln) and "lpNetWorkDelegateQueryFinish" in ln
    ]
    cb = [
        ln
        for ln in dump.splitlines()
        if runtime_line(ln) and "callBackResponse:config:userInfo:" in ln
    ]
    aa = [ln for ln in state.splitlines() if "hypothesis_AA" in ln]
    z = [ln for ln in state.splitlines() if "hypothesis_Z" in ln and "fileExists=" in ln]
    inv = [ln for ln in state.splitlines() if "invoke_orig_OK" in ln]
    reg = [ln for ln in state.splitlines() if "register_orig" in ln]
    call_next = [ln for ln in aa if "call_next" in ln]
    bounce = [ln for ln in aa if "bounce" in ln]
    reentry = [ln for ln in aa if "reentry" in ln]

    texts = []
    if isinstance(fm, dict):
        texts = [str(x) for x in (fm.get("texts") or [])]
    springboard = any(
        x in ("日历", "计算器", "时钟", "指南针", "地图", "钱包", "设置", "照片")
        for x in texts
    )
    xiaoyan = any("萧炎" in t for t in texts)

    report.update(
        {
            "qf_n": len(qf),
            "cb_n": len(cb),
            "qf_tail": qf[-3:],
            "cb_tail": cb[-3:],
            "aa_tail": aa[-12:],
            "z_tail": z[-4:],
            "invoke_ok": bool(inv),
            "call_next": bool(call_next),
            "bounce": bool(bounce),
            "reentry": bool(reentry),
            "register_tail": reg[-4:],
            "springboard": springboard,
            "xiaoyan": xiaoyan,
            "frontmost": fm,
            "ab_probe_tail": ab.splitlines()[-8:] if ab else [],
            "state_tail": state.splitlines()[-25:],
        }
    )
    if bounce:
        verdict, reason = "FAIL_BOUNCE", "不应出现 bounce"
    elif not inv:
        verdict, reason = "FAIL_NO_INVOKE", "无 invoke_orig_OK"
    elif call_next and (qf or cb) and not springboard:
        verdict, reason = "PASS_CHAIN", "call_next + QF/CB"
    elif call_next and not springboard:
        verdict, reason = "PARTIAL_AA", "call_next 已出但 QF/CB 未进 dump"
    elif aa and not springboard:
        verdict, reason = "PARTIAL_AA_LOG", "有 AA 日志但无 call_next"
    else:
        verdict, reason = "FAIL", "未打通"
    report["verdict"] = verdict
    report["reason"] = reason
    report["first_chapter_approved"] = bool(xiaoyan and (qf or cb))
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({
        "verdict": verdict,
        "reason": reason,
        "qf": len(qf),
        "cb": len(cb),
        "call_next": bool(call_next),
        "bounce": bool(bounce),
        "xiaoyan": xiaoyan,
        "springboard": springboard,
        "aa_n": len(aa),
    }, ensure_ascii=False), flush=True)
    return 0 if verdict.startswith("PASS") else 1


if __name__ == "__main__":
    raise SystemExit(main())
