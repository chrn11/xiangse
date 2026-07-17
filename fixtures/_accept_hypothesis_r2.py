#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 R2 验收：跳过致命 ORIG will/didAppear，进程存活 + invoke 保留。"""
from __future__ import annotations

import json
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
OUT = ROOT / "fixtures" / "_accept_hypothesis_r2.json"


def clear_all(c: McpClient) -> None:
    paths = c.app_paths()
    doc = paths.get("documents", "")
    cache = paths.get("caches", "")
    lib = paths.get("library", "")
    for p in c.open_once_candidates(paths):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 8}, timeout=15)
        except Exception:
            pass
    for p in (
        f"{doc}/legado_native_open_once.txt",
        f"{cache}/legado_native_open_once.txt",
        f"{lib}/Caches/legado_native_open_once.txt",
        f"{doc}/legado_openreader_trace.txt",
        f"{doc}/legado_loadcurcp_state.txt",
        f"{doc}/legado_catalog_last.txt",
        f"{doc}/legado_catalog_openreader.txt",
    ):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 8}, timeout=15)
        except Exception:
            pass


def main() -> int:
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    c.call("wake_and_home", timeout=30)
    time.sleep(1)
    c.call("kill_app", {"bundle_id": BUNDLE}, timeout=20)
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE}, timeout=40)
    time.sleep(2)
    clear_all(c)

    doc = c.app_paths().get("documents", "")
    reg = c.read_file_at(f"{doc}/legado_bridge_sources.json", max_bytes=800)
    if not reg or "bookSourceUrl" not in (reg or ""):
        c.call(
            "open_url",
            {
                "url": f"legado://import/bookSource?src={MOCK}/legado-local-mock.runtime.json?t={int(time.time())}"
            },
            timeout=20,
        )
        time.sleep(2)

    c.call(
        "open_url",
        {
            "url": f"legado://nativeRead?bookUrl={MOCK}/book/doupo.html&sourceUrl={MOCK}&idx=0"
        },
        timeout=20,
    )
    time.sleep(10)

    tr = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=300000)
    st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=120000)
    blob = (tr or "") + "\n" + (st or "")
    texts = []
    try:
        ui = c.call("get_ui_elements", {"limit": 25}, timeout=25)
        if isinstance(ui, dict):
            for el in ui.get("elements") or []:
                if isinstance(el, dict) and el.get("text"):
                    texts.append(str(el["text"])[:40])
    except Exception as e:
        texts = [str(e)]

    defer = "hypothesis_R2 defer_postCurCp_delay_1s" in blob
    r2_will = "hypothesis_R2 willAppear noop" in blob
    onreset_skip = "hypothesis_R2 onReset noArg skip ORIG" in blob
    delayed_begin = "hypothesis_R2 delayed_postCurCp_begin" in blob
    delayed_done = "hypothesis_R2 delayed_postCurCp_done" in blob
    invoke = "invoke_orig_OK" in blob
    register_count = blob.count("register_orig")
    springboard = any(t in texts for t in ("日历", "钱包", "设置"))
    bookshelf = "书架" in texts
    qf = any("lpNetWorkDelegateQueryFinish" in ln for ln in (tr or "").splitlines())
    dr = any(
        ("divisionResponse@" in ln or "contentInject postDR" in ln or "onDivisionTextFinish" in ln)
        and "enc=" not in ln and "divisionProbe" not in ln
        for ln in (tr or "").splitlines()
    )
    survived = delayed_done and not springboard

    if springboard:
        verdict, reason = "FAIL_REVERT_R2", "仍回 SpringBoard"
    elif not defer:
        verdict, reason = "FAIL", "未命中 defer_1s"
    elif not r2_will:
        verdict, reason = "FAIL", "未命中 willAppear noop"
    elif not onreset_skip and "onReset noArg enter" in blob and "beforeOrigSeed" in blob:
        verdict, reason = "FAIL", "仍走 onReset ORIG/seed（应 skip）"
    elif not delayed_begin:
        verdict, reason = "FAIL_REVERT_R2", "1s 延迟未到（中途重启）"
    elif not invoke:
        verdict, reason = "FAIL_NEED_NEXT", "delayed_postCurCp 无 invoke"
    elif qf or dr:
        verdict, reason = "PASS", "延迟 invoke 后出现 QF/DR"
    elif survived and invoke:
        verdict, reason = "PASS_PARTIAL", "延迟 invoke 存活；尚无 QF/DR"
    else:
        verdict, reason = "FAIL", "未达标"

    report = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "verdict": verdict,
        "reason": reason,
        "defer": defer,
        "r2_will": r2_will,
        "onreset_skip": onreset_skip,
        "delayed_begin": delayed_begin,
        "delayed_done": delayed_done,
        "invoke": invoke,
        "qf": qf,
        "dr": dr,
        "register_count": register_count,
        "springboard": springboard,
        "bookshelf": bookshelf,
        "ui": texts[:15],
        "nav_tail": [ln for ln in (tr or "").splitlines() if any(k in ln for k in ("R2", "invoke", "ORIG", "register", "gates", "QF", "division", "appear", "defer", "settle", "delayed", "onReset", "go0.6", "go1.4"))][-50:],
    }
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("verdict", "reason", "defer", "delayed_begin", "delayed_done", "invoke", "qf", "dr", "springboard", "ui")}, ensure_ascii=False, indent=2))
    return 0 if verdict.startswith("PASS") else 1


if __name__ == "__main__":
    raise SystemExit(main())
