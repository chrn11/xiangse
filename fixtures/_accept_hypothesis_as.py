#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AS 验收：撤 inThread + AR depth 守卫，QF 回 main 路径。

承接 AR：inThread=YES 时 QF 在 bg 跨线程操作 CFString 致 SEGV@CFStringAppendBytes。
AS 撤 inThread，QF 回 dispatch_async(main)，验证 main 线程下是否消除崩溃 + 萧炎上屏。
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.environ.setdefault("NO_PROXY", "*")
from tools.ios_mcp_client import McpClient, McpError  # noqa: E402

MCP = os.environ.get("XIANGSE_MCP", "http://192.168.1.18:8090")
MOCK = os.environ.get("XIANGSE_MOCK", "http://192.168.1.4:8765")
BUNDLE = "com.appbox.StandarReader"
SRC = f"{MOCK}/legado-local-mock.runtime.json"
BOOK = f"{MOCK}/book/doupo.html"
IPA = ROOT / "dist" / "as_1a5d1fd" / "dist" / "StandarReader-legado-bridge-debug.ipa"
OUT = ROOT / "fixtures" / "_accept_hypothesis_as.json"
SHOT = ROOT / "fixtures" / "_accept_hypothesis_as.png"


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
            "legado_openreader_trace.txt", "legado_loadcurcp_state.txt",
            "legado_catalog_openreader.txt", "legado_debug_dump.txt",
            "legado_reading_diag.txt", "legado_ab_probe.txt",
            "forensics_hook_ping.txt", "legado_ao_lbf.txt",
            "legado_debug_crash.txt", "legado_catalog_hook.txt",
        ):
            try:
                c.call("run_command", {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 10})
            except Exception:
                pass


def dismiss_disclaimer(c: McpClient) -> bool:
    for _ in range(4):
        try:
            ui = c.call("get_ui_elements", {"limit": 60}, timeout=30)
            els = ui.get("elements", []) if isinstance(ui, dict) else []
            for e in els:
                if not isinstance(e, dict):
                    continue
                txt = str(e.get("text", ""))
                if "知晓并同意" in txt or txt.strip() == "同意":
                    rect = e.get("rect", {})
                    if rect:
                        x = rect.get("x", 195) + rect.get("width", 135) / 2
                        y = rect.get("y", 743) + rect.get("height", 44) / 2
                        c.call("tap_screen", {"x": x, "y": y})
                        time.sleep(1.5)
                        return True
        except Exception:
            pass
        time.sleep(1)
    return False


def _runtime(ln: str) -> bool:
    if " enc=" in ln or " imp=" in ln:
        return False
    return ("before" in ln) or ("after" in ln)


def evaluate(trace: str, state: str, dump: str, diag: str, ab_probe: str,
             hook_ping: str, ao_lbf: str, xiaoyan) -> dict:
    blob = trace + "\n" + state + "\n" + diag + "\n" + ab_probe + "\n" + ao_lbf

    # 1. orig IMP 修正：invoke_orig_OK 且进程没崩（AQ 时 SIGSEGV）
    invoke_ok = "invoke_orig_OK" in blob or "ORIG loadCurCp OK" in blob
    orig_fixed = invoke_ok

    # 2. LBFHook 风暴消除：无 ao_lbf_hook depth>8 风暴
    max_depth = -1
    m_stats = re.search(r"ao_lbf_stats[^=]*hit=(\d+) maxDepth=(\d+) reenter=(\d+) quietSkip=(\d+)", blob)
    if m_stats:
        max_depth = int(m_stats.group(2))
    for m in re.finditer(r"depth=(\d+)", blob):
        d = int(m.group(1))
        if d > max_depth:
            max_depth = d
    no_storm_marker = max_depth < 0 or max_depth <= 8

    # 3. main 存活：invoke_orig_done_pending_render 出现
    main_drain = -1
    m_drain = re.search(r"ai_main_watch[^=]*drain=(\d+)", blob)
    if m_drain:
        main_drain = int(m_drain.group(1))
    main_drained = "invoke_orig_done_pending_render" in blob or main_drain == 1

    # 4. AS 核心：撤 inThread 验证 -- as_inThread_removed=1 且 as_qf_path_no_inject
    as_inthread_removed = "as_inThread_removed=1" in blob
    as_no_inject = "as_qf_path_no_inject" in blob
    # QF 在 main：qf_enter main=1（撤 inThread 后 QF 应在 main）
    qf_main_lines = [ln for ln in blob.splitlines()
                     if "qf_enter" in ln and "main=1" in ln]
    qf_on_main = bool(qf_main_lines)
    # CB 在 main：撤 inThread 后 callBackResponse 也应在 main
    cb_main_lines = [ln for ln in blob.splitlines()
                     if "cb_enter" in ln and "main=1" in ln]
    cb_on_main = bool(cb_main_lines)

    # 5. CFString 崩溃消除：无 SEGV_ACCERR + 无 __CFStringAppendBytes 崩溃
    cfstring_crash = ("__CFStringAppendBytes" in blob and "an_fault_signal" in blob)
    crash = "SIGSEGV" in blob or "SIGABRT" in blob or "NSArrayM length" in blob

    # 6. 萧炎
    xy = bool(xiaoyan and xiaoyan.get("passed"))

    lbf_storm_gone = no_storm_marker and not crash

    if crash:
        if cfstring_crash:
            v, reason = "FAIL_REVERT_AS", "CFString 跨线程崩溃未消除（inThread 撤后仍崩）"
        else:
            v, reason = "FAIL_REVERT_AS", f"崩溃(maxDepth={max_depth})"
    elif orig_fixed and lbf_storm_gone and main_drained and xy:
        v, reason = "PASS", "orig invoke + 无崩溃 + main 存活 + 萧炎上屏"
        if as_inthread_removed:
            reason += " + inThread 已撤"
        if qf_on_main:
            reason += " + QF 在 main"
    else:
        gaps = []
        if not orig_fixed:
            gaps.append("orig invoke 未成功")
        if not lbf_storm_gone:
            gaps.append(f"LBFHook 风暴未消除(maxDepth={max_depth})")
        if not main_drained:
            gaps.append("main 未存活")
        if not as_inthread_removed:
            gaps.append("inThread 未撤（探针缺失）")
        if not xy:
            gaps.append("萧炎未上屏")
        v = "FAIL_NEED_NEXT" if (orig_fixed or lbf_storm_gone or as_inthread_removed) else "FAIL"
        reason = ";".join(gaps)

    return {
        "verdict": v, "reason": reason,
        "orig_fixed": orig_fixed, "invoke_ok": invoke_ok,
        "lbf_storm_gone": lbf_storm_gone, "lbf_max_depth": max_depth,
        "main_drained": main_drained, "main_drain": main_drain,
        "as_inthread_removed": as_inthread_removed, "as_no_inject": as_no_inject,
        "qf_on_main": qf_on_main, "cb_on_main": cb_on_main,
        "cfstring_crash": cfstring_crash,
        "xiaoyan_passed": xy, "crash": crash,
        "qf_main_lines": qf_main_lines[-5:],
        "cb_main_lines": cb_main_lines[-5:],
    }


def main() -> int:
    if not IPA.is_file():
        raise FileNotFoundError(IPA)
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report = {"timestamp": ts(), "ipa": str(IPA), "sha": "1a5d1fd", "steps": []}

    # 卸装 + 安装
    try:
        report["uninstall"] = c.call("uninstall_app", {"bundle_id": BUNDLE}, timeout=120)
        report["steps"].append("uninstall")
    except McpError as e:
        report["uninstall_err"] = str(e)
    time.sleep(2)
    up = c.upload_file(IPA, filename=IPA.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    report["install"] = c.call("install_app", {"path": dp}, timeout=600)
    report["steps"].append("install")
    time.sleep(3)

    # diag probes
    try:
        c.call("run_command", {"command": "defaults write com.appbox.StandarReader LegadoBridgeDiagProbes -bool YES", "timeout_sec": 10})
        report["steps"].append("defaults_write_diag")
    except Exception as e:
        report["diag_err"] = str(e)

    clear_markers(c)
    report["steps"].append("clear_markers")

    # launch + 关免责声明
    c.call("wake_and_home")
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(4)
    report["steps"].append("launch")
    if dismiss_disclaimer(c):
        report["steps"].append("disclaimer_dismissed")
        time.sleep(1)

    # 导入书源（带时间戳防缓存）+ 长等待
    tstamp = int(time.time())
    c.call("open_url", {"url": f"legado://import/bookSource?src={SRC}?t={tstamp}"})
    report["steps"].append("import_source")
    time.sleep(8)

    # 第一次 nativeRead
    c.call("open_url", {"url": f"legado://nativeRead?bookUrl={BOOK}&sourceUrl={MOCK}&idx=0"})
    report["steps"].append("nativeRead_1")
    time.sleep(10)

    # 检查是否渲染，未渲染则第二次 nativeRead
    try:
        xy1 = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 3000})
    except McpError:
        xy1 = {"passed": False}
    if not (isinstance(xy1, dict) and xy1.get("passed")):
        # 清 openOnce 再试
        paths = c.app_paths()
        for p in c.open_once_candidates(paths):
            try:
                c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10})
            except Exception:
                pass
        c.call("open_url", {"url": f"legado://nativeRead?bookUrl={BOOK}&sourceUrl={MOCK}&idx=0"})
        report["steps"].append("nativeRead_2")
        time.sleep(12)

    # debugDump
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=hypothesis_ar"})
        report["steps"].append("debugDump")
    except McpError as e:
        report["dump_err"] = str(e)
    time.sleep(2)

    c.screenshot_to(SHOT)
    report["steps"].append("screenshot")

    # 读探针
    trace = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=131072)
    state = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=131072)
    marker = c.read_sandbox_text("legado_catalog_openreader.txt", max_bytes=65536)
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=262144)
    diag = c.read_sandbox_text("legado_reading_diag.txt", max_bytes=131072)
    ab_probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=131072)
    hook_ping = c.read_sandbox_text("forensics_hook_ping.txt", max_bytes=65536)
    ao_lbf = c.read_sandbox_text("legado_ao_lbf.txt", max_bytes=131072)

    # 萧炎
    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000})
    except McpError as e:
        xiaoyan = {"passed": False, "error": str(e)}

    # 前台
    try:
        fm = c.call("get_frontmost_app", timeout=15)
        report["frontmost"] = fm.get("bundleId") if isinstance(fm, dict) else str(fm)
        report["pid"] = fm.get("pid") if isinstance(fm, dict) else None
    except Exception:
        pass

    report["marker"] = marker[:2000] if marker else ""
    report.update(evaluate(trace, state, dump, diag, ab_probe, hook_ping, ao_lbf, xiaoyan))

    blob = "\n".join([trace, state, diag, ab_probe, ao_lbf])
    report["probe_hits"] = {
        "invoke_orig": [ln for ln in blob.splitlines() if "invoke_orig" in ln or "ORIG loadCurCp" in ln][-8:],
        "as_qf_path_no_inject": [ln for ln in blob.splitlines() if "as_qf_path_no_inject" in ln][-5:],
        "as_inthread_removed": [ln for ln in blob.splitlines() if "as_inThread_removed" in ln][-3:],
        "ar_loadCurCp_resolve": [ln for ln in blob.splitlines() if "ar_loadCurCp_resolve" in ln][-5:],
        "ar_orig_imp_class": [ln for ln in blob.splitlines() if "ar_orig_imp_class" in ln][-5:],
        "ar_pageStatus_pre": [ln for ln in blob.splitlines() if "ar_pageStatus_pre" in ln][-5:],
        "ao_lbf_hook": [ln for ln in blob.splitlines() if "ao_lbf_hook" in ln][-5:],
        "ao_lbf_stats": [ln for ln in blob.splitlines() if "ao_lbf_stats" in ln][-5:],
        "qf_enter": [ln for ln in blob.splitlines() if "qf_enter" in ln][-5:],
        "cb_enter": [ln for ln in blob.splitlines() if "cb_enter" in ln][-5:],
        "cf_crash": [ln for ln in blob.splitlines() if "__CFStringAppendBytes" in ln or "CFStringAppend" in ln][-5:],
        "fault_signal": [ln for ln in blob.splitlines() if "an_fault_signal" in ln or "al_fatal_signal" in ln][-5:],
        "hypothesis_V": [ln for ln in blob.splitlines() if "hypothesis_V" in ln][-3:],
        "hypothesis_Z": [ln for ln in blob.splitlines() if "hypothesis_Z" in ln][-3:],
        "register_orig": [ln for ln in blob.splitlines() if "register_orig" in ln][-5:],
        "awaitingCatalog": [ln for ln in blob.splitlines() if "awaitingCatalog" in ln][-5:],
    }

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("verdict=", report["verdict"])
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
