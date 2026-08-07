#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TC-11 Release 隐私扫描：禁止明文 URL/Cookie/token 进入写盘或 NSLog 类诊断。"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SCAN_PATHS = (
    ROOT / "LegadoBridge" / "Sources" / "LegadoBridge" / "Bridge" / "LegadoBridgeCore.swift",
    ROOT / "LegadoBridge" / "Sources" / "LegadoBridge" / "Bridge" / "NativeSourceInjector.swift",
    ROOT / "LegadoBridge" / "Sources" / "LegadoBridgeHooks" / "LegadoBridgeCExports.m",
    ROOT / "LegadoBridge" / "Sources" / "LegadoBridgeHooks" / "LBReadingHooks.m",
    ROOT / "LegadoBridge" / "Sources" / "LegadoBridgeHooks" / "LBNativeBookNavigation.m",
)

# 写盘 / 日志 format 窗口内的敏感模式
SENSITIVE = re.compile(
    r"https?://[^\s\"']+|sessionid\s*[=:]|Authorization\s*:|Bearer\s+|"
    r"src=%@|book=%@|bookName|requestInfo|password|api[_-]?key",
    re.IGNORECASE,
)
WRITE_OR_LOG = re.compile(
    r"writeToFile:|write\(toFile:|write\(to:\s*URL|NSLog\s*\(|"
    r"stringWithFormat\s*:\s*@\"[^\"]*%@",
    re.MULTILINE,
)
LEGADO_DOC = re.compile(r"Documents/legado_", re.MULTILINE)
SWIFT_DEBUG_BLOCK = re.compile(r"#if\s+DEBUG\b.*?#endif", re.DOTALL)
OBJC_DEBUG_BLOCK = re.compile(r"#if\s+DEBUG\b.*?#endif", re.DOTALL)


def _strip_debug(text: str, objc: bool) -> str:
    text = re.sub(r"//.*?$", "", text, flags=re.MULTILINE)
    pat = OBJC_DEBUG_BLOCK if objc else SWIFT_DEBUG_BLOCK
    text = re.sub(pat, "", text)
    if objc:
        def _keep_not_debug(m: re.Match[str]) -> str:
            body = m.group(1)
            parts = re.split(r"#else\b", body, maxsplit=1)
            return parts[0]

        text = re.sub(r"#if\s+!DEBUG\b(.*?)#endif", _keep_not_debug, text, flags=re.DOTALL)
    else:

        def _keep_not_debug_sw(m: re.Match[str]) -> str:
            body = m.group(1)
            parts = re.split(r"#else\b", body, maxsplit=1)
            return parts[0]

        text = re.sub(r"#if\s+!DEBUG\b(.*?)#endif", _keep_not_debug_sw, text, flags=re.DOTALL)
    return text


def scan_file(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    objc = path.suffix in (".m", ".h")
    release = _strip_debug(text, objc)
    errors: list[str] = []
    for m in WRITE_OR_LOG.finditer(release):
        start = max(0, m.start() - 120)
        end = min(len(release), m.end() + 280)
        window = release[start:end]
        if not LEGADO_DOC.search(window) and "BridgeDiagnosticRedactor" not in window:
            # 非 legado 写盘路径：仅当含敏感模式时报告
            if SENSITIVE.search(window) and "redact" not in window.lower():
                line = release.count("\n", 0, m.start()) + 1
                errors.append(f"{path.relative_to(ROOT)}:{line}: Release 写盘/日志含敏感模式")
        elif LEGADO_DOC.search(window) and SENSITIVE.search(window):
            line = release.count("\n", 0, m.start()) + 1
            errors.append(f"{path.relative_to(ROOT)}:{line}: Release legado_* 写盘含敏感内容")
    return errors


def scan_all() -> list[str]:
    errors: list[str] = []
    for path in SCAN_PATHS:
        if not path.is_file():
            continue
        errors.extend(scan_file(path))
    return errors


def _load_privacy_budget() -> int | None:
    debt_path = ROOT / "tools" / "ci" / "tc11_gate_debt.json"
    if not debt_path.is_file():
        return None
    data = json.loads(debt_path.read_text(encoding="utf-8"))
    budgets = data.get("budgets") or {}
    val = budgets.get("privacy_scan_findings")
    return int(val) if val is not None else None


def main() -> int:
    errors = scan_all()
    budget = _load_privacy_budget()
    if budget is not None and len(errors) > budget:
        print(f"TC-11 Release 隐私扫描 ratchet 失败：{len(errors)} > {budget}")
        for e in errors[:20]:
            print(f"  - {e}")
        if len(errors) > 20:
            print(f"  ... 另有 {len(errors) - 20} 条")
        return 1
    if errors and budget is None:
        print("TC-11 Release 隐私扫描失败（前 20 条）：")
        for e in errors[:20]:
            print(f"  - {e}")
        if len(errors) > 20:
            print(f"  ... 另有 {len(errors) - 20} 条")
        return 1
    note = f"（{len(errors)} 处在 ratchet 预算 {budget} 内）" if budget is not None and errors else ""
    print(f"TC-11 Release 隐私扫描通过{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
