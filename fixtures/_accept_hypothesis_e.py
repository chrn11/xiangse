#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 E 验收：didAppear UIKitSuper + window/catalog/appeared 门控后再调 onReset ORIG。"""
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
OUT = ROOT / "fixtures" / "_accept_hypothesis_e.json"


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
    env = __import__("os").environ.get("HYPOTHESIS_E_IPA")
    if env:
        p = Path(env)
        if p.is_file():
            return p
    for pat in (
        "dist-ci-run-*/dist/StandarReader-legado-debug.ipa",
        "dist-ci-run-*/dist/StandarReader-legado-bridge-debug.ipa",
        "fixtures/_devkit/ci-artifact/**/StandarReader-legado-debug.ipa",
        "dist/StandarReader-legado-debug.ipa",
    ):
        hits = sorted(ROOT.glob(pat), key=lambda x: x.stat().st_mtime, reverse=True)
        if hits:
            return hits[0]
    raise FileNotFoundError("未找到 legado-debug IPA，请设置 HYPOTHESIS_E_IPA 或先下载 CI artifact")


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
    time.sleep(10)

    trace = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=300000)
    state = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=100000)
    blob = (trace or "") + "\n" + (state or "")

    e_lines = [ln for ln in blob.splitlines() if "hypothesis_E" in ln]
    c_lines = [ln for ln in blob.splitlines() if "hypothesis_C" in ln]
    b2_lines = [ln for ln in blob.splitlines() if "hypothesis_B2" in ln]
    report["e_lines"] = e_lines
    report["c_lines"] = c_lines
    report["b2_lines"] = b2_lines[-15:] if b2_lines else []
    report["didAppear_ok"] = [ln for ln in e_lines if "UIKitSuper_OK" in ln]
    report["pre_fire_lines"] = [ln for ln in e_lines if "pre_fire" in ln]
    report["defer_lines"] = [ln for ln in e_lines if "defer_onReset" in ln]
    report["fire_lines"] = [ln for ln in c_lines if "fire_onReset" in ln]
    report["onreset_ok"] = [ln for ln in blob.splitlines() if "hypothesis_C" in ln and "ORIG_OK" in ln]
    report["after_orig_e"] = [ln for ln in e_lines if "after_ORIG pageContainerA=" in ln]

    first = next((ln for ln in b2_lines if "container_first_seen" in ln), "")
    m = re.search(r"class=([^ ]+).*byte@bd8=0x([0-9a-fA-F]+)", first)
    report["pageContainerA_class"] = m.group(1) if m else None
    report["byte_bd8"] = m.group(2) if m else None

    after_e = report["after_orig_e"][-1] if report["after_orig_e"] else ""
    m2 = re.search(r"pageContainerA=(\S+)", after_e)
    if m2:
        report["pageContainerA_after_orig"] = m2.group(1)

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
    did_appear = bool(report["didAppear_ok"])
    fired = bool(report["fire_lines"])
    orig_ok = bool(report["onreset_ok"])
    container_after = report.get("pageContainerA_after_orig", "nil")
    container_ok = container_after not in ("nil", None, "")
    report["springboard_or_shelf"] = on_shelf

    if did_appear and fired and orig_ok and container_ok and not on_shelf:
        report["verdict"] = "PASS_E"
    elif on_shelf:
        report["verdict"] = "FAIL_SPRINGBOARD_OR_SHELF"
    elif did_appear and fired and orig_ok and not container_ok:
        report["verdict"] = "PARTIAL_E_NO_CONTAINER"
    elif did_appear and fired and not orig_ok:
        report["verdict"] = "FAIL_E_NO_ORIG_OK"
    elif not did_appear:
        report["verdict"] = "FAIL_E_NO_DIDAPPEAR"
    elif report["defer_lines"] and not fired:
        report["verdict"] = "FAIL_E_DEFER_ONLY"
    else:
        report["verdict"] = "PARTIAL"

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["verdict"] == "PASS_E" else 1


if __name__ == "__main__":
    raise SystemExit(main())
