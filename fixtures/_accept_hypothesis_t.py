#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 T 验收：入栈后 invoke；阅读页可见或原生链。"""
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
OUT = ROOT / "fixtures" / "_accept_hypothesis_t.json"
IPA = (
    ROOT
    / "dist-ci-run-29565676018"
    / "Reader-Forensics-IPAs"
    / "dist"
    / "StandarReader-legado-debug.ipa"
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
    caches = paths.get("caches", "")
    if caches:
        try:
            c.call(
                "run_command",
                {"command": f"rm -f '{caches}/legado_native_open_once.txt'", "timeout_sec": 10},
            )
        except Exception:
            pass


def rt(ln: str) -> bool:
    return ("before" in ln or "after" in ln) and " enc=" not in ln


def main() -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", type=Path, default=IPA)
    ap.add_argument("--run", type=str, default="29565426067")
    args = ap.parse_args()
    ipa = args.ipa
    if not ipa.is_file():
        # fallback glob
        cands = list(ROOT.glob(f"dist-ci-run-{args.run}/**/StandarReader-legado-debug.ipa"))
        if not cands:
            raise FileNotFoundError(ipa)
        ipa = cands[0]

    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "sha": "3de552c",
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
        c.call("open_url", {"url": "legado://debugDump?phase=hypothesis_t"})
        report["steps"].append("debugDump")
    except McpError as e:
        report["dump_err"] = str(e)
    time.sleep(1)

    trace = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=200000)
    state = c.read_sandbox_text("legado_loadcurcp_state.txt")
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=196608)
    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 5000})
    except McpError as e:
        xiaoyan = {"passed": False, "error": str(e)}

    blob = trace + "\n" + state
    qf = [ln for ln in dump.splitlines() if rt(ln) and "lpNetWorkDelegateQueryFinish" in ln]
    dr = [ln for ln in dump.splitlines() if rt(ln) and "divisionResponse:cpTitle:cpIndex:" in ln]
    tip = [ln for ln in dump.splitlines() if rt(ln) and "resetLoadCpTip" in ln]
    counts = {}
    for k in ("TextReadTV", "ReadPageModel", "TextReadVC3"):
        m = re.search(rf"{k} count=(\d+)", dump)
        counts[k] = int(m.group(1)) if m else 0

    defer = [ln for ln in blob.splitlines() if "hypothesis_T" in ln]
    invoke_ok = [ln for ln in blob.splitlines() if "invoke_orig_OK" in ln]
    attached_invoke = any("attached=1" in ln and "pre_invoke" in ln for ln in defer)
    settle = [ln for ln in trace.splitlines() if "settle vis=" in ln or "visible mode=1" in ln]
    on_shelf = any("空列表" in t for s in snaps for t in s.get("texts") or [])
    on_readerish = any(
        (not any(x in (s.get("texts") or []) for x in ("书架", "空列表"))) and (s.get("texts") or [])
        for s in snaps[1:]
    ) or any("萧炎" in t or "斗" in t for s in snaps for t in s.get("texts") or [])

    native = bool(qf or dr)
    render = bool(xiaoyan.get("passed")) or counts.get("ReadPageModel", 0) >= 1
    if native or render:
        verdict, reason = "PASS", "原生链或上屏"
    elif attached_invoke and invoke_ok and not on_shelf:
        verdict, reason = "PARTIAL", "已入栈后 invoke，阅读页未立刻掉回书架"
    elif attached_invoke and invoke_ok:
        verdict, reason = "FAIL_NEED_NEXT", "入栈 invoke 成功但仍回书架/无链"
    else:
        verdict, reason = "FAIL", "未观察到 attached invoke"

    report.update(
        {
            "verdict": verdict,
            "reason": reason,
            "xiaoyan": xiaoyan,
            "native": native,
            "counts": counts,
            "qf": qf[-3:],
            "dr": dr[-3:],
            "tip": tip[-3:],
            "attached_invoke": attached_invoke,
            "on_shelf": on_shelf,
            "defer_hits": defer[-20:],
            "invoke_ok": invoke_ok[-5:],
            "settle": settle[-8:],
            "nav_hits": [
                ln
                for ln in trace.splitlines()
                if any(
                    k in ln
                    for k in (
                        "hypothesis_T",
                        "pushNativeFull",
                        "postCurCp",
                        "invoke_orig",
                        "settle",
                        "visible",
                        "skip openOnce",
                        "reopen",
                    )
                )
            ][-60:],
        }
    )
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("verdict=", verdict, reason)
    return 0 if verdict in ("PASS", "PARTIAL") else 1


if __name__ == "__main__":
    raise SystemExit(main())
