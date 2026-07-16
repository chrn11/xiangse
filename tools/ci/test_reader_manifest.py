# -*- coding: utf-8 -*-
"""reader-build-manifest 与 devkit 门禁单元测试（无需 macOS / 真机）。"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.repack.manifest import (  # noqa: E402
    REQUIRED_FIELDS,
    build_manifest,
    load_manifest,
    validate_manifest,
    write_manifest,
)
import tools.xiangse_devkit as devkit  # noqa: E402


def _sample_manifest(**overrides) -> dict:
    base = {
        "schema_version": 1,
        "variant": "baseline-debug",
        "git_commit": "abc123",
        "github_run_id": "999",
        "base_ipa_sha256": "a" * 64,
        "app_binary_sha256": "b" * 64,
        "legado_bridge_sha256": None,
        "legado_debug_sha256": "c" * 64,
        "built_at_utc": "2026-07-16T02:00:00Z",
    }
    base.update(overrides)
    return base


class ManifestTests(unittest.TestCase):
    def test_required_fields(self) -> None:
        m = _sample_manifest()
        for k in REQUIRED_FIELDS:
            self.assertIn(k, m)
        self.assertEqual(validate_manifest(m), [])

    def test_missing_field_fails(self) -> None:
        m = _sample_manifest()
        del m["github_run_id"]
        errs = validate_manifest(m)
        self.assertTrue(any("github_run_id" in e for e in errs))

    def test_variant_mismatch(self) -> None:
        m = _sample_manifest(variant="legado-debug", legado_bridge_sha256="d" * 64)
        errs = validate_manifest(m, expected_variant="baseline-debug")
        self.assertTrue(any("variant" in e for e in errs))

    def test_run_mismatch(self) -> None:
        m = _sample_manifest()
        errs = validate_manifest(m, expected_run="1000")
        self.assertTrue(any("github_run_id" in e for e in errs))

    def test_sha_mismatch(self) -> None:
        m = _sample_manifest()
        errs = validate_manifest(m, expected_sha="f" * 64)
        self.assertTrue(errs)

    def test_baseline_bridge_must_be_null(self) -> None:
        m = _sample_manifest(legado_bridge_sha256="d" * 64)
        errs = validate_manifest(m)
        self.assertTrue(any("baseline-debug" in e for e in errs))

    def test_legado_requires_bridge(self) -> None:
        m = _sample_manifest(variant="legado-debug", legado_bridge_sha256=None)
        errs = validate_manifest(m)
        self.assertTrue(any("legado-debug" in e for e in errs))

    def test_build_and_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            base = td_path / "base.ipa"
            app = td_path / "StandarReader"
            bridge = td_path / "LegadoBridge"
            debug = td_path / "LegadoBridgeDebug"
            for p in (base, app, bridge, debug):
                p.write_bytes(p.name.encode())

            m = build_manifest(
                variant="legado-debug",
                git_commit="deadbeef",
                github_run_id="42",
                base_ipa_path=base,
                app_binary_path=app,
                legado_bridge_path=bridge,
                legado_debug_path=debug,
                built_at_utc="2026-07-16T03:00:00Z",
            )
            out = td_path / "reader-build-manifest.json"
            write_manifest(out, m)
            loaded = load_manifest(out)
            self.assertEqual(loaded["variant"], "legado-debug")
            self.assertEqual(loaded["github_run_id"], "42")
            self.assertIsNotNone(loaded["legado_bridge_sha256"])


class DevkitManifestTests(unittest.TestCase):
    def test_stale_dump_detected(self) -> None:
        install_state = {
            "installed_at_utc": "2026-07-16T10:00:00Z",
            "manifest": {"built_at_utc": "2026-07-16T09:00:00Z"},
        }
        dump = "=== legado debug dump 2026-07-16T08:00:00Z ===\n"
        self.assertTrue(devkit._is_dump_stale(dump, install_state))

    def test_fresh_dump_ok(self) -> None:
        install_state = {
            "installed_at_utc": "2026-07-16T10:00:00Z",
            "manifest": {"built_at_utc": "2026-07-16T09:00:00Z"},
        }
        dump = "=== legado debug dump 2026-07-16T11:00:00Z ===\n"
        self.assertFalse(devkit._is_dump_stale(dump, install_state))

    def test_guard_manifest_exits_on_mismatch(self) -> None:
        args = mock.Mock(expected_variant="legado-debug", expected_run=None, expected_sha=None)
        client = mock.Mock()
        client.read_build_manifest.return_value = _sample_manifest(variant="baseline-debug")
        with self.assertRaises(SystemExit) as ctx:
            devkit._guard_manifest(client, args, require_device=True)
        self.assertEqual(ctx.exception.code, 3)


class IpaZipManifestTests(unittest.TestCase):
    def test_manifest_inside_zip(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            manifest = _sample_manifest()
            app_dir = td_path / "Payload" / "StandarReader.app"
            app_dir.mkdir(parents=True)
            (app_dir / "reader-build-manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            ipa = td_path / "test.ipa"
            with zipfile.ZipFile(ipa, "w") as zf:
                for f in app_dir.rglob("*"):
                    if f.is_file():
                        zf.write(f, f.relative_to(td_path).as_posix())
            with zipfile.ZipFile(ipa) as zf:
                names = [n for n in zf.namelist() if n.endswith("reader-build-manifest.json")]
            self.assertEqual(len(names), 1)


if __name__ == "__main__":
    unittest.main()
