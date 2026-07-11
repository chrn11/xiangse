#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""固定夹具 CI 硬门禁：校验 fixtures/ 下 Legado JSON 结构，失败即非零退出。

不发起网络请求；真实社区源在线测试见 .test_tools/compat_live_report.py。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "fixtures"

REQUIRED_FILES = [
    "legado-simple.json",
    "legado-js-heavy.json",
    "legado-local-mock.json",
]


def is_legado_source(obj: object) -> bool:
    if not isinstance(obj, dict):
        return False
    url = obj.get("bookSourceUrl")
    if not isinstance(url, str) or not url.strip():
        return False
    search = obj.get("searchUrl")
    has_search = isinstance(search, str) and bool(search.strip())
    has_rule = obj.get("ruleSearch") is not None
    return has_search or has_rule


def load_sources(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, dict):
        return [data]
    if isinstance(data, list):
        return [x for x in data if isinstance(x, dict)]
    raise ValueError(f"{path.name}: 根节点必须是 object 或 array")


def validate_file(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        sources = load_sources(path)
    except Exception as exc:  # noqa: BLE001
        return [f"{path.name}: 解析失败 — {exc}"]
    if not sources:
        return [f"{path.name}: 无书源对象"]
    legado = [s for s in sources if is_legado_source(s)]
    if not legado:
        errors.append(f"{path.name}: 未检测到合法 Legado 书源（需 bookSourceUrl + searchUrl/ruleSearch）")
    for idx, src in enumerate(legado):
        name = src.get("bookSourceName")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{path.name}#{idx}: 缺少 bookSourceName")
        # 核心闭环字段提示（硬门禁：至少存在规则键）
        for key in ("ruleSearch", "ruleToc", "ruleContent"):
            if key not in src and path.name != "legado-js-heavy.json":
                # js-heavy 可能把规则藏在 JS；simple/local-mock 必须有
                if path.name.startswith("legado-simple") or path.name.startswith("legado-local"):
                    if key not in src:
                        errors.append(f"{path.name}#{idx}: 缺少 {key}")
    return errors


def main() -> int:
    if not FIXTURES.is_dir():
        print(f"FAIL: fixtures 目录不存在: {FIXTURES}", file=sys.stderr)
        return 1

    errors: list[str] = []
    for name in REQUIRED_FILES:
        path = FIXTURES / name
        if not path.is_file():
            errors.append(f"缺少必需夹具: {name}")
            continue
        errors.extend(validate_file(path))

    # 额外扫描 fixtures 下其它 legado*.json
    for path in sorted(FIXTURES.glob("legado*.json")):
        if path.name in REQUIRED_FILES:
            continue
        errors.extend(validate_file(path))

    if errors:
        print("固定夹具硬门禁失败：")
        for e in errors:
            print(f"  - {e}")
        return 1

    print(f"固定夹具硬门禁通过（校验 {len(REQUIRED_FILES)} 个必需文件 + 额外 legado*.json）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
