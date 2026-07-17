#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 U 验收：invoke 后谁 pop 阅读页；对照 lifecycle trace 与 invoke 时序。"""
from __future__ import annotations

import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient, McpError

MCP = "http://192.168.1.6:8090"
MOCK = "http://192.168.1.4:8765"
BUNDLE = "com.appbox.StandarReader"
OUT = ROOT / "fixtures" / "_accept_hypothesis_u.json"


def find_ipa(run: str) -> Path:
    cands = list(ROOT.glob(f"dist-ci-run-{run}/**/StandarReader-legado-debug.ipa"))
    if cands:
        return cands[0]
    cands = sorted(ROOT.glob("dist-ci-*/**/StandarReader-legado-debug.ipa"), key=lambda p: p.stat().st_mtime)
    if cands:
        return cands[-1]
    raise FileNotFoundError("StandarReader-legado-debug.ipa not found")


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
            "legado_lifecycle_pop_trace.txt",
            "legado_catalog_openreader.txt",
            "legado_debug_dump.txt",
            "legado_native_open_once.txt",
            "forensics_hook_ping.txt",
        ):
            try:
                c.call("run_command", {"command": f"rm -f '{doc}/{n}'", "timeout_sec": 10})
            except Exception:
                pass
    caches = paths.get("caches", "")
    if caches:
        try:
            c.call(
                "run_command",
                {"command": f"rm -f '{caches}/legado_native_open_once.txt'", "timeout_sec": 10},
            )
        except Exception:
            pass


def parse_ts(ln: str) -> str | None:
    m = re.match(r"^(\d{4}-\d{2}-\d{2}T[\d:.]+Z)", ln)
    return m.group(1) if m else None


def main() -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=str, default="")
    ap.add_argument("--ipa", type=Path, default=None)
    args = ap.parse_args()
    ipa = args.ipa or (find_ipa(args.run) if args.run else find_ipa(""))
    sha = __import__("subprocess").check_output(
        ["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True
    ).strip()

    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "sha": sha,
        "ipa": str(ipa),
        "steps": [],
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

    t0 = time.time()
    c.call(
        "open_url",
        {
            "url": f"legado://nativeRead?bookUrl={MOCK}/book/doupo.html&sourceUrl={MOCK}&idx=0"
        },
    )
    report["steps"].append("nativeRead")

    snaps = []
    for cp in (1.0, 2.0, 3.5, 5.0):
        while time.time() - t0 < cp:
            time.sleep(0.05)
        try:
            ui = c.call("get_ui_elements", {"limit": 40}, timeout=40)
        except Exception as e:
            ui = {"error": str(e)}
        texts = []
        if isinstance(ui, dict):
            for el in ui.get("elements") or []:
                if isinstance(el, dict) and el.get("text"):
                    texts.append(str(el["text"])[:40])
        snaps.append({"t": cp, "texts": texts[:12]})
    report["snaps"] = snaps

    try:
        c.call("open_url", {"url": "legado://debugDump?phase=hypothesis_u"})
        report["steps"].append("debugDump")
    except McpError as e:
        report["dump_err"] = str(e)
    time.sleep(1)

    trace = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=200000)
    state = c.read_sandbox_text("legado_loadcurcp_state.txt")
    pop_trace = c.read_sandbox_text("legado_lifecycle_pop_trace.txt", max_bytes=200000)
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=196608)
    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 5000})
    except McpError as e:
        xiaoyan = {"passed": False, "error": str(e)}

    pop_lines = [ln for ln in pop_trace.splitlines() if "hypothesis_U" in ln]
    invoke_ok = [ln for ln in (trace + state).splitlines() if "invoke_orig_OK" in ln]
    gates = [ln for ln in (trace + state).splitlines() if "hypothesis_R gates" in ln or "curCp@r=" in ln]
    disappear = [ln for ln in pop_lines if "viewWillDisappear" in ln or "viewDidDisappear" in ln]
    dealloc = [ln for ln in pop_lines if " dealloc " in ln or "before dealloc" in ln]
    nav_pop = [ln for ln in pop_lines if "popViewController" in ln or "popToRoot" in ln or "popToViewController" in ln]
    set_vcs = [ln for ln in pop_lines if "setViewControllers" in ln]

    invoke_ts = parse_ts(invoke_ok[0]) if invoke_ok else None
    first_pop_ts = None
    for ln in disappear + nav_pop + dealloc:
        ts = parse_ts(ln)
        if ts:
            first_pop_ts = ts
            break

    pop_after_invoke = bool(invoke_ts and first_pop_ts and first_pop_ts >= invoke_ts)
    pop_cause_hint = "unknown"
    if nav_pop:
        pop_cause_hint = "nav_pop"
    elif set_vcs:
        pop_cause_hint = "setViewControllers"
    elif disappear and not nav_pop:
        pop_cause_hint = "vc_disappear_without_nav_pop"
    elif dealloc:
        pop_cause_hint = "reader_dealloc"

    # 从 backtrace 提取 StandarReader 帧
    bt_frames: list[str] = []
    for ln in pop_lines:
        if "bt=" not in ln:
            continue
        part = ln.split("bt=", 1)[1]
        for frag in part.split(" | "):
            if "StandarReader" in frag and frag not in bt_frames:
                bt_frames.append(frag.strip()[:120])
    bt_frames = bt_frames[:8]

    counts = {}
    for k in ("TextReadTV", "ReadPageModel", "TextReadVC3"):
        m = re.search(rf"{k} count=(\d+)", dump)
        counts[k] = int(m.group(1)) if m else 0

    on_shelf = any("空列表" in t for s in snaps for t in s.get("texts") or [])
    attached_invoke = any("attached=1" in ln and "pre_invoke" in ln for ln in (trace + state).splitlines())
    cur_cp_bad = any("curCp@r=-999" in ln or "curCp@c=-999" in ln for ln in gates)

    native = bool(xiaoyan.get("passed")) or counts.get("ReadPageModel", 0) >= 1
    if native:
        verdict, reason = "PASS", "首章上屏"
    elif pop_lines and invoke_ok:
        verdict, reason = "EVIDENCE", f"invoke 后 pop 证据：{pop_cause_hint}"
        if cur_cp_bad and pop_after_invoke:
            reason += "；gates curCp=-999 指向 R2"
    elif attached_invoke and invoke_ok and not pop_lines:
        verdict, reason = "PARTIAL", "invoke 成功但无 lifecycle trace（检查 Debug dylib）"
    else:
        verdict, reason = "FAIL", "缺少 invoke 或 lifecycle trace"

    report.update(
        {
            "verdict": verdict,
            "reason": reason,
            "xiaoyan": xiaoyan,
            "counts": counts,
            "attached_invoke": attached_invoke,
            "invoke_ok": invoke_ok[-3:],
            "gates": gates[-5:],
            "cur_cp_bad": cur_cp_bad,
            "pop_after_invoke": pop_after_invoke,
            "pop_cause_hint": pop_cause_hint,
            "pop_lines": pop_lines[-30:],
            "disappear": disappear[-8:],
            "nav_pop": nav_pop[-8:],
            "dealloc": dealloc[-5:],
            "bt_frames": bt_frames,
            "on_shelf": on_shelf,
        }
    )
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("verdict=", verdict, reason)
    return 0 if verdict in ("PASS", "EVIDENCE", "PARTIAL") else 1


if __name__ == "__main__":
    raise SystemExit(main())
