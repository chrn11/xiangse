#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AB 探针验收：装 903846e CI Debug IPA → 清 openOnce → nativeRead → 同步读末行。"""
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
OUT = ROOT / "fixtures" / "_accept_route_b.json"
SYNC = ROOT / "fixtures" / "_accept_ab_probe_sync.json"
CI_RUN = "29641331227"
EXPECT_SHA = "903846e"


def git_sha() -> str:
    r = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return (r.stdout or "").strip() or "unknown"


def dismiss(c: McpClient) -> None:
    for _ in range(4):
        try:
            els = c.call("get_ui_elements", timeout=20) or {}
            blob = json.dumps(els, ensure_ascii=False)
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
    for p in c.open_once_candidates(paths):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 8}, timeout=15)
        except Exception:
            pass
    if doc:
        for name in (
            "legado_ab_probe.txt",
            "legado_loadcurcp_state.txt",
            "legado_loadcurcp_trace.txt",
            "legado_openreader_trace.txt",
            "legado_debug_dump.txt",
            "legado_catalog_openreader.txt",
            "legado_native_open_once.txt",
            "legado_lifecycle_pop_trace.txt",
        ):
            try:
                c.call(
                    "run_command",
                    {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 8},
                    timeout=15,
                )
            except Exception:
                pass
    return doc


def decide(ab_tags: list[str], has_qf: bool, has_fatal: bool) -> dict:
    has = lambda k: any(k in ln for ln in ab_tags)
    if has_fatal or any("fatal_signal" in ln for ln in ab_tags):
        return {
            "branch": "fatal_signal_or_watchdog",
            "action": "写 watchdog/Jetsam 结论，勿再叠 AA bounce",
            "commit": False,
        }
    if has("format_enter") and not has("format_exit"):
        return {
            "branch": "format_enter_no_exit",
            "action": "一 commit：仅 inject callback_dontFormatResponse、禁 bounce、关键点 fsync；验 CB/QF",
            "commit": True,
            "fix": "dontFormat",
        }
    if has("cb_exit") and not has_qf:
        return {
            "branch": "cb_exit_no_qf",
            "action": "一 commit 只查 target/主队列派发（禁 bounce）",
            "commit": True,
            "fix": "target_dispatch",
        }
    if has("cb_exit") and has_qf:
        return {
            "branch": "cb_exit_and_qf",
            "action": "CB→QF 已通，按萧炎/FIRST-CHAPTER 裁定",
            "commit": False,
        }
    if has("cb_enter") and not has("format_enter") and not has("cb_exit"):
        return {
            "branch": "cb_enter_early_stop",
            "action": "只交取证，写清下一刀，不要瞎改",
            "commit": False,
        }
    if has("swcf_exit") and not has("cb_enter"):
        return {
            "branch": "swcf_exit_no_cb",
            "action": "notify 前崩；只交取证",
            "commit": False,
        }
    if has("swcf_enter") and not has("swcf_exit"):
        return {
            "branch": "swcf_enter_no_exit",
            "action": "读文件前/中崩；只交取证",
            "commit": False,
        }
    if has("invoke_orig_returned") and not has("swcf_enter"):
        return {
            "branch": "invoke_returned_no_swcf",
            "action": "异步块未启动或更早杀；只交取证",
            "commit": False,
        }
    return {
        "branch": "earlier_or_unknown",
        "action": "停在更早标签；只交取证，不要瞎改",
        "commit": False,
    }


def main() -> int:
    sha = git_sha()
    if not sha.startswith(EXPECT_SHA):
        print(f"WARN: HEAD={sha} expect {EXPECT_SHA}; forcing IPA {EXPECT_SHA}")
    ipa_sha = EXPECT_SHA
    ipa = ROOT / "dist-ci" / ipa_sha / "dist" / "StandarReader-legado-bridge-debug.ipa"
    if not ipa.is_file():
        raise FileNotFoundError(ipa)

    report: dict = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "sha": ipa_sha,
        "head": sha,
        "ipa": str(ipa),
        "ci_run": CI_RUN,
        "ci_conclusion": "success",
        "hypothesis": "AB",
        "role": "AB-probe-accept+one-fix",
        "model": "cursor-grok-4.5",
        "mock": MOCK,
        "mcp": MCP,
        "steps": [],
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
    gc = str(manifest.get("git_commit") or manifest.get("git_sha") or "")
    if gc and not gc.startswith(ipa_sha):
        raise RuntimeError(f"device manifest {gc} != IPA {ipa_sha}")

    c.call("wake_and_home", timeout=30)
    try:
        c.call("kill_app", {"bundle_id": BUNDLE}, timeout=30)
    except Exception:
        pass
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE}, timeout=30)
    time.sleep(2)
    dismiss(c)
    doc = clear_all(c)
    report["doc"] = doc
    report["steps"].append("reset")

    c.call(
        "open_url",
        {"url": f"legado://import/bookSource?src={MOCK}/legado-local-mock.runtime.json"},
        timeout=30,
    )
    time.sleep(2.5)
    dismiss(c)
    time.sleep(1)
    # 再清一次 openOnce，避免 import 写回
    clear_all(c)
    dismiss(c)

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

    polls = []
    for i in range(55):
        time.sleep(0.5)
        if i in (3, 8, 15):
            dismiss(c)
        probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=300000) or ""
        st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=300000) or ""
        tr = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=120000) or ""
        blob = probe + "\n" + st
        ab = [ln for ln in blob.splitlines() if "hypothesis_AB" in ln]
        rt = [ln for ln in ab if "install_" not in ln]
        interesting = [
            ln
            for ln in (st + "\n" + tr).splitlines()
            if any(
                k in ln
                for k in (
                    "invoke",
                    "hypothesis_Z",
                    "hypothesis_AB",
                    "content_",
                    "routeB",
                    "fatal",
                    "nativeRead",
                    "register_orig inv",
                )
            )
        ][-12:]
        polls.append(
            {
                "t": round(time.time() - t0, 2),
                "ab_runtime_n": len(rt),
                "ab_last": rt[-1] if rt else (ab[-1] if ab else None),
                "interesting": interesting[-6:],
            }
        )
        if rt and any(
            k in (rt[-1] or "")
            for k in (
                "cb_exit",
                "format_exit",
                "format_enter",
                "fatal_signal",
                "swcf_exit",
                "cb_enter",
                "async_plus",
            )
        ):
            time.sleep(2.5)
            break
        if i >= 45 and any("invoke_orig" in ln for ln in interesting):
            time.sleep(2)
            break

    # —— 同步读末行 ——
    probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=300000) or ""
    st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=300000) or ""
    tr = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=200000) or ""
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or ""
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=ab_accept"}, timeout=20)
        time.sleep(1.5)
        dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or dump
    except Exception as exc:
        report["dump_err"] = str(exc)

    probe_lines = [ln for ln in probe.splitlines() if ln.strip()]
    probe_last = probe_lines[-1] if probe_lines else ""
    ab_all = [ln for ln in (probe + "\n" + st).splitlines() if "hypothesis_AB" in ln]
    ab_runtime = [ln for ln in ab_all if "install_" not in ln]
    has_qf = "lpNetWorkDelegateQueryFinish" in (probe + st + dump)
    has_fatal = any("fatal_signal" in ln for ln in ab_all)

    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000}, timeout=20)
    except Exception as exc:
        xiaoyan = {"passed": False, "error": str(exc)}
    # 精简 xiaoyan（去掉巨型 screenshot）
    if isinstance(xiaoyan, dict):
        ev = xiaoyan.get("evidence") if isinstance(xiaoyan.get("evidence"), dict) else {}
        xiaoyan = {
            "passed": xiaoyan.get("passed"),
            "text": xiaoyan.get("text"),
            "elements": (ev or {}).get("elements"),
            "error": xiaoyan.get("error"),
        }

    try:
        fm = c.call("get_frontmost_app", timeout=15)
    except Exception as exc:
        fm = {"error": str(exc)}
    try:
        ui = c.call("get_ui_elements", {"limit": 30}, timeout=25)
        ui_texts = [e.get("text") for e in (ui.get("elements") or []) if e.get("text")][:20]
    except Exception as exc:
        ui_texts = [str(exc)]
    try:
        crashes = c.call("get_crash_logs", {"limit": 5}, timeout=40)
        if isinstance(crashes, dict) and "reports" in crashes:
            crashes = {
                "count": crashes.get("count"),
                "names": [r.get("name") for r in (crashes.get("reports") or [])[:8]],
            }
    except Exception as exc:
        crashes = {"error": str(exc)}

    decision = decide(ab_runtime or ab_all, has_qf, has_fatal)
    sync = {
        "probe_last_line": probe_last,
        "ab_last_runtime": ab_runtime[-1] if ab_runtime else None,
        "ab_runtime": ab_runtime,
        "ab_all_tail": ab_all[-20:],
        "state_tail": st.splitlines()[-50:],
        "trace_tail": tr.splitlines()[-40:],
        "has_qf": has_qf,
        "has_cb_enter": any("cb_enter" in ln for ln in ab_runtime),
        "has_cb_exit": any("cb_exit" in ln for ln in ab_runtime),
        "has_format_enter": any("format_enter" in ln for ln in ab_runtime),
        "has_format_exit": any("format_exit" in ln for ln in ab_runtime),
        "has_fatal": has_fatal,
        "xiaoyan": xiaoyan,
        "ui_texts": ui_texts,
        "frontmost": fm,
        "crashes": crashes,
        "decision": decision,
        "manifest": report.get("build_manifest"),
    }
    report.update(
        {
            "polls_n": len(polls),
            "polls_tail": polls[-8:],
            "probe_last_line": probe_last,
            "probe_tail": probe_lines[-40:],
            "state_tail": st.splitlines()[-60:],
            "trace_tail": tr.splitlines()[-40:],
            "ab_all": ab_all,
            "ab_runtime": ab_runtime,
            "ab_last_runtime": sync["ab_last_runtime"],
            "has_qf": has_qf,
            "has_fatal": has_fatal,
            "xiaoyan": xiaoyan,
            "ui_texts": ui_texts,
            "frontmost": fm,
            "crashes": crashes,
            "decision": decision,
            "first_chapter_approved": bool(
                isinstance(xiaoyan, dict) and xiaoyan.get("passed") and has_qf
            ),
            "note_main_has_6b5ef8e": (
                "origin/main 另有 6b5ef8e 撤全局 swcf；本轮按决策树对 903846e 末行裁定"
            ),
        }
    )
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    SYNC.write_text(json.dumps(sync, ensure_ascii=False, indent=2), encoding="utf-8")
    print(
        json.dumps(
            {
                "out": str(OUT),
                "sync": str(SYNC),
                "sha": ipa_sha,
                "probe_last_line": probe_last,
                "ab_last_runtime": sync["ab_last_runtime"],
                "decision": decision,
                "has_qf": has_qf,
                "xiaoyan": xiaoyan,
                "ui_texts": ui_texts,
                "first_chapter_approved": report["first_chapter_approved"],
                "manifest": report.get("build_manifest"),
                "trace_interesting": [
                    ln
                    for ln in tr.splitlines()
                    if any(k in ln for k in ("nativeRead", "routeB", "openOnce", "content"))
                ][-12:],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
