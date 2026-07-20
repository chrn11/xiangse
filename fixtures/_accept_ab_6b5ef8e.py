#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 AB（6b5ef8e）真机验收：同步探针最后存活点。"""
from __future__ import annotations

import json
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
SHA = "6b5ef8e"
CI_RUN = "29641500463"
IPA = ROOT / "dist-ci" / SHA / "dist" / "StandarReader-legado-bridge-debug.ipa"
OUT = ROOT / "fixtures" / "_accept_ab_6b5ef8e.json"


def main() -> int:
    if not IPA.is_file():
        raise FileNotFoundError(IPA)
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report: dict = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "sha": SHA,
        "ipa": str(IPA),
        "ci_run": CI_RUN,
    }
    up = c.upload_file(IPA, filename=IPA.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    report["install"] = c.call("install_app", {"path": dp}, timeout=600)
    time.sleep(3)
    report["build_manifest"] = c.read_build_manifest() if hasattr(c, "read_build_manifest") else None

    doc = (c.app_paths() or {}).get("documents", "")
    for n in (
        "legado_openreader_trace.txt",
        "legado_loadcurcp_state.txt",
        "legado_debug_dump.txt",
        "legado_ab_probe.txt",
    ):
        try:
            c.call(
                "run_command",
                {"command": f"rm -f '{doc}/{n}'", "timeout_sec": 8},
                timeout=15,
            )
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
    time.sleep(16)
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=ab_accept"})
        time.sleep(2)
    except McpError as exc:
        report["dump_err"] = str(exc)

    state = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=250000) or ""
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or ""
    ab = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=100000) or ""
    try:
        fm = c.call("get_frontmost_app", timeout=15) or {}
    except Exception as exc:
        fm = {"error": str(exc)}
    try:
        crashes = c.call("get_crash_logs", {"limit": 5}, timeout=40)
    except Exception as exc:
        crashes = {"error": str(exc)}

    ab_lines = [ln for ln in (ab + "\n" + state).splitlines() if "hypothesis_AB" in ln]
    z = [ln for ln in state.splitlines() if "hypothesis_Z" in ln and "fileExists=" in ln]
    inv = [ln for ln in state.splitlines() if "invoke_orig_OK" in ln or "invoke_orig_returned" in ln]
    qf = [ln for ln in dump.splitlines() if "lpNetWorkDelegateQueryFinish" in ln]
    cb_dump = [ln for ln in dump.splitlines() if "callBackResponse:config:userInfo:" in ln]

    report.update(
        {
            "ab_last": ab_lines[-1] if ab_lines else None,
            "ab_all": ab_lines,
            "ab_probe_tail": ab.splitlines()[-20:],
            "z_tail": z[-4:],
            "invoke_ok": bool(inv),
            "invoke_tail": inv[-4:],
            "has_cb_enter": any("cb_enter" in ln for ln in ab_lines),
            "has_cb_exit": any("cb_exit" in ln for ln in ab_lines),
            "has_format_enter": any("format_enter" in ln for ln in ab_lines),
            "has_format_exit": any("format_exit" in ln for ln in ab_lines),
            "has_check": any("check_" in ln for ln in ab_lines),
            "has_fatal": any("fatal_signal" in ln for ln in ab_lines),
            "qf_n": len(qf),
            "cb_dump_n": len(cb_dump),
            "qf_tail": qf[-3:],
            "state_tail": state.splitlines()[-40:],
            "frontmost": fm,
            "crashes": crashes,
            "z_file_ok": any("fileExists=1" in ln for ln in z),
        }
    )

    # 根因裁定
    last = report["ab_last"] or ""
    if report["has_fatal"]:
        root = "fatal_signal（见 ab_probe）"
    elif report["has_format_enter"] and not report["has_format_exit"]:
        root = "死在 formatCallBackResponse 内（后台 format）"
    elif report["has_cb_enter"] and not report["has_cb_exit"]:
        root = "死在 callBackResponse 内（check/format/派 QF 之间）"
    elif report["has_cb_exit"] and report["qf_n"] == 0:
        root = "CB 已返回但未进 QF（target/主队列派发）"
    elif report["invoke_ok"] and not report["has_cb_enter"]:
        root = "invoke 已返回、异步块未到 CB（读文件/组装前）"
    elif not report["invoke_ok"]:
        root = "本轮未到 invoke（流程/装测问题，非杀点窗口）"
    else:
        root = "窗口内未再现杀进程；见 ab_last"

    report["root_cause"] = root
    report["first_chapter_approved"] = bool(
        report["z_file_ok"] and report["qf_n"] > 0 and report.get("has_cb_enter")
    )
    # 粗判萧炎
    texts = []
    if isinstance(fm, dict):
        texts = [str(x) for x in (fm.get("texts") or [])]
    report["xiaoyan"] = any("萧炎" in t for t in texts)
    report["springboard"] = (
        isinstance(fm, dict) and fm.get("bundleId") == "com.apple.springboard"
    )

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(
        json.dumps(
            {
                "out": str(OUT),
                "ab_last": report["ab_last"],
                "root": root,
                "invoke": report["invoke_ok"],
                "cb_enter": report["has_cb_enter"],
                "cb_exit": report["has_cb_exit"],
                "format_enter": report["has_format_enter"],
                "format_exit": report["has_format_exit"],
                "fatal": report["has_fatal"],
                "qf": report["qf_n"],
                "z_file": report["z_file_ok"],
                "xiaoyan": report["xiaoyan"],
                "springboard": report["springboard"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
