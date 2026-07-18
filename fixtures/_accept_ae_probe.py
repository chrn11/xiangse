#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AE 探针验收：装 CI Debug IPA → 清 openOnce → nativeRead → 读 qf_dispatch_* / qf_enter。"""
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
OUT = ROOT / "fixtures" / "_accept_ae_probe.json"
SYNC = ROOT / "fixtures" / "_accept_ae_probe_sync.json"


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


def decide(tags: list[str], has_qf: bool, has_fatal: bool) -> dict:
    has = lambda k: any(k in ln for ln in tags)
    if has_fatal or any("fatal_signal" in ln for ln in tags):
        return {
            "branch": "fatal_signal_or_watchdog",
            "action": "写 watchdog 结论，勿叠 bounce/dontFormat",
            "commit": False,
        }
    if has("qf_enter") or has_qf:
        return {
            "branch": "qf_reached",
            "action": "format 返回值修复后已进 QF；按萧炎/FIRST-CHAPTER 裁定",
            "commit": False,
        }
    if has("qf_dispatch_gates") and has("format_exit"):
        return {
            "branch": "gates_no_qf",
            "action": "有门禁标签无 qf_enter；按 path=/responds 写下一刀",
            "commit": False,
        }
    if has("format_enter") and has("format_exit"):
        return {
            "branch": "format_no_qf",
            "action": "仍停在 format 后；查 void→id 是否进包",
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
        "hypothesis": "AE",
        "role": "AE-qf-dispatch-after-format",
        "model": "cursor-grok-4.5",
        "mock": MOCK,
        "mcp": MCP,
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
    for i in range(60):
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
                "qf_exit",
                "qf_enter",
                "qf_dispatch_main_pulse",
                "cb_exit",
                "format_exit",
                "fatal_signal",
            )
        ):
            # 给主队列 async QF / pulse 留时间
            time.sleep(3.0)
            break

    probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=300000) or ""
    st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=300000) or ""
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or ""
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=ae_accept"}, timeout=20)
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
        ui = c.call("get_ui_elements", timeout=20) or {}
        ui_texts = []
        for el in (ui.get("elements") or []) if isinstance(ui, dict) else []:
            t = el.get("text") if isinstance(el, dict) else None
            if t:
                ui_texts.append(t)
    except Exception:
        ui_texts = []

    tags = ac_runtime[-50:] if ac_runtime else ac_all[-50:]
    decision = decide(tags, has_qf=has_qf, has_fatal=has_fatal)
    first_chapter = bool(
        isinstance(xiaoyan, dict)
        and xiaoyan.get("passed")
        and has_qf
        and any("format_exit" in ln for ln in ac_all)
    )
    gates = [ln for ln in ac_all if "qf_dispatch_gates" in ln]

    sync = {
        "probe_last_line": probe_lines[-1] if probe_lines else "",
        "ae_last_runtime": ac_runtime[-1] if ac_runtime else (ac_all[-1] if ac_all else ""),
        "ae_runtime": ac_runtime[-40:],
        "ae_all_tail": ac_all[-50:],
        "qf_dispatch_gates": gates[-8:],
        "has_qf": has_qf,
        "qf_n": qf_n,
        "has_qf_enter": any("qf_enter" in ln for ln in ac_all),
        "has_qf_exit": any("qf_exit" in ln for ln in ac_all),
        "has_main_pulse": any("qf_dispatch_main_pulse" in ln for ln in ac_all),
        "has_format_enter": any("format_enter" in ln for ln in ac_all),
        "has_format_exit": any("format_exit" in ln for ln in ac_all),
        "has_cb_enter": any("cb_enter" in ln for ln in ac_all),
        "has_cb_exit": any("cb_exit" in ln for ln in ac_all),
        "has_check_enter": any("check_enter" in ln for ln in ac_all),
        "has_fatal": has_fatal,
        "xiaoyan": xiaoyan,
        "ui_texts": ui_texts[:20],
        "decision": decision,
        "first_chapter_approved": first_chapter,
        "install_qf": any("install_qf owner=ReadPageContainer" in ln for ln in ac_all),
        "format_out_nonzero": any(
            "format_exit outNil=0" in ln and "outLen=0" not in ln for ln in ac_all
        ),
    }
    report["polls"] = polls[-8:]
    report["sync"] = sync
    report["decision"] = decision
    report["first_chapter_approved"] = first_chapter

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    SYNC.write_text(json.dumps(sync, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(sync, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
