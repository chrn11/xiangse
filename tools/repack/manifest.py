#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成并校验 reader-build-manifest.json（forensics 双包身份契约）。"""
from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
REQUIRED_FIELDS = (
    "schema_version",
    "variant",
    "git_commit",
    "github_run_id",
    "base_ipa_sha256",
    "app_binary_sha256",
    "legado_bridge_sha256",
    "legado_debug_sha256",
    "built_at_utc",
)
VALID_VARIANTS = frozenset({"baseline-debug", "legado-debug"})


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_manifest(
    *,
    variant: str,
    git_commit: str,
    github_run_id: str,
    base_ipa_path: Path,
    app_binary_path: Path,
    legado_bridge_path: Path | None,
    legado_debug_path: Path | None,
    built_at_utc: str | None = None,
) -> dict[str, Any]:
    if variant not in VALID_VARIANTS:
        raise ValueError(f"未知 variant: {variant}")
    if not base_ipa_path.is_file():
        raise FileNotFoundError(f"基线 IPA 不存在: {base_ipa_path}")
    if not app_binary_path.is_file():
        raise FileNotFoundError(f"主程序不存在: {app_binary_path}")

    bridge_hash: str | None = None
    if legado_bridge_path and legado_bridge_path.is_file():
        bridge_hash = sha256_file(legado_bridge_path)
    elif variant == "legado-debug":
        raise FileNotFoundError(f"legado-debug 缺少 LegadoBridge: {legado_bridge_path}")

    debug_hash: str | None = None
    if legado_debug_path and legado_debug_path.is_file():
        debug_hash = sha256_file(legado_debug_path)
    else:
        raise FileNotFoundError(f"缺少 LegadoBridgeDebug: {legado_debug_path}")

    if variant == "baseline-debug" and bridge_hash is not None:
        raise ValueError("baseline-debug 不应包含 legado_bridge_sha256")

    return {
        "schema_version": SCHEMA_VERSION,
        "variant": variant,
        "git_commit": git_commit,
        "github_run_id": str(github_run_id),
        "base_ipa_sha256": sha256_file(base_ipa_path),
        "app_binary_sha256": sha256_file(app_binary_path),
        "legado_bridge_sha256": bridge_hash if variant == "legado-debug" else None,
        "legado_debug_sha256": debug_hash,
        "built_at_utc": built_at_utc or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_manifest(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("manifest 必须是 JSON 对象")
    return data


def validate_manifest(
    manifest: dict[str, Any],
    *,
    expected_variant: str | None = None,
    expected_run: str | None = None,
    expected_sha: str | None = None,
) -> list[str]:
    errors: list[str] = []
    for field in REQUIRED_FIELDS:
        if field not in manifest:
            errors.append(f"缺字段: {field}")

    if manifest.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"schema_version 不符: {manifest.get('schema_version')}")

    variant = manifest.get("variant")
    if variant not in VALID_VARIANTS:
        errors.append(f"variant 非法: {variant}")
    elif expected_variant and variant != expected_variant:
        errors.append(f"variant 不符: 期望 {expected_variant} 实际 {variant}")

    if expected_run and str(manifest.get("github_run_id", "")) != str(expected_run):
        errors.append(f"github_run_id 不符: 期望 {expected_run} 实际 {manifest.get('github_run_id')}")

    if expected_sha:
        commit = str(manifest.get("git_commit", ""))
        sha_ok = expected_sha in (
            manifest.get("base_ipa_sha256"),
            manifest.get("app_binary_sha256"),
            manifest.get("legado_bridge_sha256"),
            manifest.get("legado_debug_sha256"),
        )
        commit_ok = bool(commit) and (
            commit == expected_sha or commit.startswith(expected_sha)
        )
        if not sha_ok and not commit_ok:
            errors.append(f"expected_sha 与 manifest 哈希/git_commit 均不匹配: {expected_sha}")

    if variant == "baseline-debug" and manifest.get("legado_bridge_sha256") is not None:
        errors.append("baseline-debug 的 legado_bridge_sha256 必须为 null")
    if variant == "legado-debug" and not manifest.get("legado_bridge_sha256"):
        errors.append("legado-debug 缺少 legado_bridge_sha256")

    return errors


def main(argv: list[str] | None = None) -> int:
    import argparse

    p = argparse.ArgumentParser(description="写入 reader-build-manifest.json")
    p.add_argument("--out", required=True, help="输出 JSON 路径")
    p.add_argument("--variant", required=True, choices=sorted(VALID_VARIANTS))
    p.add_argument("--git-commit", required=True)
    p.add_argument("--github-run-id", required=True)
    p.add_argument("--base-ipa", required=True, type=Path)
    p.add_argument("--app-binary", required=True, type=Path)
    p.add_argument("--legado-bridge", type=Path, default=None)
    p.add_argument("--legado-debug", required=True, type=Path)
    p.add_argument("--built-at-utc", default=None)
    args = p.parse_args(argv)

    manifest = build_manifest(
        variant=args.variant,
        git_commit=args.git_commit,
        github_run_id=args.github_run_id,
        base_ipa_path=args.base_ipa,
        app_binary_path=args.app_binary,
        legado_bridge_path=args.legado_bridge,
        legado_debug_path=args.legado_debug,
        built_at_utc=args.built_at_utc,
    )
    write_manifest(Path(args.out), manifest)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
