#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""卡2硬验收：安装 forensics IPA → 原版TXT阅读 → 同步 dump ×10。"""
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

from tools.ios_mcp_client import McpClient, McpError
from tools.repack.manifest import validate_manifest

MCP = "http://192.168.1.6:8090"
BUNDLE = "com.appbox.StandarReader"
OUT_DIR = ROOT / "fixtures" / "_devkit"
EXPECTED_GIT = "b7ac02a528aca7f1d432d0bd2bd4c32cf68d7a0a"
FORENSICS_RUN = "29470530280"
STABILITY_N = 10


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def tap_rect_center(c: McpClient, text: str) -> bool:
    r = c.call("tap_element", {"text": text, "index": 0}, timeout=30)
    if not isinstance(r, dict) or not r.get("tapped"):
        return False
    rect = (r.get("element") or {}).get("rect") or {}
    x = int(rect.get("x", 0) + rect.get("width", 0) / 2)
    y = int(rect.get("y", 0) + rect.get("height", 0) / 2)
    if x > 1 and y > 1:
        c.call("tap_screen", {"x": x, "y": y})
        return True
    return False


def list_forensics_files(c: McpClient) -> list[str]:
    doc = c.app_paths().get("documents", "")
    if not doc:
        return []
    res = c.call("run_command", {"command": f"ls -1 '{doc}'/forensics_dump_*.json 2>/dev/null", "timeout_sec": 15})
    out = ""
    if isinstance(res, dict):
        out = res.get("output") or ""
    elif isinstance(res, str):
        out = res
    return [ln.strip() for ln in out.splitlines() if ln.strip()]


def read_json_at(c: McpClient, path: str) -> dict | None:
    text = c.read_file_at(path, max_bytes=2_000_000)
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def validate_v2(doc: dict) -> tuple[bool, list[str]]:
    errs: list[str] = []
    if doc.get("schema_version") != 2:
        errs.append(f"schema_version={doc.get('schema_version')}")
    og = doc.get("objectGraph") or {}
    if not isinstance(og, dict):
        errs.append("no objectGraph")
        return False, errs
    mo = doc.get("methodOwners") or {}
    if not mo.get("readerSelectors"):
        errs.append("methodOwners.readerSelectors empty")
    return len(errs) == 0, errs


def has_reader_signal(doc: dict) -> tuple[bool, list[str]]:
    og = doc.get("objectGraph") or {}
    hits: list[str] = []
    for name in ("TextReadVC3", "TextReadTV", "ReadPageModel"):
        block = og.get(name) or {}
        cnt = block.get("count", 0)
        if cnt and int(cnt) > 0:
            hits.append(f"{name} count={cnt}")
    blob = json.dumps(og, ensure_ascii=False)
    if re.search(r"Attr len=[1-9]|NSString len=[1-9]|NSAttributedString len=[1-9]", blob):
        hits.append("nonempty_text")
    return len(hits) >= 2 and any("count=" in h for h in hits), hits


def ensure_ipa(c: McpClient) -> dict:
    manifest = c.read_build_manifest()
    if manifest and manifest.get("git_commit", "").startswith("b7ac02a"):
        return manifest
    subprocess.run(
        [
            sys.executable,
            str(ROOT / "tools" / "xiangse_devkit.py"),
            "install",
            "--forensics",
            "--run-id",
            FORENSICS_RUN,
            "--expected-variant",
            "baseline-debug",
        ],
        check=False,
        cwd=str(ROOT),
    )
    time.sleep(3)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(5)
    manifest = c.read_build_manifest() or {}
    return manifest


def invoke_dump_sync(c: McpClient, phase: str) -> str:
    """优先同步 selector；回退异步 + 等待新 json。"""
    before = set(list_forensics_files(c))
    attempts = [
        {
            "bundle_id": BUNDLE,
            "class_name": "LBDebugPanel",
            "selector": "lb_debugDumpSyncWithPhase:",
            "class_method": True,
            "arguments": [phase],
        },
        {
            "bundle_id": BUNDLE,
            "class_name": "LBDebugPanel",
            "selector": "lb_debugDumpAction",
            "class_method": True,
        },
    ]
    last_err = ""
    for args in attempts:
        try:
            c.call("objc_invoke", args, timeout=90)
        except McpError as exc:
            last_err = str(exc)
            continue
        for _ in range(40):
            time.sleep(0.5)
            after = set(list_forensics_files(c))
            new_files = sorted(after - before)
            if new_files:
                return new_files[-1]
            ready = c.read_sandbox_text("legado_debug_dump_ready.txt", max_bytes=4096).strip()
            if ready and ready.endswith(".json"):
                return ready
        last_err = f"no new json after {args['selector']}"
    raise RuntimeError(last_err or "objc_invoke dump failed")


def open_native_txt_reader(c: McpClient) -> list[str]:
    steps: list[str] = []
    c.call("wake_and_home")
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(6)
    steps.append("launch_app")
    if not tap_rect_center(c, "小说示例"):
        raise RuntimeError("无法点开书架「小说示例」")
    steps.append("tap_book")
    time.sleep(2)
    if not tap_rect_center(c, "使用示例"):
        c.call("tap_screen", {"x": 195, "y": 240})
        steps.append("tap_chapter_coord")
    else:
        steps.append("tap_chapter")
    time.sleep(8)
    stack = c.get_vc_stack()
    steps.append(f"vc_stack={stack}")
    return steps


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    report: dict = {
        "head_expected": EXPECTED_GIT,
        "started_at": ts(),
        "passed": False,
        "steps": [],
        "stability": [],
        "sample_json": None,
        "unknown": [],
    }
    c = McpClient(MCP, BUNDLE)

    manifest = ensure_ipa(c)
    report["manifest"] = manifest
    git = manifest.get("git_commit", "")
    if not str(git).startswith("b7ac02a"):
        report["error"] = f"manifest git 不符: {git}"
        out = OUT_DIR / f"forensics_hard_accept_FAIL_{ts()}.json"
        out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 2

    try:
        report["steps"] = open_native_txt_reader(c)
    except Exception as exc:
        report["error"] = f"open_reader: {exc}"
        out = OUT_DIR / f"forensics_hard_accept_FAIL_{ts()}.json"
        out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 2

    try:
        c.call("refresh_dump", {"bundle_id": BUNDLE, "timeout": 90}, timeout=120)
        report["steps"].append("refresh_dump_ok")
    except McpError as exc:
        report["steps"].append(f"refresh_dump_warn={exc}")

    # 首次阅读页 dump
    try:
        json_path = invoke_dump_sync(c, "reader_ch1")
        doc = read_json_at(c, json_path)
        if not doc:
            raise RuntimeError(f"无法解析 JSON: {json_path}")
        ok_schema, errs = validate_v2(doc)
        ok_reader, hits = has_reader_signal(doc)
        local_json = OUT_DIR / f"forensics_sample_{ts()}.json"
        local_json.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
        report["sample_json"] = {"device_path": json_path, "local_path": str(local_json), "schema_ok": ok_schema, "reader_ok": ok_reader, "hits": hits, "errs": errs}
        if not ok_schema or not ok_reader:
            report["error"] = "首次阅读页 dump 未满足 schema/reader"
    except Exception as exc:
        report["error"] = f"first_dump: {exc}"
        out = OUT_DIR / f"forensics_hard_accept_FAIL_{ts()}.json"
        out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 1

    # 10 次稳定性
    all_ok = True
    for i in range(STABILITY_N):
        row: dict = {"i": i, "ok": False}
        try:
            path = invoke_dump_sync(c, f"stab_{i}")
            doc_i = read_json_at(c, path)
            ok_s, _ = validate_v2(doc_i or {})
            row.update({"path": path, "schema_version": (doc_i or {}).get("schema_version"), "ok": ok_s})
            if not ok_s:
                all_ok = False
        except Exception as exc:
            row["error"] = str(exc)
            all_ok = False
        report["stability"].append(row)
        time.sleep(0.3)

    crash = c.read_sandbox_text("legado_debug_crash.txt", max_bytes=8000)
    report["crash_tail"] = crash[-400:] if crash else ""
    report["unknown"] = (doc or {}).get("unknown") or []

    report["passed"] = bool(report.get("sample_json", {}).get("reader_ok")) and all_ok and not report.get("error")
    out = OUT_DIR / ("forensics_hard_accept_PASS_" if report["passed"] else "forensics_hard_accept_FAIL_") + ts() + ".json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    report["report_path"] = str(out)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
