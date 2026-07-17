#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 J 验收：defer addChild/insertSubview + ORIG_OK + H leave + pageContainerA。"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.ios_mcp_client import McpClient

MCP = "http://192.168.1.6:8090"
MOCK = "http://192.168.1.4:8765"
BUNDLE = "com.appbox.StandarReader"
OUT = ROOT / "fixtures" / "_accept_hypothesis_j.json"


def git_sha() -> str:
    r = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return (r.stdout or "").strip() or "unknown"


def resolve_ipa() -> Path:
    if len(sys.argv) > 1:
        p = Path(sys.argv[1])
        if p.is_file():
            return p
    env = __import__("os").environ.get("HYPOTHESIS_J_IPA")
    if env:
        p = Path(env)
        if p.is_file():
            return p
    for pat in (
        "dist-ci-run-*/Reader-Forensics-IPAs/dist/StandarReader-legado-debug.ipa",
        "dist-ci-run-*/dist/StandarReader-legado-bridge-debug.ipa",
        "dist-ci-run-*/dist/dist/StandarReader-legado-bridge-debug.ipa",
        "dist-ci-run-*/dist/StandarReader-legado-debug.ipa",
        "fixtures/_devkit/ci-artifact/**/StandarReader-legado-bridge-debug.ipa",
        "dist/StandarReader-legado-bridge-debug.ipa",
        "dist/StandarReader-legado-debug.ipa",
    ):
        hits = sorted(ROOT.glob(pat), key=lambda x: x.stat().st_mtime, reverse=True)
        if hits:
            return hits[0]
    raise FileNotFoundError(
        "未找到 legado-bridge-debug IPA，请设置 HYPOTHESIS_J_IPA 或先下载 CI artifact"
    )


def clear_all(c: McpClient) -> None:
    paths = c.app_paths()
    doc = paths.get("documents", "")
    for p in c.open_once_candidates(paths):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10})
        except Exception:
            pass
    if doc:
        for n in (
            "legado_openreader_trace.txt",
            "legado_loadcurcp_state.txt",
            "legado_catalog_openreader.txt",
            "legado_debug_dump.txt",
            "legado_native_open_once.txt",
        ):
            try:
                c.call("run_command", {"command": f"rm -f '{doc}/{n}'", "timeout_sec": 10})
            except Exception:
                pass


def parse_container_a(line: str) -> str | None:
    for pat in (
        r"hypothesis_J deferred_attach_OK .* pageContainerA=(\S+)",
        r"hypothesis_E after_ORIG pageContainerA=(\S+)",
        r"hypothesis_B2 probe phase=onReset_noArg_after_ORIG pageContainerA=(\S+)",
    ):
        m = re.search(pat, line)
        if m:
            return m.group(1)
    return None


def main() -> int:
    ipa = resolve_ipa()
    sha = git_sha()

    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report: dict = {
        "sha": sha,
        "ipa": str(ipa),
        "steps": [],
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "role": "integrator",
        "hypothesis": "J",
        "model": "composer-2.5",
    }

    up = c.upload_file(ipa, filename=ipa.name)
    dp = up.get("path") if isinstance(up, dict) else str(up)
    report["install"] = c.call("install_app", {"path": dp}, timeout=600)
    report["steps"].append("install")
    time.sleep(3)

    clear_all(c)
    c.call("wake_and_home")
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(2)
    clear_all(c)
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
    report["steps"].append("nativeRead")
    time.sleep(12)

    trace = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=400000)
    state = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=150000)
    blob = (trace or "") + "\n" + (state or "")

    j_lines = [ln for ln in blob.splitlines() if "hypothesis_J" in ln]
    h_lines = [ln for ln in blob.splitlines() if "hypothesis_H" in ln]
    c_lines = [ln for ln in blob.splitlines() if "hypothesis_C" in ln]

    report["j_lines"] = j_lines
    report["defer_addChild"] = [ln for ln in j_lines if "defer_addChild" in ln]
    report["deferred_attach_OK"] = [ln for ln in j_lines if "deferred_attach_OK" in ln]
    report["j_hook_lines"] = [
        ln for ln in j_lines if "hooked addChildViewController" in ln or "hooked insertSubview" in ln
    ]
    report["enter_lines"] = [ln for ln in h_lines if "hypothesis_H enter" in ln]
    report["leave_lines"] = [ln for ln in h_lines if "hypothesis_H leave" in ln and "leave EX" not in ln]
    report["onreset_ok"] = [ln for ln in c_lines if "ORIG_OK" in ln]

    container_vals = [v for v in (parse_container_a(ln) for ln in blob.splitlines()) if v]
    report["pageContainerA_cls"] = container_vals[-1] if container_vals else None
    report["pageContainerA_non_nil"] = bool(
        report["pageContainerA_cls"] and report["pageContainerA_cls"] != "nil"
    )

    try:
        cr = c.call("get_crash_logs", timeout=30)
        report["crash"] = str(cr)[:500]
    except Exception as exc:
        report["crash"] = str(exc)

    snaps = []
    for cp in (1.0, 3.0, 5.0, 8.0):
        time.sleep(1.5)
        try:
            ui = c.call("get_ui_elements", {"limit": 30}, timeout=30)
            texts = [
                e.get("text", "")
                for e in (ui.get("elements") or [])
                if e.get("text")
            ][:10]
        except Exception as exc:
            texts = [str(exc)]
        snaps.append({"t": cp, "texts": texts})
    report["snaps"] = snaps

    on_shelf = any("书架" in t or "空列表" in t for s in snaps for t in s["texts"])
    springboard = any(
        t in ("日历", "计算器", "时钟", "指南针", "地图", "钱包", "设置")
        for s in snaps
        for t in s["texts"]
    )
    report["springboard_or_shelf"] = on_shelf or springboard
    report["on_shelf"] = on_shelf
    report["springboard"] = springboard

    has_defer = bool(report["defer_addChild"])
    has_attach = bool(report["deferred_attach_OK"])
    has_orig_ok = bool(report["onreset_ok"])
    has_leave = bool(report["leave_lines"])
    has_enter = bool(report["enter_lines"])

    if springboard or on_shelf:
        report["verdict"] = "FAIL_REVERT_J"
        report["conclusion"] = "回书架或 springboard，应 revert J"
    elif has_orig_ok and has_leave and has_defer and has_attach and report["pageContainerA_non_nil"]:
        report["verdict"] = "PASS_J"
        report["conclusion"] = "defer+flush+ORIG_OK+H leave+pageContainerA"
    elif has_orig_ok and has_defer and has_attach:
        report["verdict"] = "PARTIAL_J_NO_CONTAINER"
        report["conclusion"] = "ORIG_OK+defer flush 但 pageContainerA 仍 nil"
    elif has_orig_ok and has_defer and not has_attach:
        report["verdict"] = "PARTIAL_J_NO_FLUSH"
        report["conclusion"] = "defer 已记录但未 flush"
    elif has_enter and not has_orig_ok:
        report["verdict"] = "FAIL_J_KILL"
        report["conclusion"] = "H enter 但无 ORIG_OK（D 类杀点）"
    elif not has_defer:
        report["verdict"] = "FAIL_J_NO_DEFER"
        report["conclusion"] = "未命中 defer_addChild"
    else:
        report["verdict"] = "FAIL"
        report["conclusion"] = "未满足 J 信号组合"

    report["handoff"] = {
        "role": "integrator",
        "hypothesis": "J",
        "model": "composer-2.5",
        "input_sha": "143d919",
        "output_sha": sha,
        "verdict": report["verdict"],
        "orig_ok": has_orig_ok,
        "enter_count": len(report["enter_lines"]),
        "leave_count": len(report["leave_lines"]),
        "pageContainerA": report["pageContainerA_cls"],
        "on_shelf": on_shelf,
        "springboard": springboard,
        "next_step": (
            "PASS_J → 继续渲染链（loadCurCp/division）"
            if report["verdict"] == "PASS_J"
            else "FAIL_REVERT_J → git revert J commit"
            if report["verdict"] == "FAIL_REVERT_J"
            else "PARTIAL → 分析 trace 再叠下一假设"
        ),
    }

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if report["verdict"] == "PASS_J":
        return 0
    if report["verdict"] in ("PARTIAL_J_NO_CONTAINER", "PARTIAL_J_NO_FLUSH"):
        return 5
    if report["verdict"] == "FAIL_REVERT_J":
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
