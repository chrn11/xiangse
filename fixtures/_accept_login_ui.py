#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""登录页验收：香色 WebView 打开书源 loginUrl 表单，禁止 UIAlert 冒充。

门禁（打开正确登录页）：
1. 导入含 loginUrl(+loginUi) 的受控源
2. legado://login?sourceUrl=...（不带 url= 覆盖）打开页
3. legado_visible_webview 含 XiangseOpenWebView hit（禁止 Fallback 冒充 PASS）
4. UI/OCR 可见「书源登录表单」或 username/password/登录；不是 Alert 独占
5. open marker 指向 mock_login.html

完整填账号登录：PARTIAL（勿瞎填真实账号）；本脚本可点 mock 登录按钮，不强制。
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
HOST = os.environ.get("XIANGSE_MOCK_HOST", "http://192.168.1.4:8765").rstrip("/")
OUT = ROOT / "fixtures" / "_devkit" / "login_ui"
SRC_JSON = f"{HOST}/legado-login-ui-mock.runtime.json"
SOURCE_ID = f"{HOST}/login-ui-source"
LOGIN_PAGE = f"{HOST}/mock_login.html"


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
        time.sleep(0.5)


def ui_blob(c: McpClient) -> str:
    try:
        ui = c.call("get_ui_elements", {"limit": 160}, timeout=30)
        els = ui.get("elements", []) if isinstance(ui, dict) else []
        texts = []
        for e in els:
            if isinstance(e, dict) and e.get("text"):
                texts.append(str(e["text"]))
        return " | ".join(texts)
    except Exception:
        return ""


def clear_markers(c: McpClient, doc: str) -> None:
    for name in (
        "legado_visible_webview.txt",
        "legado_visible_webview_open.txt",
        "legado_login_openurl.txt",
        "legado_login_ui_probe.txt",
        "legado_login_submit.txt",
        "legado_login_cookie.txt",
    ):
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
        "src": SRC_JSON,
        "source_id": SOURCE_ID,
        "login_page": LOGIN_PAGE,
        "checks": {},
        "verdict": "FAIL",
        "full_login": "PARTIAL",
    }
    c = McpClient(MCP, BUNDLE)
    try:
        c.health()
        c.call("wake_and_home")
        c.call("kill_app", {"bundle_id": BUNDLE})
        time.sleep(1.2)
        c.call("launch_app", {"bundle_id": BUNDLE})
        time.sleep(3.0)
        dismiss_disclaimer(c)
        doc = c.app_paths().get("documents", "")
        clear_markers(c, doc)

        # 导入受控登录源
        imp = "legado://import/bookSource?src=" + urllib.parse.quote(SRC_JSON, safe="")
        c.call("open_url", {"url": imp})
        time.sleep(4.0)
        report["import"] = imp

        clear_markers(c, doc)
        # 仅 sourceUrl：应解析书源 loginUrl → mock_login.html
        deep = "legado://login?sourceUrl=" + urllib.parse.quote(SOURCE_ID, safe="")
        c.call("open_url", {"url": deep})
        report["deep_link"] = deep
        time.sleep(5.5)

        login_open = c.read_sandbox_text("legado_login_openurl.txt", 4096) or ""
        wv_open = c.read_sandbox_text("legado_visible_webview_open.txt", 4096) or ""
        wv_log = c.read_sandbox_text("legado_visible_webview.txt", 16384) or ""
        login_probe = c.read_sandbox_text("legado_login_ui_probe.txt", 4096) or ""
        blob = ui_blob(c)
        shot = OUT / f"login_form_{stamp}.png"
        shot_ok = c.screenshot_to(shot)
        report["screenshot"] = (
            str(shot.relative_to(ROOT)).replace("\\", "/") if shot_ok else None
        )

        ocr_text = ""
        try:
            ocr = c.call("ocr_screen", {}, timeout=60)
            ocr_text = (
                json.dumps(ocr, ensure_ascii=False)[:2500]
                if isinstance(ocr, dict)
                else str(ocr)[:2500]
            )
        except Exception as e:
            ocr_text = f"ocr_skip:{e}"

        combined = blob + "\n" + ocr_text + "\n" + wv_open + "\n" + wv_log
        has_native = ("path=XiangseOpenWebView hit" in wv_log) and ("class=" in wv_log)
        used_fallback_only = ("path=FallbackWKWebView" in wv_log) and (not has_native)
        opened_login_page = ("mock_login.html" in wv_open) or ("mock_login.html" in login_open)
        form_visible = any(
            x in combined
            for x in (
                "书源登录表单",
                "username",
                "password",
                "用户名",
                "密码",
            )
        ) and ("登录" in combined)
        # Alert 冒充：标题「书源登录」+ 双 TextField，且无 WebView 证据
        alert_only = (
            ("书源登录" in blob)
            and ("username" in blob.lower())
            and ("password" in blob.lower())
            and (not has_native)
            and ("mock_login" not in wv_open)
        )
        defaults_webview = ("mode=alert" not in login_open.lower()) and (
            "mode=webview" in login_open or "mode=" not in login_open or login_open == ""
        )
        # 无 url= 覆盖时，openURL 标记 mode=webview；open 文件可能仍有
        if "openURL login" in login_open:
            defaults_webview = "mode=alert" not in login_open.lower()

        front = c.call("get_frontmost_app")
        alive = isinstance(front, dict) and front.get("bundleId") == BUNDLE

        report["markers"] = {
            "login_open": login_open[-500:],
            "wv_open": wv_open[-500:],
            "wv_log": wv_log[-1200:],
            "login_ui_probe": login_probe[-500:],
            "ui": blob[:900],
            "ocr": ocr_text[:900],
        }
        report["checks"] = {
            "process_alive": alive,
            "has_xiangse_native_hit": has_native,
            "not_fallback_only": not used_fallback_only,
            "opened_mock_login_page": opened_login_page,
            "form_visible": form_visible,
            "not_alert_only": not alert_only,
            "defaults_to_webview": defaults_webview,
            "screenshot_saved": bool(shot_ok),
            "login_ui_probe_present": ("path=XiangseWebLogin" in login_probe)
            or ("loginUiLen=" in login_probe),
        }
        # 打开正确登录页：探针文件为增强项（新包才有），不挡本轮 PASS
        must = [
            report["checks"]["process_alive"],
            report["checks"]["has_xiangse_native_hit"],
            report["checks"]["not_fallback_only"],
            report["checks"]["opened_mock_login_page"],
            report["checks"]["form_visible"],
            report["checks"]["not_alert_only"],
            report["checks"]["defaults_to_webview"],
            report["checks"]["screenshot_saved"],
        ]
        report["verdict"] = "PASS" if all(must) else "FAIL"
        report["full_login"] = "PARTIAL"
        report["note"] = (
            "打开正确登录页门禁；完整账号登录 PARTIAL（mock 可点，勿填真实账号）。"
            " login_ui_probe 需含 path=XiangseWebLogin 的包才算探针增强 PASS。"
        )

        # 对照：mode=alert 仍可触发，但不得当作产品路径
        try:
            clear_markers(c, doc)
            alert_deep = (
                "legado://login?mode=alert&sourceUrl="
                + urllib.parse.quote(SOURCE_ID, safe="")
            )
            c.call("open_url", {"url": alert_deep})
            time.sleep(2.5)
            alert_ui = ui_blob(c)
            alert_open = c.read_sandbox_text("legado_login_openurl.txt", 2048) or ""
            report["alert_control"] = {
                "deep": alert_deep,
                "open": alert_open[-300:],
                "ui": alert_ui[:400],
                "is_alert_mode": "mode=alert" in alert_open,
            }
        except McpError as e:
            report["alert_control_err"] = str(e)

    except Exception as e:
        report["error"] = str(e)
        report["verdict"] = "FAIL"

    out = OUT / f"login_accept_{stamp}.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / "report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "verdict": report["verdict"],
                "full_login": report.get("full_login"),
                "checks": report.get("checks"),
                "out": str(out),
            },
            ensure_ascii=False,
        )
    )
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
