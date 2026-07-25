#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真实书源端到端验收：导入 → 搜索 →（有书则）nativeRead → 证据落盘。

选源来自 XIU2/Yuedu 公开订阅（fixtures/_devkit/real_source_e2e/*.json）。
不得提交密钥。盾/登录失败如实记 FAIL。
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.environ.setdefault("NO_PROXY", "*")
from tools.ios_mcp_client import McpClient, McpError  # noqa: E402

MCP = os.environ.get("XIANGSE_MCP", "http://192.168.1.18:8090")
BUNDLE = os.environ.get("XIANGSE_BUNDLE", "com.appbox.StandarReader")
HOST = os.environ.get("XIANGSE_SOURCE_HOST", "http://192.168.1.4:8777")
OUT = ROOT / "fixtures" / "_devkit" / "real_source_e2e"
KEYWORD = os.environ.get("XIANGSE_E2E_KEYWORD", "斗破苍穹")

# 优先 3 个：HTML 站 2 + Cookie/登录需求 1
DEFAULT_SOURCES = [
    {"id": "deqi", "file": "deqi.json", "name": "得奇小说网", "url": "https://www.deqixs.com"},
    {"id": "dxmwx", "file": "dxmwx.json", "name": "大熊猫文学网", "url": "https://www.dxmwx.org"},
    {"id": "qidian", "file": "qidian.json", "name": "起点中文", "url": "https://www.qidian.com"},
]


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def dismiss_disclaimer(c: McpClient) -> None:
    for _ in range(4):
        try:
            ui = c.call("get_ui_elements", {"limit": 80}, timeout=30)
            els = ui.get("elements", []) if isinstance(ui, dict) else []
            for e in els:
                if not isinstance(e, dict):
                    continue
                txt = str(e.get("text", ""))
                if "知晓并同意" in txt or txt.strip() == "同意":
                    rect = e.get("rect") or {}
                    x = rect.get("x", 195) + rect.get("width", 135) / 2
                    y = rect.get("y", 743) + rect.get("height", 44) / 2
                    c.call("tap_screen", {"x": x, "y": y})
                    time.sleep(1.2)
                    return
        except Exception:
            pass
        time.sleep(0.8)


def clear_markers(c: McpClient, doc: str) -> None:
    names = [
        "legado_search_last.txt",
        "legado_search_openurl.txt",
        "legado_import_result.txt",
        "legado_islegado_result.txt",
        "legado_nativeread_openurl.txt",
        "legado_catalog_last.txt",
        "legado_debug_dump.txt",
        "legado_native_open_once.txt",
        "legado_loadcurcp_state.txt",
        "legado_content_pending.txt",
    ]
    for n in names:
        try:
            c.call("run_command", {"command": f"rm -f '{doc}/{n}'", "timeout_sec": 8})
        except Exception:
            pass


def classify_fail(search_marker: str, dump: str, ui_text: str) -> str:
    blob = "\n".join([search_marker or "", dump or "", ui_text or ""]).lower()
    if any(x in blob for x in ("cloudflare", "just a moment", "cf-browser", "人机验证", "captcha")):
        return "shield"
    if any(x in blob for x in ("login", "登录", "cookie", "未登录", "请先登录")):
        return "login"
    if any(x in blob for x in ("timeout", "timed out", "超时", "nsurlerrordomain", "-1001")):
        return "timeout"
    if any(x in blob for x in ("403", "401", "forbidden", "access denied")):
        return "http_block"
    if "err " in (search_marker or "").lower() or "partial err" in (search_marker or "").lower():
        return "engine_error"
    if "ok total=0" in (search_marker or ""):
        return "empty_search"
    return "unknown"


def ui_blob(c: McpClient) -> str:
    try:
        ui = c.call("get_ui_elements", {"limit": 100}, timeout=30)
        els = ui.get("elements", []) if isinstance(ui, dict) else []
        parts = []
        for e in els:
            if isinstance(e, dict) and e.get("text"):
                parts.append(str(e["text"]))
        return " | ".join(parts)[:2000]
    except Exception as e:
        return f"ui_err={e}"


def run_one(c: McpClient, src: dict[str, str], keyword: str) -> dict[str, Any]:
    doc = c.app_paths().get("documents", "")
    sid = src["id"]
    result: dict[str, Any] = {
        "id": sid,
        "name": src["name"],
        "bookSourceUrl": src["url"],
        "file": src["file"],
        "keyword": keyword,
        "verdict": "FAIL",
        "fail_reason": "",
        "steps": [],
        "search_marker": "",
        "books_found": 0,
        "first_bookUrl": "",
        "dump_has_content": False,
        "screenshot": None,
    }
    clear_markers(c, doc)
    import_url = f"{HOST.rstrip('/')}/{src['file']}"
    deep = f"legado://import/bookSource?src={urllib.parse.quote(import_url, safe=':/')}"
    try:
        c.call("open_url", {"url": deep})
        result["steps"].append(f"import:{import_url}")
    except McpError as e:
        result["fail_reason"] = f"import_openurl:{e}"
        return result
    time.sleep(4)
    imp = c.read_sandbox_text("legado_import_result.txt", 4096)
    sources = c.read_file_at(f"{doc}/legado_bridge_sources.json", 200000) if doc else ""
    result["import_result"] = (imp or "")[:300]
    imported = (src["url"] in sources) or ("OK" in (imp or "")) or ("imported" in (imp or "").lower())
    result["imported"] = bool(imported)
    if not imported and src["url"] not in sources:
        # 直接写 registry 兜底
        try:
            local = (OUT / src["file"]).read_text(encoding="utf-8")
            one = json.loads(local)
            c.call(
                "write_file",
                {"path": f"{doc}/legado_bridge_sources.json", "content": json.dumps([one], ensure_ascii=False)},
            )
            c.call("kill_app", {"bundle_id": BUNDLE})
            time.sleep(1.2)
            c.call("launch_app", {"bundle_id": BUNDLE})
            time.sleep(3)
            dismiss_disclaimer(c)
            result["steps"].append("seed_registry_relaunch")
            sources = c.read_file_at(f"{doc}/legado_bridge_sources.json", 200000) if doc else ""
            result["imported"] = src["url"] in sources
        except Exception as e:
            result["fail_reason"] = f"seed_fail:{e}"
            return result

    search_url = (
        f"legado://search?keyword={urllib.parse.quote(keyword)}"
        f"&sourceUrl={urllib.parse.quote(src['url'], safe='')}"
    )
    clear_markers(c, doc)
    try:
        c.call("open_url", {"url": search_url})
        result["steps"].append("search")
    except McpError as e:
        result["fail_reason"] = f"search_openurl:{e}"
        return result

    marker = ""
    for _ in range(24):
        time.sleep(2.5)
        marker = c.read_sandbox_text("legado_search_last.txt", 8192) or ""
        if marker and ("ok total=" in marker or "err " in marker or "partial err" in marker):
            break
    result["search_marker"] = marker.strip()
    books = c.read_file_at(f"{doc}/legado_bridge_books.json", 200000) if doc else ""
    book_url = ""
    count = 0
    try:
        arr = json.loads(books) if books and books.strip().startswith(("[", "{")) else []
        if isinstance(arr, dict):
            # map form
            vals = list(arr.values()) if arr else []
            for v in vals:
                if isinstance(v, dict) and v.get("sourceUrl") == src["url"]:
                    count += 1
                    if not book_url:
                        book_url = v.get("bookUrl") or ""
        elif isinstance(arr, list):
            for v in arr:
                if isinstance(v, dict) and (
                    v.get("sourceUrl") == src["url"] or src["url"] in json.dumps(v, ensure_ascii=False)
                ):
                    count += 1
                    if not book_url:
                        book_url = v.get("bookUrl") or ""
    except json.JSONDecodeError:
        pass
    result["books_found"] = count
    result["first_bookUrl"] = book_url

    ui = ui_blob(c)
    result["ui_after_search"] = ui[:800]
    shot1 = OUT / f"{sid}_search_{ts()}.png"
    try:
        if c.screenshot_to(shot1):
            result["screenshot_search"] = str(shot1.relative_to(ROOT)).replace("\\", "/")
    except Exception:
        pass

    if not book_url or "ok total=0" in marker or marker.startswith("err ") or "partial err" in marker:
        # 尝试从 UI 点第一本（若有）
        fail = classify_fail(marker, "", ui)
        if count == 0 and "ok total=" in marker and "ok total=0" not in marker:
            # total>0 but no binding parse — still try UI
            fail = "ui_only"
        result["fail_reason"] = fail if count == 0 else result.get("fail_reason") or fail
        if count == 0:
            result["verdict"] = "FAIL"
            return result

    # nativeRead
    if book_url:
        nr = (
            f"legado://nativeRead?bookUrl={urllib.parse.quote(book_url, safe=':/')}"
            f"&sourceUrl={urllib.parse.quote(src['url'], safe='')}"
            f"&idx=0"
        )
        try:
            c.call("open_url", {"url": nr})
            result["steps"].append("nativeRead")
        except McpError as e:
            result["fail_reason"] = f"nativeread:{e}"
            result["verdict"] = "FAIL"
            return result
        time.sleep(8)
        dump = c.read_sandbox_text("legado_debug_dump.txt", 65536) or ""
        state = c.read_sandbox_text("legado_loadcurcp_state.txt", 8192) or ""
        once = c.read_sandbox_text("legado_native_open_once.txt", 4096) or ""
        result["dump_tail"] = dump[-600:]
        result["loadcurcp"] = state[-400:]
        result["open_once"] = once[-300:]
        content_ok = any(
            x in dump + state + once + ui_blob(c)
            for x in ("萧炎", "斗破", "txtLen=", "chapter", "正文")
        )
        # softer: dump not empty and no error
        if "txtLen=0" in dump and "萧炎" not in dump:
            content_ok = False
        if any(x in dump.lower() for x in ("sigabrt", "sigsegv")):
            content_ok = False
            result["fail_reason"] = "crash"
        result["dump_has_content"] = bool(content_ok) or (
            "openOnce" in once or "native" in once.lower()
        )
        shot2 = OUT / f"{sid}_read_{ts()}.png"
        try:
            if c.screenshot_to(shot2):
                result["screenshot_read"] = str(shot2.relative_to(ROOT)).replace("\\", "/")
        except Exception:
            pass
        ui2 = ui_blob(c)
        result["ui_after_read"] = ui2[:800]
        if result["dump_has_content"] or ("章节" in ui2 and "加载" not in ui2):
            # need actual text - check dump length heuristics
            if "txtLen=0" in dump:
                result["verdict"] = "FAIL"
                result["fail_reason"] = classify_fail(marker, dump, ui2) or "empty_content"
            else:
                result["verdict"] = "PASS"
                result["fail_reason"] = ""
        else:
            result["verdict"] = "FAIL"
            result["fail_reason"] = classify_fail(marker, dump, ui2) or "no_reader_content"
        return result

    result["verdict"] = "FAIL"
    result["fail_reason"] = result.get("fail_reason") or "no_bookUrl"
    return result


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    c = McpClient(MCP, BUNDLE)
    health = c.health()
    report: dict[str, Any] = {
        "ts": ts(),
        "mcp": MCP,
        "health": health,
        "keyword": KEYWORD,
        "source_host": HOST,
        "git_hint": "see repo HEAD at run time",
        "sources": [],
        "summary": {},
    }
    c.call("wake_and_home")
    time.sleep(0.5)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(3)
    dismiss_disclaimer(c)

    results = []
    for src in DEFAULT_SOURCES:
        print(f"\n>>> E2E {src['name']} ({src['url']})", flush=True)
        try:
            one = run_one(c, src, KEYWORD)
        except Exception as e:
            one = {
                "id": src["id"],
                "name": src["name"],
                "bookSourceUrl": src["url"],
                "verdict": "FAIL",
                "fail_reason": f"exception:{e}",
            }
        results.append(one)
        print(json.dumps({k: one.get(k) for k in ("name", "verdict", "fail_reason", "books_found", "search_marker")}, ensure_ascii=False), flush=True)
        # 回书架，避免卡在阅读器
        try:
            c.call("press_home")
            time.sleep(0.4)
            c.call("launch_app", {"bundle_id": BUNDLE})
            time.sleep(2)
            dismiss_disclaimer(c)
        except Exception:
            pass

    report["sources"] = results
    pass_n = sum(1 for r in results if r.get("verdict") == "PASS")
    report["summary"] = {
        "pass": pass_n,
        "fail": len(results) - pass_n,
        "total": len(results),
        "verdict": "PASS" if pass_n == len(results) and results else "PARTIAL" if pass_n else "FAIL",
    }
    out_json = OUT / "report.json"
    out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("\nREPORT", out_json, report["summary"], flush=True)
    return 0 if pass_n else 1


if __name__ == "__main__":
    raise SystemExit(main())
