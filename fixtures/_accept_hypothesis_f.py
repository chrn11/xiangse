#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 F 验收：ORIG_OK 后 ivar/child 枚举 + FindContainer 关联缓存。"""
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
OUT = ROOT / "fixtures" / "_accept_hypothesis_f.json"


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
    env = __import__("os").environ.get("HYPOTHESIS_F_IPA")
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
    raise FileNotFoundError("未找到 legado-debug IPA，请设置 HYPOTHESIS_F_IPA 或先下载 CI artifact")


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

    f_lines = [ln for ln in blob.splitlines() if "hypothesis_F" in ln]
    e_lines = [ln for ln in blob.splitlines() if "hypothesis_E" in ln]
    c_lines = [ln for ln in blob.splitlines() if "hypothesis_C" in ln]
    report["f_lines"] = f_lines
    report["e_lines"] = e_lines
    report["c_lines"] = c_lines
    report["probe_lines"] = [ln for ln in f_lines if "hypothesis_F probe" in ln]
    report["found_lines"] = [ln for ln in f_lines if "hypothesis_F found" in ln]
    report["miss_lines"] = [ln for ln in f_lines if "hypothesis_F miss" in ln]
    report["cache_lines"] = [ln for ln in blob.splitlines() if "hypothesis_F cache_container" in ln]
    report["assoc_hit_lines"] = [ln for ln in blob.splitlines() if "hypothesis_F findContainer hit" in ln]
    report["onreset_ok"] = [ln for ln in blob.splitlines() if "hypothesis_C" in ln and "ORIG_OK" in ln]
    report["invoke_ok"] = [ln for ln in blob.splitlines() if "invoke_orig_OK" in ln]
    report["schedule_lines"] = [
        ln for ln in blob.splitlines()
        if "schedule_invoke" in ln or "resume_schedule_invoke" in ln or "defer_tick" in ln
    ]

    m_found = re.search(r"hypothesis_F found class=(\S+)", blob)
    report["found_class"] = m_found.group(1) if m_found else None

    m_probe = next((ln for ln in report["probe_lines"]), "")
    m_cat = re.search(r"arrCatalog=(\d+)", m_probe)
    report["arrCatalog_after_orig"] = int(m_cat.group(1)) if m_cat else None

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
    orig_ok = bool(report["onreset_ok"])
    found = bool(report["found_lines"])
    miss = bool(report["miss_lines"])
    invoke_ok = bool(report["invoke_ok"])
    schedule_started = bool(report["schedule_lines"])
    cat_ok = (report.get("arrCatalog_after_orig") or 0) >= 1
    report["springboard_or_shelf"] = on_shelf

    if on_shelf:
        report["verdict"] = "FAIL_SPRINGBOARD_OR_SHELF"
    elif found and orig_ok and (invoke_ok or schedule_started) and not on_shelf:
        report["verdict"] = "PASS_F"
    elif found and orig_ok and not on_shelf:
        report["verdict"] = "PARTIAL_F_FOUND_NO_INVOKE"
    elif miss and orig_ok and not on_shelf:
        report["verdict"] = "MISS_F_FACTORY_NO_CHILD"
    elif not orig_ok:
        report["verdict"] = "FAIL_F_NO_ORIG_OK"
    elif not cat_ok:
        report["verdict"] = "FAIL_F_NO_CATALOG"
    else:
        report["verdict"] = "PARTIAL"

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["verdict"] == "PASS_F" else 1


if __name__ == "__main__":
    raise SystemExit(main())
