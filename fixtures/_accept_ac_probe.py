#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AC 探针验收：装当前 CI Debug IPA → 清 openOnce → nativeRead → 同步读 check_* 末行。"""
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
OUT = ROOT / "fixtures" / "_accept_ac_probe.json"
SYNC = ROOT / "fixtures" / "_accept_ac_probe_sync.json"


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


def decide(tags: list[str], has_qf: bool, has_fatal: bool) -> dict:
    has = lambda k: any(k in ln for ln in tags)
    if has_fatal or any("fatal_signal" in ln for ln in tags):
        return {
            "branch": "fatal_signal_or_watchdog",
            "action": "写 watchdog 结论，勿叠 bounce/dontFormat",
            "commit": False,
        }
    if has("check_early_return reason=check_failed") or (
        has("check_exit ok=0") and not has("format_enter")
    ):
        return {
            "branch": "check_failed_early_return",
            "action": "一 commit 修数据/config 使 check 通过",
            "commit": True,
            "fix": "check_data_config",
        }
    if has("check_exit ok=1") and has("format_enter") and not has("format_exit"):
        return {
            "branch": "format_enter_no_exit",
            "action": "下一刀打 format 内；本回合只交探针",
            "commit": False,
        }
    if has("check_exit ok=1") and has("format_exit") and has("cb_exit"):
        if has_qf:
            return {
                "branch": "check_format_cb_qf",
                "action": "CB→QF 已通，按萧炎/FIRST-CHAPTER 裁定",
                "commit": False,
            }
        return {
            "branch": "cb_exit_no_qf",
            "action": "一 commit 只查 target/主队列派发（禁 bounce）",
            "commit": True,
            "fix": "target_dispatch",
        }
    if has("cb_enter") and not has("check_enter"):
        return {
            "branch": "cb_enter_no_check",
            "action": "仍卡在 next 链；查 install_cb_peeled / reentry",
            "commit": False,
        }
    if has("cb_enter") and has("check_enter") and not has("check_exit"):
        return {
            "branch": "check_enter_no_exit",
            "action": "死在 original check 内；下一刀",
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
        # 允许环境变量 / 最近成功 artifact 目录
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
        "hypothesis": "AC",
        "role": "AC-check-early-return-probe",
        "model": "cursor-grok-4.5",
        "mock": MOCK,
        "mcp": MCP,
        "reverted_6b5ef8e": True,
        "banned": ["bounce", "dontFormat"],
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
        blob = probe + "\n" + st
        ac = [ln for ln in blob.splitlines() if "hypothesis_AC" in ln]
        rt = [ln for ln in ac if "install_" not in ln]
        polls.append(
            {
                "t": round(time.time() - t0, 2),
                "ac_runtime_n": len(rt),
                "ac_last": rt[-1] if rt else (ac[-1] if ac else None),
            }
        )
        if rt and any(
            k in (rt[-1] or "")
            for k in (
                "cb_exit",
                "format_exit",
                "format_enter",
                "check_exit",
                "check_early_return",
                "fatal_signal",
                "cb_enter",
            )
        ):
            time.sleep(2.5)
            break

    probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=300000) or ""
    st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=300000) or ""
    tr = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=200000) or ""
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or ""
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=ac_accept"}, timeout=20)
        time.sleep(1.5)
        dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or dump
    except Exception as exc:
        report["dump_err"] = str(exc)

    probe_lines = [ln for ln in probe.splitlines() if ln.strip()]
    probe_last = probe_lines[-1] if probe_lines else ""
    ac_all = [ln for ln in (probe + "\n" + st).splitlines() if "hypothesis_AC" in ln]
    ac_runtime = [ln for ln in ac_all if "install_" not in ln]
    has_qf = "lpNetWorkDelegateQueryFinish" in (probe + st + dump)
    cb_dump = [
        ln
        for ln in dump.splitlines()
        if "callBackResponse:config:userInfo:" in ln
        or "lpNetWorkDelegateQueryFinish" in ln
    ]
    has_fatal = any("fatal_signal" in ln for ln in ac_all)

    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000}, timeout=20)
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

    decision = decide(ac_runtime or ac_all, has_qf, has_fatal)
    first_chapter = bool(isinstance(xiaoyan, dict) and xiaoyan.get("passed") and has_qf)

    sync = {
        "probe_last_line": probe_last,
        "ac_last_runtime": ac_runtime[-1] if ac_runtime else None,
        "ac_runtime": ac_runtime[-80:],
        "ac_all_tail": ac_all[-30:],
        "has_qf": has_qf,
        "qf_n": sum(1 for ln in dump.splitlines() if "lpNetWorkDelegateQueryFinish" in ln),
        "cb_dump_n": len(cb_dump),
        "has_check_enter": any("check_enter" in ln for ln in ac_runtime),
        "has_check_exit": any("check_exit" in ln for ln in ac_runtime),
        "has_check_early_return": any("check_early_return" in ln for ln in ac_runtime),
        "has_format_enter": any("format_enter" in ln for ln in ac_runtime),
        "has_format_exit": any("format_exit" in ln for ln in ac_runtime),
        "has_cb_enter": any("cb_enter" in ln for ln in ac_runtime),
        "has_cb_exit": any("cb_exit" in ln for ln in ac_runtime),
        "has_fatal": has_fatal,
        "xiaoyan": xiaoyan,
        "ui_texts": ui_texts,
        "frontmost": fm,
        "crashes": crashes,
        "decision": decision,
        "first_chapter_approved": first_chapter,
        "reverted_6b5ef8e": True,
    }
    report.update(
        {
            "polls_n": len(polls),
            "polls_tail": polls[-8:],
            "probe_last_line": probe_last,
            "probe_tail": probe_lines[-40:],
            "state_tail": st.splitlines()[-60:],
            "trace_tail": tr.splitlines()[-40:],
            "ac_all": ac_all,
            "ac_runtime": ac_runtime,
            "decision": decision,
            "has_qf": has_qf,
            "qf_n": sync["qf_n"],
            "cb_dump_n": sync["cb_dump_n"],
            "xiaoyan": xiaoyan,
            "ui_texts": ui_texts,
            "frontmost": fm,
            "crashes": crashes,
            "first_chapter_approved": first_chapter,
        }
    )
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    SYNC.write_text(json.dumps(sync, ensure_ascii=False, indent=2), encoding="utf-8")
    print(
        json.dumps(
            {
                "out": str(OUT),
                "sync": str(SYNC),
                "sha": sha,
                "probe_last_line": probe_last,
                "ac_last_runtime": sync["ac_last_runtime"],
                "decision": decision,
                "has_qf": has_qf,
                "qf_n": sync["qf_n"],
                "cb_dump_n": sync["cb_dump_n"],
                "xiaoyan": xiaoyan,
                "first_chapter_approved": first_chapter,
                "reverted_6b5ef8e": True,
                "check_flags": {
                    k: sync[k]
                    for k in (
                        "has_check_enter",
                        "has_check_exit",
                        "has_check_early_return",
                        "has_format_enter",
                        "has_cb_exit",
                    )
                },
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
