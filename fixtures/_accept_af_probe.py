#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AF 探针验收：撤 inThread；主队列心跳/appState；强制前台 StandarReader 后复验 QF/萧炎。"""
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
OUT = ROOT / "fixtures" / "_accept_af_probe.json"
SYNC = ROOT / "fixtures" / "_accept_af_probe_sync.json"

# 验收时禁止把这些当成阅读器前台
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
    bid = str(fm.get("bundleId") or "")
    return bid == BUNDLE


def ensure_reader_front(c: McpClient, report: dict, reason: str) -> dict:
    """保证前台是 StandarReader；否则 launch_app 拉回。"""
    fm = frontmost(c)
    report.setdefault("frontmost_log", []).append({"reason": reason, "front": fm})
    if is_reader_front(fm):
        return fm
    try:
        c.call("launch_app", {"bundle_id": BUNDLE}, timeout=30)
        time.sleep(1.2)
    except Exception as exc:
        report.setdefault("frontmost_log", []).append(
            {"reason": f"{reason}_launch_err", "error": str(exc)}
        )
    fm2 = frontmost(c)
    report.setdefault("frontmost_log", []).append({"reason": f"{reason}_after", "front": fm2})
    return fm2


def dismiss_reader_only(c: McpClient, report: dict) -> None:
    """仅在 StandarReader 前台时点 Alert，避免误点短信/他 App。"""
    fm = ensure_reader_front(c, report, "dismiss_pre")
    if not is_reader_front(fm):
        return
    for _ in range(4):
        try:
            els = c.call("get_ui_elements", timeout=20) or {}
            blob = json.dumps(els, ensure_ascii=False)
            # 短信/信息界面特征：放弃点按
            if any(k in blob for k in ("中国移动", "垃圾信息", "拟我表情", "听写")):
                report.setdefault("frontmost_log", []).append(
                    {"reason": "dismiss_skip_sms_ui", "hint": True}
                )
                ensure_reader_front(c, report, "dismiss_sms_recover")
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


def decide(tags: list[str], has_qf: bool, has_fatal: bool, reader_ok: bool) -> dict:
    has = lambda k: any(k in ln for ln in tags)
    if not reader_ok:
        return {
            "branch": "foreground_not_reader",
            "action": "前台非 StandarReader；先修验收拉回再谈 QF/萧炎",
            "commit": False,
        }
    if has_fatal or any("fatal_signal" in ln for ln in tags):
        return {
            "branch": "fatal_signal_or_watchdog",
            "action": "写 watchdog 结论，勿叠 bounce/dontFormat",
            "commit": False,
        }
    if has("qf_enter") or has_qf:
        return {
            "branch": "qf_reached_async_main",
            "action": "无 inThread 已进 QF；按萧炎/FIRST-CHAPTER 裁定",
            "commit": False,
        }
    if has("qf_dispatch_gates") and has("format_exit"):
        return {
            "branch": "gates_no_qf",
            "action": "有门禁无 qf_enter；对照 af_main_hb / appState / pulse",
            "commit": False,
        }
    if has("format_enter") and has("format_exit"):
        return {
            "branch": "format_no_qf",
            "action": "仍停在 format 后；查主队列心跳是否停",
            "commit": False,
        }
    return {
        "branch": "earlier_or_unknown",
        "action": "停在更早标签；只交取证",
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
        "hypothesis": "AF",
        "role": "AF-main-queue-drain-no-inThread",
        "model": "cursor-grok-4.5",
        "mock": MOCK,
        "mcp": MCP,
        "banned": ["bounce", "dontFormat", "callback_inThread_inject"],
        "steps": [],
        "frontmost_log": [],
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
    except Exception:
        pass
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE}, timeout=30)
    time.sleep(2)
    ensure_reader_front(c, report, "post_launch")
    dismiss_reader_only(c, report)
    # 先等 install_done，再清探针，避免误读旧 format_exit / 装钩竞态
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
    ensure_reader_front(c, report, "post_import")
    dismiss_reader_only(c, report)
    time.sleep(1)
    clear_all(c)
    dismiss_reader_only(c, report)
    ensure_reader_front(c, report, "pre_nativeRead")

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
    # nativeRead 后立刻拉回前台，防止短信/他 App 抢焦点导致主队列挂起
    time.sleep(0.8)
    ensure_reader_front(c, report, "post_nativeRead")

    polls = []
    for i in range(60):
        time.sleep(0.5)
        if i in (2, 6, 12, 20):
            ensure_reader_front(c, report, f"poll_{i}")
            dismiss_reader_only(c, report)
        probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=300000) or ""
        st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=300000) or ""
        blob = probe + "\n" + st
        ac = [ln for ln in blob.splitlines() if "hypothesis_AC" in ln]
        rt = [ln for ln in ac if "install_" not in ln]
        polls.append(
            {
                "t": round(time.time() - t0, 2),
                "ac_runtime_n": len(rt),
                "ac_last": rt[-1] if rt else (ac[-1] if ac else None),
                "front": frontmost(c).get("bundleId"),
            }
        )
        if rt and any(
            k in (rt[-1] or "")
            for k in (
                "qf_exit",
                "qf_enter",
                "qf_dispatch_main_pulse",
                "af_main_hb",
                "cb_exit",
                "format_exit",
                "fatal_signal",
            )
        ):
            # 给主队列 async QF / pulse / hb 留时间，并保持前台
            for _ in range(6):
                ensure_reader_front(c, report, "post_hit_hold")
                time.sleep(0.5)
            break

    # 最终前台硬断言
    fm_final = ensure_reader_front(c, report, "pre_assert")
    reader_ok = is_reader_front(fm_final)
    bid_final = str(fm_final.get("bundleId") or "")
    if any(x in bid_final for x in FORBIDDEN_FRONT) or (
        bid_final and bid_final != BUNDLE
    ):
        reader_ok = False

    probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=300000) or ""
    st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=300000) or ""
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or ""
    try:
        if reader_ok:
            c.call("open_url", {"url": "legado://debugDump?phase=af_accept"}, timeout=20)
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
    hb = [ln for ln in ac_all if "af_main_hb" in ln]
    install_after = [ln for ln in ac_all if "install_done" in ln or "install_qf" in ln]

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

    tags = ac_runtime[-50:] if ac_runtime else ac_all[-50:]
    decision = decide(tags, has_qf=has_qf, has_fatal=has_fatal, reader_ok=reader_ok)
    first_chapter = bool(
        reader_ok
        and isinstance(xiaoyan, dict)
        and xiaoyan.get("passed")
        and has_qf
        and any("format_exit" in ln for ln in ac_all)
        and any("path=async_main" in ln for ln in ac_all)
        and not any("qf_dispatch_inject_inThread" in ln for ln in ac_all)
    )
    gates = [ln for ln in ac_all if "qf_dispatch_gates" in ln]

    sync = {
        "sha": sha,
        "probe_last_line": probe_lines[-1] if probe_lines else "",
        "af_last_runtime": ac_runtime[-1] if ac_runtime else (ac_all[-1] if ac_all else ""),
        "af_runtime": ac_runtime[-50:],
        "qf_dispatch_gates": gates[-8:],
        "has_qf": has_qf,
        "qf_n": qf_n,
        "has_qf_enter": any("qf_enter" in ln for ln in ac_all),
        "has_qf_exit": any("qf_exit" in ln for ln in ac_all),
        "has_main_pulse": any("qf_dispatch_main_pulse" in ln for ln in ac_all),
        "has_main_hb": len(hb) > 0,
        "main_hb_n": len(hb),
        "main_hb_tail": hb[-6:],
        "has_drain_slot": any("af_main_drain_slot" in ln for ln in ac_all),
        "has_drain_ok": any("af_main_drain_ok" in ln for ln in ac_all),
        "has_drain_timeout": any("af_main_drain_TIMEOUT" in ln for ln in ac_all),
        "has_drain_wait_ok": any("af_main_drain_wait_ok" in ln for ln in ac_all),
        "has_async_plus": any("async_plus0.6s_enter" in ln for ln in ac_all),
        "pids": sorted(
            {
                ln.split("pid=")[-1].split()[0]
                for ln in ac_all
                if "pid=" in ln
            }
        )[:8],
        "has_format_enter": any("format_enter" in ln for ln in ac_all),
        "has_format_exit": any("format_exit" in ln for ln in ac_all),
        "has_cb_enter": any("cb_enter" in ln for ln in ac_all),
        "has_cb_exit": any("cb_exit" in ln for ln in ac_all),
        "has_no_inThread_inject": any("af_no_inThread_inject" in ln for ln in ac_all),
        "has_inject_inThread": any("qf_dispatch_inject_inThread" in ln for ln in ac_all),
        "path_async_main": any("path=async_main" in ln for ln in ac_all),
        "path_sync_inThread": any("path=sync_inThread" in ln for ln in ac_all),
        "has_fatal": has_fatal,
        "reader_foreground": reader_ok,
        "frontmost_final": fm_final,
        "xiaoyan": xiaoyan,
        "ui_texts": ui_texts[:20],
        "decision": decision,
        "first_chapter_approved": first_chapter,
        "install_qf": any("install_qf owner=ReadPageContainer" in ln for ln in ac_all),
        "reinstall_suspect": len(install_after) > 4,
        "app_state_tags": [ln for ln in ac_all if "app=" in ln][-12:],
    }
    report["polls"] = polls[-10:]
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
