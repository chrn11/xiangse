#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Frida 透视启动器 — attach StandarReader，调 dumpReader/refresh RPC，落 fixtures/_devkit。"""
from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "frida" / "xiangse_inspect.js"
OUT_DIR = ROOT / "fixtures" / "_devkit"
DEFAULT_PROCESS = "StandarReader"


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _load_frida():
    try:
        import frida  # type: ignore
    except ImportError as exc:
        raise SystemExit(
            "未安装 frida。请执行: pip install frida frida-tools\n"
            "设备需运行 frida-server（TrollStore+RootHide 可 sideload）。"
        ) from exc
    return frida


def attach_session(frida_mod, process: str, spawn: bool):
    device = frida_mod.get_usb_device(timeout=8)
    if spawn:
        pid = device.spawn([process])
        session = device.attach(pid)
        device.resume(pid)
        time.sleep(1.5)
        return session
    return device.attach(process)


def run_rpc(command: str, process: str, spawn: bool, timeout: float) -> dict:
    frida_mod = _load_frida()
    if not SCRIPT.is_file():
        raise SystemExit(f"脚本不存在: {SCRIPT}")

    source = SCRIPT.read_text(encoding="utf-8")
    session = attach_session(frida_mod, process, spawn)
    result_holder: dict = {}

    def on_message(message, _data):
        if message.get("type") == "send":
            result_holder["send"] = message.get("payload")

    script = session.create_script(source)
    script.on("message", on_message)
    script.load()
    time.sleep(0.3)

    api = script.exports_sync
    deadline = time.time() + timeout
    if command in ("dump", "dumpreader"):
        payload = api.dumpreader()
    elif command in ("refresh", "refersh"):
        payload = api.refresh()
    elif command == "crash":
        payload = api.crash()
    else:
        raise SystemExit(f"未知子命令: {command}（支持 dump|refresh|crash）")

    if time.time() > deadline:
        pass  # RPC 已返回

    result_holder["result"] = payload
    session.detach()
    out = payload if isinstance(payload, dict) else {"data": payload}
    out["_command"] = command
    out["_process"] = process
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="香色 Frida 透视（真机 USB attach）",
        epilog="前置: 设备 frida-server + pip install frida frida-tools",
    )
    parser.add_argument(
        "command",
        choices=["dump", "refresh", "refersh", "crash"],
        nargs="?",
        default="dump",
        help="dump=ivar 透视; refresh/refersh=重触发刷新链; crash=读 legado_debug_crash.txt",
    )
    parser.add_argument("-n", "--process", default=DEFAULT_PROCESS, help="进程名或 bundle 显示名")
    parser.add_argument("--spawn", action="store_true", help="spawn 而非 attach 已运行进程")
    parser.add_argument("--no-save", action="store_true", help="不写 fixtures/_devkit")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args(argv)

    cmd = "dump" if args.command == "dump" else ("refresh" if args.command == "refersh" else args.command)
    try:
        result = run_rpc(cmd, args.process, args.spawn, args.timeout)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2

    text = json.dumps(result, ensure_ascii=False, indent=2)
    print(text)

    if not args.no_save:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        fname = OUT_DIR / f"frida_{cmd}_{_ts()}.json"
        fname.write_text(text, encoding="utf-8")
        print(f"# saved: {fname}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
