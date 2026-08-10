#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TC-08RV prerequisite gate for TC-11/TC-12.

This is a read-only, device-free gate.  It deliberately accepts *only* a
single, explicit TC-08RV report whose entire 22-case matrix is green.  A
historical partial/blocked/failed report must never be used to satisfy the
transitive TC-11 dependency, even when some individual cases are marked
``passed``.

The gate does not inspect screenshots or claim to replace the strict device
runner.  It only prevents stale or incomplete evidence from being consumed by
later cards; the runner remains responsible for producing truthful structured
assertions and evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REVIEW = ROOT / ".cursor" / "plans" / "XBS与阅读源原生闭环修复_CURRENT_REVIEW.md"

# Keep this list explicit.  A report that silently drops or renames a case is
# not equivalent to the plan's 22-case transitively required gate.
EXPECTED_CASES = (
    "XBS.no_bridge_ui_takeover",
    "XBS.three_channels",
    "XBS.tag_switch",
    "XBS.refresh_page1_replace",
    "XBS.pagination_append_dedupe",
    "XBS.cold_last_good_then_refresh",
    "XBS.offline_cache",
    "XBS.search",
    "Legado.per_source_snapshot",
    "Legado.switch_shows_own_cache",
    "Legado.cache_miss_native_loading",
    "Legado.explore_catalog_own_only",
    "Legado.search",
    "NativeLocal.source_smoke",
    "Cross.xbs_legado_xbs",
    "Cross.legado_xbs_legado",
    "Cross.aba_delayed_callback",
    "Nav.discover_book_to_detail",
    "Nav.shelf_book_no_crash",
    "Nav.detail_catalog_reader",
    "Safety.crash_delta_0",
    "Safety.manager_deep_hash_invariant",
)

# TC-08RV's contract requires these files for every case.  The runner may
# expose them as absolute paths or paths relative to ``--artifact-root``;
# either way the gate checks that every file exists and is non-empty.
COMMON_REQUIRED_ARTIFACTS = (
    "selectionToken.json",
    "controllerStack.json",
    "managerDeepHashBefore.txt",
    "managerDeepHashAfter.txt",
    "requestGeneration.json",
    "parserCount.json",
    "publishedIdentityArrN.json",
    "cacheState.json",
    "stalePermitRejectCount.json",
    "crashDelta.json",
    "screenshot.png",
)
REQUIRED_ARTIFACTS_BY_CASE = {
    case_id: list(COMMON_REQUIRED_ARTIFACTS)
    for case_id in EXPECTED_CASES
}
REQUIRED_ARTIFACTS_BY_CASE["XBS.no_bridge_ui_takeover"].append("uiOwnership.json")
REQUIRED_ARTIFACTS_BY_CASE["Cross.aba_delayed_callback"].append("permitRejects.json")
REQUIRED_ARTIFACTS_BY_CASE["Safety.crash_delta_0"] = ["crashDelta.json"]
REQUIRED_ARTIFACTS_BY_CASE["Safety.manager_deep_hash_invariant"] = [
    "managerDeepHashBefore.txt",
    "managerDeepHashAfter.txt",
]


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _bool_values(value: Any) -> list[bool]:
    """Collect booleans from an assertion tree without treating numbers as bools."""
    if isinstance(value, bool):
        return [value]
    if isinstance(value, dict):
        out: list[bool] = []
        for child in value.values():
            out.extend(_bool_values(child))
        return out
    if isinstance(value, list):
        out = []
        for child in value:
            out.extend(_bool_values(child))
        return out
    return []


def _first_nonempty(mapping: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        value = mapping.get(key)
        if value not in (None, "", [], {}, ()):  # 0 is a meaningful count
            return value
    return None


def _number(mapping: dict[str, Any], *keys: str) -> float | None:
    value = _first_nonempty(mapping, *keys)
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value) if value is not None and str(value).strip() else None
    except (TypeError, ValueError):
        return None


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _path_from_record(record: Any) -> str | None:
    if isinstance(record, str):
        return record.strip() or None
    if isinstance(record, dict):
        value = _first_nonempty(record, "path", "file", "artifact", "uri")
        return str(value).strip() if value not in (None, "") else None
    return None


def _resolve_under(root: Path, raw_path: str) -> Path | None:
    """Resolve a path and return it only when it remains under ``root``."""
    root_resolved = root.resolve()
    candidate = Path(raw_path)
    if not candidate.is_absolute():
        candidate = root_resolved / candidate
    resolved = candidate.resolve(strict=False)
    try:
        resolved.relative_to(root_resolved)
    except ValueError:
        return None
    return resolved


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _artifact_records(result: dict[str, Any]) -> list[Any]:
    for key in ("artifactPaths", "artifacts", "requiredArtifacts"):
        raw = result.get(key)
        if isinstance(raw, dict):
            # Accept {artifactName: path|{path,size}} and preserve names for
            # diagnostics while still checking every value.
            return [
                value if isinstance(value, dict) else {"name": name, "path": value}
                for name, value in raw.items()
            ]
        if isinstance(raw, list):
            return raw
    return []


def _validate_artifacts(
    case_id: str,
    result: dict[str, Any],
    *,
    artifact_root: Path,
    seen_paths: dict[Path, str],
) -> list[str]:
    errors: list[str] = []
    records = _artifact_records(result)
    if not records:
        return [f"{case_id}: required artifact metadata missing"]
    paths: dict[str, Path] = {}
    for idx, record in enumerate(records):
        path_text = _path_from_record(record)
        if not path_text:
            errors.append(f"{case_id}: artifact[{idx}] path missing")
            continue
        path = _resolve_under(artifact_root, path_text)
        if path is None:
            errors.append(f"{case_id}: artifact escapes artifactRoot: {path_text}")
            continue
        case_scope = case_id.replace(".", "_")
        try:
            relative = path.relative_to(artifact_root.resolve())
        except ValueError:
            errors.append(f"{case_id}: artifact escapes artifactRoot: {path_text}")
            continue
        # Artifacts may live below an image/json subdirectory, but the
        # sanitized case id must occur in the resolved path.  This prevents a
        # single shared fixture from satisfying multiple cases.
        if case_scope not in relative.parts:
            errors.append(f"{case_id}: artifact is not case-scoped: {path_text}")
        owner = seen_paths.get(path)
        if owner is not None and owner != case_id:
            errors.append(f"{case_id}: artifact path reused by {owner}: {path}")
        else:
            seen_paths[path] = case_id
        paths[path.name] = path
        size = record.get("size") if isinstance(record, dict) else None
        if size is not None:
            try:
                if int(size) <= 0:
                    errors.append(f"{case_id}: artifact {path_text} declares empty size")
            except (TypeError, ValueError):
                errors.append(f"{case_id}: artifact {path_text} has invalid size")
        if not path.is_file():
            errors.append(f"{case_id}: artifact missing: {path}")
        elif path.stat().st_size <= 0:
            errors.append(f"{case_id}: artifact empty: {path}")
        elif size is not None:
            try:
                if path.stat().st_size != int(size):
                    errors.append(f"{case_id}: artifact {path_text} size mismatch")
            except (TypeError, ValueError):
                pass
        declared_sha = _first_nonempty(record, "sha256", "sha256Hex", "sha256_hash") if isinstance(record, dict) else None
        if declared_sha is not None:
            if not re.fullmatch(r"[0-9a-fA-F]{64}", str(declared_sha)):
                errors.append(f"{case_id}: artifact {path_text} has invalid SHA-256")
            elif path.is_file() and _sha256_file(path).lower() != str(declared_sha).lower():
                errors.append(f"{case_id}: artifact {path_text} SHA-256 mismatch")
    expected = REQUIRED_ARTIFACTS_BY_CASE.get(case_id, [])
    for name in expected:
        if name not in paths:
            errors.append(f"{case_id}: required artifact not declared: {name}")
    return errors


def _validate_semantics(case_id: str, result: dict[str, Any]) -> list[str]:
    """Reject known false-positive shapes exposed by the old runner schema."""
    errors: list[str] = []
    assertions = _as_dict(result.get("assertions"))
    bools = _bool_values(assertions)
    if not assertions:
        errors.append(f"{case_id}: assertions missing")
    elif any(value is not True for value in bools):
        errors.append(f"{case_id}: at least one assertion is false")
    evidence = _as_dict(result.get("evidence"))

    if case_id == "XBS.three_channels":
        if not evidence:
            return errors + [f"{case_id}: per-channel evidence missing"]
        for channel, raw in evidence.items():
            item = _as_dict(raw)
            if item.get("on_discover") is not True and item.get("activeDiscovery") is not True:
                errors.append(f"{case_id}:{channel}: active discovery evidence missing")
            # arrN alone is explicitly not a book proof.  Require a visible
            # identity/list/count plus a request/source proof per channel.
            visible = _first_nonempty(
                item,
                "visibleBookIdentities",
                "bookIdentities",
                "visibleBooks",
                "books",
                "visibleBookCount",
                "booksVisible",
            )
            if not (
                isinstance(visible, list)
                and len(visible) > 0
                or isinstance(visible, (int, float))
                and visible > 0
            ):
                errors.append(f"{case_id}:{channel}: real visible book evidence missing")
            request = _first_nonempty(
                item,
                "request",
                "requestSource",
                "requestedSource",
                "sourceUrl",
                "sourceIdentity",
                "exactSource",
            )
            if request in (None, "", [], {}):
                errors.append(f"{case_id}:{channel}: request/source evidence missing")

    elif case_id == "XBS.tag_switch":
        tag = _first_nonempty(evidence, "selectedTag", "selected_tag")
        expected_tag = _first_nonempty(evidence, "expectedTag", "expected_tag", "requestedTag")
        if not _nonempty_string(tag) or not _nonempty_string(expected_tag) or tag != expected_tag:
            errors.append(f"{case_id}: selected tag is not an exact requested tag")
        before = _as_dict(evidence.get("before"))
        after = _as_dict(evidence.get("after"))
        before_gen = _number(before, "contentGeneration", "queryGeneration", "generation", "requestSequence")
        after_gen = _number(after, "contentGeneration", "queryGeneration", "generation", "requestSequence")
        if before_gen is None or after_gen is None or after_gen <= before_gen:
            errors.append(f"{case_id}: query/content generation did not strictly increase")

    elif case_id == "XBS.pagination_append_dedupe":
        before = _as_dict(evidence.get("before"))
        after = _as_dict(evidence.get("after"))
        page_before = _number(before, "page", "pageNumber")
        page_after = _number(after, "page", "pageNumber")
        seq_before = _number(before, "requestSequence", "sequence")
        seq_after = _number(after, "requestSequence", "sequence")
        if page_before is None or page_after is None or page_after <= page_before:
            errors.append(f"{case_id}: page number evidence missing or not increasing")
        if seq_before is None or seq_after is None or seq_after <= seq_before:
            errors.append(f"{case_id}: requestSequence evidence missing or not increasing")
        ids_before = _first_nonempty(before, "bookIdentities", "book_ids", "books")
        ids_after = _first_nonempty(after, "bookIdentities", "book_ids", "books")
        if not isinstance(ids_before, list) or not isinstance(ids_after, list):
            errors.append(f"{case_id}: before/after book identities missing")
        else:
            before_set = {json.dumps(x, ensure_ascii=False, sort_keys=True) for x in ids_before}
            after_set = {json.dumps(x, ensure_ascii=False, sort_keys=True) for x in ids_after}
            if not after_set - before_set:
                errors.append(f"{case_id}: no changed/appended book identity")
            if len(ids_after) != len(after_set):
                errors.append(f"{case_id}: appended book identities are not deduped")

    elif case_id == "XBS.search":
        if assertions.get("open_detail_native") is not True:
            errors.append(f"{case_id}: native detail open assertion is false")
        stack = _first_nonempty(evidence, "nativeDetailStack", "detailStack", "stack")
        if not isinstance(stack, list) or not stack or any(not _nonempty_string(x) for x in stack):
            errors.append(f"{case_id}: native detail stack missing")
        if isinstance(stack, list) and any("CatalogCon" in str(x) or "Bridge" in str(x) for x in stack):
            errors.append(f"{case_id}: detail stack contains non-native controller")

    elif case_id == "Legado.cache_miss_native_loading":
        # A cache miss is intentionally a zero-book state.  It must show the
        # native loading/error state without rows inherited from the previous
        # source; the generic Legado ``books > 0`` rule does not apply here.
        if assertions.get("legado") is False:
            errors.append(f"{case_id}: Legado assertion is false")
        loading = _first_nonempty(evidence, "nativeLoading", "native_loading", "loading")
        if loading is not True:
            errors.append(f"{case_id}: native loading evidence missing")
        books = _first_nonempty(evidence, "bookIdentities", "visibleBooks", "books")
        if isinstance(books, list):
            if books:
                errors.append(f"{case_id}: cache miss exposes current book rows")
        elif isinstance(books, (int, float)):
            if books != 0:
                errors.append(f"{case_id}: cache miss book count is not zero")
        else:
            errors.append(f"{case_id}: cache miss zero-book evidence missing")
        prior = _first_nonempty(
            evidence,
            "previousSourceRows",
            "priorSourceRows",
            "staleRows",
            "previous_source_rows",
            "noPreviousSourceRows",
            "no_prior_source_rows",
        )
        if isinstance(prior, bool):
            if prior is not True:
                errors.append(f"{case_id}: previous-source rows are not proven absent")
        elif isinstance(prior, (int, float)):
            if prior != 0:
                errors.append(f"{case_id}: previous-source row count is not zero")
        elif isinstance(prior, list):
            if prior:
                errors.append(f"{case_id}: previous-source rows are non-empty")
        else:
            errors.append(f"{case_id}: previous-source row isolation evidence missing")
        source = _first_nonempty(evidence, "currentSource", "sourceIdentity", "legado_name")
        if not _nonempty_string(source):
            errors.append(f"{case_id}: current-source identity missing")

    elif case_id.startswith("Legado."):
        if assertions.get("legado") is not True:
            errors.append(f"{case_id}: Legado assertion is false")
        source = _first_nonempty(evidence, "currentSource", "sourceIdentity", "legado_name")
        if not _nonempty_string(source):
            errors.append(f"{case_id}: current-source identity missing")
        books = _first_nonempty(evidence, "bookIdentities", "visibleBooks", "books")
        if isinstance(books, list):
            if not books:
                errors.append(f"{case_id}: current-source visible books empty")
        elif isinstance(books, (int, float)):
            if books <= 0:
                errors.append(f"{case_id}: current-source book count is zero")
            # Numeric ``books`` alone can be a category-wall count; a strict
            # runner must add at least one identity/name sample.
            if not _first_nonempty(evidence, "bookIdentitySample", "bookNames", "visibleBookIdentities"):
                errors.append(f"{case_id}: numeric book count lacks book identity sample")
        else:
            errors.append(f"{case_id}: current-source book evidence missing")

    elif case_id == "Nav.discover_book_to_detail":
        stack = _first_nonempty(evidence, "nativeDetailStack", "detailStack", "stack")
        if not isinstance(stack, list) or not stack or any(not _nonempty_string(x) for x in stack):
            errors.append(f"{case_id}: native detail stack missing")
        if isinstance(stack, list) and any("CatalogCon" in str(x) or "Bridge" in str(x) for x in stack):
            errors.append(f"{case_id}: Nav stack contains non-native controller")

    elif case_id == "Nav.detail_catalog_reader":
        stack = _first_nonempty(evidence, "nativeDetailCatalogReaderStack", "detailCatalogReaderStack", "stack")
        if not isinstance(stack, list) or not stack or any(not _nonempty_string(x) for x in stack):
            errors.append(f"{case_id}: detail→catalog→reader stack missing")
        elif any("bridge" in str(x).lower() for x in stack):
            errors.append(f"{case_id}: stack contains Bridge controller")
        else:
            names = [str(x).lower() for x in stack]
            detail_i = next(
                (i for i, name in enumerate(names) if any(m in name for m in ("detail", "bookinfo", "bookdetail"))),
                None,
            )
            catalog_i = next(
                (
                    i
                    for i, name in enumerate(names)
                    if any(m in name for m in ("catalog", "directory", "chapter"))
                ),
                None,
            )
            reader_i = next(
                (
                    i
                    for i, name in enumerate(names)
                    if any(m in name for m in ("textread", "reader", "readvc"))
                ),
                None,
            )
            if detail_i is None or catalog_i is None or reader_i is None or not (detail_i < catalog_i < reader_i):
                errors.append(f"{case_id}: stack is not ordered native detail→catalog→reader")

    return errors


def _read_json(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"missing report: {path}") from exc
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid JSON report {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ValueError(f"report root must be an object: {path}")
    return raw


def _review_flags(review_path: Path) -> dict[str, Any]:
    """Read the few machine-readable YAML-ish flags used by CURRENT_REVIEW.

    The review is Markdown with fenced YAML rather than a YAML dependency.  A
    missing flag is treated as a blocker (fail closed).
    """

    try:
        text = review_path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError, UnicodeError) as exc:
        return {"errors": [f"review_unreadable:{exc}"]}

    def scalar(key: str) -> str | None:
        match = re.search(rf"(?m)^\s*{re.escape(key)}:\s*([^\n#]+)", text)
        return match.group(1).strip() if match else None

    next_allowed = scalar("nextCardAllowed")
    active_card = scalar("activeCard")
    review_status = scalar("review_status")
    authorization_id = scalar("continuous_authorization_id")
    authorization_max = scalar("continuous_authorization_max_level")
    chain: list[str] = []
    chain_block = re.search(r"(?ms)^chain:\s*\n(?P<body>.*?)(?=^\S|\Z)", text)
    if chain_block:
        chain = re.findall(r"(?m)^\s*-\s*(TC-[A-Za-z0-9-]+)\s*$", chain_block.group("body"))
    return {
        "nextCardAllowed": next_allowed.lower() == "true" if next_allowed else None,
        "activeCard": active_card,
        "review_status": review_status,
        "continuous_authorization_id": authorization_id,
        "continuous_authorization_max_level": authorization_max,
        "authorization_receipt_path": scalar("receipt_path"),
        "chain": chain,
        "errors": [],
    }


def _review_allows_continuous_progress(review: dict[str, Any]) -> bool:
    """A4 continuous authorization supersedes the per-card pause flag."""
    if review.get("review_status") != "continuous_execution_authorized":
        return False
    if not review.get("continuous_authorization_id"):
        return False
    if str(review.get("continuous_authorization_max_level") or "").upper() != "A4":
        return False
    chain = set(review.get("chain") or [])
    if not {"TC-11", "TC-12"}.issubset(chain):
        return False
    active = str(review.get("activeCard") or "")
    return bool(active) and not active.startswith("TC-08RV")


def _validate_authorization_receipt(review: dict[str, Any]) -> list[str]:
    """Check that the receipt exists and proves the same A4 chain/scope."""
    errors: list[str] = []
    raw_path = review.get("authorization_receipt_path") or review.get("receipt_path")
    if not isinstance(raw_path, str) or not raw_path.strip():
        return ["authorization receipt path missing"]
    path = Path(raw_path)
    if not path.is_absolute():
        path = ROOT / path
    path = path.resolve(strict=False)
    if not path.is_file():
        return [f"authorization receipt missing: {path}"]
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return [f"authorization receipt unreadable: {exc}"]
    if not isinstance(receipt, dict):
        return ["authorization receipt root is not an object"]
    receipt_id = receipt.get("authorizationID") or receipt.get("authorization_id")
    if receipt_id != review.get("continuous_authorization_id"):
        errors.append("authorization receipt ID mismatch")
    receipt_level = receipt.get("maxLevel") or receipt.get("max_level")
    if str(receipt_level).upper() != str(review.get("continuous_authorization_max_level") or "").upper():
        errors.append("authorization receipt max level mismatch")
    receipt_chain = receipt.get("chain") or receipt.get("scope") or []
    if not isinstance(receipt_chain, list):
        errors.append("authorization receipt chain/scope missing")
    else:
        required_chain = set(review.get("chain") or [])
        if not required_chain.issubset(set(str(x) for x in receipt_chain)):
            errors.append("authorization receipt scope does not cover CURRENT_REVIEW chain")
        if not {"TC-11", "TC-12"}.issubset(set(str(x) for x in receipt_chain)):
            errors.append("authorization receipt scope omits TC-11/TC-12")
    return errors


def validate_tc08rv_report(
    report: dict[str, Any],
    *,
    expected_commit: str | None = None,
    expected_clone_bundle: str | None = None,
    review: dict[str, Any] | None = None,
    artifact_root: Path | None = None,
) -> list[str]:
    """Return fail-closed reasons; an empty list means the report is usable."""

    errors: list[str] = []
    if report.get("schemaVersion") != 1:
        errors.append("schemaVersion!=1")
    if report.get("cardID") != "TC-08RV":
        errors.append("cardID_not_TC-08RV")
    if report.get("verdict") != "passed":
        errors.append(f"verdict={report.get('verdict')!r}; only exact passed is consumable")
    if report.get("deviceTouched") is not True:
        errors.append("deviceTouched!=true")
    if report.get("realBundleTouched") is not False:
        errors.append("realBundleTouched!=false")
    note = str(report.get("deviceTouchedNote") or "")
    if "clone_only" not in note:
        errors.append("device_scope_not_clone_only")
    clone_id = _first_nonempty(
        report,
        "cloneBundleId",
        "clone_bundle_id",
        "deviceBundleId",
    )
    if not isinstance(clone_id, str) or not clone_id.strip():
        errors.append("clone bundle identity is missing")
    if expected_clone_bundle and clone_id != expected_clone_bundle:
        errors.append(f"clone bundle identity={clone_id!r}; expected {expected_clone_bundle}")

    frozen = report.get("cloneBundleFrozen")
    if frozen is not True:
        errors.append("cloneBundleFrozen!=true")
    real_id = _first_nonempty(report, "realBundleId", "real_bundle_id", "protectedRealBundleId")
    vanilla_id = _first_nonempty(report, "vanillaBundleId", "vanilla_bundle_id", "protectedVanillaBundleId")
    if not _nonempty_string(real_id):
        errors.append("protected real bundle identity missing")
    if not _nonempty_string(vanilla_id):
        errors.append("vanilla bundle identity missing")
    if _nonempty_string(clone_id) and clone_id in {real_id, vanilla_id}:
        errors.append("clone bundle identity overlaps protected real/vanilla identity")
    isolation = _as_dict(report.get("containerIsolation"))
    if isolation.get("isolated") is not True:
        errors.append("containerIsolation.isolated!=true")
    clone_container = _first_nonempty(isolation, "cloneDataContainer", "cloneContainer", "clone")
    real_container = _first_nonempty(isolation, "realDataContainer", "realContainer", "real")
    if not _nonempty_string(clone_container) or not _nonempty_string(real_container):
        errors.append("clone/real data container identities missing")
    elif clone_container == real_container:
        errors.append("clone and real data container identities overlap")
    vanilla_container = _first_nonempty(
        isolation,
        "vanillaDataContainer",
        "vanillaContainer",
        "vanilla",
    )
    if vanilla_id != real_id:
        if not _nonempty_string(vanilla_container):
            errors.append("vanilla data container identity missing")
        elif vanilla_container in {clone_container, real_container}:
            errors.append("vanilla data container overlaps clone/real container")

    summary = _as_dict(report.get("summary"))
    if summary.get("verdict") != "passed":
        errors.append(f"summary.verdict={summary.get('verdict')!r}")
    counts = _as_dict(summary.get("counts"))
    expected_counts = {"passed": 22, "failed": 0, "blocked": 0, "not_run": 0, "total": 22}
    for key, expected in expected_counts.items():
        if counts.get(key) != expected:
            errors.append(f"summary.counts.{key}={counts.get(key)!r}; expected {expected}")

    passed = summary.get("passed")
    if not isinstance(passed, list) or set(passed) != set(EXPECTED_CASES):
        errors.append("summary.passed does not contain exactly all 22 canonical cases")

    if artifact_root is None:
        errors.append("artifactRoot is required")
        resolved_artifact_root = None
    else:
        resolved_artifact_root = artifact_root.resolve()
    seen_artifacts: dict[Path, str] = {}

    case_results = _as_dict(report.get("caseResults"))
    if set(case_results) != set(EXPECTED_CASES):
        missing = sorted(set(EXPECTED_CASES) - set(case_results))
        extra = sorted(set(case_results) - set(EXPECTED_CASES))
        errors.append(f"caseResults set mismatch missing={missing} extra={extra}")
    for case_id in EXPECTED_CASES:
        result = _as_dict(case_results.get(case_id))
        if result.get("status") != "passed" or result.get("passed") is not True:
            errors.append(f"{case_id}: status/passed is not strict green")
        missing_artifacts = result.get("missing_artifacts")
        if missing_artifacts not in (None, [], {}):
            errors.append(f"{case_id}: missing_artifacts is non-empty")
        if resolved_artifact_root is not None:
            errors.extend(
                _validate_artifacts(
                    case_id,
                    result,
                    artifact_root=resolved_artifact_root,
                    seen_paths=seen_artifacts,
                )
            )
        else:
            errors.append(f"{case_id}: required artifact root unavailable")
        errors.extend(_validate_semantics(case_id, result))

    performance = _as_dict(summary.get("performance") or report.get("performance"))
    if not performance:
        errors.append("performance evidence missing")
    else:
        required_samples = _number(performance, "sampleSizeRequired")
        obtained_samples = _number(performance, "sampleSizeObtained")
        samples = performance.get("samplesMs")
        if required_samples is None or required_samples < 20:
            errors.append("performance.sampleSizeRequired<20")
        if obtained_samples is None or obtained_samples < 20:
            errors.append("performance.sampleSizeObtained<20")
        if not isinstance(samples, list) or len(samples) < 20:
            errors.append("performance.samplesMs has fewer than 20 samples")
        if performance.get("p95Pass") is not True:
            errors.append("performance.p95Pass!=true")
        if _number(performance, "p95Ms") is None:
            errors.append("performance.p95Ms missing")

    identity = _as_dict(report.get("buildIdentity"))
    report_commit = str(report.get("currentHead") or report.get("baseCommit") or "")
    identity_commit = str(identity.get("commit") or "")
    if not report_commit or not identity_commit or report_commit != identity_commit:
        errors.append("build identity commit is incomplete or inconsistent")
    if expected_commit:
        if report_commit != expected_commit or identity_commit != expected_commit:
            errors.append(
                f"commit mismatch report={report_commit!r} identity={identity_commit!r} expected={expected_commit!r}"
            )
    ipa_sha = str(identity.get("ipaSha256") or "")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", ipa_sha):
        errors.append("buildIdentity.ipaSha256 is not a SHA-256")
    ipa_path_raw = identity.get("ipaPath") or identity.get("ipa")
    if not isinstance(ipa_path_raw, str) or not ipa_path_raw.strip():
        errors.append("buildIdentity.ipaPath missing")
    else:
        ipa_path = Path(ipa_path_raw)
        if not ipa_path.is_absolute():
            ipa_path = ROOT / ipa_path
        ipa_path = ipa_path.resolve(strict=False)
        if not ipa_path.is_file():
            errors.append(f"buildIdentity.ipaPath missing: {ipa_path}")
        elif re.fullmatch(r"[0-9a-fA-F]{64}", ipa_sha) and _sha256_file(ipa_path).lower() != ipa_sha.lower():
            errors.append("buildIdentity.ipaPath SHA-256 mismatch")

    if review is not None:
        errors.extend(str(x) for x in review.get("errors", []))
        errors.extend(_validate_authorization_receipt(review))
        active = str(review.get("activeCard") or "")
        if not _review_allows_continuous_progress(review):
            errors.append("CURRENT_REVIEW lacks valid continuous A4 authorization for TC-11/TC-12")
        if active.startswith("TC-08RV"):
            errors.append(f"CURRENT_REVIEW activeCard still indicates TC-08RV remediation: {active}")
    elif report.get("nextCardAllowed") is False:
        errors.append("nextCardAllowed=false without CURRENT_REVIEW authorization")
    return errors


def build_gate_result(
    report_path: Path,
    *,
    expected_commit: str | None = None,
    expected_clone_bundle: str | None = None,
    review_path: Path | None = None,
    artifact_root: Path | None = None,
) -> dict[str, Any]:
    report = _read_json(report_path)
    review = _review_flags(review_path) if review_path else None
    errors = validate_tc08rv_report(
        report,
        expected_commit=expected_commit,
        expected_clone_bundle=expected_clone_bundle,
        review=review,
        artifact_root=artifact_root,
    )
    return {
        "schemaVersion": 1,
        "gate": "TC-08RV-prerequisite-for-TC-11-TC-12",
        "reportPath": str(report_path),
        "reviewPath": str(review_path) if review_path else None,
        "artifactRoot": str(artifact_root) if artifact_root else None,
        "reportRunID": report.get("runID"),
        "reportVerdict": report.get("verdict"),
        "expectedCommit": expected_commit,
        "expectedCloneBundle": expected_clone_bundle,
        "passed": not errors,
        "errors": errors,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path, help="explicit TC-08RV task-report.json")
    parser.add_argument("--review", type=Path, default=DEFAULT_REVIEW, help="CURRENT_REVIEW path")
    parser.add_argument("--expected-commit", required=True, help="commit that the report must bind to")
    parser.add_argument(
        "--expected-clone-bundle",
        help="optional frozen clone bundle id; no TC-12 bundle id is hardcoded",
    )
    parser.add_argument(
        "--artifact-root",
        type=Path,
        required=True,
        help="root containing the report's per-case required artifact files",
    )
    parser.add_argument("--json-out", type=Path, help="optional output path for the gate result")
    args = parser.parse_args(argv)

    try:
        result = build_gate_result(
            args.report,
            expected_commit=args.expected_commit,
            expected_clone_bundle=args.expected_clone_bundle,
            review_path=args.review,
            artifact_root=args.artifact_root,
        )
    except ValueError as exc:
        result = {
            "schemaVersion": 1,
            "gate": "TC-08RV-prerequisite-for-TC-11-TC-12",
            "reportPath": str(args.report),
            "reviewPath": str(args.review),
            "artifactRoot": str(args.artifact_root),
            "passed": False,
            "errors": [str(exc)],
        }

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
