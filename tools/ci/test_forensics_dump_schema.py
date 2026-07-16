#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Forensics dump JSON schema 契约测试（纯离线，不依赖真机）。"""
from __future__ import annotations

import json
import unittest

REQUIRED_TOP = {
    "schema_version",
    "forensics_dump_version",
    "phase",
    "timestamp_utc",
    "manifest_sha_prefix",
    "objectGraph",
    "methodOwners",
    "observerEvents",
    "lifecycleSnapshots",
    "unknown",
    "textSummary",
}

CANDIDATES = [
    "TextReadVC3",
    "TextRPageContainer",
    "TextRPageContainerPage",
    "TextRScrollContainer",
    "TextReadTV",
    "ReadPageModel",
]


def validate_forensics_dump(doc: dict) -> list[str]:
    errors: list[str] = []
    missing = REQUIRED_TOP - set(doc.keys())
    if missing:
        errors.append(f"缺少顶层字段: {sorted(missing)}")
    if doc.get("schema_version") != 2:
        errors.append(f"schema_version 应为 2，实际 {doc.get('schema_version')}")
    og = doc.get("objectGraph")
    if not isinstance(og, dict):
        errors.append("objectGraph 必须是 dict")
        return errors
    for c in CANDIDATES:
        if c not in og:
            errors.append(f"objectGraph 缺少候选 {c}")
    mo = doc.get("methodOwners")
    if isinstance(mo, dict):
        if "readerSelectors" not in mo:
            errors.append("methodOwners 缺少 readerSelectors")
    else:
        errors.append("methodOwners 必须是 dict")
    return errors


class TestForensicsDumpSchema(unittest.TestCase):
    def test_minimal_valid(self):
        doc = {
            "schema_version": 2,
            "forensics_dump_version": "2.0",
            "phase": "manual",
            "timestamp_utc": "2026-07-16T00:00:00Z",
            "manifest_sha_prefix": "abcd1234",
            "objectGraph": {c: {"count": 0, "instances": []} for c in CANDIDATES},
            "methodOwners": {"readerSelectors": [], "unresolvedSelectors": [], "classMethodLayers": {}},
            "observerEvents": [],
            "lifecycleSnapshots": {},
            "unknown": CANDIDATES,
            "textSummary": "test",
        }
        self.assertEqual(validate_forensics_dump(doc), [])

    def test_instance_shape(self):
        inst = {
            "address": "0x1",
            "class": "TextReadTV",
            "superclass": "TextReadTVBase",
            "kind": "UIView",
            "ivars": [{"name": "x", "typeEncoding": "@", "valueSummary": "null"}],
            "ctFrameFields": {},
        }
        self.assertIn("address", inst)
        self.assertIn("ivars", inst)


if __name__ == "__main__":
    unittest.main()
