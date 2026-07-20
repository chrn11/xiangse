#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""6A 链路存活取证：invoke orig 空操作假说判定（单轮）。

背景（baseline-vs-legado-diff §8.1，指令级 confirmed）：
  原版 loadCurCp 首指令 [self curPageVC]，随后 cmp pageStatus,#3；
  curPageVC=nil 或 pageStatus!=3 时控制流在 0x1000d7fd4 直接返回（空操作）。
  真机历史 invoke_orig_OK 后无崩溃/无 QF/无萧炎，invoke_orig_OK 只证明函数指针返回。

本脚本安装同 SHA（47887ff）Debug IPA，走一轮 reset->nativeRead，
解析 ar_origpath_pre/post（原版路径 container->curPageVC->pageModel->pageStatus）
与既有 KVC 读数（ar_pageStatus_pre/post）对照，判定：

  CONFIRMED_NOOP  curPageVC=nil 或 origPath pageStatus!=3
                  -> invoke 空转证实；下一假设唯一方向=补齐 curPageVC/pageStatus 前置
  REFUTED_NOOP    curPageVC 非 nil 且 pageStatus==3
                  -> 空操作假说证伪；问题在 QF/division 下游
  CRASH / INCONCLUSIVE

同时输出 6A 门禁布尔（计划任务卡 6 第一章门禁 6A 节）：
  no_signal / foreground / preferNativeFull_once / openonce_clean /
  invoke_orig_ok / origpath_probe_hit / qf_on_main
注意：6A 完整门禁要求连续 10 轮；本脚本为单轮取证（single_round=True），
假说确认后再跑 10 轮循环。
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
IPA = ROOT / "dist" / "6a_47887ff" / "dist" / "StandarReader-legado-bridge-debug.ipa"
OUT = ROOT / "fixtures" / "_accept_6a_origpath.json"
SHOT = ROOT / "fixtures" / "_accept_6a_origpath.png"
SHA = "47887ff"


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


def evaluate(blob: str, xiaoyan, openonce_left, frontmost_bundle) -> dict:
    crash = ("SIGSEGV" in blob or "SIGABRT" in blob
             or "an_fault_signal" in blob or "al_fatal_signal" in blob)

    pre = re.findall(r"ar_origpath_pre curPageVC=(\S+) pageStatus=(\S+)", blob)
    post = re.findall(r"ar_origpath_post curPageVC=(\S+) pageStatus=(\S+)", blob)
    kvc_pre = re.findall(r"ar_pageStatus_pre container=(\S+) val=(\S+)", blob)
    kvc_post = re.findall(r"ar_pageStatus_post container=(\S+) val=(\S+)", blob)

    invoke_ok = "invoke_orig_OK" in blob or "ORIG loadCurCp OK" in blob
    prefer_full = blob.count("preferNativeFull")
    qf_main = [ln for ln in blob.splitlines() if "qf_enter" in ln and "main=1" in ln]
    xy = bool(xiaoyan and xiaoyan.get("passed"))

    # 空操作假说判定（diff §8.1）
    if crash:
        hv, hreason = "CRASH", "进程崩溃，无法判定空操作假说"
    elif not pre:
        hv, hreason = ("INCONCLUSIVE",
                       "缺 ar_origpath_pre 探针行（invoke 未到达或 47887ff 探针未装入）")
    else:
        last_vc, last_ps = pre[-1]
        vc_nil = last_vc == "nil"
        ps3 = last_ps == "3"
        if vc_nil or not ps3:
            hv = "CONFIRMED_NOOP"
            why = []
            if vc_nil:
                why.append("curPageVC=nil")
            if not ps3:
                why.append(f"origPath pageStatus={last_ps}!=3")
            hreason = ("invoke 落在空操作分支：" + "；".join(why)
                       + "（下一假设唯一方向=补齐 curPageVC/pageStatus 前置，禁叠加其他猜测）")
        else:
            hv = "REFUTED_NOOP"
            hreason = (f"curPageVC={last_vc} 且 pageStatus=3，空操作假说证伪；"
                       "loadCurCp 主体应已执行，问题在 QF/division 下游")

    gate_6a = {
        "no_signal": not crash,
        "foreground": frontmost_bundle == BUNDLE,
        "preferNativeFull_once": prefer_full == 1,
        "openonce_clean": not openonce_left,
        "invoke_orig_ok": invoke_ok,
        "origpath_probe_hit": bool(pre),
        "qf_on_main": bool(qf_main),
    }
    gate_6a_pass = all([
        gate_6a["no_signal"], gate_6a["foreground"],
        gate_6a["preferNativeFull_once"], gate_6a["openonce_clean"],
        gate_6a["invoke_orig_ok"], gate_6a["origpath_probe_hit"],
    ])

    return {
        "hypothesis_verdict": hv, "hypothesis_reason": hreason,
        "gate_6a": gate_6a, "gate_6a_pass": gate_6a_pass,
        "origpath_pre": pre, "origpath_post": post,
        "kvc_pre": kvc_pre, "kvc_post": kvc_post,
        "preferNativeFull_count": prefer_full,
        "qf_main_lines": qf_main[-5:],
        "xiaoyan_passed": xy, "crash": crash,
        "openonce_left": openonce_left,
    }

def main() -> int:
    if not IPA.is_file():
        raise FileNotFoundError(IPA)
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report = {"timestamp": ts(), "ipa": str(IPA), "sha": SHA,
              "single_round": True, "steps": []}

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

    try:
        c.call("run_command", {"command": "defaults write com.appbox.StandarReader LegadoBridgeDiagProbes -bool YES", "timeout_sec": 10})
        report["steps"].append("defaults_write_diag")
    except Exception as e:
        report["diag_err"] = str(e)

    clear_markers(c)
    report["steps"].append("clear_markers")

    c.call("wake_and_home")
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(4)
    report["steps"].append("launch")
    if dismiss_disclaimer(c):
        report["steps"].append("disclaimer_dismissed")
        time.sleep(1)

    tstamp = int(time.time())
    c.call("open_url", {"url": f"legado://import/bookSource?src={SRC}?t={tstamp}"})
    report["steps"].append("import_source")
    time.sleep(8)

    c.call("open_url", {"url": f"legado://nativeRead?bookUrl={BOOK}&sourceUrl={MOCK}&idx=0"})
    report["steps"].append("nativeRead_1")
    time.sleep(10)

    try:
        xy1 = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 3000})
    except McpError:
        xy1 = {"passed": False}
    if not (isinstance(xy1, dict) and xy1.get("passed")):
        paths = c.app_paths()
        for p in c.open_once_candidates(paths):
            try:
                c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10})
            except Exception:
                pass
        c.call("open_url", {"url": f"legado://nativeRead?bookUrl={BOOK}&sourceUrl={MOCK}&idx=0"})
        report["steps"].append("nativeRead_2")
        time.sleep(12)

    try:
        c.call("open_url", {"url": "legado://debugDump?phase=hypothesis_6a"})
        report["steps"].append("debugDump")
    except McpError as e:
        report["dump_err"] = str(e)
    time.sleep(2)

    c.screenshot_to(SHOT)
    report["steps"].append("screenshot")

    trace = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=131072)
    state = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=131072)
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=262144)
    diag = c.read_sandbox_text("legado_reading_diag.txt", max_bytes=131072)
    ab_probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=131072)
    hook_ping = c.read_sandbox_text("forensics_hook_ping.txt", max_bytes=65536)
    ao_lbf = c.read_sandbox_text("legado_ao_lbf.txt", max_bytes=131072)
    blob = "\n".join([trace, state, dump, diag, ab_probe, hook_ping, ao_lbf])

    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000})
    except McpError as e:
        xiaoyan = {"passed": False, "error": str(e)}

    frontmost_bundle = ""
    try:
        fm = c.call("get_frontmost_app", timeout=15)
        frontmost_bundle = fm.get("bundleId") if isinstance(fm, dict) else str(fm)
        report["frontmost"] = frontmost_bundle
        report["pid"] = fm.get("pid") if isinstance(fm, dict) else None
    except Exception:
        pass

    # openOnce 残留检查（6A 门禁：最终不存在）
    openonce_left = []
    try:
        paths = c.app_paths()
        for p in c.open_once_candidates(paths):
            try:
                r = c.call("run_command", {"command": f"test -f '{p}' && echo EXISTS || echo MISSING", "timeout_sec": 10})
                if "EXISTS" in str(r):
                    openonce_left.append(p)
            except Exception:
                pass
    except Exception:
        pass

    report.update(evaluate(blob, xiaoyan, openonce_left, frontmost_bundle))
    report["probe_hits"] = {
        "ar_origpath_pre": [ln for ln in blob.splitlines() if "ar_origpath_pre" in ln][-5:],
        "ar_origpath_post": [ln for ln in blob.splitlines() if "ar_origpath_post" in ln][-5:],
        "ar_pageStatus_pre": [ln for ln in blob.splitlines() if "ar_pageStatus_pre" in ln][-5:],
        "ar_pageStatus_post": [ln for ln in blob.splitlines() if "ar_pageStatus_post" in ln][-5:],
        "invoke_orig": [ln for ln in blob.splitlines() if "invoke_orig" in ln or "ORIG loadCurCp" in ln][-8:],
        "register_orig": [ln for ln in blob.splitlines() if "register_orig" in ln][-5:],
        "qf_enter": [ln for ln in blob.splitlines() if "qf_enter" in ln][-5:],
        "fault_signal": [ln for ln in blob.splitlines() if "an_fault_signal" in ln or "al_fatal_signal" in ln][-5:],
    }

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("hypothesis_verdict=", report["hypothesis_verdict"])
    print("gate_6a_pass=", report["gate_6a_pass"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

