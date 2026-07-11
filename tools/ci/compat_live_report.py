#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""限速在线兼容报告（非 CI 硬门禁）。

读取 curated 清单（默认 .test_tools/curated_100_sources.json），对每个源限速探测
sourceJsonUrl / bookSourceUrl 可达性，并按类别输出成功率报告。

排除项（login/captcha/webview/comic/audio/video）不计入分母。
首版目标：排除后核心闭环成功率 >= 90%（本脚本目前做可达性 + JSON 形态探针；
完整搜索→详情→目录→正文闭环需真机/引擎就绪后扩展）。
"""
from __future__ import annotations

import argparse
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path

_HERE = Path(__file__).resolve().parent
ROOT = _HERE.parent if _HERE.name == ".test_tools" else _HERE.parents[1]
DEFAULT_LIST = ROOT / ".test_tools" / "curated_100_sources.json"
FALLBACK_LIST = ROOT / "fixtures" / "compatibility" / "curated_100.skeleton.json"


@dataclass
class ProbeResult:
    id: str
    category: str
    displayName: str
    status: str  # success | site_down | invalid_json | excluded | network_error | rule_gap | skipped
    detail: str
    latencyMs: int


def load_list(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def is_legado(obj: object) -> bool:
    if not isinstance(obj, dict):
        return False
    url = obj.get("bookSourceUrl")
    if not isinstance(url, str) or not url.strip():
        return False
    search = obj.get("searchUrl")
    return (isinstance(search, str) and bool(search.strip())) or obj.get("ruleSearch") is not None


def fetch(url: str, timeout: float) -> tuple[int, bytes | None, str]:
    ctx = ssl.create_default_context()
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "XiangseLegadoCompatProbe/1.0"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.getcode() or 200, resp.read(), ""
    except urllib.error.HTTPError as exc:
        return exc.code, None, str(exc)
    except Exception as exc:  # noqa: BLE001
        return 0, None, str(exc)


def probe_one(entry: dict, timeout: float, delay: float) -> ProbeResult:
    eid = entry.get("id", "?")
    cat = entry.get("category", "")
    name = entry.get("displayName", eid)
    excludes = entry.get("excludeReasons") or []
    if excludes:
        return ProbeResult(eid, cat, name, "excluded", ",".join(map(str, excludes)), 0)
    if not entry.get("enabled", True):
        return ProbeResult(eid, cat, name, "skipped", "enabled=false", 0)

    url = entry.get("sourceJsonUrl") or entry.get("bookSourceUrl")
    if not isinstance(url, str) or not url.strip():
        return ProbeResult(eid, cat, name, "rule_gap", "缺少 sourceJsonUrl/bookSourceUrl", 0)

    # example.invalid 骨架占位：不真正请求，记为 skipped
    if "example.invalid" in url:
        time.sleep(delay)
        return ProbeResult(eid, cat, name, "skipped", "骨架占位 URL，待替换为公开源", 0)

    t0 = time.perf_counter()
    code, body, err = fetch(url, timeout)
    latency = int((time.perf_counter() - t0) * 1000)
    time.sleep(delay)

    if code == 0 or body is None:
        return ProbeResult(eid, cat, name, "network_error", err or f"http={code}", latency)
    if code >= 400:
        return ProbeResult(eid, cat, name, "site_down", f"http={code} {err}", latency)
    try:
        data = json.loads(body.decode("utf-8", errors="replace"))
    except Exception as exc:  # noqa: BLE001
        return ProbeResult(eid, cat, name, "invalid_json", str(exc), latency)

    items = data if isinstance(data, list) else [data]
    if not any(is_legado(x) for x in items if isinstance(x, dict)):
        return ProbeResult(eid, cat, name, "rule_gap", "响应非 Legado 书源 JSON", latency)
    return ProbeResult(eid, cat, name, "success", "ok", latency)


def main() -> int:
    parser = argparse.ArgumentParser(description="限速在线兼容报告（非硬门禁）")
    parser.add_argument("--list", type=Path, default=None, help="curated JSON 路径")
    parser.add_argument("--out", type=Path, default=ROOT / ".test_tools" / "compat_report.json")
    parser.add_argument("--concurrency", type=int, default=2)
    parser.add_argument("--delay", type=float, default=1.5, help="每个源完成后额外等待秒数")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--limit", type=int, default=0, help="仅测前 N 个（0=全部）")
    args = parser.parse_args()

    list_path = args.list
    if list_path is None:
        list_path = DEFAULT_LIST if DEFAULT_LIST.is_file() else FALLBACK_LIST
    if not list_path.is_file():
        print(f"找不到 curated 清单: {list_path}", file=sys.stderr)
        return 2

    doc = load_list(list_path)
    sources = list(doc.get("sources") or [])
    if args.limit > 0:
        sources = sources[: args.limit]

    policy = doc.get("policy") or {}
    threshold = float(policy.get("successThresholdAfterExclusions") or 0.90)

    results: list[ProbeResult] = []
    with ThreadPoolExecutor(max_workers=max(1, args.concurrency)) as pool:
        futs = [
            pool.submit(probe_one, s, args.timeout, args.delay)
            for s in sources
        ]
        for fut in as_completed(futs):
            results.append(fut.result())

    results.sort(key=lambda r: r.id)
    counted = [r for r in results if r.status not in ("excluded", "skipped")]
    success = [r for r in counted if r.status == "success"]
    rate = (len(success) / len(counted)) if counted else 0.0

    by_status: dict[str, int] = {}
    for r in results:
        by_status[r.status] = by_status.get(r.status, 0) + 1

    report = {
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "list": str(list_path),
        "total": len(results),
        "counted": len(counted),
        "success": len(success),
        "successRate": round(rate, 4),
        "threshold": threshold,
        "meetsThreshold": rate >= threshold if counted else False,
        "byStatus": by_status,
        "note": "本报告默认不阻断 CI；固定夹具硬门禁见 tools/ci/validate_fixtures.py",
        "results": [asdict(r) for r in results],
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"兼容报告: {args.out}")
    print(f"  样本 {len(results)} / 计入 {len(counted)} / 成功 {len(success)} / 率 {rate:.1%}")
    print(f"  分类: {by_status}")
    if counted and rate < threshold:
        print(f"  未达阈值 {threshold:.0%}（不作为普通 CI 失败）")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
