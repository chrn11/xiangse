#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""登录页验收：打开表单 + mock 填表提交 → 成功页 + Cookie 回灌。

门禁 A（打开正确登录页）：
1. 导入含 loginUrl(+loginUi) 的受控源
2. legado://login?sourceUrl=...（不带 url= 覆盖）打开页
3. legado_visible_webview 含 XiangseOpenWebView hit（禁止 Fallback 冒充 PASS）
4. UI/OCR 可见「书源登录表单」或 username/password/登录；不是 Alert 独占
5. open marker 指向 mock_login.html
6. login_ui_probe 含 path=XiangseWebLogin（增强）

门禁 B（受控 mock 提交链路，非真实站账号）：
1. 填 mock 用户名/密码并点登录
2. 落到 mock_login_ok / LOGIN_OK
3. Cookie 回灌 jar：LB_LOGIN=ok（探针/jar/wv_log）

真实站完整账号登录：始终 PARTIAL（勿瞎填）。
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
OUT = ROOT / "fixtures" / "_devkit" / "login_ui"
SRC_JSON = f"{HOST}/legado-login-ui-mock.runtime.json"
SOURCE_ID = f"{HOST}/login-ui-source"
LOGIN_PAGE = f"{HOST}/mock_login.html"
MOCK_USER = os.environ.get("XIANGSE_MOCK_LOGIN_USER", "mock_user")
MOCK_PASS = os.environ.get("XIANGSE_MOCK_LOGIN_PASS", "mock_pass")


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


def ui_elements(c: McpClient, limit: int = 180) -> list[dict[str, Any]]:
    try:
        ui = c.call("get_ui_elements", {"limit": limit}, timeout=30)
        els = ui.get("elements", []) if isinstance(ui, dict) else []
        return [e for e in els if isinstance(e, dict)]
    except Exception:
        return []


def ui_blob(c: McpClient) -> str:
    texts = []
    for e in ui_elements(c):
        if e.get("text"):
            texts.append(str(e["text"]))
    return " | ".join(texts)


def tap_rect(c: McpClient, e: dict[str, Any]) -> None:
    rect = e.get("rect") or {}
    x = float(rect.get("x", 0)) + float(rect.get("width", 40)) / 2
    y = float(rect.get("y", 0)) + float(rect.get("height", 30)) / 2
    c.call("tap_screen", {"x": x, "y": y})


def find_field(els: list[dict[str, Any]], *needles: str) -> dict[str, Any] | None:
    lowered = [n.lower() for n in needles]
    for e in els:
        blob = " ".join(
            str(e.get(k, "") or "")
            for k in ("text", "label", "name", "value", "type", "role", "identifier")
        ).lower()
        if any(n in blob for n in lowered):
            return e
    return None


def type_into(c: McpClient, text: str) -> str:
    """先 input_text，失败改 type_text。"""
    try:
        c.call("input_text", {"text": text}, timeout=20)
        return "input_text"
    except Exception as e1:
        try:
            c.call("type_text", {"text": text}, timeout=20)
            return f"type_text_after:{e1}"
        except Exception as e2:
            return f"fail:{e1}|{e2}"


def fill_and_submit(c: McpClient) -> dict[str, Any]:
    """在 WebView 登录表单填 mock 账号并点登录。"""
    info: dict[str, Any] = {"user": MOCK_USER, "steps": []}
    els = ui_elements(c)
    user_el = find_field(els, "username", "用户名")
    if user_el is None:
        # 占位符常单独成节点
        for e in els:
            t = str(e.get("text", "")).strip().lower()
            if t in ("username", "用户名"):
                user_el = e
                break
    if user_el is not None:
        tap_rect(c, user_el)
        time.sleep(0.4)
        how = type_into(c, MOCK_USER)
        info["steps"].append({"field": "username", "how": how, "text": str(user_el.get("text", ""))})
    else:
        info["steps"].append({"field": "username", "how": "missing"})

    time.sleep(0.3)
    els = ui_elements(c)
    pass_el = find_field(els, "password", "密码")
    if pass_el is None:
        for e in els:
            t = str(e.get("text", "")).strip().lower()
            if t in ("password", "密码"):
                pass_el = e
                break
    if pass_el is not None:
        tap_rect(c, pass_el)
        time.sleep(0.4)
        how = type_into(c, MOCK_PASS)
        info["steps"].append({"field": "password", "how": how, "text": str(pass_el.get("text", ""))})
    else:
        info["steps"].append({"field": "password", "how": "missing"})

    time.sleep(0.4)
    els = ui_elements(c)
    login_btn = None
    for e in els:
        t = str(e.get("text", "")).strip()
        if t == "登录":
            login_btn = e
            break
    if login_btn is None:
        login_btn = find_field(els, "lb-login-submit", "登录")
    if login_btn is not None:
        tap_rect(c, login_btn)
        info["steps"].append({"field": "submit", "how": "tap", "text": str(login_btn.get("text", ""))})
        info["submitted"] = True
    else:
        try:
            c.call("tap_element", {"text": "登录"})
            info["steps"].append({"field": "submit", "how": "tap_element"})
            info["submitted"] = True
        except Exception as e:
            info["steps"].append({"field": "submit", "how": f"fail:{e}"})
            info["submitted"] = False
    return info


def clear_markers(c: McpClient, doc: str) -> None:
    for name in (
        "legado_visible_webview.txt",
        "legado_visible_webview_open.txt",
        "legado_login_openurl.txt",
        "legado_login_ui_probe.txt",
        "legado_login_submit.txt",
        "legado_login_cookie.txt",
        "legado_cookie_jar.txt",
        "legado_cookie_dump.txt",
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
        "mock_user": MOCK_USER,
        "checks": {},
        "mock_submit_checks": {},
        "verdict": "FAIL",
        "mock_submit": "FAIL",
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
        open_pass = all(must)
        report["verdict"] = "PASS" if open_pass else "FAIL"

        # —— 门禁 B：mock 填表提交 ——
        submit_info = {"skipped": True}
        if open_pass:
            submit_info = fill_and_submit(c)
            # 新包：导航后 cookie watch 会在 ~2s 内回灌；旧包仅开页时 harvest，需轮询确认缺口
            has_lb_login = False
            has_harvest = False
            landed_ok = False
            mock_hit = False
            blob2 = ""
            ocr2 = ""
            wv_open2 = ""
            wv_log2 = ""
            cookie_jar = ""
            cookie_dump = ""
            cookie_store = ""
            login_cookie = ""
            mock_log = ""
            shot2_ok = False
            poll_notes: list[str] = []
            for poll_i in range(12):  # ~24s
                time.sleep(2.0)
                wv_open2 = c.read_sandbox_text("legado_visible_webview_open.txt", 8192) or ""
                wv_log2 = c.read_sandbox_text("legado_visible_webview.txt", 32768) or ""
                cookie_jar = c.read_sandbox_text("legado_cookie_jar.txt", 16384) or ""
                cookie_dump = c.read_sandbox_text("legado_cookie_dump.txt", 16384) or ""
                cookie_store = c.read_sandbox_text("legado_cookie_store.json", 16384) or ""
                login_cookie = c.read_sandbox_text("legado_login_cookie.txt", 4096) or ""
                blob2 = ui_blob(c)
                # jar/dump/探针必须含 LB_LOGIN；UI 的 document.cookie 仅作辅助，不算回灌 PASS
                probe_blob = "\n".join(
                    [cookie_jar, cookie_dump, cookie_store, login_cookie, wv_log2]
                )
                has_lb_login = "LB_LOGIN" in probe_blob
                has_harvest = ("cookieJarSaved" in wv_log2) or (
                    "WKCookieStore harvest" in wv_log2
                ) or ("login cookie probe" in wv_log2)
                landed_ok = (
                    ("LOGIN_OK" in blob2)
                    or ("mock_login_ok" in wv_open2)
                    or ("mock_login_ok.html" in wv_log2)
                    or ("xiangse path nav url=" in wv_log2 and "mock_login_ok" in wv_log2)
                    or ("登录成功" in blob2)
                )
                try:
                    mock_log = http_get(f"{HOST}/_log")
                    raw = mock_log.lstrip("\ufeff").strip()
                    entries = json.loads(raw) if raw.startswith("[") else []
                    if isinstance(entries, list):
                        for e in entries:
                            if not isinstance(e, dict):
                                continue
                            ts_e = str(e.get("ts") or "")
                            if ts_e and ts_e < stamp:
                                continue
                            if "mock_login_ok" in str(e.get("path") or ""):
                                mock_hit = True
                                break
                except Exception as e:
                    mock_log = f"err:{e}"
                poll_notes.append(
                    f"i={poll_i} landed={landed_ok} lb={has_lb_login} mock_hit={mock_hit}"
                )
                if landed_ok and has_lb_login:
                    break

            shot2 = OUT / f"login_ok_{stamp}.png"
            shot2_ok = c.screenshot_to(shot2)
            try:
                ocr_r = c.call("ocr_screen", {}, timeout=60)
                ocr2 = (
                    json.dumps(ocr_r, ensure_ascii=False)[:2000]
                    if isinstance(ocr_r, dict)
                    else str(ocr_r)[:2000]
                )
            except Exception as e:
                ocr2 = f"ocr_skip:{e}"

            front2 = c.call("get_frontmost_app")
            alive2 = isinstance(front2, dict) and front2.get("bundleId") == BUNDLE

            report["submit"] = submit_info
            report["poll_notes"] = poll_notes
            report["screenshot_ok"] = (
                str(shot2.relative_to(ROOT)).replace("\\", "/") if shot2_ok else None
            )
            report["markers_after_submit"] = {
                "wv_open": wv_open2[-600:],
                "wv_log_tail": wv_log2[-1500:],
                "ui": blob2[:900],
                "ocr": ocr2[:700],
                "cookie_jar_tail": cookie_jar[-800:],
                "cookie_dump_tail": cookie_dump[-600:],
                "login_cookie": login_cookie[-400:],
                "mock_log_tail": mock_log[-1200:],
            }
            report["mock_submit_checks"] = {
                "submitted": bool(submit_info.get("submitted")),
                "landed_success_page": bool(landed_ok or mock_hit),
                "mock_login_ok_request": mock_hit,
                "cookie_lb_login_in_jar": has_lb_login,
                "cookie_harvest_seen": has_harvest,
                "process_alive_after": alive2,
                "screenshot_ok_saved": bool(shot2_ok),
            }
            submit_must = [
                report["mock_submit_checks"]["submitted"],
                report["mock_submit_checks"]["landed_success_page"],
                report["mock_submit_checks"]["cookie_lb_login_in_jar"],
                report["mock_submit_checks"]["process_alive_after"],
                report["mock_submit_checks"]["screenshot_ok_saved"],
            ]
            report["mock_submit"] = "PASS" if all(submit_must) else "FAIL"
        else:
            report["mock_submit"] = "SKIP"
            report["submit"] = submit_info

        report["full_login"] = "PARTIAL"
        report["note"] = (
            "verdict=打开正确登录页；mock_submit=受控 mock 填表提交+Cookie 回灌；"
            "full_login=真实站账号仍 PARTIAL（勿瞎填）。"
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
        report["mock_submit"] = report.get("mock_submit") or "FAIL"

    out = OUT / f"login_accept_{stamp}.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / "report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "verdict": report["verdict"],
                "mock_submit": report.get("mock_submit"),
                "full_login": report.get("full_login"),
                "checks": report.get("checks"),
                "mock_submit_checks": report.get("mock_submit_checks"),
                "out": str(out),
            },
            ensure_ascii=False,
        )
    )
    # 本轮任务以 mock 提交链路为准；打开页也须 PASS
    ok = report.get("verdict") == "PASS" and report.get("mock_submit") == "PASS"
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
