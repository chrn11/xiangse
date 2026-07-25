#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""可见 WebView 验收：legado://webview / legado://login 必须打开网页（非 Alert）。

门禁（香色规格）：
1. Documents/legado_visible_webview_open.txt 存在
2. legado_visible_webview.txt 必须含 `path=XiangseOpenWebView hit` + `class=`（原生命中）
3. FallbackWKWebView 不得单独作为香色规格 PASS
4. 截图/UI 不是「书源登录」Alert 独占；允许原生 WK 导航栏（无「完成/回灌Cookie」）
5. 禁止把 BackstageWebView 当成本项 PASS
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
OUT = ROOT / "fixtures" / "_devkit" / "phase88_visible_webview"
PAGE = os.environ.get(
    "XIANGSE_VISIBLE_WV_URL",
    f"{HOST.rstrip('/')}/mock_login.html",
)


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


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
        time.sleep(0.6)


def ui_texts(c: McpClient) -> list[str]:
    try:
        ui = c.call("get_ui_elements", {"limit": 120}, timeout=30)
        els = ui.get("elements", []) if isinstance(ui, dict) else []
        out = []
        for e in els:
            if isinstance(e, dict) and e.get("text"):
                out.append(str(e["text"]))
        return out
    except Exception:
        return []


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    c = McpClient(MCP, BUNDLE)
    report: dict[str, Any] = {
        "ts": ts(),
        "mcp": MCP,
        "page": PAGE,
        "checks": {},
        "verdict": "FAIL",
    }
    try:
        c.health()
        c.call("wake_and_home")
        c.call("launch_app", {"bundle_id": BUNDLE})
        time.sleep(3)
        dismiss_disclaimer(c)
        paths = c.app_paths()
        doc = paths.get("documents", "")
        for name in (
            "legado_visible_webview.txt",
            "legado_visible_webview_open.txt",
            "legado_login_openurl.txt",
            "legado_cookie_jar.txt",
            "legado_webview_debug.txt",
        ):
            try:
                c.call("run_command", {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 8})
            except Exception:
                pass

        deep = f"legado://webview?url={urllib.parse.quote(PAGE, safe='')}"
        c.call("open_url", {"url": deep})
        report["deep_link"] = deep
        time.sleep(5)

        open_marker = c.read_sandbox_text("legado_visible_webview_open.txt", 4096) or ""
        wv_log = c.read_sandbox_text("legado_visible_webview.txt", 16384) or ""
        cookie_jar = c.read_sandbox_text("legado_cookie_jar.txt", 8192) or ""
        bwv_debug = c.read_sandbox_text("legado_webview_debug.txt", 4096) or ""
        texts = ui_texts(c)
        blob = " | ".join(texts)

        shot = OUT / f"visible_wv_{ts()}.png"
        shot_ok = c.screenshot_to(shot)
        report["screenshot"] = str(shot.relative_to(ROOT)).replace("\\", "/") if shot_ok else None

        ocr_text = ""
        try:
            ocr = c.call("ocr_screen", {}, timeout=60)
            if isinstance(ocr, dict):
                ocr_text = json.dumps(ocr, ensure_ascii=False)[:2000]
            else:
                ocr_text = str(ocr)[:2000]
        except Exception as e:
            ocr_text = f"ocr_skip:{e}"

        has_open = "open visibleWV" in open_marker or PAGE.split("/")[-1] in open_marker
        # 香色规格：必须原生 hit + 类名；Fallback 单独不算 PASS
        has_native_hit = ("path=XiangseOpenWebView hit" in wv_log) and ("class=" in wv_log)
        used_fallback_only = ("path=FallbackWKWebView" in wv_log) and (not has_native_hit)
        is_alert_only = (
            "书源登录" in blob
            and "username" in blob.lower()
            and "password" in blob.lower()
            and "完成" not in blob
            and "回灌Cookie" not in blob
            and not has_native_hit
        )
        looks_web = any(
            x in blob + ocr_text + wv_log
            for x in (
                "完成",
                "回灌Cookie",
                "可见WebView",
                "书源登录/过盾",
                "mock_login",
                "登录",
                "Cloudflare",
                "Just a moment",
                "WKWebView",
                "didFinish",
                "XiangseOpenWebView hit",
                "WebViewController_WK",
                "user",
                "pass",
            )
        )
        not_backstage = "path=BackstageWebView" not in wv_log
        report["markers"] = {
            "open": open_marker[-500:],
            "wv_log": wv_log[-1200:],
            "cookie_jar": cookie_jar[-500:],
            "ui": blob[:800],
            "ocr": ocr_text[:800],
            "bwv_debug_ignored": (bwv_debug[:200] if bwv_debug else ""),
        }
        report["checks"] = {
            "has_open_marker": has_open,
            "has_xiangse_native_hit": has_native_hit,
            "not_fallback_only": not used_fallback_only,
            "not_alert_only": not is_alert_only,
            "looks_like_web": looks_web,
            "not_claiming_backstage": not_backstage,
            "screenshot_saved": bool(shot_ok),
        }
        ok = all(
            [
                has_open,
                has_native_hit,
                not used_fallback_only,
                not is_alert_only,
                looks_web,
                not_backstage,
                shot_ok,
            ]
        )
        report["verdict"] = "PASS" if ok else "FAIL"

        try:
            c.call(
                "open_url",
                {
                    "url": (
                        "legado://login?sourceUrl="
                        + urllib.parse.quote("https://www.qidian.com", safe="")
                        + "&url="
                        + urllib.parse.quote(PAGE, safe="")
                    )
                },
            )
            time.sleep(4)
            login_open = c.read_sandbox_text("legado_login_openurl.txt", 2048) or ""
            login_wv = c.read_sandbox_text("legado_visible_webview.txt", 16384) or ""
            report["login_openurl"] = login_open[-400:]
            report["checks"]["login_defaults_to_webview"] = (
                "mode=webview" in login_open or "mode=" not in login_open
            )
            report["checks"]["login_native_hit"] = "path=XiangseOpenWebView hit" in login_wv
        except McpError as e:
            report["login_openurl_err"] = str(e)

    except Exception as e:
        report["error"] = str(e)
        report["verdict"] = "FAIL"

    out = OUT / "report.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(
        json.dumps(
            {"verdict": report["verdict"], "checks": report.get("checks"), "out": str(out)},
            ensure_ascii=False,
        )
    )
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
