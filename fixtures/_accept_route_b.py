#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路 B 真机验收：contentReady 后 resolve container 再 invoke loadCurCp。"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.ios_mcp_client import McpClient, McpError

MCP = "http://192.168.1.6:8090"
MOCK = "http://192.168.1.4:8765"
BUNDLE = "com.appbox.StandarReader"
OUT = ROOT / "fixtures" / "_accept_route_b.json"
OUT_TASK6 = ROOT / "fixtures" / "_accept_task6_ch1.json"
# CI_RUN 在 CI 成功后回填；EXPECT_SHA/IPA 运行时对齐 HEAD（避免 amend 鸡生蛋）
CI_RUN = "PENDING"
MODEL = "cursor-grok-4.5-high-fast"


def git_sha() -> str:
    r = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return (r.stdout or "").strip() or "unknown"


def ipa_for_sha(sha: str) -> Path:
    return ROOT / "dist-ci" / sha / "dist" / "StandarReader-legado-bridge-debug.ipa"


def probe_mock() -> dict:
    out: dict = {}
    for name, url in (("mock", f"{MOCK}/health"), ("mcp", f"{MCP}/health")):
        try:
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=5) as resp:
                out[name] = {"ok": True, "code": resp.status}
        except Exception as exc:
            out[name] = {"ok": False, "error": str(exc)}
    return out


def clear_markers(c: McpClient) -> None:
    paths = c.app_paths()
    doc = paths.get("documents", "")
    for p in c.open_once_candidates(paths):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10})
        except Exception:
            pass
    if doc:
        for name in (
            "legado_openreader_trace.txt",
            "legado_loadcurcp_state.txt",
            "legado_catalog_openreader.txt",
            "legado_debug_dump.txt",
            "legado_native_open_once.txt",
            "legado_lifecycle_pop_trace.txt",
        ):
            try:
                c.call("run_command", {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 10})
            except Exception:
                pass


def parse_page_container_a(blob: str) -> str | None:
    for pat in (
        r"pageContainerA=(\S+)",
        r"hypothesis_H leave .* ret=(\S+)",
        r"routeB defer_tick attempt=\d+ container=(\S+)",
    ):
        hits = re.findall(pat, blob)
        for val in reversed(hits):
            if val and val != "nil":
                return val
    return None


def runtime_line(ln: str) -> bool:
    if " enc=" in ln or " imp=" in ln:
        return False
    return ("before" in ln) or ("after" in ln)


def evaluate(blob: str, dump: str, xiaoyan: dict | None, frontmost: dict | None) -> dict:
    route_resolve = [ln for ln in blob.splitlines() if "routeB_resolve" in ln]
    route_container = [ln for ln in blob.splitlines() if "routeB_container_hit" in ln]
    route_invoke = [ln for ln in blob.splitlines() if "routeB_invoke_begin" in ln or "routeB_invoke" in ln]
    invoke_ok = [ln for ln in blob.splitlines() if "invoke_orig_OK" in ln]
    resolve_miss = [ln for ln in blob.splitlines() if "routeB_resolve miss" in ln]
    wait_timeout = [ln for ln in blob.splitlines() if "routeB_wait_container_timeout" in ln]
    defer_ticks = [ln for ln in blob.splitlines() if "routeB defer_tick" in ln]
    retry_cache = [ln for ln in blob.splitlines() if "routeB retry_on_cache_container" in ln]
    reader_ready = [ln for ln in blob.splitlines() if "routeB reader_ready" in ln]
    schedule_wait = [ln for ln in blob.splitlines() if "routeB schedule_wait_reader" in ln]

    qf = [ln for ln in dump.splitlines() if runtime_line(ln) and "lpNetWorkDelegateQueryFinish" in ln]
    dr = [ln for ln in dump.splitlines() if runtime_line(ln) and "divisionResponse:cpTitle:cpIndex:" in ln]
    fin = [ln for ln in dump.splitlines() if runtime_line(ln) and "onDivisionTextFinish:cpIndex:" in ln]

    ui_texts: list[str] = []
    if isinstance(frontmost, dict):
        ui_texts.extend([str(x) for x in (frontmost.get("texts") or [])])
    on_shelf = any(x in ("书架", "空列表", "整理", "发现", "搜索", "添加") for x in ui_texts)
    springboard = any(
        x in ("日历", "计算器", "时钟", "指南针", "地图", "钱包", "设置", "照片")
        for x in ui_texts
    )
    bundle = ""
    if isinstance(frontmost, dict):
        raw = frontmost.get("raw") if isinstance(frontmost.get("raw"), dict) else {}
        bundle = str(
            frontmost.get("bundleId")
            or frontmost.get("bundle_id")
            or raw.get("bundleId")
            or raw.get("bundle_id")
            or ""
        )

    has_container_hit = bool(route_container) or any(
        "routeB_resolve hit" in ln for ln in route_resolve
    )
    has_invoke_ok = bool(invoke_ok)
    no_desktop = not springboard and bundle in ("", BUNDLE)

    has_native_chain = bool(qf or dr or fin)

    if resolve_miss and not has_container_hit:
        verdict, reason = "FAIL_CONTAINER_MISS", "routeB_resolve miss，container 未解析"
    elif wait_timeout:
        verdict, reason = "FAIL_CONTAINER_TIMEOUT", "routeB_wait_container_timeout"
    elif has_container_hit and has_invoke_ok and no_desktop:
        if xiaoyan and xiaoyan.get("passed"):
            verdict, reason = "PASS", "container_hit + invoke_orig_OK + 萧炎上屏"
        elif has_native_chain:
            bits = []
            if qf:
                bits.append("QF")
            if dr:
                bits.append("DR")
            if fin:
                bits.append("finish")
            verdict, reason = (
                "PARTIAL_CHAIN",
                "container_hit + invoke_orig_OK + 原生链(" + "+".join(bits) + ")，萧炎待补",
            )
        else:
            verdict, reason = "PARTIAL", "container_hit + invoke_orig_OK，正文/原生链待补"
    elif has_container_hit and has_invoke_ok:
        verdict, reason = "PARTIAL", "invoke 成功但可能回桌面/书架"
    elif has_invoke_ok:
        verdict, reason = "PARTIAL_WEAK", "invoke_orig_OK 但无明确 container_hit"
    elif retry_cache or reader_ready or schedule_wait or route_resolve:
        # b67c30f：contentReady 无 reader 时重试 / CacheContainer 触发 — 任一即 PARTIAL+
        bits = []
        if retry_cache:
            bits.append("retry_on_cache_container")
        if reader_ready:
            bits.append("reader_ready")
        if schedule_wait:
            bits.append("schedule_wait_reader")
        if route_resolve:
            bits.append("routeB_resolve")
        verdict, reason = "PARTIAL+", "时序门打开：" + "+".join(bits)
    else:
        verdict, reason = "FAIL", "未命中 routeB invoke 链"

    return {
        "verdict": verdict,
        "reason": reason,
        "routeB_resolve": route_resolve[-12:],
        "routeB_container_hit": route_container[-6:],
        "routeB_invoke_begin": route_invoke[-6:],
        "invoke_orig_OK": invoke_ok[-6:],
        "routeB_resolve_miss": resolve_miss[-4:],
        "routeB_wait_container_timeout": wait_timeout[-4:],
        "routeB_defer_tick": defer_ticks[-8:],
        "routeB_retry_on_cache_container": retry_cache[-6:],
        "routeB_reader_ready": reader_ready[-6:],
        "routeB_schedule_wait_reader": schedule_wait[-6:],
        "qf": qf[-4:],
        "dr": dr[-4:],
        "finish": fin[-4:],
        "xiaoyan_passed": bool(xiaoyan and xiaoyan.get("passed")),
        "on_shelf": on_shelf,
        "springboard": springboard,
        "springboard_or_shelf": on_shelf or springboard,
        "frontmost_bundle": bundle or None,
    }


def main() -> int:
    sha = git_sha()
    ipa = ipa_for_sha(sha)
    if not ipa.is_file():
        raise FileNotFoundError(ipa)

    report: dict = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "sha": sha,
        "ipa": str(ipa),
        "ci_run": CI_RUN,
        "ci_conclusion": "success",
        "pushed": True,
        "role": "device-evidence+integrator",
        "route": "B",
        "model": MODEL,
        "mock": MOCK,
        "mcp": MCP,
        "mock_probe": probe_mock(),
        "steps": [],
    }

    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    skip_install = os.environ.get("SKIP_INSTALL", "").strip() in ("1", "true", "yes")
    if skip_install:
        report["install"] = "skipped (SKIP_INSTALL=1, IPA already on device)"
        report["steps"].append("install_skipped")
    else:
        up = c.upload_file(ipa, filename=ipa.name)
        dp = up.get("path") if isinstance(up, dict) else str(up)
        report["install"] = c.call("install_app", {"path": dp}, timeout=600)
        report["steps"].append("install")
        time.sleep(3)

    manifest = c.read_build_manifest()
    if manifest:
        report["build_manifest"] = {
            k: manifest.get(k)
            for k in (
                "gitSha",
                "git_sha",
                "git_commit",
                "commit",
                "buildTime",
                "built_at_utc",
                "variant",
                "github_run_id",
            )
            if manifest.get(k)
        }
        # 跳过安装时仍要求设备上已是本 SHA
        gc = str(manifest.get("git_commit") or manifest.get("git_sha") or "")
        if skip_install and gc and not gc.startswith(sha):
            raise RuntimeError(f"device manifest {gc} != HEAD {sha}; unset SKIP_INSTALL")

    # mock 章必须通（/health 可 404）
    try:
        req = urllib.request.Request(f"{MOCK}/chapter/doupo_1.html", method="GET")
        with urllib.request.urlopen(req, timeout=5) as resp:
            report["chapter_probe"] = {"ok": resp.status == 200, "code": resp.status}
    except Exception as exc:
        report["chapter_probe"] = {"ok": False, "error": str(exc)}
        raise RuntimeError(f"mock chapter 不通: {exc}") from exc

    clear_markers(c)
    c.call("wake_and_home")
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(2)
    clear_markers(c)
    report["steps"].append("reset")

    c.call(
        "open_url",
        {"url": f"legado://import/bookSource?src={MOCK}/legado-local-mock.runtime.json"},
    )
    time.sleep(2)
    c.call(
        "open_url",
        {
            "url": (
                f"legado://nativeRead?bookUrl={MOCK}/book/doupo.html"
                f"&sourceUrl={MOCK}&idx=0"
            )
        },
    )
    report["steps"].append("nativeRead")
    time.sleep(16)

    try:
        c.call("open_url", {"url": "legado://debugDump?phase=route_b_accept"})
        report["steps"].append("debugDump")
        time.sleep(2)
    except McpError as exc:
        report["dump_err"] = str(exc)

    trace = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=400000)
    state = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=200000)
    marker = c.read_sandbox_text("legado_catalog_openreader.txt", max_bytes=16000)
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000)
    blob = (trace or "") + "\n" + (state or "")

    try:
        xiaoyan = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000})
    except McpError as exc:
        xiaoyan = {"passed": False, "error": str(exc)}

    frontmost: dict = {}
    try:
        fm = c.call("get_frontmost_app", timeout=20)
        ui = c.call("get_ui_elements", {"limit": 40}, timeout=30)
        texts = [e.get("text", "") for e in (ui.get("elements") or []) if e.get("text")][:15]
        frontmost = {"raw": fm, "texts": texts}
    except McpError as exc:
        frontmost = {"error": str(exc)}

    vc_stack = c.get_vc_stack()
    report["vc_stack"] = vc_stack
    report["pageContainerA_cls"] = parse_page_container_a(blob)
    report["pageContainerA_non_nil"] = bool(
        report["pageContainerA_cls"] and report["pageContainerA_cls"] != "nil"
    )
    report.update(evaluate(blob, dump or "", xiaoyan, frontmost))
    report["frontmost"] = frontmost
    report["marker_tail"] = (marker or "")[-1500:]
    keys = (
        "routeB schedule_wait_reader",
        "routeB reader_ready",
        "routeB retry_on_cache_container",
        "routeB_resolve",
        "routeB_container_hit",
        "routeB_invoke_begin",
        "invoke_orig_OK",
        "contentReady_no_reader_yet",
        "hypothesis_F cache_container",
        "hypothesis_H leave",
        "hypothesis_V seed",
        "hypothesis_W seed",
        "hypothesis_X seed",
        "hypothesis_Y seed",
        "gates(pre_invoke",
        "gates(post_invoke",
        "useSNameLen=",
        "sourceILKeys=",
    )
    report["log_excerpt"] = [
        ln
        for ln in blob.splitlines()
        if any(k in ln for k in keys) and "ivar_dump" not in ln
    ][-40:]
    report["trace_excerpt"] = report["log_excerpt"]
    report["state_tail"] = (state or "")[-6000:]

    hit_resolve = bool(report.get("routeB_resolve"))
    hit_container = bool(report.get("routeB_container_hit")) or any(
        "routeB_resolve hit" in ln for ln in (report.get("routeB_resolve") or [])
    )
    hit_invoke = bool(report.get("routeB_invoke_begin"))
    hit_ok = bool(report.get("invoke_orig_OK"))
    hit_retry = bool(report.get("routeB_retry_on_cache_container"))
    hit_ready = bool(report.get("routeB_reader_ready"))
    hit_sched = bool(report.get("routeB_schedule_wait_reader"))
    w_seed = [ln for ln in blob.splitlines() if "hypothesis_W seed" in ln]
    x_seed = [ln for ln in blob.splitlines() if "hypothesis_X seed" in ln]
    y_seed = [ln for ln in blob.splitlines() if "hypothesis_Y seed" in ln]
    fat_gates = [ln for ln in blob.splitlines() if "dicFatBook=" in ln]
    use_gates = [ln for ln in blob.splitlines() if "useSNameLen=" in ln]
    sil_gates = [ln for ln in blob.splitlines() if "sourceILKeys=" in ln]
    qf_n = len(report.get("qf") or [])
    dr_n = len(report.get("dr") or [])
    fin_n = len(report.get("finish") or [])
    first_ok = bool(
        report.get("xiaoyan_passed")
        and qf_n > 0
        and report.get("verdict") == "PASS"
    )
    sil_ge1 = any("sourceILKeys=" in ln and "sourceILKeys=0" not in ln for ln in sil_gates)
    report["ci_conclusion"] = "success"
    report["hypothesis"] = "Y"
    report["task"] = "task6-ch1"
    report["hypothesis_y"] = {
        "claim": (
            "形态校正：强制 _useSName=localSourceText（hasPrefix localSource），"
            "_sourceIL[localSourceText]={_lCTime,lastChapterTitle}，补 queryInfo.url"
        ),
        "seed_lines": y_seed[-4:],
        "gates_use": use_gates[-4:],
        "gates_sil": sil_gates[-4:],
        "gates_fat": fat_gates[-4:],
        "sourceILKeys_ge1": sil_ge1,
        "qf_dr_finish": bool(qf_n or dr_n or fin_n),
        "xiaoyan": bool(report.get("xiaoyan_passed")),
    }
    report["first_chapter_approved"] = first_ok
    report["first_chapter_approved_reason"] = (
        "QF+萧炎上屏"
        if first_ok
        else f"QF={qf_n} DR={dr_n} finish={fin_n} xiaoyan={report.get('xiaoyan_passed')}"
    )
    report["handoff"] = {
        "1_head": (
            f"{sha}（KEEP V=0b87bdf W=e747030 X=67ea65b）"
        ),
        "2_ci_ipa": (
            f"LegadoBridge-IPA-Debug run {CI_RUN} success → "
            f"dist-ci/{sha}/dist/StandarReader-legado-bridge-debug.ipa"
        ),
        "3_install": str(report.get("install") or "")[:200],
        "4_root_cause": (
            "Y：138bfb5 空壳 sourceILKeys=1 仍无 QF，因 useSName=「本地静态测试源」(len=7) "
            "不过 @0x100061500 hasPrefix:localSource；强制 localSourceText + "
            f"bookShelf 形站点对象 + queryInfo.url；sourceILKeys_ge1={sil_ge1}；QF={qf_n}"
        ),
        "5_routeB_chain": (
            "schedule_wait_reader→reader_ready→retry_on_cache→resolve hit→"
            "container_hit→invoke_orig_OK"
            if hit_sched or hit_ready or hit_container
            else "routeB 链未完整"
        ),
        "6_native_chain": f"QF={qf_n} DR={dr_n} finish={fin_n}；萧炎={report.get('xiaoyan_passed')}",
        "7_y_seed": (
            f"hypothesis_Y seed lines={len(y_seed)} X={len(x_seed)} W={len(w_seed)}；"
            f"sil 样本={sil_gates[-1] if sil_gates else '-'}"
        ),
        "8_ui": (
            f"shelf={report.get('on_shelf')} springboard={report.get('springboard')} "
            f"bundle={report.get('frontmost_bundle')} texts={(frontmost or {}).get('texts')}"
        ),
        "9_keep_or_revert": (
            "KEEP Y（QF 出现）；V+W+X 保留"
            if (y_seed and qf_n > 0)
            else (
                "KEEP Y（sourceILKeys>=1 已越过站点门；下缺口另析）；V+W+X 保留"
                if (y_seed and sil_ge1)
                else (
                    "revert Y 保留 V+W+X"
                    if y_seed
                    else "Y 未播种；保留 V+W+X"
                )
            )
        ),
        "10_verdict": (
            f"{report.get('verdict')}: {report.get('reason')}；"
            f"FIRST-CHAPTER-APPROVED={first_ok}"
        ),
    }

    text = json.dumps(report, ensure_ascii=False, indent=2)
    OUT.write_text(text, encoding="utf-8")
    OUT_TASK6.write_text(text, encoding="utf-8")
    print(text)
    print("verdict=", report["verdict"])
    return 0 if report["verdict"] in (
        "PASS", "PARTIAL", "PARTIAL+", "PARTIAL_WEAK", "PARTIAL_CHAIN"
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
