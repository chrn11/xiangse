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
from tools.repack.manifest import REQUIRED_FIELDS, validate_manifest
from tools.ci.acceptance_contract import (
    evaluate_acceptance,
    format_rejection_cli,
    is_dump_stale,
    manifest_identity_block,
)

DEFAULT_MOCK = os.environ.get("XIANGSE_MOCK", "http://192.168.1.4:8765")
OUT_DIR = ROOT / "fixtures" / "_devkit"
MANIFEST_STATE = OUT_DIR / "last_install_manifest.json"
MANIFEST_COPY_DIR = OUT_DIR / "manifest_copies"
TRACE_KEYWORDS = (
    "preferNativeFull",
    "SIGNAL",
    "nativePaged",
    "tvHasNeedleStrict",
    "openOnce",
)
DEBUG_DUMP_KEYWORDS = (
    "textViewL",
    "textViewR",
    "txtLen",
    "NSArrayM",
    "SIGABRT",
    "callStackSymbols",
    "pageModel",
    "ReadPageModel",
)
BOOKSHELF_MARKERS = ("书架", "書架")
READER_MARKERS = ("萧炎", "斗破", "章节", "目录", "阅读")


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _print(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def _parse_iso_utc(value: str) -> datetime | None:
    if not value:
        return None
    try:
        if value.endswith("Z"):
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _save_manifest_copy(manifest: dict[str, Any], label: str) -> Path:
    MANIFEST_COPY_DIR.mkdir(parents=True, exist_ok=True)
    dest = MANIFEST_COPY_DIR / f"{label}_{_ts()}.json"
    dest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return dest


def _load_install_state() -> dict[str, Any]:
    if MANIFEST_STATE.is_file():
        try:
            data = json.loads(MANIFEST_STATE.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            pass
    return {}


def _save_install_state(manifest: dict[str, Any]) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    state = {
        "installed_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "manifest": manifest,
    }
    MANIFEST_STATE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def _read_device_manifest(client: McpClient) -> dict[str, Any] | None:
    return client.read_build_manifest()


def _check_manifest_expectations(
    manifest: dict[str, Any] | None,
    args: argparse.Namespace,
    *,
    require_device: bool = False,
) -> tuple[list[str], dict[str, Any] | None]:
    errors: list[str] = []
    if manifest is None:
        if require_device:
            errors.append("无法从已安装 App 读取 reader-build-manifest.json")
        return errors, None
    errors.extend(
        validate_manifest(
            manifest,
            expected_variant=getattr(args, "expected_variant", None),
            expected_run=getattr(args, "expected_run", None),
            expected_sha=getattr(args, "expected_sha", None),
        )
    )
    return errors, manifest


def _guard_manifest(client: McpClient, args: argparse.Namespace, *, require_device: bool = False) -> dict[str, Any] | None:
    """任一 manifest 期望不匹配则 SystemExit(非 0)。"""
    if not any(
        (
            getattr(args, "expected_variant", None),
            getattr(args, "expected_run", None),
            getattr(args, "expected_sha", None),
            require_device,
        )
    ):
        return _read_device_manifest(client) if require_device else None
    manifest = _read_device_manifest(client)
    errors, manifest = _check_manifest_expectations(manifest, args, require_device=require_device)
    if errors:
        _print({"manifest_errors": errors, "manifest": manifest})
        raise SystemExit(3)
    return manifest


def _is_dump_stale(dump_text: str, install_state: dict[str, Any]) -> bool:
    return is_dump_stale(dump_text, install_state)


def add_manifest_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--expected-sha", help="期望 manifest 内某哈希字段完全匹配")
    parser.add_argument("--expected-run", help="期望 github_run_id")
    parser.add_argument("--expected-variant", choices=["baseline-debug", "legado-debug"], help="期望 variant")


def attach_manifest_to_output(out: dict[str, Any], manifest: dict[str, Any] | None) -> None:
    if manifest is not None:
        out["build_manifest"] = manifest


def attach_manifest_identity(
    out: dict[str, Any],
    manifest: dict[str, Any] | None,
    args: argparse.Namespace,
    *,
    manifest_missing: bool = False,
) -> None:
    ident = manifest_identity_block(
        manifest,
        expected_variant=getattr(args, "expected_variant", None),
        expected_run=getattr(args, "expected_run", None),
        expected_sha=getattr(args, "expected_sha", None),
        manifest_missing=manifest_missing,
    )
    out["manifest_identity"] = ident
    out["expected"] = ident["expected"]
    out["actual"] = ident["actual"]


def make_client(args: argparse.Namespace) -> McpClient:
    return McpClient(base_url=args.mcp, bundle_id=args.bundle)


def cmd_status(client: McpClient, args: argparse.Namespace) -> int:
    manifest = _guard_manifest(client, args, require_device=bool(
        args.expected_variant or args.expected_run or args.expected_sha
    ))
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
    attach_manifest_to_output(out, manifest)
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

    artifact = getattr(args, "artifact", None) or "LegadoBridge-IPA"
    if getattr(args, "forensics", False):
        artifact = "Reader-Forensics-IPAs"

    if args.run_id:
        dl_cmd = ["gh", "run", "download", str(args.run_id), "-n", artifact, "-D", str(out_dir)]
    else:
        workflow = "reader-forensics.yml" if getattr(args, "forensics", False) else "bridge-ci.yml"
        listed = _run_subprocess(
            ["gh", "run", "list", "--workflow", workflow, "--status", "success", "--limit", "1", "--json", "databaseId"],
            cwd=ROOT,
        )
        if listed.returncode != 0:
            raise SystemExit(f"gh run list 失败: {listed.stderr or listed.stdout}")
        runs = json.loads(listed.stdout or "[]")
        if not runs:
            raise SystemExit(f"未找到成功的 {workflow} workflow run")
        run_id = str(runs[0]["databaseId"])
        dl_cmd = ["gh", "run", "download", run_id, "-n", artifact, "-D", str(out_dir)]

    dl = _run_subprocess(dl_cmd, cwd=ROOT)
    if dl.returncode != 0:
        raise SystemExit(f"gh run download 失败: {dl.stderr or dl.stdout}")

    variant = getattr(args, "expected_variant", None)
    name_map = {
        "baseline-debug": "StandarReader-baseline-debug.ipa",
        "legado-debug": "StandarReader-legado-debug.ipa",
    }
    preferred = name_map.get(variant or "", "")
    if preferred:
        candidates = list(out_dir.rglob(preferred))
    else:
        candidates = list(out_dir.rglob("StandarReader-legado-bridge-debug.ipa"))
        if not candidates:
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
    time.sleep(2)
    try:
        client.call("launch_app", {"bundle_id": client.bundle_id})
        steps.append("launch_app_for_manifest")
        time.sleep(3)
    except McpError:
        steps.append("launch_app_for_manifest_skipped")

    manifest = _read_device_manifest(client)
    errors, manifest = _check_manifest_expectations(manifest, args, require_device=True)
    if errors:
        out = {"steps": steps, "device_path": device_path, "manifest_errors": errors, "build_manifest": manifest}
        _print(out)
        return 3

    if manifest:
        _save_install_state(manifest)
        copy_path = _save_manifest_copy(manifest, "install")
        steps.append(f"manifest_copy={copy_path}")

    out = {"steps": steps, "device_path": device_path, "install_result": ins, "build_manifest": manifest}
    _print(out)
    return 0


def extract_signal(marker_text: str, trace_text: str) -> list[str]:
    blob = marker_text + "\n" + trace_text
    return re.findall(r"SIGNAL sig=\d+", blob)


def cmd_debug_dump(client: McpClient, args: argparse.Namespace) -> int:
    manifest = _guard_manifest(client, args, require_device=bool(
        args.expected_variant or args.expected_run or args.expected_sha
    ))
    install_state = _load_install_state()
    if args.trigger:
        client.call("launch_app", {"bundle_id": client.bundle_id})
        time.sleep(args.trigger_wait)
        client.call("open_url", {"url": "legado://debugDump"})
        time.sleep(args.trigger_wait)
    dump_text = client.read_sandbox_text("legado_debug_dump.txt", max_bytes=args.max_bytes)
    crash_text = client.read_sandbox_text("legado_debug_crash.txt", max_bytes=args.max_bytes)
    if _is_dump_stale(dump_text, install_state):
        out = {
            "error": "stale_dump",
            "message": "debug dump 时间早于安装/构建时间，不可作为成功证据",
            "build_manifest": manifest,
        }
        _print(out)
        return 4
    keywords = tuple(args.keyword) if args.keyword else DEBUG_DUMP_KEYWORDS
    out = {
        "dump_hits": filter_trace_lines(dump_text, keywords),
        "crash_hits": filter_trace_lines(crash_text, keywords),
        "dump_tail": dump_text[-args.tail :],
        "crash_tail": crash_text[-args.tail :],
        "has_txtLen_zero": "txtLen=0" in dump_text,
        "has_nsarraym": "NSArrayM" in crash_text or "NSArrayM" in dump_text,
        "has_sigabrt": "SIGABRT" in crash_text or "sig=6" in crash_text,
    }
    attach_manifest_to_output(out, manifest)
    if manifest:
        copy_path = _save_manifest_copy(manifest, "debug_dump")
        out["manifest_copy"] = str(copy_path)
    if args.save:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        stamp = _ts()
        if dump_text:
            (OUT_DIR / f"debug_dump_{stamp}.txt").write_text(dump_text, encoding="utf-8")
        if crash_text:
            (OUT_DIR / f"debug_crash_{stamp}.txt").write_text(crash_text, encoding="utf-8")
        out["saved_to"] = str(OUT_DIR)

    if args.json:
        _print(out)
    else:
        for label, text in (("dump", dump_text), ("crash", crash_text)):
            if not text:
                print(f"\n=== {label}: (empty) ===")
                continue
            print(f"\n=== {label} hits ===")
            hits = out[f"{label}_hits"]
            for kw, lines in hits.items():
                if lines:
                    print(f"  [{kw}] ({len(lines)})")
                    for ln in lines[-10:]:
                        print(f"    {ln}")
        print(
            f"\nhas_txtLen_zero={out['has_txtLen_zero']} "
            f"has_nsarraym={out['has_nsarraym']} has_sigabrt={out['has_sigabrt']}"
        )
    return 0


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
    manifest: dict[str, Any] | None = None
    manifest_missing = False

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
        manifest = _read_device_manifest(client)
        if manifest is None:
            manifest_missing = True
        errors, manifest = _check_manifest_expectations(manifest, args, require_device=True)
        attach_manifest_identity(report, manifest, args, manifest_missing=manifest_missing)
        if errors or manifest_missing:
            report["manifest_errors"] = errors
            report["build_manifest"] = manifest
            report["passed"] = False
            report["strict_passed"] = False
            report["fail_reason"] = "manifest_mismatch"
            report["fail_reasons"] = ["manifest_identity_failed"] + errors
            out_path = OUT_DIR / f"accept_{stamp}.json"
            out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            _print(report)
            return 3
        if manifest:
            _save_install_state(manifest)
            report["build_manifest"] = manifest
            report["manifest_copy"] = str(_save_manifest_copy(manifest, "accept_install"))
    else:
        if args.expected_variant or args.expected_run or args.expected_sha:
            manifest = _guard_manifest(client, args, require_device=True)
        else:
            manifest = _read_device_manifest(client)
        if manifest is None and (args.expected_variant or args.expected_run or args.expected_sha):
            manifest_missing = True
        attach_manifest_to_output(report, manifest)
        attach_manifest_identity(report, manifest, args, manifest_missing=manifest_missing)
        if manifest:
            report["manifest_copy"] = str(_save_manifest_copy(manifest, "accept"))
        elif args.require_manifest:
            report["passed"] = False
            report["strict_passed"] = False
            report["fail_reasons"] = ["manifest_identity_failed"]
            out_path = OUT_DIR / f"accept_{stamp}.json"
            out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            _print(report)
            return 3

    # reset
    paths = client.app_paths()
    report["steps"].append("reset_begin")
    deleted = clear_open_once(client, paths)
    removed = clear_trace_files(client, paths) if not args.keep_trace else []
    report["reset"] = {"deleted_open_once": deleted, "removed_trace": removed}

    mock_status = check_mock_reachable(args.mock)
    report["mock"] = mock_status
    if args.require_mock and not mock_status["reachable"]:
        report["passed"] = False
        report["strict_passed"] = False
        report["fail_reason"] = "mock_unreachable"
        report["fail_reasons"] = ["mock_unreachable"]
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

    if args.trigger_dump:
        try:
            client.call("open_url", {"url": "legado://debugDump?phase=accept"})
            time.sleep(args.dump_wait)
            report["steps"].append("debugDump")
        except McpError as exc:
            report["debug_dump_trigger_error"] = str(exc)

    front = client.call("get_frontmost_app")
    front_bundle = front.get("bundleId") if isinstance(front, dict) else str(front)
    report["frontmost"] = front

    shot_path = OUT_DIR / f"accept_{stamp}.png"
    saved = client.screenshot_to(shot_path)
    report["screenshot"] = str(shot_path) if saved else None

    xiaoyan = client.call("assert_text_present", {"text": "萧炎", "timeout_ms": args.assert_timeout})
    ui_texts, ocr_texts = collect_ui_texts(client)
    ocr_full = client.ocr_screen_full()
    vc_stack = client.get_vc_stack()

    trace_text = client.read_sandbox_text("legado_openreader_trace.txt")
    marker_text = client.read_sandbox_text("legado_catalog_openreader.txt")
    dump_text = client.read_sandbox_text("legado_debug_dump.txt", max_bytes=131072)
    crash_text = client.read_sandbox_text("legado_debug_crash.txt", max_bytes=65536)
    crash_evidence = client.collect_crash_evidence()

    open_once_after: dict[str, bool] = {}
    for p in client.open_once_candidates(paths):
        open_once_after[p] = client.file_exists(p)
    report["open_once_after"] = open_once_after
    open_once_present = any(open_once_after.values())

    install_state = _load_install_state()
    accept_result = evaluate_acceptance(
        front_bundle=front_bundle,
        vc_stack=vc_stack,
        ui_texts=ui_texts,
        ocr_texts=ocr_texts,
        ocr_result=ocr_full,
        xiaoyan_assert=xiaoyan if isinstance(xiaoyan, dict) else None,
        trace_text=trace_text,
        marker_text=marker_text,
        dump_text=dump_text,
        crash_text=crash_text,
        open_once_present=open_once_present,
        overlay_tag_present=client.overlay_tag_92011_present(),
        manifest=manifest,
        manifest_missing=manifest_missing,
        install_state=install_state,
        expected_variant=args.expected_variant,
        expected_run=args.expected_run,
        expected_sha=args.expected_sha,
        mock_reachable=mock_status["reachable"],
        new_crash_detected=bool(crash_evidence.get("crash_logs")) and bool(crash_text),
    )

    report.update(accept_result.to_dict())
    report["xiaoyan"] = xiaoyan
    report["reader_ui"] = assess_reader_ui(ui_texts, ocr_texts, accept_result.checks.get("xiaoyan_passed", False))
    report["trace_tail"] = trace_text[-6000:]
    report["marker_tail"] = marker_text[-2000:]
    report["dump_tail"] = dump_text[-4000:]
    report["crash_evidence"] = {
        k: v for k, v in crash_evidence.items() if k != "sandbox_crash" or len(str(v)) < 4000
    }
    report["preferNativeFull_count"] = accept_result.checks.get("trace", {}).get("preferNativeFull_count", 0)
    report["has_signal"] = accept_result.checks.get("trace", {}).get("has_signal", False)
    report["signals"] = accept_result.checks.get("trace", {}).get("signals", [])

    out_path = OUT_DIR / f"accept_{stamp}.json"
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    report["report_path"] = str(out_path)

    if not accept_result.passed and accept_result.fail_reasons:
        report["rejection_preview"] = format_rejection_cli(accept_result)

    _print(report)

    if accept_result.fail_reasons:
        if "manifest_identity_failed" in accept_result.fail_reasons:
            return 3
        if "stale_dump" in accept_result.fail_reasons:
            return 4
        if "mock_unreachable" in accept_result.fail_reasons:
            return 2
        return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="香色真机开发套件（ios-mcp）")
    p.add_argument("--mcp", default=os.environ.get("XIANGSE_MCP", "http://192.168.1.6:8090"))
    p.add_argument("--mock", default=DEFAULT_MOCK)
    p.add_argument("--bundle", default=DEFAULT_BUNDLE)
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="设备/应用状态与 openOnce 检查")
    ps = sub.choices["status"]
    add_manifest_args(ps)

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
    pi.add_argument("--forensics", action="store_true", help="从 reader-forensics workflow 下载 artifact")
    add_manifest_args(pi)

    sub.add_parser("crash", help="崩溃日志 + marker SIGNAL 摘要")

    pd = sub.add_parser("debug-dump", help="拉 legado_debug_dump/crash 并按关键词过滤")
    pd.add_argument("-k", "--keyword", action="append", help="额外关键词（可重复）")
    pd.add_argument("--tail", type=int, default=6000)
    pd.add_argument("--max-bytes", type=int, default=131072)
    pd.add_argument("--json", action="store_true")
    pd.add_argument("--save", action="store_true", help="落盘到 fixtures/_devkit")
    pd.add_argument("--trigger", action="store_true", help="先 legado://debugDump 远程写 dump")
    pd.add_argument("--trigger-wait", type=float, default=2.0, help="trigger 后等待秒数")
    add_manifest_args(pd)

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
    pa.add_argument("--trigger-dump", action="store_true", help="nativeRead 后 legado://debugDump 拉 native dump")
    pa.add_argument("--dump-wait", type=float, default=2.0)
    pa.add_argument("--require-manifest", action="store_true", help="无 manifest 时立即失败")
    pa.add_argument("--forensics", action="store_true", help="安装 forensics artifact")
    add_manifest_args(pa)

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
        "debug-dump": cmd_debug_dump,
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
