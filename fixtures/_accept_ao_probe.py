#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AO 验收：强化 post-cb 故障捕获 + LBFHook QF 窗重入/开销；KEEP AK/strftime/inThread；前台硬断言萧炎。"""
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
OUT = ROOT / "fixtures" / "_accept_ao_probe.json"
SYNC = ROOT / "fixtures" / "_accept_ao_probe_sync.json"
KILL = ROOT / "fixtures" / "_accept_ao_kill_syslog.json"

FORBIDDEN_FRONT = (
    "com.apple.MobileSMS",
    "com.apple.springboard",
    "com.apple.Preferences",
)

SYSLOG_KEYS = (
    "jetsam",
    "memorystatus",
    "SIGSEGV",
    "SIGKILL",
    "SIGBUS",
    "Watchdog",
    "watchdog",
    "scene-update",
    "UIWindowScene",
    "non-main thread",
    "Corpse",
    "termination",
    "Terminated",
    "exited",
    "exit reason",
    "Exit reason",
    "RBSProcessExitStatus",
    "RBSTermination",
    "runningboard",
    "RunningBoard",
    "ReportCrash",
    "Exception Type",
    "faulting",
    "domain:signal",
    "domain:jetsam",
    "domain:watchdog",
    "Process exited",
    "crashreporter",
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
    for tmp in ("/tmp/legado_al_fatal.txt", "/tmp/legado_am_hb.txt", "/tmp/legado_an_fault.txt", "/tmp/legado_ao_fault.txt", "/tmp/legado_ao_lbf.txt"):
        try:
            c.call("run_command", {"command": f"rm -f {tmp}", "timeout_sec": 8}, timeout=15)
        except Exception:
            pass
    return doc


def classify_exit_hits(hits: list[dict]) -> dict:
    def has(*keys: str) -> list[dict]:
        out = []
        for h in hits:
            blob = f"{h.get('message', '')} {h.get('process', '')}"
            low = blob.lower()
            if any(k.lower() in low for k in keys):
                out.append(h)
        return out

    return {
        "sigsegv": has("SIGSEGV", "signal(2)", "domain:signal"),
        "jetsam": has("Jetsam", "memorystatus", "domain:jetsam"),
        "watchdog": has("watchdog", "domain:watchdog"),
        "termination": has("termination", "Terminated", "RBSTermination"),
        "exit_reason": has("exit reason", "RBSProcessExitStatus", "Process exited"),
        "corpse": has("Corpse"),
        "runningboard": has("runningboard", "RunningBoard"),
    }


def decide(
    *,
    has_qf: bool,
    reader_ok: bool,
    pid_stable: bool,
    has_ak_skip: bool,
    qf_main: bool,
    scene_syslog_n: int,
    am_hb_n: int,
    am_icu_n: int,
    exit_reason_n: int,
    sigsegv_n: int,
    xiaoyan_ok: bool,
    ao_fault_n: int = 0,
    an_fault_n: int = 0,
    ao_lbf_n: int = 0,
    ao_handler_stolen_n: int = 0,
    an_icu_stack_n: int = 0,
    an_mem_path_n: int = 0,
) -> dict:
    if (
        reader_ok
        and xiaoyan_ok
        and has_qf
        and qf_main
        and pid_stable
        and scene_syslog_n == 0
        and sigsegv_n == 0
    ):
        return {
            "branch": "first_chapter",
            "action": "主线程 QF + 萧炎 + pid 稳；AO 成功可最小修落盘",
            "commit": True,
        }
    if ao_fault_n > 0 or an_fault_n > 0:
        return {
            "branch": "ao_fault_pc",
            "action": "故障 PC 已落；对照 LBFHook 统计与 syslog exit reason",
            "commit": False,
        }
    if not pid_stable and exit_reason_n == 0 and sigsegv_n == 0 and ao_fault_n == 0:
        return {
            "branch": "pid_only_no_sigsegv",
            "action": "无 SIGSEGV/故障 PC，仅 pid 变；对照 LBFHook 与晚杀窗",
            "commit": False,
        }
    if ao_lbf_n > 0 and not pid_stable:
        return {
            "branch": "ao_lbf_overhead",
            "action": "LBFHook 有 QF 窗命中且 pid 变；评估是否可降噪",
            "commit": False,
        }
    if am_hb_n > 0 and (am_icu_n > 0 or exit_reason_n > 0 or not pid_stable):
        return {
            "branch": "am_hb_icu_or_exit",
            "action": "心跳/exit 仍在；对照 ao_fault / handler stolen",
            "commit": False,
        }
    if has_ak_skip and scene_syslog_n == 0 and not pid_stable:
        return {
            "branch": "ak_keep_still_kill",
            "action": "AK KEEP 仍成立但 pid 变；AO 证据不足则加深",
            "commit": False,
        }
    if not pid_stable:
        return {
            "branch": "pid_changed",
            "action": "pid 不稳；对照 ao_fault / syslog exit reason / LBFHook",
            "commit": False,
        }
    return {
        "branch": "ao_incomplete",
        "action": "AO 证据不足",
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
        "hypothesis": "AO",
        "role": "AO-remain-kill-lbfhook-qf-window",
        "model": "cursor-grok-4.5",
        "mock": MOCK,
        "mcp": MCP,
        "banned": [
            "bounce",
            "dontFormat",
            "mid_chain_launch_app",
            "dispatch_sync_main_QF",
            "empty_WakeUp",
            "full_thread_suspend_heartbeat",
        ],
        "keep": [
            "inject_inThread",
            "V+W+X+Y+Z",
            "BQM check/format id return",
            "ak_bg_windows_api_skip",
            "strftime_LBForensicsUTCNow",
            "fe1c9eb_AK",
            "8984070_AN",
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
    # AO：同版号覆盖安装可能留下旧 dylib；先卸再装，硬保证 build_manifest=HEAD
    try:
        report["uninstall"] = c.call(
            "uninstall_app", {"bundle_id": BUNDLE}, timeout=120
        )
    except Exception as exc:
        report["uninstall_err"] = str(exc)
    time.sleep(1.5)
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
        if "install_done" in early and ("install_qf" in early or "am_icu_hook_ok" in early):
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
            or "am_" in ln
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
        if any("ao_post_hb_watch_done" in (ln or "") for ln in rt) or any(
            "ao_fault_signal" in (ln or "") for ln in rt
        ):
            time.sleep(1.5)
            break
        if rt and any(
            k in (rt[-1] or "")
            for k in (
                "am_post_cb_hb_done",
                "qf_exit",
                "ag_post_qf",
                "cb_exit",
                "am_post_cb_hb i=40",
                "fatal_signal",
                "ag_atexit",
            )
        ):
            # 仍等晚杀窗探针（hb 后再 2s）
            time.sleep(0.5)
            continue

    pid1 = reader_pid(c)
    report["pid_log"].append(
        {"t": round(time.time() - t0, 2), "phase": "post_poll", "pid": pid1}
    )

    capture_stop = None
    try:
        capture_stop = c.call("stop_capture", timeout=60)
        if isinstance(capture_stop, dict):
            entries = capture_stop.get("syslog_entries") or []
            hits = []
            for e in entries:
                if not isinstance(e, dict):
                    continue
                blob = f"{e.get('message', '')} {e.get('process', '')}"
                if any(k.lower() in blob.lower() for k in SYSLOG_KEYS):
                    hits.append(
                        {
                            "date": e.get("date"),
                            "process": e.get("process"),
                            "level": e.get("level"),
                            "message": str(e.get("message") or "")[:500],
                        }
                    )
                    if len(hits) >= 160:
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

    tmp_hb = ""
    tmp_fatal = ""
    tmp_an_fault = ""
    try:
        tmp_hb = c.call(
            "run_command",
            {"command": "cat /tmp/legado_am_hb.txt 2>/dev/null | tail -n 50", "timeout_sec": 8},
            timeout=15,
        )
        report["tmp_hb"] = tmp_hb
    except Exception as exc:
        report["tmp_hb_err"] = str(exc)
    try:
        tmp_fatal = c.call(
            "run_command",
            {"command": "cat /tmp/legado_al_fatal.txt 2>/dev/null | tail -n 20", "timeout_sec": 8},
            timeout=15,
        )
        report["tmp_fatal"] = tmp_fatal
    except Exception as exc:
        report["tmp_fatal_err"] = str(exc)
    try:
        tmp_an_fault = c.call(
            "run_command",
            {
                "command": "cat /tmp/legado_an_fault.txt 2>/dev/null | tail -n 40; "
                "echo '---'; cat /tmp/legado_ao_fault.txt 2>/dev/null | tail -n 40; "
                "echo '---'; cat /tmp/legado_ao_lbf.txt 2>/dev/null | tail -n 60; "
                "echo '---'; cat /var/mobile/Containers/Data/Application/*/Documents/legado_ao_fault.txt 2>/dev/null | tail -n 40; "
                "echo '---'; cat ~/Documents/legado_native_crash_pending.txt 2>/dev/null; "
                "ls -la /var/mobile/Library/Logs/CrashReporter 2>/dev/null | head -n 30",
                "timeout_sec": 12,
            },
            timeout=20,
        )
        report["tmp_an_fault"] = tmp_an_fault
        report["tmp_ao_fault"] = tmp_an_fault
    except Exception as exc:
        report["tmp_an_fault_err"] = str(exc)
        report["tmp_ao_fault_err"] = str(exc)
    try:
        an_doc = c.read_sandbox_text("legado_an_fault.txt", max_bytes=50000) or ""
        report["an_fault_doc"] = an_doc[-4000:]
    except Exception as exc:
        report["an_fault_doc_err"] = str(exc)
    try:
        ao_doc = c.read_sandbox_text("legado_ao_fault.txt", max_bytes=50000) or ""
        report["ao_fault_doc"] = ao_doc[-4000:]
    except Exception as exc:
        report["ao_fault_doc_err"] = str(exc)
    try:
        ao_lbf_doc = c.read_sandbox_text("legado_ao_lbf.txt", max_bytes=80000) or ""
        report["ao_lbf_doc"] = ao_lbf_doc[-6000:]
    except Exception as exc:
        report["ao_lbf_doc_err"] = str(exc)

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
            c.call("open_url", {"url": "legado://debugDump?phase=ao_accept"}, timeout=20)
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

    def _cmd_text(v) -> str:
        if isinstance(v, dict):
            return str(v.get("stdout") or v.get("output") or v)
        return str(v or "")

    tmp_hb_text = _cmd_text(tmp_hb)
    tmp_fatal_text = _cmd_text(tmp_fatal)
    tmp_an_fault_text = _cmd_text(tmp_an_fault)
    an_doc_text = str(report.get("an_fault_doc") or "")
    ao_doc_text = str(report.get("ao_fault_doc") or "")
    ao_lbf_doc_text = str(report.get("ao_lbf_doc") or "")

    ac_all = [
        ln
        for ln in (
            blob_all
            + "\n"
            + ai_probe
            + "\n"
            + tmp_hb_text
            + "\n"
            + tmp_fatal_text
            + "\n"
            + tmp_an_fault_text
            + "\n"
            + an_doc_text
            + "\n"
            + ao_doc_text
            + "\n"
            + ao_lbf_doc_text
        ).splitlines()
        if "hypothesis_AC" in ln
        or "hypothesis_AK" in ln
        or "ak_main_block" in ln
        or "ak_main_idle" in ln
        or "ak_bg_windows" in ln
        or "ak_keep_inThread" in ln
        or "am_" in ln
        or "al_" in ln
        or "an_" in ln
        or "ao_" in ln
        or "ai_main_" in ln
        or "ai_bg_uikit" in ln
    ]
    ac_runtime = [ln for ln in ac_all if "install_" not in ln]
    has_qf = (
        "lpNetWorkDelegateQueryFinish" in (probe + st + dump)
        or any("qf_enter" in ln for ln in ac_all)
    )
    has_fatal = any(
        "fatal_signal" in ln or "al_fatal_signal" in ln
        or "an_fault_signal" in ln or "ao_fault_signal" in ln
        for ln in ac_all
    )
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
    exit_cls = classify_exit_hits(syslog_hits)
    sigsegv = exit_cls["sigsegv"]
    corpse = exit_cls["corpse"]

    am_hb = [ln for ln in ac_all if "am_post_cb_hb" in ln]
    am_icu = [ln for ln in ac_all if "am_icu_caller" in ln]
    am_hook = [ln for ln in ac_all if "am_icu_hook_ok" in ln]
    ak_skip = [ln for ln in ac_all if "ak_bg_windows_api_skip" in ln]
    ak_block = [ln for ln in ac_all if "ak_main_block_" in ln or "al_icu_busy" in ln]
    al_icu = [ln for ln in ac_all if "al_icu_" in ln]
    al_fatal = [ln for ln in ac_all if "al_fatal_signal" in ln]
    an_fault = [ln for ln in ac_all if "an_fault_signal" in ln]
    ao_fault = [ln for ln in ac_all if "ao_fault_signal" in ln]
    an_claim = [ln for ln in ac_all if "an_fault_claim" in ln]
    ao_claim = [ln for ln in ac_all if "ao_fault_claim" in ln]
    ao_handler = [ln for ln in ac_all if "ao_fault_handler" in ln]
    ao_handler_stolen = [ln for ln in ao_handler if "ours=0" in ln]
    ao_lbf = [ln for ln in ac_all if "ao_lbf_" in ln]
    an_icu_stack = [ln for ln in ac_all if "an_icu_stack" in ln]
    an_mem_path = [ln for ln in ac_all if "an_mem_path" in ln]
    an_qf_stack = [ln for ln in ac_all if "an_qf_enter_stack" in ln]
    has_ak_skip = len(ak_skip) > 0
    xiaoyan_ok = isinstance(xiaoyan, dict) and bool(xiaoyan.get("passed"))

    hb_ms_max = None
    hb_mem0 = None
    hb_mem1 = None
    for ln in am_hb:
        if "ms=" in ln:
            try:
                part = ln.split("ms=")[1].split()[0]
                v = int(part)
                hb_ms_max = v if hb_ms_max is None else max(hb_ms_max, v)
            except Exception:
                pass
        if "mem=" in ln:
            try:
                mv = int(ln.split("mem=")[1].split()[0])
                if hb_mem0 is None:
                    hb_mem0 = mv
                hb_mem1 = mv
            except Exception:
                pass

    mem_class_counts: dict[str, int] = {}
    for ln in an_mem_path:
        cls = "unknown"
        if "class=" in ln:
            cls = ln.split("class=")[1].split()[0]
        mem_class_counts[cls] = mem_class_counts.get(cls, 0) + 1
    mem_vs_icu = {
        "hb_mem0": hb_mem0,
        "hb_mem1": hb_mem1,
        "hb_mem_delta": (None if hb_mem0 is None or hb_mem1 is None else hb_mem1 - hb_mem0),
        "path_class_counts": mem_class_counts,
        "icu_dominant": mem_class_counts.get("icu", 0)
        >= max(1, sum(mem_class_counts.values()) // 2),
        "page_dominant": mem_class_counts.get("page", 0)
        >= max(1, sum(mem_class_counts.values()) // 2),
        "verdict": (
            "icu_path"
            if mem_class_counts.get("icu", 0)
            > mem_class_counts.get("page", 0)
            and mem_class_counts.get("icu", 0) > 0
            else (
                "page_path"
                if mem_class_counts.get("page", 0)
                > mem_class_counts.get("icu", 0)
                and mem_class_counts.get("page", 0) > 0
                else (
                    "mixed_or_other"
                    if an_mem_path
                    else "no_mem_path_sample"
                )
            )
        ),
    }

    fault_pc = None
    fault_lr = None
    fault_si = None
    fault_src = ao_fault[-1] if ao_fault else (an_fault[-1] if an_fault else None)
    if fault_src:
        last = fault_src
        try:
            if "pc=" in last:
                fault_pc = last.split("pc=")[1].split()[0]
            if "lr=" in last:
                fault_lr = last.split("lr=")[1].split()[0]
            if "fault=" in last:
                fault_si = last.split("fault=")[1].split()[0]
        except Exception:
            pass

    lbf_hit = None
    lbf_max_depth = None
    lbf_reenter = None
    for ln in ao_lbf:
        if "hit=" in ln:
            try:
                lbf_hit = int(ln.split("hit=")[1].split()[0])
            except Exception:
                pass
        if "maxDepth=" in ln:
            try:
                lbf_max_depth = int(ln.split("maxDepth=")[1].split()[0])
            except Exception:
                pass
        if "reenter=" in ln:
            try:
                lbf_reenter = int(ln.split("reenter=")[1].split()[0])
            except Exception:
                pass

    decision = decide(
        has_qf=has_qf,
        reader_ok=reader_ok,
        pid_stable=pid_stable,
        has_ak_skip=has_ak_skip,
        qf_main=qf_main,
        scene_syslog_n=len(scene_syslog),
        am_hb_n=len(am_hb),
        am_icu_n=len(am_icu),
        exit_reason_n=len(exit_cls["exit_reason"]) + len(exit_cls["termination"]),
        sigsegv_n=len(sigsegv),
        xiaoyan_ok=xiaoyan_ok,
        ao_fault_n=len(ao_fault),
        an_fault_n=len(an_fault),
        ao_lbf_n=len(ao_lbf),
        ao_handler_stolen_n=len(ao_handler_stolen),
        an_icu_stack_n=len(an_icu_stack),
        an_mem_path_n=len(an_mem_path),
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
        "am_last_runtime": ac_runtime[-1] if ac_runtime else (ac_all[-1] if ac_all else ""),
        "am_runtime": ac_runtime[-120:],
        "am_post_cb_hb": am_hb[-48:],
        "am_hb_ms_max": hb_ms_max,
        "am_hb_done": any("am_post_cb_hb_done" in ln for ln in ac_all),
        "am_icu_caller": am_icu[-24:],
        "am_icu_hook": am_hook[-4:],
        "al_icu": al_icu[-12:],
        "al_fatal": al_fatal[-8:],
        "an_fault_signal": an_fault[-8:],
        "ao_fault_signal": ao_fault[-8:],
        "an_fault_claim": an_claim[-8:],
        "ao_fault_claim": ao_claim[-8:],
        "ao_fault_handler": ao_handler[-12:],
        "ao_fault_handler_stolen": ao_handler_stolen[-8:],
        "ao_lbf": ao_lbf[-24:],
        "ao_lbf_hit": lbf_hit,
        "ao_lbf_max_depth": lbf_max_depth,
        "ao_lbf_reenter": lbf_reenter,
        "an_icu_stack": an_icu_stack[-16:],
        "an_mem_path": an_mem_path[-24:],
        "an_qf_enter_stack": an_qf_stack[-4:],
        "ao_fault_pc": fault_pc,
        "ao_fault_lr": fault_lr,
        "ao_fault_addr": fault_si,
        "an_fault_pc": fault_pc,
        "an_fault_lr": fault_lr,
        "an_fault_addr": fault_si,
        "mem_vs_icu": mem_vs_icu,
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
        "has_am_keep_inThread": any("am_keep_inThread=1" in ln for ln in ac_all),
        "path_sync_inThread": any("path=sync_inThread" in ln for ln in ac_all),
        "has_fatal": has_fatal,
        "am_hb_n": len(am_hb),
        "am_icu_caller_n": len(am_icu),
        "an_fault_n": len(an_fault),
        "ao_fault_n": len(ao_fault),
        "ao_lbf_n": len(ao_lbf),
        "ao_handler_stolen_n": len(ao_handler_stolen),
        "an_icu_stack_n": len(an_icu_stack),
        "an_mem_path_n": len(an_mem_path),
        "ao_post_hb_watch_done": any("ao_post_hb_watch_done" in ln for ln in ac_all),
        "scene_syslog_n": len(scene_syslog),
        "sigsegv_n": len(sigsegv),
        "corpse_n": len(corpse),
        "exit_class": {k: len(v) for k, v in exit_cls.items()},
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
        "am_hb_ms_max": hb_ms_max,
        "am_hb_done": sync["am_hb_done"],
        "am_icu_caller": am_icu[-16:],
        "ao_fault_pc": fault_pc,
        "ao_fault_lr": fault_lr,
        "ao_fault_addr": fault_si,
        "ao_lbf_hit": lbf_hit,
        "ao_lbf_max_depth": lbf_max_depth,
        "ao_lbf_reenter": lbf_reenter,
        "an_icu_stack": an_icu_stack[-12:],
        "mem_vs_icu": mem_vs_icu,
        "hits": syslog_hits[:80],
        "exit_class": {k: v[:12] for k, v in exit_cls.items()},
        "scene_syslog": scene_syslog[:12],
        "sigsegv": sigsegv[:8],
        "corpse": corpse[:8],
        "tmp_hb_tail": tmp_hb_text[-2500:],
        "tmp_fatal_head": tmp_fatal_text[:2000],
        "tmp_an_fault": tmp_an_fault_text[:4000],
        "crash_stack": report.get("crash_stack") or [],
    }

    corpse_doc = {
        "sha": sha,
        "pid0": pid0,
        "pid1": pid1,
        "exit_reason": {
            "raw": [
                str(h.get("message") or "")
                for h in (exit_cls.get("exit_reason") or [])[:6]
            ],
            "termination": [
                str(h.get("message") or "")
                for h in (exit_cls.get("termination") or [])[:6]
            ],
            "corpse": [
                str(h.get("message") or "") for h in (corpse or [])[:6]
            ],
        },
        "ao_fault_signal": ao_fault[-8:],
        "an_fault_signal": an_fault[-8:],
        "ao_fault_claim": ao_claim[-8:],
        "an_fault_claim": an_claim[-8:],
        "ao_fault_handler_stolen": ao_handler_stolen[-8:],
        "ao_lbf": ao_lbf[-16:],
        "fault_pc": fault_pc,
        "fault_lr": fault_lr,
        "fault_addr": fault_si,
        "crash_logs": report.get("crash_logs"),
        "crash_stack": report.get("crash_stack") or [],
        "tmp_ao_fault": tmp_an_fault_text[:6000],
        "ao_fault_doc": ao_doc_text[-4000:],
        "an_fault_doc": an_doc_text[-4000:],
    }
    fault_doc = {
        "sha": sha,
        "fault_pc": fault_pc,
        "fault_lr": fault_lr,
        "fault_addr": fault_si,
        "ao_fault_signal": ao_fault[-8:],
        "an_fault_signal": an_fault[-8:],
        "ao_fault_claim": ao_claim[-8:],
        "ao_fault_handler": ao_handler[-12:],
        "ao_lbf_hit": lbf_hit,
        "ao_lbf_max_depth": lbf_max_depth,
        "ao_lbf_reenter": lbf_reenter,
        "ao_lbf": ao_lbf[-24:],
        "an_icu_stack": an_icu_stack[-16:],
        "an_mem_path": an_mem_path[-24:],
        "mem_vs_icu": mem_vs_icu,
        "am_icu_caller_sample": am_icu[-12:],
        "verdict_no_sigsegv_pid_only": (
            not pid_stable
            and len(ao_fault) == 0
            and len(an_fault) == 0
            and len(sigsegv) == 0
        ),
    }

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    SYNC.write_text(json.dumps(sync, ensure_ascii=False, indent=2), encoding="utf-8")
    KILL.write_text(json.dumps(kill_doc, ensure_ascii=False, indent=2), encoding="utf-8")
    (ROOT / "fixtures" / "_accept_ao_corpse.json").write_text(
        json.dumps(corpse_doc, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (ROOT / "analysis" / "reader-forensics" / "ao_fault_summary.json").write_text(
        json.dumps(fault_doc, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(sync, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
