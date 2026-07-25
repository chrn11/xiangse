#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""网页等待 startBrowserAwait 真机验收。

路径：受控源 searchUrl @js → java.startBrowserAwait → 香色 LCStandarConfig
→ 点「完成验证」→ Cookie 回灌 → 后续 await_search 请求带 Cookie。

门禁（最小）：
1. legado_visible_webview.txt 含 startBrowserAwait overlay（或 user done / harvest）
2. 含 XiangseOpenWebView hit（禁止 Fallback 冒充）
3. Cookie 回灌证据：jar/dump 含 AWAIT_TOKEN，或 mock 请求日志 Cookie 含 AWAIT_TOKEN=ok
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.environ.setdefault("NO_PROXY", "*")
from tools.ios_mcp_client import McpClient, McpError  # noqa: E402

MCP = os.environ.get("XIANGSE_MCP", "http://192.168.1.18:8090")
BUNDLE = os.environ.get("XIANGSE_BUNDLE", "com.appbox.StandarReader")
HOST = os.environ.get("XIANGSE_MOCK_HOST", "http://192.168.1.4:8765").rstrip("/")
OUT = ROOT / "fixtures" / "_devkit" / "browser_await"
SRC_URL = f"{HOST}/legado-browser-await-mock.runtime.json"
SOURCE_ID = f"{HOST}/browser-await-source"


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def http_get(url: str, timeout: float = 8) -> str:
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def dismiss_disclaimer(c: McpClient) -> None:
    for _ in range(3):
        try:
            ui = c.call("get_ui_elements", {"limit": 60}, timeout=30)
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
                    time.sleep(1.0)
                    return
        except Exception:
            pass
        time.sleep(0.5)


def ui_blob(c: McpClient) -> str:
    try:
        ui = c.call("get_ui_elements", {"limit": 150}, timeout=30)
        els = ui.get("elements", []) if isinstance(ui, dict) else []
        texts = []
        for e in els:
            if isinstance(e, dict) and e.get("text"):
                texts.append(str(e["text"]))
        return " | ".join(texts)
    except Exception:
        return ""


def tap_done(c: McpClient) -> bool:
    # 优先无障碍文案
    try:
        r = c.call("tap_element", {"text": "完成验证"}, timeout=20)
        if r is not None:
            return True
    except Exception:
        pass
    blob = ui_blob(c)
    if "完成验证" in blob:
        try:
            ui = c.call("get_ui_elements", {"limit": 150}, timeout=30)
            els = ui.get("elements", []) if isinstance(ui, dict) else []
            for e in els:
                if not isinstance(e, dict):
                    continue
                if "完成验证" in str(e.get("text", "")):
                    rect = e.get("rect") or {}
                    x = rect.get("x", 300) + rect.get("width", 100) / 2
                    y = rect.get("y", 56) + rect.get("height", 40) / 2
                    c.call("tap_screen", {"x": x, "y": y})
                    return True
        except Exception:
            pass
    # 右上角悬浮按钮兜底（390 宽屏）
    try:
        c.call("tap_screen", {"x": 337, "y": 76})
        return True
    except Exception:
        return False


def clear_markers(c: McpClient, doc: str) -> None:
    names = [
        "legado_visible_webview.txt",
        "legado_visible_webview_open.txt",
        "legado_cookie_jar.txt",
        "legado_cookie_dump.txt",
        "legado_request_cookie_probe.txt",
        "legado_browser_await_openurl.txt",
        "legado_browser_await_result.txt",
        "legado_search_body_probe.txt",
        "legado_search_openurl.txt",
    ]
    for name in names:
        try:
            c.call("run_command", {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 8})
        except Exception:
            pass


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    stamp = ts()
    report: dict[str, Any] = {
        "ts": stamp,
        "mcp": MCP,
        "host": HOST,
        "src": SRC_URL,
        "package_expected": "pending WKInject fix after f142774 FAIL",
        "checks": {},
        "verdict": "FAIL",
    }
    c = McpClient(MCP, BUNDLE)
    try:
        health = http_get(f"{HOST}/health")
        report["mock_health"] = health[:200]
    except Exception as e:
        report["mock_health_error"] = str(e)
        report["fail_reason"] = "mock 不可达"
        (OUT / f"browser_await_accept_{stamp}.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 2

    try:
        c.health()
        c.call("wake_and_home")
        c.call("launch_app", {"bundle_id": BUNDLE})
        time.sleep(3)
        dismiss_disclaimer(c)
        paths = c.app_paths()
        doc = paths.get("documents", "")
        report["documents"] = doc
        clear_markers(c, doc)

        # 导入受控源
        imp = f"legado://import/bookSource?src={urllib.parse.quote(SRC_URL, safe=':/?=&')}"
        c.call("open_url", {"url": imp})
        report["import_url"] = imp
        time.sleep(4)

        # 触发搜索（@js 内 startBrowserAwait 会阻塞直到完成验证）
        search = (
            "legado://search?keyword="
            + urllib.parse.quote("等待")
            + "&sourceUrl="
            + urllib.parse.quote(SOURCE_ID, safe="")
        )
        c.call("open_url", {"url": search})
        report["search_url"] = search

        # 等原生开页 + 自动 harvest（现包 finish 未同步等 cookie；2.5s/5s 延迟 harvest）
        overlay_seen = False
        for i in range(24):
            time.sleep(1.0)
            wv = c.read_sandbox_text("legado_visible_webview.txt", 16384) or ""
            openm = c.read_sandbox_text("legado_visible_webview_open.txt", 4096) or ""
            if "startBrowserAwait overlay" in wv or "XiangseOpenWebView hit" in wv:
                overlay_seen = True
                report["overlay_wait_sec"] = i + 1
                break
            if "open visibleWV" in openm and "await_gate" in openm:
                overlay_seen = True
                report["overlay_wait_sec"] = i + 1
                break

        def process_alive() -> bool:
            try:
                apps = c.call("list_running_apps")
                items = apps.get("apps") if isinstance(apps, dict) else apps
                for a in items or []:
                    if isinstance(a, dict) and a.get("bundleId") == BUNDLE:
                        return True
            except Exception:
                pass
            return False

        def frontmost_bundle() -> str:
            try:
                f = c.call("get_frontmost_app")
                if isinstance(f, dict):
                    return str(f.get("bundleId") or "")
            except Exception:
                pass
            return ""

        alive_before_tap = process_alive()
        front_before_tap = frontmost_bundle()
        report["alive_before_tap"] = alive_before_tap
        report["frontmost_before_tap"] = front_before_tap

        shot1 = OUT / f"await_wait_{stamp}.png"
        c.screenshot_to(shot1)
        report["screenshot_wait"] = str(shot1.relative_to(ROOT)).replace("\\", "/")

        # 进程已死 / 落到主屏：直接判 FAIL，禁止用 gate 页 Cookie 冒充后续请求成功
        ui_before = ui_blob(c)
        report["ui_before_done"] = ui_before[:800]
        springboard_ui = ("日历" in ui_before and "计算器" in ui_before) or front_before_tap == "com.apple.springboard"
        report["springboard_suspected"] = bool(springboard_ui or (not alive_before_tap))

        tapped = False
        if alive_before_tap and not springboard_ui:
            time.sleep(2.0)
            tapped = tap_done(c)
            time.sleep(4.0)
        report["tapped_done"] = tapped

        shot2 = OUT / f"await_after_{stamp}.png"
        c.screenshot_to(shot2)
        report["screenshot_after"] = str(shot2.relative_to(ROOT)).replace("\\", "/")

        alive_after = process_alive()
        front_after = frontmost_bundle()
        report["alive_after"] = alive_after
        report["frontmost_after"] = front_after

        wv_log = c.read_sandbox_text("legado_visible_webview.txt", 32768) or ""
        open_marker = c.read_sandbox_text("legado_visible_webview_open.txt", 8192) or ""
        cookie_jar = c.read_sandbox_text("legado_cookie_jar.txt", 16384) or ""
        cookie_dump = c.read_sandbox_text("legado_cookie_dump.txt", 16384) or ""
        cookie_probe = c.read_sandbox_text("legado_request_cookie_probe.txt", 8192) or ""
        search_probe = c.read_sandbox_text("legado_search_body_probe.txt", 8192) or ""
        store = c.read_sandbox_text("legado_cookie_store.json", 16384) or ""

        mock_log = ""
        try:
            mock_log = http_get(f"{HOST}/_log")
        except Exception as e:
            mock_log = f"err:{e}"

        has_overlay = "startBrowserAwait overlay" in wv_log
        has_user_done = "startBrowserAwait user done" in wv_log
        has_harvest = "startBrowserAwait harvest done" in wv_log or "xiangse path WKCookieStore harvest done" in wv_log
        has_native = ("path=XiangseOpenWebView hit" in wv_log) and ("class=" in wv_log)
        fallback_only = ("path=FallbackWKWebView" in wv_log) and (not has_native)
        token_in_jar = "AWAIT_TOKEN" in (cookie_jar + cookie_dump + store)

        # 只认后续搜索请求：await_search* 带 AWAIT_TOKEN=ok；禁止用 await_gate / runtime.json 冒充
        token_in_await_search = False
        try:
            entries = json.loads(mock_log) if mock_log.strip().startswith("[") else []
            if isinstance(entries, list):
                for e in entries:
                    if not isinstance(e, dict):
                        continue
                    path = str(e.get("path") or "")
                    ck = str(e.get("cookie") or "")
                    if "await_search" in path and "AWAIT_TOKEN=ok" in ck:
                        token_in_await_search = True
                        break
        except Exception:
            token_in_await_search = "await_search" in mock_log and "AWAIT_TOKEN=ok" in mock_log

        process_ok = bool(alive_before_tap and alive_after and not springboard_ui)

        report["markers"] = {
            "wv_log_tail": wv_log[-1500:],
            "open": open_marker[-500:],
            "cookie_jar_tail": cookie_jar[-600:],
            "cookie_dump_tail": cookie_dump[-600:],
            "cookie_probe": cookie_probe[-800:],
            "search_probe": search_probe[-600:],
            "mock_log_tail": mock_log[-1200:],
        }
        report["checks"] = {
            "overlay_or_open_seen": overlay_seen or has_overlay or ("await_gate" in open_marker),
            "startBrowserAwait_overlay": has_overlay,
            "startBrowserAwait_user_done": has_user_done,
            "harvest_done": has_harvest,
            "xiangse_native_hit": has_native,
            "not_fallback_only": not fallback_only,
            "process_survived": process_ok,
            "token_in_jar_or_dump": token_in_jar,
            "token_in_await_search": token_in_await_search,
            "tapped_done": tapped,
        }

        # 最小成功：进程存活 + 原生开页 +（user done 或 harvest）+ await_search Cookie
        triggered = has_overlay or has_user_done or has_harvest
        ok = bool(
            triggered
            and has_native
            and (not fallback_only)
            and process_ok
            and token_in_await_search
            and (has_user_done or has_harvest)
        )
        report["verdict"] = "PASS" if ok else "FAIL"
        if not ok:
            reasons = [k for k, v in report["checks"].items() if not v]
            report["fail_reasons"] = reasons

        out_json = OUT / f"browser_await_accept_{stamp}.json"
        out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (OUT / "browser_await_accept_latest.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(json.dumps({"verdict": report["verdict"], "checks": report["checks"], "out": str(out_json)}, ensure_ascii=False, indent=2))
        return 0 if ok else 1
    except McpError as e:
        report["error"] = str(e)
        (OUT / f"browser_await_accept_{stamp}.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
