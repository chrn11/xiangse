#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TC-11 文件级验收：binding/navigation/cache/hook 关键单测须存在且非空。"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# card → 必须存在的测试文件（相对仓库根）
REQUIRED_TEST_FILES: dict[str, list[str]] = {
    "binding": [
        "LegadoBridge/Tests/LegadoBridgeTests/BookIdentityTests.swift",
        "LegadoBridge/Tests/LegadoBridgeTests/BookBindingResolverTests.swift",
        "LegadoBridge/Tests/LegadoBridgeTests/BookBindingStoreV2Tests.swift",
        "LegadoBridge/Tests/LegadoBridgeTests/BookBindingMigrationTests.swift",
    ],
    "navigation": [
        "LegadoBridge/Tests/LegadoBridgeHooksTests/LBNativeBookNavigationTests.m",
        "LegadoBridge/Tests/LegadoBridgeTests/NativeNavigationIdentityTests.swift",
    ],
    "cache": [
        "LegadoBridge/Tests/LegadoBridgeTests/ExploreCatalogStoreTests.swift",
        "LegadoBridge/Tests/LegadoBridgeTests/ExploreCatalogCorePersistTests.swift",
        "LegadoBridge/Tests/LegadoBridgeTests/ExploreCatalogCoreCachePublishTests.swift",
        "LegadoBridge/Tests/LegadoBridgeTests/SourceSessionCoordinatorTests.swift",
        "LegadoBridge/Tests/LegadoBridgeTests/ExploreSwitchRaceTests.swift",
        "LegadoBridge/Tests/LegadoBridgeTests/NativeExploreSnapshotBridgeTests.swift",
    ],
    "hook": [
        "LegadoBridge/Tests/LegadoBridgeHooksTests/SetDicBookRegistryTests.m",
        "LegadoBridge/Tests/LegadoBridgeHooksTests/LBXBSModelHandoffTests.m",
        "LegadoBridge/Tests/LegadoBridgeHooksTests/LBNativeExploreModelBuilderTests.m",
    ],
    "privacy": [
        "LegadoBridge/Tests/LegadoBridgeTests/BridgeDiagnosticRedactorTests.swift",
        "LegadoBridge/Tests/LegadoBridgeTests/LegacyNativeShellMigratorTests.swift",
    ],
}

MIN_BYTES = 200


def scan_manifest() -> list[str]:
    errors: list[str] = []
    for domain, paths in REQUIRED_TEST_FILES.items():
        for rel in paths:
            p = ROOT / rel
            if not p.is_file():
                errors.append(f"{domain}: 缺少测试文件 {rel}")
                continue
            if p.stat().st_size < MIN_BYTES:
                errors.append(f"{domain}: 测试文件过短（<{MIN_BYTES}B） {rel}")
            text = p.read_text(encoding="utf-8", errors="replace")
            if "test" not in text.lower() and "XCT" not in text:
                errors.append(f"{domain}: 未检测到测试符号 {rel}")
    return errors


def main() -> int:
    errors = scan_manifest()
    if errors:
        print("TC-11 测试文件清单门禁失败：")
        for e in errors:
            print(f"  - {e}")
        return 1
    total = sum(len(v) for v in REQUIRED_TEST_FILES.values())
    print(f"TC-11 测试文件清单门禁通过（{total} 个必需文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
