#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 H 验收：VC3/VC2/VC1 全挂 pageContainer 只观察 swizzle。"""
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
OUT = ROOT / "fixtures" / "_accept_hypothesis_h.json"


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
    env = __import__("os").environ.get("HYPOTHESIS_H_IPA")
    if env:
        p = Path(env)
        if p.is_file():
            return p
    for pat in (
        "dist-ci-run-*/dist/StandarReader-legado-bridge-debug.ipa",
        "dist-ci-run-*/dist/dist/StandarReader-legado-bridge-debug.ipa",
        "dist-ci-run-*/dist/StandarReader-legado-debug.ipa",
        "fixtures/_devkit/ci-artifact/**/StandarReader-legado-debug.ipa",
        "dist/StandarReader-legado-debug.ipa",
    ):
        hits = sorted(ROOT.glob(pat), key=lambda x: x.stat().st_mtime, reverse=True)
        if hits:
            return hits[0]
    raise FileNotFoundError("未找到 legado-debug IPA，请设置 HYPOTHESIS_H_IPA 或先下载 CI artifact")


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


def parse_leave(line: str) -> dict | None:
    m = re.search(
        r"hypothesis_H leave cls=(\S+) hookOwner=(\S+) ret=(\S+) children=(\d+)",
        line,
    )
    if not m:
        return None
    return {
        "cls": m.group(1),
        "hookOwner": m.group(2),
        "ret": m.group(3),
        "children": int(m.group(4)),
    }


def parse_hooked(line: str) -> str | None:
    m = re.search(r"hypothesis_H hooked pageContainer on (\S+)", line)
    return m.group(1) if m else None


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
    f_lines = [ln for ln in blob.splitlines() if "hypothesis_F" in ln]
    c_lines = [ln for ln in blob.splitlines() if "hypothesis_C" in ln]
    report["h_lines"] = h_lines
    report["enter_lines"] = [ln for ln in h_lines if "hypothesis_H enter" in ln]
    report["leave_lines"] = [ln for ln in h_lines if "hypothesis_H leave" in ln]
    report["hook_lines"] = [ln for ln in h_lines if "hypothesis_H hooked" in ln]
    report["f_lines"] = f_lines
    report["c_lines"] = c_lines
    report["onreset_ok"] = [ln for ln in blob.splitlines() if "hypothesis_C" in ln and "ORIG_OK" in ln]
    report["f_miss"] = [ln for ln in f_lines if "hypothesis_F miss" in ln]

    hooked_classes = [parse_hooked(ln) for ln in report["hook_lines"]]
    report["hooked_classes"] = [x for x in hooked_classes if x]

    enters = [parse_enter(ln) for ln in report["enter_lines"]]
    leaves = [parse_leave(ln) for ln in report["leave_lines"]]
    report["enter_parsed"] = [e for e in enters if e]
    report["leave_parsed"] = [e for e in leaves if e]

    report["getter_called"] = bool(report["enter_lines"])
    report["getter_call_count"] = len(report["enter_lines"])

    conclusion = "UNKNOWN"
    if report["getter_call_count"] == 0 and report["onreset_ok"]:
        conclusion = "H_STILL_NOT_CALLED"
    elif report["enter_parsed"] and report["leave_parsed"]:
        last_enter = report["enter_parsed"][-1]
        last_leave = report["leave_parsed"][-1]
        if last_enter["hookOwner"] in ("TextReadVC3", "TextReadVC2"):
            conclusion = "H_CALLED_SUBCLASS_HOOK"
        elif last_enter["cat"] == 0:
            conclusion = "H_CALLED_CAT0_EARLY_EXIT"
        elif last_leave["ret"] == "nil":
            conclusion = "H_CALLED_RET_NIL"
        elif last_leave["ret"] != "nil" and report["f_miss"]:
            conclusion = "H_CALLED_RET_OK_BUT_IVAR_NOT_WRITTEN"
        elif last_leave["ret"] != "nil" and last_leave["children"] == 0:
            conclusion = "H_CALLED_RET_OK_NO_CHILD"
        else:
            conclusion = "H_CALLED_RET_OK"
    report["conclusion"] = conclusion

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

    if springboard and not report["getter_called"]:
        report["verdict"] = "FAIL_REVERT_H_SWIZZLE"
    elif springboard:
        report["verdict"] = "FAIL_SPRINGBOARD"
    elif report["getter_called"] and report["onreset_ok"]:
        report["verdict"] = "PASS_H_OBSERVE"
    elif not report["getter_called"] and report["onreset_ok"]:
        report["verdict"] = "PASS_H_STILL_NOT_CALLED"
    elif not report["onreset_ok"]:
        report["verdict"] = "FAIL_H_NO_ORIG_OK"
    else:
        report["verdict"] = "PARTIAL"

    report["handoff"] = {
        "commit": sha,
        "hooked_classes": report["hooked_classes"],
        "enter_leave_raw": {
            "enter": report["enter_lines"],
            "leave": report["leave_lines"],
            "hook": report["hook_lines"],
        },
        "enter_count": report["getter_call_count"],
        "leave_count": len(report["leave_lines"]),
        "onreset_context": [
            ln
            for ln in blob.splitlines()
            if any(
                k in ln
                for k in (
                    "onReset noArg enter",
                    "hypothesis_E pre_fire",
                    "hypothesis_C fire_onReset",
                    "hypothesis_C onReset",
                    "hypothesis_F",
                )
            )
        ],
        "explains_G_gap": (
            "若 VC3/VC2 enter>0 → G 漏挂继承链；"
            "若仍零 enter → direct-IMP 或 EarlyWrap 绕 msgSend"
        ),
        "next_step": (
            "PASS_H_STILL_NOT_CALLED 时查 direct-IMP / EarlyWrap（本回合不叠）"
        ),
    }

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    ok_verdicts = {"PASS_H_OBSERVE", "PASS_H_STILL_NOT_CALLED"}
    return 0 if report["verdict"] in ok_verdicts else 1


if __name__ == "__main__":
    raise SystemExit(main())
