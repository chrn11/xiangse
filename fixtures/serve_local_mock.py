#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""局域网静态 mock 书源 HTTP 服务。

自动探测本机可达设备侧的 LAN IP（默认探测 192.168.1.6:8090），
将 fixtures/legado-local-mock.json 中的 __LAN_HOST__ 写成 runtime JSON，
并在 0.0.0.0:8765 提供 fixtures/ 静态文件。

用法：
  python fixtures/serve_local_mock.py
  python fixtures/serve_local_mock.py --port 8765 --probe 192.168.1.6
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = Path(__file__).resolve().parent
TEMPLATE = FIXTURE_DIR / "legado-local-mock.json"
RUNTIME = FIXTURE_DIR / "legado-local-mock.runtime.json"
PURIFY_TEMPLATE = FIXTURE_DIR / "legado-purify-mock.json"
PURIFY_RUNTIME = FIXTURE_DIR / "legado-purify-mock.runtime.json"
WEBVIEW_TEMPLATE = FIXTURE_DIR / "legado-webview-mock.json"
WEBVIEW_RUNTIME = FIXTURE_DIR / "legado-webview-mock.runtime.json"
WEBVIEW_MIN_TEMPLATE = FIXTURE_DIR / "legado-webview-min.json"
WEBVIEW_MIN_RUNTIME = FIXTURE_DIR / "legado-webview-min.runtime.json"
DEFAULT_PROBE = "192.168.1.6"


def lan_ip(probe_host: str) -> str:
    """选一个设备可达的本机 IPv4；禁止写死过期地址。"""
    # 1) UDP connect 到 probe（不发包），取出站网卡 IP
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect((probe_host, 80))
            ip = s.getsockname()[0]
            if ip and not ip.startswith("127."):
                return ip
        finally:
            s.close()
    except OSError:
        pass
    # 2) 主机名解析
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip and not ip.startswith("127.") and not ip.startswith("169.254."):
                return ip
    except OSError:
        pass
    raise SystemExit("无法探测 LAN IP：请用 --host 显式指定设备可达地址")


def _write_template_runtime(template: Path, dest: Path, host: str, port: int, book_source_url: str) -> dict:
    raw = template.read_text(encoding="utf-8")
    text = raw.replace("__LAN_HOST__", host)
    data = json.loads(text)
    data["bookSourceUrl"] = book_source_url
    if "searchUrl" in data:
        data["searchUrl"] = f"http://{host}:{port}/mock_search.html?q={{{{key}}}}"
    if "exploreUrl" in data:
        data["exploreUrl"] = f"http://{host}:{port}/mock_explore.html"
    if "loginUrl" in data:
        data["loginUrl"] = f"http://{host}:{port}/mock_login.html"
    dest.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return data


def write_runtime(host: str, port: int) -> dict:
    data = _write_template_runtime(
        TEMPLATE, RUNTIME, host, port, f"http://{host}:{port}"
    )
    if PURIFY_TEMPLATE.is_file():
        _write_template_runtime(
            PURIFY_TEMPLATE,
            PURIFY_RUNTIME,
            host,
            port,
            f"http://{host}:{port}",
        )
    if WEBVIEW_TEMPLATE.is_file():
        _write_template_runtime(
            WEBVIEW_TEMPLATE,
            WEBVIEW_RUNTIME,
            host,
            port,
            f"http://{host}:{port}/webview-source",
        )
    if WEBVIEW_MIN_TEMPLATE.is_file():
        _write_template_runtime(
            WEBVIEW_MIN_TEMPLATE,
            WEBVIEW_MIN_RUNTIME,
            host,
            port,
            f"http://{host}:{port}/webview-source",
        )
    return data


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(FIXTURE_DIR), **kwargs)

    def end_headers(self) -> None:
        # 禁止 304：LBLegadoFetchAndImport 只接受 HTTP 200，条件请求会导致书源导入失败
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        super().end_headers()

    def send_head(self):
        path = self.translate_path(self.path.split("?", 1)[0])
        if os.path.isfile(path):
            ctype = self.guess_type(path)
            try:
                f = open(path, "rb")
            except OSError:
                return None
            fs = os.fstat(f.fileno())
            self.send_response(200)
            self.send_header("Content-type", ctype)
            self.send_header("Content-Length", str(fs[6]))
            self.end_headers()
            return f
        return super().send_head()

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock-http] " + (fmt % args) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description="Legado 本地 mock HTTP")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--probe", default=DEFAULT_PROBE, help="用于探测出站网卡的设备 IP")
    ap.add_argument("--host", default="", help="显式指定 LAN IP（跳过探测）")
    args = ap.parse_args()

    host = args.host.strip() or lan_ip(args.probe)
    src = write_runtime(host, args.port)
    base = f"http://{host}:{args.port}"
    print(f"LAN={host}")
    print(f"serving {base}  root={FIXTURE_DIR}")
    print(f"runtime_source={RUNTIME}")
    print(f"bookSourceUrl={src.get('bookSourceUrl')}")
    print(f"searchUrl={src.get('searchUrl')}")
    print(f"import: open_url legado://import/bookSource?src={base}/legado-local-mock.runtime.json")
    if PURIFY_RUNTIME.is_file():
        print(f"purify_import: legado://import/bookSource?src={base}/legado-purify-mock.runtime.json")
    print(f"或 MCP open_file_with_app / 粘贴 JSON: {RUNTIME}")

    httpd = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("stop")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
