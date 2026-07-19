#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AL 验收：corpse/致命栈 + QF 窗 al_qf_uikit_* + ICU 标签；KEEP AK/inThread；前台硬断言萧炎。"""
from __future__ import annotations

import json
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient

MCP = "http://192.168.1.6:8090"
MOCK = "http://192.168.1.4:8765"
BUNDLE = "com.appbox.StandarReader"
OUT = ROOT / "fixtures" / "_accept_al_probe.json"
SYNC = ROOT / "fixtures" / "_accept_al_probe_sync.json"
KILL = ROOT / "fixtures" / "_accept_al_kill_syslog.json"

FORBIDDEN_FRONT = (
    "com.apple.MobileSMS",
    "com.apple.springboard",
    "com.apple.Preferences",
)


def git_sha() -> str:
    r = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return (r.stdout or "").strip() or "unknown"


def frontmost(c: McpClient) -> dict:
    try:
        fm = c.call("get_frontmost_app", timeout=15) or {}
        return fm if isinstance(fm, dict) else {"raw": fm}
    except Exception as exc:
        return {"error": str(exc)}


def is_reader_front(fm: dict) -> bool:
    return str(fm.get("bundleId") or "") == BUNDLE


def reader_pid(c: McpClient) -> int | None:
    try:
        apps = c.call("list_running_apps", timeout=20) or {}
        items = apps.get("apps") if isinstance(apps, dict) else apps
        if isinstance(items, list):
            for a in items:
                if not isinstance(a, dict):
                    continue
                bid = str(a.get("bundleId") or a.get("bundle_id") or "")
                if bid == BUNDLE:
                    pid = a.get("pid") or a.get("processIdentifier")
                    if pid is not None:
                        return int(pid)
    except Exception:
        pass
    fm = frontmost(c)
    if is_reader_front(fm) and fm.get("pid") is not None:
        try:
            return int(fm["pid"])
        except Exception:
            return None
    return None


def dismiss_reader_only(c: McpClient, report: dict) -> None:
    fm = frontmost(c)
    report.setdefault("frontmost_log", []).append({"reason": "dismiss_check", "front": fm})
    if not is_reader_front(fm):
        return
    for _ in range(4):
        try:
            els = c.call("get_ui_elements", timeout=20) or {}
            blob = json.dumps(els, ensure_ascii=False)
            if any(k in blob for k in ("中国移动", "垃圾信息", "拟我表情", "听写")):
                report.setdefault("frontmost_log", []).append(
                    {"reason": "dismiss_skip_sms_ui", "hint": True}
                )
                return
            hit = False
            for text in ("好", "确定", "关闭", "取消"):
                if text in blob:
                    try:
                        c.call("tap_element", {"text": text}, timeout=12)
                        hit = True
                        time.sleep(0.5)
                    except Exception:
                        pass
            if not hit:
                break
        except Exception:
            break


def clear_all(c: McpClient) -> str:
    paths = c.app_paths() or {}
    doc = paths.get("documents", "")
    cache = paths.get("caches", "") or paths.get("library_caches", "")
    for p in c.open_once_candidates(paths):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 8}, timeout=15)
        except Exception:
            pass
    bases = [b for b in (doc, cache) if b]
    names = (
        "legado_ab_probe.txt",
        "legado_ai_probe.txt",
        "legado_loadcurcp_state.txt",
        "legado_debug_dump.txt",
        "legado_openreader_trace.txt",
    )
    for base in bases:
        for name in names:
            try:
                c.call(
                    "run_command",
                    {"command": f"rm -f '{base}/{name}'", "timeout_sec": 8},
                    timeout=15,
                )
            except Exception:
                pass
    try:
        c.call("run_command", {"command": "rm -f /tmp/legado_al_fatal.txt", "timeout_sec": 8}, timeout=15)
    except Exception:
        pass
    return doc


def decide(
    tags: list[str],
    *,
    has_qf: bool,
    has_fatal: bool,
    reader_ok: bool,
    pid_stable: bool,
    has_ak_skip: bool,
    qf_main: bool,
    scene_syslog_n: int,
    bg_uikit_n: int,
    al_fatal_n: int,
    al_uikit_n: int,
    al_icu_n: int,
    al_thr_n: int,
    xiaoyan_ok: bool,
) -> dict:
    if (
        reader_ok
        and xiaoyan_ok
        and has_qf
        and qf_main
        and pid_stable
        and scene_syslog_n == 0
        and not has_fatal
        and al_fatal_n == 0
    ):
        return {
            "branch": "first_chapter",
            "action": "主线程 QF + 萧炎 + 无 SIGSEGV；AL 成功",
            "commit": True,
        }
    if al_fatal_n > 0:
        return {
            "branch": "al_fatal_stack",
            "action": "采到 al_fatal_signal；按 PC/LR 决定是否最小修",
            "commit": False,
        }
    if al_uikit_n > 0:
        return {
            "branch": "al_qf_uikit",
            "action": "QF/死后窗有 bg UIKit；对照栈决定是否最小修",
            "commit": False,
        }
    if al_icu_n > 0 and al_thr_n > 0:
        return {
            "branch": "al_icu_and_threads",
            "action": "ICU 忙等 + 多线程 PC 已采；无致命栈则只交取证",
            "commit": False,
        }
    if has_ak_skip and scene_syslog_n == 0 and bg_uikit_n == 0 and not pid_stable:
        return {
            "branch": "ak_keep_still_segv",
            "action": "AK KEEP 仍成立但 pid/SIGSEGV 未消；缺致命栈则加深取证",
            "commit": False,
        }
    if not pid_stable:
        return {
            "branch": "pid_changed",
            "action": "pid 不稳；对照 syslog SIGSEGV / al_fatal",
            "commit": False,
        }
    return {
        "branch": "al_incomplete",
        "action": "AL 证据不足",
        "commit": False,
    }


def pull_crash_stack(c: McpClient, report: dict) -> list[dict]:
    out: list[dict] = []
    try:
        logs = c.call("get_crash_logs", {"bundle_id": BUNDLE, "limit": 8}, timeout=30) or {}
        report["crash_logs"] = {
            "count": logs.get("count") if isinstance(logs, dict) else None,
            "reports": (logs.get("reports") or [])[:8] if isinstance(logs, dict) else [],
        }
        for r in (logs.get("reports") or [])[:3] if isinstance(logs, dict) else []:
            path = r.get("path") if isinstance(r, dict) else None
            if not path:
                continue
            try:
                body = c.call("read_crash_log", {"path": path, "format": "text"}, timeout=60)
                text = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
                out.append({"path": path, "head": text[:4000]})
            except Exception as exc:
                out.append({"path": path, "error": str(exc)})
            try:
                sym = c.call("symbolicate", {"path": path}, timeout=90)
                out.append(
                    {
                        "path": path,
                        "symbolicate_head": json.dumps(sym, ensure_ascii=False)[:4000]
                        if not isinstance(sym, str)
                        else sym[:4000],
                    }
                )
            except Exception as exc:
                out.append({"path": path, "symbolicate_err": str(exc)})
    except Exception as exc:
        report["crash_logs_err"] = str(exc)
    return out


def main() -> int:
    sha = git_sha()
    ipa = ROOT / "dist-ci" / sha / "dist" / "StandarReader-legado-bridge-debug.ipa"
    if not ipa.is_file():
        cands = sorted(
            (ROOT / "dist-ci").glob("*/dist/StandarReader-legado-bridge-debug.ipa"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if not cands:
            raise FileNotFoundError(f"no IPA for {sha}")
        ipa = cands[0]
        print(f"WARN: using IPA {ipa} (HEAD={sha})")

    report: dict = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "sha": sha,
        "ipa": str(ipa),
        "hypothesis": "AL",
        "role": "AL-corpse-qf-uikit-icu-forensics",
        "model": "cursor-grok-4.5",
        "mock": MOCK,
        "mcp": MCP,
        "banned": [
            "bounce",
            "dontFormat",
            "mid_chain_launch_app",
            "dispatch_sync_main_QF",
            "empty_WakeUp",
        ],
        "keep": [
            "inject_inThread",
            "V+W+X+Y+Z",
            "BQM check/format id return",
            "ak_bg_windows_api_skip",
        ],
        "steps": [],
        "frontmost_log": [],
        "pid_log": [],
        "launch_app_calls": [],
    }

    req = urllib.request.Request(f"{MOCK}/chapter/doupo_1.html", method="GET")
    with urllib.request.urlopen(req, timeout=5) as resp:
        report["chapter_probe"] = {"ok": resp.status == 200, "code": resp.status}

    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    up = c.upload_file(ipa, filename=ipa.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    report["upload"] = {k: up.get(k) for k in ("path", "filename", "size") if isinstance(up, dict)}
    report["install"] = c.call("install_app", {"path": dp}, timeout=600)
    report["steps"].append("install")
    time.sleep(3)

    manifest = c.read_build_manifest() or {}
    report["build_manifest"] = {
        k: manifest.get(k)
        for k in ("git_commit", "git_sha", "variant", "github_run_id", "built_at_utc")
        if manifest.get(k)
    }

    c.call("wake_and_home", timeout=30)
    try:
        c.call("kill_app", {"bundle_id": BUNDLE}, timeout=30)
        report["launch_app_calls"].append({"phase": "setup_kill", "ok": True})
    except Exception as exc:
        report["launch_app_calls"].append({"phase": "setup_kill", "error": str(exc)})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE}, timeout=30)
    report["launch_app_calls"].append({"phase": "setup_launch", "ok": True})
    time.sleep(2)
    dismiss_reader_only(c, report)
    for _ in range(40):
        early = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=200000) or ""
        if "install_done" in early and "install_qf" in early:
            break
        time.sleep(0.25)
    doc = clear_all(c)
    report["doc"] = doc
    report["steps"].append("reset")

    c.call(
        "open_url",
        {"url": f"legado://import/bookSource?src={MOCK}/legado-local-mock.runtime.json"},
        timeout=30,
    )
    time.sleep(2.5)
    dismiss_reader_only(c, report)
    time.sleep(1)
    clear_all(c)
    dismiss_reader_only(c, report)

    fm_pre = frontmost(c)
    report["frontmost_log"].append({"reason": "pre_nativeRead_observe", "front": fm_pre})
    if not is_reader_front(fm_pre):
        c.call("launch_app", {"bundle_id": BUNDLE}, timeout=30)
        report["launch_app_calls"].append({"phase": "pre_nativeRead_recover", "ok": True})
        time.sleep(1.5)
        dismiss_reader_only(c, report)

    pid0 = reader_pid(c)
    report["pid_log"].append({"t": 0.0, "phase": "pre_nativeRead", "pid": pid0})

    try:
        report["capture_start"] = c.call(
            "start_capture", {"bundle_ids": [BUNDLE]}, timeout=20
        )
    except Exception as exc:
        report["capture_start_err"] = str(exc)

    t0 = time.time()
    c.call(
        "open_url",
        {
            "url": (
                f"legado://nativeRead?bookUrl={MOCK}/book/doupo.html"
                f"&sourceUrl={MOCK}&idx=0"
            )
        },
        timeout=30,
    )
    report["steps"].append("nativeRead")
    report["mid_chain_launch_app"] = False

    polls = []
    for i in range(50):
        time.sleep(0.4)
        fm = frontmost(c)
        pid = reader_pid(c)
        if i in (0, 2, 5, 10, 20, 35):
            dismiss_reader_only(c, report)
            report["pid_log"].append(
                {
                    "t": round(time.time() - t0, 2),
                    "phase": f"poll_{i}",
                    "pid": pid,
                    "front": fm.get("bundleId"),
                }
            )
        probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=300000) or ""
        st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=300000) or ""
        blob = probe + "\n" + st
        ac = [
            ln
            for ln in blob.splitlines()
            if "hypothesis_AC" in ln
            or "hypothesis_AK" in ln
            or "al_" in ln
            or "ak_main_block" in ln
        ]
        rt = [ln for ln in ac if "install_" not in ln]
        polls.append(
            {
                "t": round(time.time() - t0, 2),
                "ac_runtime_n": len(rt),
                "ac_last": rt[-1] if rt else (ac[-1] if ac else None),
                "front": fm.get("bundleId"),
                "pid": pid,
            }
        )
        if rt and any(
            k in (rt[-1] or "")
            for k in (
                "qf_exit",
                "ag_post_qf",
                "al_fatal_signal",
                "al_post_cb_sample_end",
                "ak_main_idle_forensics_end",
                "cb_exit",
                "fatal_signal",
                "ag_atexit",
            )
        ):
            time.sleep(2.5)
            break

    pid1 = reader_pid(c)
    report["pid_log"].append(
        {"t": round(time.time() - t0, 2), "phase": "post_poll", "pid": pid1}
    )

    capture_stop = None
    try:
        capture_stop = c.call("stop_capture", timeout=60)
        if isinstance(capture_stop, dict):
            entries = capture_stop.get("syslog_entries") or []
            keys = (
                "jetsam",
                "memorystatus",
                "SIGSEGV",
                "SIGKILL",
                "Watchdog",
                "scene-update",
                "UIWindowScene",
                "non-main thread",
                "Corpse",
                "termination",
                "exited",
                "ReportCrash",
                "Exception Type",
                "faulting",
            )
            hits = []
            for e in entries:
                if not isinstance(e, dict):
                    continue
                blob = f"{e.get('message', '')} {e.get('process', '')}"
                if any(k.lower() in blob.lower() for k in keys):
                    hits.append(
                        {
                            "date": e.get("date"),
                            "process": e.get("process"),
                            "level": e.get("level"),
                            "message": str(e.get("message") or "")[:400],
                        }
                    )
                    if len(hits) >= 100:
                        break
            report["capture_stop"] = {
                "capture_seconds": capture_stop.get("capture_seconds"),
                "new_crash_count": capture_stop.get("new_crash_count"),
                "new_crash_reports": capture_stop.get("new_crash_reports"),
                "syslog_count": capture_stop.get("syslog_count"),
                "syslog_kill_hits": hits,
            }
        else:
            report["capture_stop"] = capture_stop
    except Exception as exc:
        report["capture_stop_err"] = str(exc)

    report["crash_stack"] = pull_crash_stack(c, report)

    # 死后 relaunch 前尽量捞 /tmp fatal
    tmp_fatal = ""
    try:
        tmp_fatal = c.call(
            "run_command",
            {"command": "cat /tmp/legado_al_fatal.txt 2>/dev/null | tail -n 20", "timeout_sec": 8},
            timeout=15,
        )
        report["tmp_fatal"] = tmp_fatal
    except Exception as exc:
        report["tmp_fatal_err"] = str(exc)

    fm_final = frontmost(c)
    reader_ok = is_reader_front(fm_final)
    relaunch_after = False
    if not reader_ok:
        try:
            c.call("launch_app", {"bundle_id": BUNDLE}, timeout=30)
            report["launch_app_calls"].append({"phase": "post_chain_recover", "ok": True})
            relaunch_after = True
            time.sleep(1.5)
            fm_final = frontmost(c)
            reader_ok = is_reader_front(fm_final)
        except Exception as exc:
            report["launch_app_calls"].append(
                {"phase": "post_chain_recover", "error": str(exc)}
            )

    bid_final = str(fm_final.get("bundleId") or "")
    if any(x in bid_final for x in FORBIDDEN_FRONT) or (bid_final and bid_final != BUNDLE):
        reader_ok = False

    probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=300000) or ""
    st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=300000) or ""
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or ""
    try:
        if reader_ok:
            c.call("open_url", {"url": "legado://debugDump?phase=al_accept"}, timeout=20)
            time.sleep(1.5)
            dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or dump
    except Exception as exc:
        report["dump_err"] = str(exc)

    probe_lines = [ln for ln in probe.splitlines() if ln.strip()]
    blob_all = probe + "\n" + st
    try:
        ai_probe = c.read_sandbox_text("legado_ai_probe.txt", max_bytes=300000) or ""
    except Exception:
        ai_probe = ""
    tmp_text = ""
    if isinstance(tmp_fatal, dict):
        tmp_text = str(tmp_fatal.get("stdout") or tmp_fatal.get("output") or tmp_fatal)
    elif isinstance(tmp_fatal, str):
        tmp_text = tmp_fatal

    ac_all = [
        ln
        for ln in (blob_all + "\n" + ai_probe + "\n" + tmp_text).splitlines()
        if "hypothesis_AC" in ln
        or "hypothesis_AK" in ln
        or "ak_main_block" in ln
        or "ak_main_idle" in ln
        or "ak_bg_windows" in ln
        or "ak_keep_inThread" in ln
        or "al_" in ln
        or "ai_main_" in ln
        or "ai_bg_uikit" in ln
    ]
    ac_runtime = [ln for ln in ac_all if "install_" not in ln]
    has_qf = (
        "lpNetWorkDelegateQueryFinish" in (probe + st + dump)
        or any("qf_enter" in ln for ln in ac_all)
    )
    has_fatal = any("fatal_signal" in ln or "al_fatal_signal" in ln for ln in ac_all)
    qf_n = sum(
        1
        for ln in (probe + st + dump).splitlines()
        if "lpNetWorkDelegateQueryFinish" in ln or "qf_enter" in ln
    )
    qf_main = any("qf_enter" in ln and "main=1" in ln for ln in ac_all)
    pids = sorted(
        {
            ln.split("pid=")[-1].split()[0]
            for ln in ac_all
            if "pid=" in ln
        }
    )[:12]
    probe_pid_stable = len(pids) <= 1
    os_pid_stable = (
        pid0 is not None and pid1 is not None and int(pid0) == int(pid1) and not relaunch_after
    )
    pid_stable = probe_pid_stable and os_pid_stable

    xiaoyan: dict | str
    if not reader_ok:
        xiaoyan = {
            "passed": False,
            "error": f"foreground_not_reader bid={bid_final}",
            "skipped": True,
        }
    else:
        try:
            xiaoyan = c.call(
                "assert_text_present", {"text": "萧炎", "timeout_ms": 8000}, timeout=20
            )
        except Exception as exc:
            xiaoyan = {"passed": False, "error": str(exc)}
        if isinstance(xiaoyan, dict):
            ev = xiaoyan.get("evidence") if isinstance(xiaoyan.get("evidence"), dict) else {}
            xiaoyan = {
                "passed": xiaoyan.get("passed"),
                "text": xiaoyan.get("text"),
                "elements": (ev or {}).get("elements"),
                "error": xiaoyan.get("error"),
            }

    try:
        ui = c.call("get_ui_elements", timeout=20) or {}
        ui_texts = []
        for el in (ui.get("elements") or []) if isinstance(ui, dict) else []:
            t = el.get("text") if isinstance(el, dict) else None
            if t:
                ui_texts.append(t)
    except Exception:
        ui_texts = []

    syslog_hits = []
    if isinstance(report.get("capture_stop"), dict):
        syslog_hits = report["capture_stop"].get("syslog_kill_hits") or []
    scene_syslog = [
        h
        for h in syslog_hits
        if "UIWindowScene" in str(h.get("message") or "")
        or "non-main thread" in str(h.get("message") or "").lower()
    ]
    sigsegv = [
        h
        for h in syslog_hits
        if "SIGSEGV" in str(h.get("message") or "") or "signal(2)" in str(h.get("message") or "")
    ]
    corpse = [h for h in syslog_hits if "Corpse" in str(h.get("message") or "")]

    tags = ac_runtime[-100:] if ac_runtime else ac_all[-100:]
    ak_skip = [ln for ln in ac_all if "ak_bg_windows_api_skip" in ln]
    ak_block = [ln for ln in ac_all if "ak_main_block_" in ln or "al_icu_busy" in ln]
    al_fatal = [ln for ln in ac_all if "al_fatal_signal" in ln]
    al_uikit = [ln for ln in ac_all if "al_qf_uikit" in ln]
    al_icu = [ln for ln in ac_all if "al_icu_" in ln]
    al_thr = [ln for ln in ac_all if "al_thr_pc" in ln]
    al_exc = [ln for ln in ac_all if "al_uncaught_exception" in ln or "al_qf_exception" in ln]
    has_ak_skip = len(ak_skip) > 0
    xiaoyan_ok = isinstance(xiaoyan, dict) and bool(xiaoyan.get("passed"))
    decision = decide(
        tags,
        has_qf=has_qf,
        has_fatal=has_fatal,
        reader_ok=reader_ok,
        pid_stable=pid_stable,
        has_ak_skip=has_ak_skip,
        qf_main=qf_main,
        scene_syslog_n=len(scene_syslog),
        bg_uikit_n=len([ln for ln in ac_all if "ai_bg_uikit" in ln]),
        al_fatal_n=len(al_fatal),
        al_uikit_n=len(al_uikit),
        al_icu_n=len(al_icu),
        al_thr_n=len(al_thr),
        xiaoyan_ok=xiaoyan_ok,
    )
    first_chapter = bool(
        reader_ok
        and xiaoyan_ok
        and has_qf
        and qf_main
        and any("format_exit" in ln for ln in ac_all)
        and pid_stable
        and len(sigsegv) == 0
        and len(scene_syslog) == 0
    )
    gates = [ln for ln in ac_all if "qf_dispatch_gates" in ln]

    sync = {
        "sha": sha,
        "probe_last_line": probe_lines[-1] if probe_lines else "",
        "al_last_runtime": ac_runtime[-1] if ac_runtime else (ac_all[-1] if ac_all else ""),
        "al_runtime": ac_runtime[-100:],
        "al_fatal": al_fatal[-8:],
        "al_qf_uikit": al_uikit[-16:],
        "al_icu": al_icu[-16:],
        "al_thr_pc": al_thr[-24:],
        "al_exception": al_exc[-8:],
        "ak_bg_skip": ak_skip[-12:],
        "ak_main_block": ak_block[-12:],
        "qf_dispatch_gates": gates[-8:],
        "has_qf": has_qf,
        "qf_n": qf_n,
        "has_qf_enter": any("qf_enter" in ln for ln in ac_all),
        "has_qf_exit": any("qf_exit" in ln for ln in ac_all),
        "qf_main": qf_main,
        "has_ak_skip": has_ak_skip,
        "pids": pids,
        "pid0": pid0,
        "pid1": pid1,
        "pid_stable": pid_stable,
        "probe_pid_stable": probe_pid_stable,
        "os_pid_stable": os_pid_stable,
        "relaunch_after_chain": relaunch_after,
        "mid_chain_launch_app": False,
        "has_format_enter": any("format_enter" in ln for ln in ac_all),
        "has_format_exit": any("format_exit" in ln for ln in ac_all),
        "has_cb_enter": any("cb_enter" in ln for ln in ac_all),
        "has_cb_exit": any("cb_exit" in ln for ln in ac_all),
        "has_inject_inThread": any("qf_dispatch_inject_inThread" in ln for ln in ac_all),
        "has_ak_keep_inThread": any("ak_keep_inThread=1" in ln for ln in ac_all),
        "has_al_keep_inThread": any("al_keep_inThread=1" in ln for ln in ac_all),
        "path_sync_inThread": any("path=sync_inThread" in ln for ln in ac_all),
        "has_fatal": has_fatal,
        "al_fatal_n": len(al_fatal),
        "al_qf_uikit_n": len(al_uikit),
        "al_icu_n": len(al_icu),
        "al_thr_pc_n": len(al_thr),
        "scene_syslog_n": len(scene_syslog),
        "sigsegv_n": len(sigsegv),
        "corpse_n": len(corpse),
        "reader_foreground": reader_ok,
        "frontmost_final": fm_final,
        "xiaoyan": xiaoyan,
        "ui_texts": ui_texts[:20],
        "decision": decision,
        "first_chapter_approved": first_chapter,
        "syslog_kill_hits_n": len(syslog_hits),
        "crash_stack_n": len(report.get("crash_stack") or []),
    }
    report["polls"] = polls[-12:]
    report["sync"] = sync
    report["decision"] = decision
    report["first_chapter_approved"] = first_chapter
    report["reader_foreground"] = reader_ok

    kill_doc = {
        "sha": sha,
        "pid0": pid0,
        "pid1": pid1,
        "conclusion": decision.get("action"),
        "mid_chain_launch_app": False,
        "hits": syslog_hits[:50],
        "scene_syslog": scene_syslog[:12],
        "sigsegv": sigsegv[:8],
        "corpse": corpse[:8],
        "al_fatal": al_fatal[-8:],
        "al_qf_uikit": al_uikit[-12:],
        "al_icu": al_icu[-12:],
        "al_thr_pc": al_thr[-16:],
        "crash_stack": report.get("crash_stack") or [],
        "tmp_fatal_head": tmp_text[:2000],
    }

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    SYNC.write_text(json.dumps(sync, ensure_ascii=False, indent=2), encoding="utf-8")
    KILL.write_text(json.dumps(kill_doc, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(sync, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
