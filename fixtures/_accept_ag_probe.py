#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AG 探针验收：KEEP inThread；链路内禁 launch_app；pid/bg_hb/jetsam 取证；前台硬断言萧炎。"""
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
OUT = ROOT / "fixtures" / "_accept_ag_probe.json"
SYNC = ROOT / "fixtures" / "_accept_ag_probe_sync.json"

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
    """从 running apps / frontmost 取 StandarReader pid，不 launch。"""
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
    """仅在已是 StandarReader 前台时点 Alert；绝不 launch_app。"""
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
        "legado_loadcurcp_state.txt",
        "legado_loadcurcp_trace.txt",
        "legado_openreader_trace.txt",
        "legado_debug_dump.txt",
        "legado_catalog_openreader.txt",
        "legado_native_open_once.txt",
        "legado_lifecycle_pop_trace.txt",
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
    return doc


def decide(tags: list[str], has_qf: bool, has_fatal: bool, reader_ok: bool, pid_stable: bool) -> dict:
    has = lambda k: any(k in ln for ln in tags)
    if not reader_ok:
        return {
            "branch": "foreground_not_reader",
            "action": "前台非 StandarReader；杀因/萧炎均不可信",
            "commit": False,
        }
    if has_fatal or any("fatal_signal" in ln for ln in tags):
        return {
            "branch": "fatal_signal",
            "action": "有 fatal_signal；写信号结论",
            "commit": False,
        }
    if has("ag_atexit"):
        return {
            "branch": "voluntary_exit",
            "action": "命中 ag_atexit：自愿 exit 路径",
            "commit": False,
        }
    if not pid_stable and has("ag_bg_hb"):
        return {
            "branch": "sigkill_or_external_relaunch",
            "action": "bg_hb 中断且 pid 变：SIGKILL/外部 relaunch（对照是否误 launch_app）",
            "commit": False,
        }
    if has("qf_enter") or has_qf:
        return {
            "branch": "qf_reached_inThread",
            "action": "KEEP inThread 下 QF 通；按萧炎/pid 裁定",
            "commit": False,
        }
    return {
        "branch": "earlier_or_unknown",
        "action": "未进 QF；只交取证",
        "commit": False,
    }


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
        "hypothesis": "AG",
        "role": "AG-silent-kill-forensics-keep-inThread",
        "model": "cursor-grok-4.5",
        "mock": MOCK,
        "mcp": MCP,
        "banned": ["bounce", "dontFormat", "mid_chain_launch_app", "remove_inThread"],
        "keep": ["inject_inThread", "V+W+X+Y+Z", "BQM check/format id return"],
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

    # 仅在 nativeRead 前允许 launch/kill（准备态）
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
        # 准备失败才允许最后一次 launch；之后链路禁 launch
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
    # ★ 关键：nativeRead 后整条链路禁止 launch_app，避免误杀/重建伪造成静默杀
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
        ac = [ln for ln in blob.splitlines() if "hypothesis_AC" in ln]
        rt = [ln for ln in ac if "install_" not in ln]
        hb = [ln for ln in ac if "ag_bg_hb" in ln]
        polls.append(
            {
                "t": round(time.time() - t0, 2),
                "ac_runtime_n": len(rt),
                "ac_last": rt[-1] if rt else (ac[-1] if ac else None),
                "front": fm.get("bundleId"),
                "pid": pid,
                "bg_hb_n": len(hb),
            }
        )
        if rt and any(
            k in (rt[-1] or "")
            for k in (
                "qf_exit",
                "ag_post_qf",
                "ag_bg_hb_done",
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
        report["capture_stop"] = capture_stop
    except Exception as exc:
        report["capture_stop_err"] = str(exc)

    # 链结束后才允许一次拉回前台（若已死则记录 relaunch，不当作 CB 窗口杀因）
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
            c.call("open_url", {"url": "legado://debugDump?phase=ag_accept"}, timeout=20)
            time.sleep(1.5)
            dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or dump
    except Exception as exc:
        report["dump_err"] = str(exc)

    probe_lines = [ln for ln in probe.splitlines() if ln.strip()]
    ac_all = [ln for ln in (probe + "\n" + st).splitlines() if "hypothesis_AC" in ln]
    ac_runtime = [ln for ln in ac_all if "install_" not in ln]
    has_qf = (
        "lpNetWorkDelegateQueryFinish" in (probe + st + dump)
        or any("qf_enter" in ln for ln in ac_all)
    )
    has_fatal = any("fatal_signal" in ln for ln in ac_all)
    qf_n = sum(
        1
        for ln in (probe + st + dump).splitlines()
        if "lpNetWorkDelegateQueryFinish" in ln or "qf_enter" in ln
    )
    hb = [ln for ln in ac_all if "ag_bg_hb" in ln]
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

    # jetsam / 新 ips
    crashes = None
    try:
        crashes = c.call("get_crash_logs", {"limit": 12}, timeout=40)
    except Exception as exc:
        report["crash_err"] = str(exc)

    today = datetime.now().strftime("%Y-%m-%d")
    new_standar_ips = []
    jetsam_hits = []
    if isinstance(crashes, dict):
        for r in crashes.get("reports") or []:
            name = str(r.get("name") or "")
            path = str(r.get("path") or "")
            if "StandarReader" in name and today.replace("-", "")[:4] in name.replace("-", ""):
                # 名称含日期：StandarReader-2026-07-18-...
                if "2026-07-18" in name or today in name:
                    new_standar_ips.append(name)
            if "Jetsam" in name or "jetsam" in name.lower():
                jetsam_hits.append(name)
            if "StandarReader" in name and "2026-07-18" in name:
                new_standar_ips.append(name)

    tags = ac_runtime[-60:] if ac_runtime else ac_all[-60:]
    decision = decide(
        tags, has_qf=has_qf, has_fatal=has_fatal, reader_ok=reader_ok, pid_stable=pid_stable
    )
    first_chapter = bool(
        reader_ok
        and isinstance(xiaoyan, dict)
        and xiaoyan.get("passed")
        and has_qf
        and any("format_exit" in ln for ln in ac_all)
        and any("qf_dispatch_inject_inThread" in ln for ln in ac_all)
        and pid_stable
    )
    gates = [ln for ln in ac_all if "qf_dispatch_gates" in ln]

    sync = {
        "sha": sha,
        "probe_last_line": probe_lines[-1] if probe_lines else "",
        "ag_last_runtime": ac_runtime[-1] if ac_runtime else (ac_all[-1] if ac_all else ""),
        "ag_runtime": ac_runtime[-60:],
        "qf_dispatch_gates": gates[-8:],
        "has_qf": has_qf,
        "qf_n": qf_n,
        "has_qf_enter": any("qf_enter" in ln for ln in ac_all),
        "has_qf_exit": any("qf_exit" in ln for ln in ac_all),
        "has_ag_post_qf": any("ag_post_qf" in ln for ln in ac_all),
        "has_main_pulse": any("qf_dispatch_main_pulse" in ln for ln in ac_all),
        "has_bg_hb": len(hb) > 0,
        "bg_hb_n": len(hb),
        "bg_hb_tail": hb[-8:],
        "has_bg_hb_done": any("ag_bg_hb_done" in ln for ln in ac_all),
        "has_atexit": any("ag_atexit" in ln for ln in ac_all),
        "has_async_plus": any("async_plus0.6s_enter" in ln for ln in ac_all),
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
        "path_sync_inThread": any("path=sync_inThread" in ln for ln in ac_all),
        "path_async_main": any("path=async_main" in ln for ln in ac_all),
        "has_fatal": has_fatal,
        "reader_foreground": reader_ok,
        "frontmost_final": fm_final,
        "xiaoyan": xiaoyan,
        "ui_texts": ui_texts[:20],
        "decision": decision,
        "first_chapter_approved": first_chapter,
        "new_standar_ips_today": sorted(set(new_standar_ips)),
        "jetsam_hits": jetsam_hits[:8],
        "capture_new_crashes": (
            (capture_stop or {}).get("new_crashes")
            if isinstance(capture_stop, dict)
            else None
        ),
    }
    report["polls"] = polls[-12:]
    report["sync"] = sync
    report["decision"] = decision
    report["first_chapter_approved"] = first_chapter
    report["reader_foreground"] = reader_ok

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    SYNC.write_text(json.dumps(sync, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(sync, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
