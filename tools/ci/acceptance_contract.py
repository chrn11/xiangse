#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真机原生阅读验收合同（纯逻辑，可单元测试，无需 MCP / 真机）。"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from tools.repack.manifest import REQUIRED_FIELDS, validate_manifest

STANDAR_READER_BUNDLE = "com.appbox.StandarReader"
SPRINGBOARD_BUNDLE = "com.apple.springboard"
NEEDLE_DEFAULT = "萧炎"

NATIVE_READER_VC_MARKERS = (
    "TextReadVC",
    "TextRPageContainer",
    "TextReadTV",
    "ReadVC",
)
BOOKSHELF_MARKERS = ("书架", "書架", "BookShelf")
DEBUG_PANEL_MARKERS = (
    "LegadoBridgeDebug 面板",
    "LegadoBridgeDebug",
    "lb_debugDumpAction",
    "Debug 面板",
    "三指单击",
)
ERROR_PAGE_MARKERS = (
    "ReadErrorView",
    "加载失败",
    "网络错误",
    "error: no reader",
    "no reader host",
)
SPRINGBOARD_MARKERS = ("SpringBoard", "主屏幕", "滑动来解锁")

# 正文 OCR 命中区（相对屏幕比例）
BODY_REGION = {"x_min": 0.05, "x_max": 0.95, "y_min": 0.12, "y_max": 0.88}

READER_PRIVATE_IVARS = frozenset(
    {"textViewL", "textViewR", "curPageTV", "pageModel", "container", "pageContainer"}
)


def _parse_iso_utc(value: str) -> datetime | None:
    if not value:
        return None
    try:
        if value.endswith("Z"):
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def is_dump_stale(dump_text: str, install_state: dict[str, Any]) -> bool:
    if not dump_text.strip():
        return False
    installed_at = _parse_iso_utc(str(install_state.get("installed_at_utc", "")))
    manifest = install_state.get("manifest") if isinstance(install_state.get("manifest"), dict) else {}
    built_at = _parse_iso_utc(str(manifest.get("built_at_utc", "")))
    ref = installed_at or built_at
    if not ref:
        return False
    m = re.search(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)", dump_text[:300])
    if not m:
        m = re.search(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)", dump_text)
    if not m:
        return False
    dump_at = _parse_iso_utc(m.group(1))
    if not dump_at:
        return False
    return dump_at < ref


def manifest_identity_block(
    manifest: dict[str, Any] | None,
    *,
    expected_variant: str | None = None,
    expected_run: str | None = None,
    expected_sha: str | None = None,
    manifest_missing: bool = False,
) -> dict[str, Any]:
    """报告身份块：expected/actual SHA、run、variant、二进制 hash。"""
    actual = manifest or {}
    block: dict[str, Any] = {
        "expected": {
            "variant": expected_variant,
            "github_run_id": expected_run,
            "sha": expected_sha,
        },
        "actual": {
            "variant": actual.get("variant"),
            "github_run_id": actual.get("github_run_id"),
            "git_commit": actual.get("git_commit"),
            "base_ipa_sha256": actual.get("base_ipa_sha256"),
            "app_binary_sha256": actual.get("app_binary_sha256"),
            "legado_bridge_sha256": actual.get("legado_bridge_sha256"),
            "legado_debug_sha256": actual.get("legado_debug_sha256"),
            "built_at_utc": actual.get("built_at_utc"),
        },
        "manifest_present": manifest is not None and not manifest_missing,
    }
    errors: list[str] = []
    if manifest_missing or manifest is None:
        errors.append("无法读取 reader-build-manifest.json")
    else:
        for fld in REQUIRED_FIELDS:
            if fld not in actual:
                errors.append(f"manifest 缺字段: {fld}")
        errors.extend(
            validate_manifest(
                actual,
                expected_variant=expected_variant,
                expected_run=expected_run,
                expected_sha=expected_sha,
            )
        )
    block["errors"] = errors
    block["ok"] = not errors
    return block


def _norm_rect(item: dict[str, Any], screen: dict[str, float] | None) -> dict[str, float] | None:
    rect = item.get("rect") or item.get("bounding_box") or item.get("bbox")
    if not isinstance(rect, dict):
        x, y = item.get("x"), item.get("y")
        w, h = item.get("width"), item.get("height")
        if all(v is not None for v in (x, y, w, h)):
            rect = {"x": x, "y": y, "width": w, "height": h}
        else:
            return None
    x = float(rect.get("x", 0))
    y = float(rect.get("y", 0))
    w = float(rect.get("width", rect.get("w", 0)))
    h = float(rect.get("height", rect.get("h", 0)))
    if screen and all(k in screen for k in ("width", "height")) and screen["width"] > 1 and screen["height"] > 1:
        sw, sh = float(screen["width"]), float(screen["height"])
        if max(x, y, w, h) <= 1.5:
            return {"x": x * sw, "y": y * sh, "width": w * sw, "height": h * sh}
    return {"x": x, "y": y, "width": w, "height": h}


def ocr_needle_in_body_region(
    ocr_result: dict[str, Any] | list[Any] | None,
    needle: str = NEEDLE_DEFAULT,
    screen_size: dict[str, float] | None = None,
) -> dict[str, Any]:
    """OCR bounding box 须在正文区域命中 needle。"""
    out: dict[str, Any] = {"needle": needle, "hits_in_body": [], "passed": False}
    texts: list[dict[str, Any]] = []
    if isinstance(ocr_result, dict):
        raw = ocr_result.get("texts") or ocr_result.get("results") or ocr_result.get("items") or []
        if isinstance(raw, list):
            texts = [t for t in raw if isinstance(t, dict)]
        screen_size = screen_size or ocr_result.get("screen") or ocr_result.get("screenSize")
    elif isinstance(ocr_result, list):
        texts = [t for t in ocr_result if isinstance(t, dict)]

    sw = float((screen_size or {}).get("width", 390))
    sh = float((screen_size or {}).get("height", 844))
    body = {
        "x_min": BODY_REGION["x_min"] * sw,
        "x_max": BODY_REGION["x_max"] * sw,
        "y_min": BODY_REGION["y_min"] * sh,
        "y_max": BODY_REGION["y_max"] * sh,
    }

    for item in texts:
        text = str(item.get("text", ""))
        if needle not in text:
            continue
        rect = _norm_rect(item, {"width": sw, "height": sh})
        if not rect:
            continue
        cx = rect["x"] + rect["width"] / 2
        cy = rect["y"] + rect["height"] / 2
        in_body = (
            body["x_min"] <= cx <= body["x_max"]
            and body["y_min"] <= cy <= body["y_max"]
        )
        hit = {"text": text, "rect": rect, "center": {"x": cx, "y": cy}, "in_body": in_body}
        if in_body:
            out["hits_in_body"].append(hit)

    out["passed"] = len(out["hits_in_body"]) > 0
    out["body_region"] = body
    return out


def parse_vc_stack_from_dump(dump_text: str) -> list[str]:
    lines = dump_text.splitlines()
    stack: list[str] = []
    in_stack = False
    for ln in lines:
        if ln.strip().startswith("vcStack:"):
            in_stack = True
            continue
        if in_stack:
            s = ln.strip()
            if not s:
                break
            if s.startswith("readerVC=") or s.startswith("readerHost=") or s.startswith("error:"):
                break
            if s[0].isalpha() or s.startswith("UI"):
                stack.append(s)
    if stack:
        return stack
    for ln in lines:
        if "## TextReadVC" in ln or "TextReadVC3" in ln:
            m = re.search(r"(TextReadVC\w*)", ln)
            if m:
                stack.append(m.group(1))
    return stack


def vc_stack_has_native_reader(vc_stack: list[str]) -> bool:
    joined = " ".join(vc_stack)
    return any(m in joined for m in NATIVE_READER_VC_MARKERS)


def classify_screen(ui_texts: list[str], ocr_texts: list[str], front_bundle: str) -> dict[str, Any]:
    joined = "".join(ui_texts) + "".join(ocr_texts)
    is_springboard = front_bundle == SPRINGBOARD_BUNDLE or any(m in joined for m in SPRINGBOARD_MARKERS)
    has_bookshelf = any(m in joined for m in BOOKSHELF_MARKERS)
    has_debug = any(m in joined for m in DEBUG_PANEL_MARKERS)
    has_error = any(m in joined for m in ERROR_PAGE_MARKERS)
    has_reader_marker = any(m in joined for m in ("萧炎", "斗破", "章节", "目录"))
    empty_bookshelf = has_bookshelf and not has_reader_marker
    return {
        "is_springboard": is_springboard,
        "has_bookshelf_marker": has_bookshelf,
        "empty_bookshelf_suspected": empty_bookshelf,
        "has_debug_panel": has_debug,
        "has_error_page": has_error,
        "screen_ok": not (is_springboard or empty_bookshelf or has_debug or has_error),
    }


def parse_trace_metrics(trace_text: str, marker_text: str) -> dict[str, Any]:
    prefer_lines = [ln for ln in trace_text.splitlines() if "goStart preferNativeFull" in ln]
    strict_hits = [ln for ln in trace_text.splitlines() if "tvHasNeedleStrict" in ln]
    probe_only = [
        ln for ln in trace_text.splitlines()
        if "tvHasNeedleProbeOnly" in ln or "probeOnly" in ln
    ]
    false_paged = [
        ln for ln in trace_text.splitlines()
        if "nativePaged=1" in ln and "tvHasNeedle+" in ln and "tvHasNeedleStrict" not in ln
    ]
    native_paged_lines = [ln for ln in trace_text.splitlines() if re.search(r"nativePaged=1\b", ln)]
    overlay_in_trace = "overlay92011" in trace_text or "overlay92011" in marker_text
    signals = re.findall(r"SIGNAL sig=\d+", marker_text + "\n" + trace_text)
    return {
        "preferNativeFull_count": len(prefer_lines),
        "tvHasNeedleStrict_lines": len(strict_hits),
        "tvHasNeedleProbeOnly_lines": len(probe_only),
        "false_nativePaged_probe_only": len(false_paged),
        "nativePaged_lines": len(native_paged_lines),
        "has_native_paged_signal": len(native_paged_lines) > 0 or any("nativePaged=1" in ln for ln in strict_hits),
        "has_signal": bool(signals) or "SIGNAL sig=" in trace_text,
        "signals": signals,
        "overlay_in_trace": overlay_in_trace,
        "probe_only_counts_as_pass": False,
    }


def parse_native_dump(dump_text: str) -> dict[str, Any]:
    """解析 legado_debug_dump / forensics textSummary。"""
    if not dump_text.strip():
        return {
            "dump_present": False,
            "host_non_null": False,
            "page_model_non_null": False,
            "ct_frame_present": False,
            "native_host_ok": False,
        }
    host_ok = bool(re.search(r"readerHost=(?!nil\b|-\s*$)(TextReadTV|TextRPageContainer)", dump_text))
    if not host_ok:
        host_ok = "TextReadTV" in dump_text and "count=" in dump_text
    page_model = re.search(r"pageModel:\s*(?!nil\b)([^\n]+)", dump_text)
    page_ok = bool(page_model and page_model.group(1).strip() not in ("-", ""))
    if not page_ok:
        page_ok = bool(re.search(r"ReadPageModel count=[1-9]", dump_text))
    ct_ok = bool(
        re.search(r"ctFrame=\{[^}]*exists\s*=\s*1", dump_text)
        or re.search(r"CTFrame.*exists.*1", dump_text)
        or re.search(r"ctFrame=1", dump_text)
        or "LBReadPageModelHasCTFrame" in dump_text
    )
    if not ct_ok and page_ok:
        ct_ok = "txtLen=" in dump_text and "txtLen=0" not in dump_text
    return {
        "dump_present": True,
        "host_non_null": host_ok,
        "page_model_non_null": page_ok,
        "ct_frame_present": ct_ok,
        "native_host_ok": host_ok and (page_ok or ct_ok),
    }


def crash_has_uncaught(crash_text: str) -> bool:
    if not crash_text.strip():
        return False
    markers = ("UNCAUGHT", "NSException", "SIGABRT", "callStackSymbols", "NSArrayM")
    return any(m in crash_text for m in markers)


@dataclass
class AcceptResult:
    passed: bool
    fail_reasons: list[str] = field(default_factory=list)
    checks: dict[str, Any] = field(default_factory=dict)
    manifest_identity: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "passed": self.passed,
            "strict_passed": self.passed,
            "fail_reasons": self.fail_reasons,
            "fail_reason": self.fail_reasons[0] if self.fail_reasons else None,
            "checks": self.checks,
            "manifest_identity": self.manifest_identity,
        }


def evaluate_acceptance(
    *,
    front_bundle: str,
    vc_stack: list[str] | None = None,
    ui_texts: list[str] | None = None,
    ocr_texts: list[str] | None = None,
    ocr_result: dict[str, Any] | None = None,
    screen_size: dict[str, float] | None = None,
    xiaoyan_assert: dict[str, Any] | None = None,
    trace_text: str = "",
    marker_text: str = "",
    dump_text: str = "",
    crash_text: str = "",
    open_once_present: bool = False,
    overlay_tag_present: bool = False,
    manifest: dict[str, Any] | None = None,
    manifest_missing: bool = False,
    install_state: dict[str, Any] | None = None,
    expected_variant: str | None = None,
    expected_run: str | None = None,
    expected_sha: str | None = None,
    mock_reachable: bool = True,
    new_crash_detected: bool = False,
    needle: str = NEEDLE_DEFAULT,
) -> AcceptResult:
    """严格 passed：全部检查项满足才为 True。"""
    reasons: list[str] = []
    checks: dict[str, Any] = {}

    ident = manifest_identity_block(
        manifest,
        expected_variant=expected_variant,
        expected_run=expected_run,
        expected_sha=expected_sha,
        manifest_missing=manifest_missing,
    )
    checks["manifest_identity"] = ident
    if not ident["ok"]:
        reasons.append("manifest_identity_failed")
        for err in ident["errors"]:
            reasons.append(f"manifest:{err}")

    if not mock_reachable:
        reasons.append("mock_unreachable")

    in_app = front_bundle == STANDAR_READER_BUNDLE
    checks["still_in_app"] = in_app
    checks["frontmost_bundle"] = front_bundle
    if not in_app:
        reasons.append("frontmost_not_standar_reader")

    stack = vc_stack or parse_vc_stack_from_dump(dump_text)
    checks["vc_stack"] = stack
    native_vc = vc_stack_has_native_reader(stack)
    checks["native_reader_vc_on_stack"] = native_vc
    if not native_vc:
        reasons.append("vc_stack_missing_native_reader")

    screen = classify_screen(ui_texts or [], ocr_texts or [], front_bundle)
    checks["screen_class"] = screen
    if not screen["screen_ok"]:
        if screen["is_springboard"]:
            reasons.append("screen_springboard")
        if screen["empty_bookshelf_suspected"]:
            reasons.append("screen_empty_bookshelf")
        if screen["has_debug_panel"]:
            reasons.append("screen_debug_panel")
        if screen["has_error_page"]:
            reasons.append("screen_error_page")

    ocr_gate = ocr_needle_in_body_region(ocr_result, needle=needle, screen_size=screen_size)
    if ocr_result is None and ocr_texts:
        ocr_gate = {
            "needle": needle,
            "passed": needle in "".join(ocr_texts),
            "hits_in_body": [],
            "fallback_joined_ocr": True,
        }
    checks["ocr_body_needle"] = ocr_gate
    xiaoyan_ok = bool(xiaoyan_assert.get("passed")) if isinstance(xiaoyan_assert, dict) else ocr_gate["passed"]
    checks["xiaoyan_passed"] = xiaoyan_ok and ocr_gate.get("passed", False)
    if not checks["xiaoyan_passed"]:
        reasons.append("ocr_body_needle_missing")

    trace = parse_trace_metrics(trace_text, marker_text)
    checks["trace"] = trace
    if trace["preferNativeFull_count"] != 1:
        reasons.append(f"preferNativeFull_count={trace['preferNativeFull_count']}")
    if trace["has_signal"]:
        reasons.append("has_signal")
    if trace["tvHasNeedleProbeOnly_lines"] > 0 and trace["tvHasNeedleStrict_lines"] == 0:
        reasons.append("probe_only_without_strict")
    if trace["false_nativePaged_probe_only"] > 0:
        reasons.append("false_nativePaged_probe_only")
    if not trace["has_native_paged_signal"] and trace["tvHasNeedleStrict_lines"] == 0:
        reasons.append("missing_native_paged_signal")

    if open_once_present:
        reasons.append("open_once_still_present")
    checks["open_once_present"] = open_once_present

    if overlay_tag_present or trace["overlay_in_trace"]:
        reasons.append("overlay_92011_present")
    checks["overlay_tag_present"] = overlay_tag_present or trace["overlay_in_trace"]

    install_state = install_state or {}
    stale = is_dump_stale(dump_text, install_state) if dump_text else False
    checks["dump_stale"] = stale
    if stale:
        reasons.append("stale_dump")

    dump_native = parse_native_dump(dump_text)
    checks["native_dump"] = dump_native
    if dump_text and not dump_native["native_host_ok"]:
        reasons.append("native_dump_host_or_model_empty")
    if dump_text and not dump_native["page_model_non_null"] and not dump_native["ct_frame_present"]:
        reasons.append("native_dump_no_page_model_or_ctframe")

    uncaught = crash_has_uncaught(crash_text)
    checks["crash"] = {"uncaught": uncaught, "new_crash": new_crash_detected}
    if uncaught or new_crash_detected:
        reasons.append("crash_or_uncaught")

    passed = len(reasons) == 0
    return AcceptResult(passed=passed, fail_reasons=reasons, checks=checks, manifest_identity=ident)


def format_rejection_cli(result: AcceptResult) -> str:
    """供文档/示例：假通过场景被拒绝时的 CLI 风格输出。"""
    lines = ["=== acceptance-contract REJECTED ==="]
    lines.append(f"strict_passed={result.passed}")
    if result.fail_reasons:
        lines.append("fail_reasons:")
        for r in result.fail_reasons:
            lines.append(f"  - {r}")
    lines.append("manifest_identity:")
    lines.append(json.dumps(result.manifest_identity, ensure_ascii=False, indent=2))
    lines.append("checks:")
    lines.append(json.dumps(result.checks, ensure_ascii=False, indent=2))
    return "\n".join(lines)
