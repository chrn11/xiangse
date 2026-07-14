#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""香色真机开发套件 — Windows CLI，经 ios-mcp 操作 StandarReader。"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ios_mcp_client import DEFAULT_BUNDLE, McpClient, McpError

DEFAULT_MOCK = os.environ.get("XIANGSE_MOCK", "http://192.168.1.4:8765")
OUT_DIR = ROOT / "fixtures" / "_devkit"
TRACE_KEYWORDS = (
    "preferNativeFull",
    "SIGNAL",
    "nativePaged",
    "tvHasNeedleStrict",
    "openOnce",
)
BOOKSHELF_MARKERS = ("书架", "書架")
READER_MARKERS = ("萧炎", "斗破", "章节", "目录", "阅读")


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _print(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def make_client(args: argparse.Namespace) -> McpClient:
    return McpClient(base_url=args.mcp, bundle_id=args.bundle)


def cmd_status(client: McpClient, args: argparse.Namespace) -> int:
    out: dict[str, Any] = {"bundle": client.bundle_id}
    try:
        out["health"] = client.health()
    except Exception as exc:
        out["health_error"] = str(exc)

    try:
        info = client.call("get_app_info", {"bundle_id": client.bundle_id})
        out["app_info"] = info
        paths = info.get("paths", {}) if isinstance(info, dict) else {}
    except McpError as exc:
        out["app_info_error"] = str(exc)
        paths = {}

    try:
        front = client.call("get_frontmost_app")
        out["frontmost"] = front
    except McpError as exc:
        out["frontmost_error"] = str(exc)

    open_once: dict[str, bool] = {}
    for p in client.open_once_candidates(paths):
        open_once[p] = client.file_exists(p)
    out["open_once"] = open_once
    out["open_once_present"] = any(open_once.values())
    _print(out)
    return 0 if not out.get("health_error") and not out.get("app_info_error") else 1


def clear_open_once(client: McpClient, paths: dict[str, str] | None = None) -> list[str]:
    deleted: list[str] = []
    for p in client.open_once_candidates(paths):
        if not p:
            continue
        try:
            client.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10}, timeout=20)
            deleted.append(p)
        except McpError:
            pass
    return deleted


def clear_trace_files(client: McpClient, paths: dict[str, str] | None = None, backup_dir: Path | None = None) -> list[str]:
    paths = paths or client.app_paths()
    doc = paths.get("documents", "")
    removed: list[str] = []
    if not doc:
        return removed
    for name in ("legado_openreader_trace.txt", "legado_catalog_openreader.txt"):
        full = f"{doc}/{name}"
        if backup_dir:
            backup_dir.mkdir(parents=True, exist_ok=True)
            try:
                text = client.read_sandbox_text(name, max_bytes=131072)
                if text:
                    (backup_dir / f"{name}.{_ts()}.bak").write_text(text, encoding="utf-8")
            except Exception:
                pass
        try:
            client.call("run_command", {"command": f"rm -f '{full}'", "timeout_sec": 10}, timeout=20)
            removed.append(full)
        except McpError:
            pass
    return removed


def cmd_reset(client: McpClient, args: argparse.Namespace) -> int:
    paths = client.app_paths()
    backup_dir = OUT_DIR / "backup" if args.backup else None
    deleted = clear_open_once(client, paths)
    removed: list[str] = []
    if not args.keep_trace:
        removed = clear_trace_files(client, paths, backup_dir=backup_dir)

    open_once_after: dict[str, bool] = {}
    for p in client.open_once_candidates(paths):
        open_once_after[p] = client.file_exists(p)

    out = {
        "deleted_open_once": deleted,
        "removed_trace": removed,
        "open_once_after": open_once_after,
        "open_once_still_present": any(open_once_after.values()),
    }
    _print(out)
    return 1 if out["open_once_still_present"] else 0


def filter_trace_lines(text: str, keywords: tuple[str, ...] | None = None) -> dict[str, list[str]]:
    kws = keywords or TRACE_KEYWORDS
    lines = text.splitlines()
    hits: dict[str, list[str]] = {}
    for kw in kws:
        hits[kw] = [ln for ln in lines if kw in ln]
    return hits


def cmd_trace(client: McpClient, args: argparse.Namespace) -> int:
    trace_text = client.read_sandbox_text("legado_openreader_trace.txt", max_bytes=args.max_bytes)
    marker_text = client.read_sandbox_text("legado_catalog_openreader.txt", max_bytes=8192)
    once_text = ""
    paths = client.app_paths()
    for p in client.open_once_candidates(paths):
        if client.file_exists(p):
            try:
                res = client.call("read_file", {"path": p, "max_bytes": 4096}, timeout=20)
                once_text = res.get("content", "") if isinstance(res, dict) else str(res)
            except McpError:
                pass
            break

    keywords = tuple(args.keyword) if args.keyword else TRACE_KEYWORDS
    out = {
        "trace_hits": filter_trace_lines(trace_text, keywords),
        "marker_hits": filter_trace_lines(marker_text, keywords),
        "open_once": once_text,
        "trace_tail": trace_text[-args.tail :],
        "marker_tail": marker_text[-min(args.tail, 2000) :],
        "preferNativeFull_count": sum(1 for ln in trace_text.splitlines() if "goStart preferNativeFull" in ln),
        "has_signal": "SIGNAL sig=" in trace_text or "SIGNAL sig=" in marker_text,
    }
    if args.json:
        _print(out)
    else:
        for kw, lines in out["trace_hits"].items():
            if lines:
                print(f"\n=== trace:{kw} ({len(lines)}) ===")
                for ln in lines[-20:]:
                    print(ln)
        print(f"\npreferNativeFull_count={out['preferNativeFull_count']} has_signal={out['has_signal']}")
    return 0


def mock_urls(mock_base: str) -> dict[str, str]:
    base = mock_base.rstrip("/")
    return {
        "src": f"{base}/legado-local-mock.runtime.json",
        "book": f"{base}/book/doupo.html",
        "source": base,
    }


def check_mock_reachable(mock_base: str, timeout: float = 3) -> dict[str, Any]:
    urls = mock_urls(mock_base)
    result: dict[str, Any] = {"mock_base": mock_base, "reachable": False, "checks": {}}
    for name, url in urls.items():
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                result["checks"][name] = {"url": url, "status": resp.status}
                result["reachable"] = True
        except Exception as exc:
            result["checks"][name] = {"url": url, "error": str(exc)}
    return result


def cmd_read(client: McpClient, args: argparse.Namespace) -> int:
    urls = mock_urls(args.mock)
    book = args.book or urls["book"]
    src = args.src or urls["src"]
    source = args.source or urls["source"]
    idx = args.idx

    steps: list[str] = []
    client.call("wake_and_home")
    steps.append("wake_and_home")
    if args.kill_first:
        client.call("kill_app", {"bundle_id": client.bundle_id})
        time.sleep(1)
    client.call("launch_app", {"bundle_id": client.bundle_id})
    steps.append("launch_app")
    time.sleep(args.launch_wait)

    if args.import_source:
        client.call("open_url", {"url": f"legado://import/bookSource?src={src}"})
        steps.append("import_source")
        time.sleep(2)

    read_url = f"legado://nativeRead?bookUrl={book}&sourceUrl={source}&idx={idx}"
    client.call("open_url", {"url": read_url})
    steps.append("nativeRead")
    time.sleep(args.wait)

    front = client.call("get_frontmost_app")
    out = {
        "steps": steps,
        "read_url": read_url,
        "frontmost": front,
        "still_in_app": (front.get("bundleId") if isinstance(front, dict) else str(front)) == client.bundle_id,
    }
    _print(out)
    return 0


def _run_subprocess(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace")


def resolve_local_ipa(args: argparse.Namespace) -> Path:
    if args.ipa:
        p = Path(args.ipa)
        if not p.is_file():
            raise SystemExit(f"IPA 不存在: {p}")
        return p

    out_dir = OUT_DIR / "ci-artifact"
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.ipa"):
        old.unlink(missing_ok=True)

    if args.run_id:
        dl_cmd = ["gh", "run", "download", str(args.run_id), "-n", "LegadoBridge-IPA", "-D", str(out_dir)]
    else:
        listed = _run_subprocess(
            ["gh", "run", "list", "--workflow", "bridge-ci.yml", "--status", "success", "--limit", "1", "--json", "databaseId"],
            cwd=ROOT,
        )
        if listed.returncode != 0:
            raise SystemExit(f"gh run list 失败: {listed.stderr or listed.stdout}")
        runs = json.loads(listed.stdout or "[]")
        if not runs:
            raise SystemExit("未找到成功的 bridge-ci workflow run")
        run_id = str(runs[0]["databaseId"])
        dl_cmd = ["gh", "run", "download", run_id, "-n", "LegadoBridge-IPA", "-D", str(out_dir)]

    dl = _run_subprocess(dl_cmd, cwd=ROOT)
    if dl.returncode != 0:
        raise SystemExit(f"gh run download 失败: {dl.stderr or dl.stdout}")

    candidates = list(out_dir.rglob("StandarReader-legado-bridge.ipa"))
    if not candidates:
        candidates = list(out_dir.rglob("*.ipa"))
    if not candidates:
        raise SystemExit(f"artifact 目录无 IPA: {out_dir}")
    return candidates[0]


def cmd_install(client: McpClient, args: argparse.Namespace) -> int:
    ipa = resolve_local_ipa(args)
    steps: list[str] = [f"local_ipa={ipa}"]

    if args.wake:
        client.call("wake_and_home")
        steps.append("wake_and_home")

    uploaded = client.upload_file(ipa, filename=ipa.name)
    steps.append(f"upload={uploaded}")

    device_path = ""
    if isinstance(uploaded, dict):
        device_path = uploaded.get("path") or uploaded.get("file_path") or uploaded.get("dest") or ""
    if not device_path:
        device_path = str(uploaded).strip()

    ins = client.call("install_app", {"path": device_path}, timeout=args.timeout)
    steps.append(f"install={ins}")

    out = {"steps": steps, "device_path": device_path, "install_result": ins}
    _print(out)
    return 0


def extract_signal(marker_text: str, trace_text: str) -> list[str]:
    blob = marker_text + "\n" + trace_text
    return re.findall(r"SIGNAL sig=\d+", blob)


def cmd_crash(client: McpClient, args: argparse.Namespace) -> int:
    out: dict[str, Any] = {}
    try:
        out["crash_logs"] = client.call("get_crash_logs", timeout=60)
    except McpError as exc:
        out["crash_logs_error"] = str(exc)

    trace_text = client.read_sandbox_text("legado_openreader_trace.txt")
    marker_text = client.read_sandbox_text("legado_catalog_openreader.txt")
    signals = extract_signal(marker_text, trace_text)
    out["signals"] = signals
    out["marker_tail"] = marker_text[-2000:]
    out["trace_signal_lines"] = [ln for ln in trace_text.splitlines() if "SIGNAL" in ln][-30:]
    _print(out)
    return 0


def collect_ui_texts(client: McpClient) -> tuple[list[str], list[str]]:
    ui_texts: list[str] = []
    ocr_texts: list[str] = []
    try:
        ui = client.call("get_ui_elements", {"limit": 120}, timeout=40)
        if isinstance(ui, dict):
            ui_texts = [e.get("text", "") for e in ui.get("elements", []) if e.get("text")]
    except McpError:
        pass
    try:
        ocr = client.call("ocr_screen", timeout=50)
        if isinstance(ocr, dict):
            ocr_texts = [t.get("text", "") for t in ocr.get("texts", []) if t.get("text")]
    except McpError:
        pass
    return ui_texts, ocr_texts


def assess_reader_ui(ui_texts: list[str], ocr_texts: list[str], xiaoyan_passed: bool) -> dict[str, Any]:
    joined = "".join(ui_texts) + "".join(ocr_texts)
    has_bookshelf = any(m in joined for m in BOOKSHELF_MARKERS)
    has_reader = xiaoyan_passed or any(m in joined for m in READER_MARKERS)
    empty_bookshelf = has_bookshelf and not has_reader
    return {
        "reader_ui_ok": not empty_bookshelf,
        "has_bookshelf_marker": has_bookshelf,
        "has_reader_marker": has_reader,
        "empty_bookshelf_suspected": empty_bookshelf,
        "ui_sample": ui_texts[:15],
        "ocr_sample": ocr_texts[:15],
    }


def cmd_accept(client: McpClient, args: argparse.Namespace) -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = _ts()
    report: dict[str, Any] = {"timestamp": stamp, "steps": []}

    # reset
    paths = client.app_paths()
    report["steps"].append("reset_begin")
    deleted = clear_open_once(client, paths)
    removed = clear_trace_files(client, paths) if not args.keep_trace else []
    report["reset"] = {"deleted_open_once": deleted, "removed_trace": removed}

    # optional install
    if args.install:
        ipa = resolve_local_ipa(args)
        uploaded = client.upload_file(ipa, filename=ipa.name)
        device_path = ""
        if isinstance(uploaded, dict):
            device_path = uploaded.get("path") or uploaded.get("file_path") or ""
        if not device_path:
            device_path = str(uploaded).strip()
        ins = client.call("install_app", {"path": device_path}, timeout=args.install_timeout)
        report["install"] = {"ipa": str(ipa), "device_path": device_path, "result": ins}
        report["steps"].append("install")
        time.sleep(2)

    # mock check
    mock_status = check_mock_reachable(args.mock)
    report["mock"] = mock_status
    if args.require_mock and not mock_status["reachable"]:
        report["passed"] = False
        report["fail_reason"] = "mock_unreachable"
        out_path = OUT_DIR / f"accept_{stamp}.json"
        out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        _print(report)
        return 2

    urls = mock_urls(args.mock)
    client.call("wake_and_home")
    report["steps"].append("wake_and_home")
    client.call("kill_app", {"bundle_id": client.bundle_id})
    time.sleep(1)
    client.call("launch_app", {"bundle_id": client.bundle_id})
    report["steps"].append("launch")
    time.sleep(args.launch_wait)

    if args.import_source:
        client.call("open_url", {"url": f"legado://import/bookSource?src={urls['src']}"})
        report["steps"].append("import_source")
        time.sleep(2)

    book = args.book or urls["book"]
    source = args.source or urls["source"]
    client.call("open_url", {"url": f"legado://nativeRead?bookUrl={book}&sourceUrl={source}&idx={args.idx}"})
    report["steps"].append("nativeRead")
    time.sleep(args.wait)

    front = client.call("get_frontmost_app")
    front_bundle = front.get("bundleId") if isinstance(front, dict) else str(front)
    still_in_app = front_bundle == client.bundle_id
    report["still_in_app"] = still_in_app
    report["frontmost"] = front

    shot_path = OUT_DIR / f"accept_{stamp}.png"
    saved = client.screenshot_to(shot_path)
    report["screenshot"] = str(shot_path) if saved else None

    xiaoyan = client.call("assert_text_present", {"text": "萧炎", "timeout_ms": args.assert_timeout})
    xiaoyan_passed = bool(xiaoyan.get("passed")) if isinstance(xiaoyan, dict) else False
    report["xiaoyan"] = xiaoyan
    report["xiaoyan_passed"] = xiaoyan_passed

    ui_texts, ocr_texts = collect_ui_texts(client)
    ui_gate = assess_reader_ui(ui_texts, ocr_texts, xiaoyan_passed)
    report["reader_ui"] = ui_gate
    report["reader_ui_ok"] = ui_gate["reader_ui_ok"]

    trace_text = client.read_sandbox_text("legado_openreader_trace.txt")
    marker_text = client.read_sandbox_text("legado_catalog_openreader.txt")
    prefer_lines = [ln for ln in trace_text.splitlines() if "goStart preferNativeFull" in ln]
    strict_hits = [ln for ln in trace_text.splitlines() if "tvHasNeedleStrict" in ln]
    probe_only = [ln for ln in trace_text.splitlines() if "tvHasNeedleProbeOnly" in ln or "probeOnly" in ln]
    false_paged = [
        ln for ln in trace_text.splitlines()
        if "nativePaged=1" in ln and "tvHasNeedle+" in ln and "tvHasNeedleStrict" not in ln
    ]

    report["prefer_count"] = len(prefer_lines)
    report["preferNativeFull_count"] = len(prefer_lines)
    report["tvHasNeedleStrict_lines"] = len(strict_hits)
    report["tvHasNeedleProbeOnly_lines"] = len(probe_only)
    report["false_nativePaged_probe_only"] = len(false_paged)
    report["signals"] = extract_signal(marker_text, trace_text)
    report["has_signal"] = bool(report["signals"]) or ("SIGNAL sig=" in trace_text)
    report["trace_tail"] = trace_text[-6000:]
    report["marker_tail"] = marker_text[-2000:]

    report["passed"] = (
        still_in_app
        and xiaoyan_passed
        and report["reader_ui_ok"]
        and mock_status["reachable"]
    )

    out_path = OUT_DIR / f"accept_{stamp}.json"
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    report["report_path"] = str(out_path)
    _print(report)
    return 0 if report["passed"] else 1


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="香色真机开发套件（ios-mcp）")
    p.add_argument("--mcp", default=os.environ.get("XIANGSE_MCP", "http://192.168.1.6:8090"))
    p.add_argument("--mock", default=DEFAULT_MOCK)
    p.add_argument("--bundle", default=DEFAULT_BUNDLE)
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="设备/应用状态与 openOnce 检查")

    pr = sub.add_parser("reset", help="清除 openOnce 与 trace/marker")
    pr.add_argument("--keep-trace", action="store_true", help="保留 trace/marker")
    pr.add_argument("--backup", action="store_true", help="删除 trace 前备份到 fixtures/_devkit/backup")

    pt = sub.add_parser("trace", help="读取 trace/marker 并按关键词过滤")
    pt.add_argument("-k", "--keyword", action="append", help="额外关键词（可重复）")
    pt.add_argument("--tail", type=int, default=4000)
    pt.add_argument("--max-bytes", type=int, default=65536)
    pt.add_argument("--json", action="store_true")

    prd = sub.add_parser("read", help="深链 nativeRead 打开正文")
    prd.add_argument("--book", default="")
    prd.add_argument("--src", default="")
    prd.add_argument("--source", default="")
    prd.add_argument("--idx", default="0")
    prd.add_argument("--wait", type=float, default=14)
    prd.add_argument("--launch-wait", type=float, default=2)
    prd.add_argument("--import-source", action="store_true", default=True)
    prd.add_argument("--no-import-source", dest="import_source", action="store_false")
    prd.add_argument("--kill-first", action="store_true", default=True)
    prd.add_argument("--no-kill-first", dest="kill_first", action="store_false")

    pi = sub.add_parser("install", help="上传并安装 IPA（本地或 CI artifact）")
    pi.add_argument("--ipa", help="本地 IPA 路径")
    pi.add_argument("--run-id", help="GitHub Actions run databaseId")
    pi.add_argument("--wake", action="store_true", default=True)
    pi.add_argument("--no-wake", dest="wake", action="store_false")
    pi.add_argument("--timeout", type=float, default=300)

    sub.add_parser("crash", help="崩溃日志 + marker SIGNAL 摘要")

    pa = sub.add_parser("accept", help="一键验收：reset → read → 断言 → JSON 报告")
    pa.add_argument("--install", action="store_true", help="验收前安装 CI IPA")
    pa.add_argument("--ipa", help="安装用本地 IPA")
    pa.add_argument("--run-id", help="安装用 CI run id")
    pa.add_argument("--require-mock", action="store_true", default=True)
    pa.add_argument("--no-require-mock", dest="require_mock", action="store_false")
    pa.add_argument("--keep-trace", action="store_true")
    pa.add_argument("--book", default="")
    pa.add_argument("--source", default="")
    pa.add_argument("--idx", default="0")
    pa.add_argument("--wait", type=float, default=14)
    pa.add_argument("--launch-wait", type=float, default=2)
    pa.add_argument("--import-source", action="store_true", default=True)
    pa.add_argument("--no-import-source", dest="import_source", action="store_false")
    pa.add_argument("--assert-timeout", type=int, default=15000)
    pa.add_argument("--install-timeout", type=float, default=300)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    client = make_client(args)
    handlers = {
        "status": cmd_status,
        "reset": cmd_reset,
        "trace": cmd_trace,
        "read": cmd_read,
        "install": cmd_install,
        "crash": cmd_crash,
        "accept": cmd_accept,
    }
    try:
        return handlers[args.command](client, args)
    except McpError as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
