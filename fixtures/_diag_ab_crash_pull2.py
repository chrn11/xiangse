#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 AB：crash / syslog / jetsam 取证（避免 PowerShell 吞 2>/dev/null）。"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient

BUNDLE = "com.appbox.StandarReader"
MCP = "http://192.168.1.6:8090"
OUT = ROOT / "analysis" / "reader-forensics" / "hypothesis-AB-crash-pull.json"


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    out: dict = {"mcp": MCP}

    try:
        out["crashes"] = c.call("get_crash_logs", {"limit": 12}, timeout=45)
    except Exception as exc:
        out["crashes"] = {"error": str(exc)}

    try:
        out["syslog"] = c.call(
            "get_syslog", {"limit": 120, "process": "StandarReader"}, timeout=50
        )
    except Exception as exc:
        try:
            out["syslog"] = c.call("get_syslog", {"limit": 60}, timeout=50)
            out["syslog_fallback"] = True
        except Exception as exc2:
            out["syslog"] = {"error": str(exc2), "prev": str(exc)}

    cmds = [
        "ls -lt /var/mobile/Library/Logs/CrashReporter/*.ips | head -25",
        "ls -lt /var/mobile/Library/Logs/CrashReporter/*Standar* 2>&1 | head -15",
        "ls -lt /var/mobile/Library/Logs/CrashReporter/Retired/*Standar* 2>&1 | head -15",
        "ls -lt /var/mobile/Library/Logs/CrashReporter/*Jetsam* 2>&1 | head -20",
        "ls -lt /Library/Logs/CrashReporter/*Standar* 2>&1 | head -10",
        "find /var/mobile/Library/Logs -name '*Standar*' -mtime -2 2>&1 | head -30",
        "find /var/mobile/Library/Logs -name '*Jetsam*' -mtime -2 2>&1 | head -30",
    ]
    out["cmds"] = []
    for cmd in cmds:
        try:
            r = c.call("run_command", {"command": cmd, "timeout_sec": 20}, timeout=35)
            if isinstance(r, str) and len(r) > 4000:
                r = r[:4000]
            out["cmds"].append({"cmd": cmd, "r": r})
        except Exception as exc:
            out["cmds"].append({"cmd": cmd, "error": str(exc)})

    # 读最新 StandarReader ips 头（即便是 7/16）看 exception type
    reports = []
    if isinstance(out.get("crashes"), dict):
        reports = out["crashes"].get("reports") or []
    sr = [x for x in reports if "StandarReader" in str(x.get("name", ""))]
    out["standar_reports"] = sr[:5]
    if sr:
        name = sr[0]["name"]
        try:
            body = c.call("read_crash_log", {"name": name}, timeout=90)
            text = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
            out["latest_sr_crash_name"] = name
            out["latest_sr_crash_head"] = text[:5000]
            # 关键字段粗提
            keys = (
                "exception",
                "EXC_",
                "Termination",
                "faulting thread",
                "triggered by",
                "signal",
                "Jetsam",
                "codeSigning",
            )
            hits = [ln for ln in text.splitlines() if any(k.lower() in ln.lower() for k in keys)]
            out["latest_sr_crash_hits"] = hits[:40]
        except Exception as exc:
            out["latest_sr_crash_err"] = str(exc)

    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({
        "out": str(OUT),
        "sr_n": len(sr),
        "syslog_type": type(out.get("syslog")).__name__,
        "cmds_n": len(out["cmds"]),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
