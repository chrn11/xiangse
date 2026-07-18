#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 AB：装测后拉取 fsync 探针，定位最后存活点。"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient

BUNDLE = "com.appbox.StandarReader"
MOCK = "http://192.168.1.4:8765"
MCP = "http://192.168.1.6:8090"
OUT = ROOT / "fixtures" / "_diag_ab_probe_run.json"


def find_ipa(sha: str) -> Path | None:
    cands = [
        ROOT / "dist-ci" / sha / "dist" / "StandarReader-legado-bridge-debug.ipa",
        ROOT / "dist-ci" / sha / "dist" / "StandarReader-legado-debug.ipa",
    ]
    for p in cands:
        if p.is_file():
            return p
    hits = sorted(ROOT.glob(f"dist-ci*/**/StandarReader-legado*debug.ipa"))
    return hits[-1] if hits else None


def main() -> None:
    sha = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    report: dict = {"sha": sha, "mcp": MCP}

    if sha:
        ipa = find_ipa(sha)
        report["ipa"] = str(ipa) if ipa else None
        if ipa:
            up = c.upload_file(ipa, timeout=600)
            report["upload"] = up
            path = None
            if isinstance(up, dict):
                path = up.get("path") or up.get("device_path") or up.get("filename")
            report["install"] = c.call(
                "install_app",
                {"path": path or str(ipa)},
                timeout=600,
            )

    info = c.call("get_app_info", {"bundle_id": BUNDLE}, timeout=30)
    doc = None
    if isinstance(info, dict):
        doc = (info.get("paths") or {}).get("documents") or info.get("data_container")
        if doc and not str(doc).endswith("Documents"):
            doc = str(doc).rstrip("/") + "/Documents"
    report["doc"] = doc

    def rc(cmd: str, t: int = 20):
        return c.call("run_command", {"command": cmd, "timeout_sec": t}, timeout=t + 15)

    if doc:
        for name in (
            "legado_ab_probe.txt",
            "legado_loadcurcp_state.txt",
            "legado_loadcurcp_trace.txt",
            "legado_openreader_trace.txt",
        ):
            rc(f"rm -f '{doc}/{name}'")

    c.call("wake_and_home", timeout=30)
    c.call("kill_app", {"bundle_id": BUNDLE}, timeout=30)
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE}, timeout=30)
    time.sleep(2)
    c.call(
        "open_url",
        {"url": f"legado://import/bookSource?src={MOCK}/legado-local-mock.runtime.json"},
        timeout=30,
    )
    time.sleep(2)
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

    polls = []
    for i in range(20):
        time.sleep(0.4)
        probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=200000) or ""
        st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=250000) or ""
        fm = {}
        try:
            fm = c.call("get_frontmost_app", timeout=12) or {}
        except Exception as exc:
            fm = {"error": str(exc)}
        blob = probe + "\n" + st
        ab_lines = [ln for ln in blob.splitlines() if "hypothesis_AB" in ln]
        polls.append(
            {
                "t": round(time.time() - t0, 2),
                "bundle": fm.get("bundleId") if isinstance(fm, dict) else None,
                "invoke": "invoke_orig_OK" in blob or "invoke_orig_returned" in blob,
                "ab_last": ab_lines[-6:],
                "z": [ln for ln in st.splitlines() if "hypothesis_Z" in ln][-2:],
                "cb": any("cb_enter" in ln for ln in ab_lines),
                "qf": "lpNetWorkDelegateQueryFinish" in blob or "queryFinish" in blob,
                "register": [ln for ln in st.splitlines() if "register_orig" in ln][-2:],
            }
        )
        if isinstance(fm, dict) and fm.get("bundleId") == "com.apple.springboard" and i >= 4:
            break

    probe = c.read_sandbox_text("legado_ab_probe.txt", max_bytes=250000) or ""
    st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=250000) or ""
    ab_lines = [ln for ln in (probe + "\n" + st).splitlines() if "hypothesis_AB" in ln]
    last = ab_lines[-1] if ab_lines else None

    crashes = None
    try:
        crashes = c.call("get_crash_logs", {"limit": 6}, timeout=40)
    except Exception as exc:
        crashes = {"error": str(exc)}

    report.update(
        {
            "polls": polls,
            "probe_tail": probe.splitlines()[-40:],
            "state_tail": st.splitlines()[-50:],
            "ab_last": last,
            "ab_all": ab_lines[-40:],
            "has_cb": any("cb_enter" in ln for ln in ab_lines),
            "has_cb_exit": any("cb_exit" in ln for ln in ab_lines),
            "has_swcf": any("swcf_exit" in ln for ln in ab_lines),
            "has_format": any("format_enter" in ln for ln in ab_lines),
            "has_fatal": any("fatal_signal" in ln for ln in ab_lines),
            "has_qf": "lpNetWorkDelegateQueryFinish" in (probe + st),
            "crashes": crashes,
            "frontmost": c.call("get_frontmost_app", timeout=15),
        }
    )
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(
        json.dumps(
            {
                "out": str(OUT),
                "ab_last": last,
                "has_cb": report["has_cb"],
                "has_swcf": report["has_swcf"],
                "has_format": report["has_format"],
                "has_fatal": report["has_fatal"],
                "has_qf": report["has_qf"],
                "frontmost": report["frontmost"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
