#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 I 验收：fire 时解包真 native IMP + hypothesis_H enter 观察。"""
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
OUT = ROOT / "fixtures" / "_accept_hypothesis_i.json"


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
    env = __import__("os").environ.get("HYPOTHESIS_I_IPA")
    if env:
        p = Path(env)
        if p.is_file():
            return p
    for pat in (
        "dist-ci-run-*/dist/StandarReader-legado-bridge-debug.ipa",
        "dist-ci-run-*/dist/dist/StandarReader-legado-bridge-debug.ipa",
        "dist-ci-run-*/dist/StandarReader-legado-debug.ipa",
        "fixtures/_devkit/ci-artifact/**/StandarReader-legado-bridge-debug.ipa",
        "dist/StandarReader-legado-bridge-debug.ipa",
    ):
        hits = sorted(ROOT.glob(pat), key=lambda x: x.stat().st_mtime, reverse=True)
        if hits:
            return hits[0]
    raise FileNotFoundError(
        "未找到 legado-bridge-debug IPA，请设置 HYPOTHESIS_I_IPA 或先下载 CI artifact"
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


def parse_enter(line: str) -> dict | None:
    m = re.search(
        r"hypothesis_H enter cls=(\S+) hookOwner=(\S+) cat=(\d+) type=(-?\d+) bd8=(0x[0-9a-fA-F]+) a=(\S+)",
        line,
    )
    if not m:
        return None
    return {
        "cls": m.group(1),
        "hookOwner": m.group(2),
        "cat": int(m.group(3)),
        "type": int(m.group(4)),
        "bd8": m.group(5),
        "a": m.group(6),
    }


def parse_i_fire(line: str) -> dict | None:
    m = re.search(
        r"hypothesis_I fire orig=(0x[0-9a-fA-F]+) resolved=(0x[0-9a-fA-F]+) dl=(\S+)",
        line,
    )
    if not m:
        return None
    return {
        "orig": m.group(1),
        "resolved": m.group(2),
        "dl": m.group(3),
    }


def main() -> int:
    ipa = resolve_ipa()
    sha = git_sha()

    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report: dict = {
        "sha": sha,
        "ipa": str(ipa),
        "steps": [],
        "timestamp": datetime.now(timezone.utc).isoformat(),
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

    h_lines = [ln for ln in blob.splitlines() if "hypothesis_H" in ln]
    i_lines = [ln for ln in blob.splitlines() if "hypothesis_I" in ln]
    c_lines = [ln for ln in blob.splitlines() if "hypothesis_C" in ln]

    report["h_lines"] = h_lines
    report["i_lines"] = i_lines
    report["enter_lines"] = [ln for ln in h_lines if "hypothesis_H enter" in ln]
    report["leave_lines"] = [ln for ln in h_lines if "hypothesis_H leave" in ln]
    report["hook_lines"] = [ln for ln in h_lines if "hypothesis_H hooked" in ln]
    report["i_fire_lines"] = [ln for ln in i_lines if "hypothesis_I fire" in ln]
    report["onreset_ok"] = [ln for ln in c_lines if "ORIG_OK" in ln]

    report["enter_parsed"] = [e for e in (parse_enter(ln) for ln in report["enter_lines"]) if e]
    report["i_fire_parsed"] = [e for e in (parse_i_fire(ln) for ln in report["i_fire_lines"]) if e]
    report["enter_count"] = len(report["enter_lines"])
    report["leave_count"] = len(report["leave_lines"])
    report["getter_called"] = report["enter_count"] > 0

    last_fire = report["i_fire_parsed"][-1] if report["i_fire_parsed"] else None
    report["resolved_dl"] = last_fire["dl"] if last_fire else None
    report["resolved_in_app"] = bool(
        last_fire and last_fire["dl"] and "StandarReader" in last_fire["dl"]
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

    has_i_fire = bool(report["i_fire_lines"])
    has_orig_ok = bool(report["onreset_ok"])

    if springboard and not report["getter_called"]:
        report["verdict"] = "FAIL_REVERT_I_SPRINGBOARD"
        report["conclusion"] = "SPRINGBOARD_REVERT"
    elif springboard:
        report["verdict"] = "FAIL_SPRINGBOARD"
        report["conclusion"] = "SPRINGBOARD_WITH_ENTER"
    elif report["getter_called"] and has_i_fire and has_orig_ok:
        report["verdict"] = "PASS_I_H_ENTER"
        report["conclusion"] = "I_RESOLVED_AND_H_ENTER"
    elif has_i_fire and has_orig_ok and report["resolved_in_app"]:
        report["verdict"] = "PASS_I_STILL_NO_ENTER"
        report["conclusion"] = "I_RESOLVED_APP_IMP_ZERO_ENTER"
    elif not has_i_fire:
        report["verdict"] = "FAIL_I_NO_FIRE_LOG"
        report["conclusion"] = "MISSING_HYPOTHESIS_I_FIRE"
    elif not has_orig_ok:
        report["verdict"] = "FAIL_I_NO_ORIG_OK"
        report["conclusion"] = "MISSING_ORIG_OK"
    else:
        report["verdict"] = "PARTIAL"
        report["conclusion"] = "UNKNOWN"

    report["handoff"] = {
        "commit": sha,
        "enter_count": report["enter_count"],
        "leave_count": report["leave_count"],
        "resolved_dl": report["resolved_dl"],
        "springboard": springboard,
        "i_fire": report["i_fire_lines"],
        "enter": report["enter_lines"],
        "next_step": (
            "PASS_I_H_ENTER → 继续渲染链"
            if report["verdict"] == "PASS_I_H_ENTER"
            else "PASS_I_STILL_NO_ENTER → resolved 已是 App IMP，停"
            if report["verdict"] == "PASS_I_STILL_NO_ENTER"
            else "FAIL_REVERT_I_SPRINGBOARD → revert"
        ),
    }

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    ok_verdicts = {"PASS_I_H_ENTER", "PASS_I_STILL_NO_ENTER"}
    return 0 if report["verdict"] in ok_verdicts else 1


if __name__ == "__main__":
    raise SystemExit(main())
