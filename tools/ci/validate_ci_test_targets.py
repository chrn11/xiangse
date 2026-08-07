#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TC-11：Package.swift 测试 target 须与 bridge-ci workflow 全量覆盖一致。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "LegadoBridge" / "Package.swift"
WORKFLOW = ROOT / ".github" / "workflows" / "bridge-ci.yml"

EXPECTED_TEST_TARGETS = (
    "LegadoRuleCoreTests",
    "LegadoBridgeTests",
    "LegadoBridgeHooksTests",
)


def _parse_test_targets(pkg_text: str) -> set[str]:
    found: set[str] = set()
    for m in re.finditer(r"\.testTarget\(\s*name:\s*\"([^\"]+)\"", pkg_text):
        found.add(m.group(1))
    return found


def main() -> int:
    errors: list[str] = []
    if not PACKAGE.is_file():
        errors.append("LegadoBridge/Package.swift 不存在")
    else:
        targets = _parse_test_targets(PACKAGE.read_text(encoding="utf-8"))
        for t in EXPECTED_TEST_TARGETS:
            if t not in targets:
                errors.append(f"Package.swift 缺少 testTarget {t}")
        extra = targets - set(EXPECTED_TEST_TARGETS)
        if extra:
            errors.append(f"Package.swift 有未列入 CI 清单的 testTarget: {sorted(extra)}")

    if not WORKFLOW.is_file():
        errors.append(".github/workflows/bridge-ci.yml 不存在")
    else:
        wf = WORKFLOW.read_text(encoding="utf-8")
        if "spm-full-tests" not in wf:
            errors.append("bridge-ci.yml 缺少 spm-full-tests 全量 job")
        if "python-gates" not in wf:
            errors.append("bridge-ci.yml 缺少 python-gates job")
        if "privacy-scan" not in wf:
            errors.append("bridge-ci.yml 缺少 privacy-scan job（须在出包前）")
        if "unit-tests-smoke" in wf:
            errors.append("bridge-ci.yml 仍含 unit-tests-smoke（须删除 -only-testing 冒烟 job）")
        if "-only-testing:" in wf:
            errors.append("bridge-ci.yml 仍含 -only-testing 过滤")
        # library scheme 无 test action；全量须用 SPM Package scheme
        if "LegadoBridge-Package" not in wf:
            errors.append("bridge-ci.yml 未用 LegadoBridge-Package 跑全量单测")
        if "spm-package-full.log" not in wf:
            errors.append("bridge-ci.yml 缺少 spm-package-full.log 产出")
        if "validate_test_file_manifest.py" not in wf:
            errors.append("bridge-ci.yml 未调用 validate_test_file_manifest.py")
        if "test_clone_packaging" not in wf and "test_clone_packaging.py" not in wf:
            errors.append("bridge-ci.yml 未包含 clone packaging 门禁")

    if errors:
        print("TC-11 CI target 对齐门禁失败：")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("TC-11 CI target 对齐门禁通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
