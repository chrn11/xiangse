#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生产 LegadoBridgeHooks 静态硬门禁：命中禁止模式即非零退出。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOKS_DIR = ROOT / "LegadoBridge" / "Sources" / "LegadoBridgeHooks"
HOOKS_FILES = ("LegadoBridgeCExports.m", "LBReadingHooks.m", "LBBridgeReaderVC.m", "LBLoadCurCpBridge.m")

READER_IVAR_PATTERN = re.compile(
    r"(?:object_setIvar|LBForceSetIvar)\(\s*readerVC\s*,\s*@\"("
    + "|".join(re.escape(x) for x in sorted(
        {"textViewL", "textViewR", "curPageTV", "pageModel", "container", "pageContainer"}
    ))
    + r")\"",
    re.MULTILINE,
)
TEXTREADTV_ALLOC = re.compile(r"\[\s*TextReadTV\s+alloc\s*\]", re.MULTILINE)
TEXTR_CONTAINER_ALLOC = re.compile(
    r"\[\s*TextRPageContainer\s+alloc\s*\]|\[\s*TextRPageContainerPage\s+alloc\s*\]",
    re.MULTILINE,
)
KVC_PAGE_MODEL = re.compile(
    r"setValue\s*:\s*[^;]+forKey\s*:\s*@\"pageModel\"|"
    r"setValue\s*:\s*[^;]+forKeyPath\s*:\s*@\"pageModel\"",
    re.MULTILINE,
)
OVERLAY_CODE = re.compile(
    r"\.tag\s*=\s*92011|\[okPaths addObject:@\"overlay92011\"\]"
)
PROBE_FUNC = re.compile(
    r"static void LBStampTextReadTVProbe\([^)]*\)\s*\{(.*?)\n\}",
    re.DOTALL,
)
DIRECT_ACCESSIBILITY_PROBE = re.compile(
    r"(?:textReadTV|tv)\.accessibilityLabel\s*=",
    re.MULTILINE,
)
SIGNAL_HANDLER = re.compile(
    r"static\s+void\s+(\w+SignalHandler\w*)\s*\([^)]*\)\s*\{(.*?)\n\}",
    re.DOTALL,
)
ASYNC_UNSAFE_IN_HANDLER = re.compile(
    r"@\"|@try|@catch|@synchronized|NSFileManager|objc_msgSend|objc_\w+\(",
    re.MULTILINE,
)


def _read_hooks() -> dict[str, str]:
    out: dict[str, str] = {}
    for name in HOOKS_FILES:
        path = HOOKS_DIR / name
        if path.is_file():
            out[name] = path.read_text(encoding="utf-8", errors="replace")
    return out


def _line_no(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def _check_reader_ivar_writes(filename: str, text: str) -> list[str]:
    errors: list[str] = []
    for m in READER_IVAR_PATTERN.finditer(text):
        errors.append(
            f"{filename}:{_line_no(text, m.start())}: 禁止 object_setIvar/LBForceSetIvar 写 reader 私有 ivar {m.group(1)!r}"
        )
    return errors


def _check_manual_allocs(filename: str, text: str) -> list[str]:
    errors: list[str] = []
    for pat, label in (
        (TEXTREADTV_ALLOC, "[TextReadTV alloc]"),
        (TEXTR_CONTAINER_ALLOC, "手工构造 TextRPageContainer"),
    ):
        for m in pat.finditer(text):
            errors.append(f"{filename}:{_line_no(text, m.start())}: 禁止 {label}")
    return errors


def _check_kvc_page_model(filename: str, text: str) -> list[str]:
    errors: list[str] = []
    for m in KVC_PAGE_MODEL.finditer(text):
        errors.append(
            f"{filename}:{_line_no(text, m.start())}: 禁止 KVC setPageModel（须走 selector 且非注入私有 ivar）"
        )
    return errors


def _check_signal_handlers(filename: str, text: str) -> list[str]:
    errors: list[str] = []
    for m in SIGNAL_HANDLER.finditer(text):
        name, body = m.group(1), m.group(2)
        if "SignalHandler" not in name:
            continue
        if ASYNC_UNSAFE_IN_HANDLER.search(body):
            errors.append(
                f"{filename}: signal handler {name} 含 ObjC/NSFileManager/objc_*（须 async-signal-safe）"
            )
    return errors


def _probe_helper_guarded(text: str) -> bool:
    m = PROBE_FUNC.search(text)
    if not m:
        return False
    head = m.group(1)[:400]
    return "LBBridgeDebugLoaded()" in head and "return" in head


def _check_overlay_guard(filename: str, text: str) -> list[str]:
    """overlay / probe 路径须由 LBBridgeDebugLoaded() 守卫（Release 禁止）。"""
    errors: list[str] = []
    probe_fn_ok = _probe_helper_guarded(text)
    for m in OVERLAY_CODE.finditer(text):
        start = max(0, m.start() - 3500)
        window = text[start : m.start()]
        if "LBBridgeDebugLoaded()" not in window:
            errors.append(
                f"{filename}:{_line_no(text, m.start())}: overlay92011/92011 无 LBBridgeDebugLoaded 守卫"
            )
    if not probe_fn_ok:
        for m in DIRECT_ACCESSIBILITY_PROBE.finditer(text):
            start = max(0, m.start() - 800)
            window = text[start : m.start()]
            if "LBBridgeDebugLoaded()" not in window and "LBStampTextReadTVProbe" not in window:
                errors.append(
                    f"{filename}:{_line_no(text, m.start())}: accessibility probe 无 LBBridgeDebugLoaded 守卫"
                )
    return errors


def scan_hooks(sources: dict[str, str] | None = None) -> list[str]:
    sources = sources or _read_hooks()
    errors: list[str] = []
    for filename, text in sources.items():
        errors.extend(_check_reader_ivar_writes(filename, text))
        errors.extend(_check_manual_allocs(filename, text))
        errors.extend(_check_kvc_page_model(filename, text))
        errors.extend(_check_signal_handlers(filename, text))
        errors.extend(_check_overlay_guard(filename, text))
    return errors


def main() -> int:
    if not HOOKS_DIR.is_dir():
        print(f"FAIL: Hooks 目录不存在: {HOOKS_DIR}", file=sys.stderr)
        return 1
    errors = scan_hooks()
    if errors:
        print("LegadoBridgeHooks 静态硬门禁失败：")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"LegadoBridgeHooks 静态硬门禁通过（扫描 {len(HOOKS_FILES)} 个生产 .m 文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
