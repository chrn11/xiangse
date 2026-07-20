#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AS 验收辅助：关闭弹窗 + 重试书源导入 + 等 catalog + nativeRead。"""
from __future__ import annotations
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.environ.setdefault("NO_PROXY", "*")
from tools.ios_mcp_client import McpClient, McpError  # noqa: E402

MCP = os.environ.get("XIANGSE_MCP", "http://192.168.1.18:8090")
MOCK = os.environ.get("XIANGSE_MOCK", "http://192.168.1.4:8765")
BUNDLE = "com.appbox.StandarReader"
SRC = f"{MOCK}/legado-local-mock.runtime.json"
BOOK = f"{MOCK}/book/doupo.html"


def dismiss_any_dialog(c: McpClient) -> bool:
    """关闭任意弹窗（好/确定/同意/知晓并同意）。"""
    for _ in range(5):
        try:
            ui = c.call("get_ui_elements", {"limit": 50}, timeout=30)
            els = ui.get("elements", []) if isinstance(ui, dict) else []
            for e in els:
                if not isinstance(e, dict):
                    continue
                txt = str(e.get("text", "")).strip()
                if txt in ("好", "确定", "同意", "OK", "确认") or "知晓并同意" in txt:
                    rect = e.get("rect", {})
                    if rect:
                        x = rect.get("x", 0) + rect.get("width", 0) / 2
                        y = rect.get("y", 0) + rect.get("height", 0) / 2
                        print(f"  点击 {txt} x={x:.0f} y={y:.0f}")
                        c.call("tap_screen", {"x": x, "y": y})
                        time.sleep(1.5)
                        return True
        except Exception as ex:
            print(f"  UI 探测失败: {ex}")
        time.sleep(1)
    return False


def main() -> int:
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)

    # 1. 关闭当前弹窗
    print("=== 步骤 1: 关闭弹窗 ===")
    dismiss_any_dialog(c)
    time.sleep(1)

    # 2. 测试设备到 mock 的连通性
    print("=== 步骤 2: 设备->mock 连通性 ===")
    try:
        r = c.call("run_command", {
            "command": 'curl -s -o /dev/null -w "%{http_code}" ' +
                       f"{SRC} --max-time 5",
            "timeout_sec": 12,
        })
        print(f"  curl {SRC}: {r}")
    except Exception as ex:
        print(f"  curl 失败: {ex}")

    # 3. 确保 app 在前台
    print("=== 步骤 3: 唤醒+启动 app ===")
    c.call("wake_and_home")
    c.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(4)
    # 关免责声明
    dismiss_any_dialog(c)
    time.sleep(1)

    # 4. 导入书源（带时间戳）
    print("=== 步骤 4: 导入书源 ===")
    tstamp = int(time.time())
    c.call("open_url", {
        "url": f"legado://import/bookSource?src={SRC}?t={tstamp}",
    })
    time.sleep(8)
    dismiss_any_dialog(c)
    time.sleep(2)

    # 5. 检查 UI 是否有书架
    print("=== 步骤 5: 检查书架 ===")
    try:
        ui = c.call("get_ui_elements", {"limit": 50}, timeout=30)
        els = ui.get("elements", []) if isinstance(ui, dict) else []
        texts = [str(e.get("text", ""))[:30] for e in els if isinstance(e, dict)]
        print(f"  UI 文本 ({len(texts)}): {texts[:15]}")
    except Exception as ex:
        print(f"  UI 失败: {ex}")

    # 6. nativeRead
    print("=== 步骤 6: nativeRead ===")
    c.call("open_url", {
        "url": f"legado://nativeRead?bookUrl={BOOK}&sourceUrl={MOCK}&idx=0",
    })
    time.sleep(10)
    dismiss_any_dialog(c)
    time.sleep(2)

    # 7. 检查萧炎
    print("=== 步骤 7: 检查萧炎 ===")
    try:
        xy = c.call("assert_text_present", {"text": "萧炎", "timeout_ms": 5000})
        print(f"  萧炎: {xy}")
    except McpError as ex:
        print(f"  萧炎未找到: {ex}")

    # 8. 读 catalog/trace 探针
    print("=== 步骤 8: 读探针 ===")
    for name in ["legado_openreader_trace.txt", "legado_catalog_openreader.txt",
                 "forensics_hook_ping.txt"]:
        try:
            txt = c.read_sandbox_text(name, max_bytes=4096)
            lines = txt.splitlines()
            print(f"--- {name} ({len(lines)} 行) ---")
            for ln in lines[-8:]:
                print(f"  {ln[:180]}")
        except Exception as ex:
            print(f"--- {name} ERR: {ex}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
