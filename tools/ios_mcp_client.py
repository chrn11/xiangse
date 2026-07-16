#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""共用 iOS MCP HTTP 客户端（JSON-RPC + upload + 截图落盘）。"""
from __future__ import annotations

import base64
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_MCP_BASE = os.environ.get("XIANGSE_MCP", "http://192.168.1.6:8090")
DEFAULT_BUNDLE = os.environ.get("XIANGSE_BUNDLE", "com.appbox.StandarReader")


class McpError(RuntimeError):
    pass


class McpClient:
    def __init__(self, base_url: str | None = None, bundle_id: str | None = None):
        self.base_url = (base_url or DEFAULT_MCP_BASE).rstrip("/")
        self.mcp_url = f"{self.base_url}/mcp"
        self.bundle_id = bundle_id or DEFAULT_BUNDLE

    def health(self, timeout: float = 5) -> dict[str, Any]:
        req = urllib.request.Request(f"{self.base_url}/health", method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())

    def call(self, tool: str, arguments: dict | None = None, timeout: float = 180) -> Any:
        payload = {
            "jsonrpc": "2.0",
            "id": int(time.time() * 1000) % 100000,
            "method": "tools/call",
            "params": {"name": tool, "arguments": arguments or {}},
        }
        req = urllib.request.Request(
            self.mcp_url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise McpError(f"MCP HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise McpError(f"MCP 不可达 {self.base_url}: {exc}") from exc

        if "error" in body:
            raise McpError(json.dumps(body["error"], ensure_ascii=False))

        result = body.get("result", {})
        sc = result.get("structuredContent")
        if sc is not None:
            return sc

        content = result.get("content", [])
        if content and content[0].get("type") == "text":
            text = content[0]["text"]
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return text

        if content:
            return {"content": content}
        return body

    def upload_file(self, local_path: Path, filename: str | None = None, timeout: float = 600) -> Any:
        name = filename or local_path.name
        data = local_path.read_bytes()
        req = urllib.request.Request(
            f"{self.base_url}/upload_file",
            data=data,
            headers={"X-Filename": name, "Content-Type": "application/octet-stream"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode()
        except urllib.error.URLError as exc:
            raise McpError(f"upload_file 失败: {exc}") from exc
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"path": raw.strip()}

    @staticmethod
    def extract_image_bytes(result: Any) -> bytes | None:
        items: list[dict] = []
        if isinstance(result, dict):
            items = result.get("content") or []
            if not items and result.get("type") == "image" and result.get("data"):
                items = [result]
        for item in items:
            if item.get("type") == "image" and item.get("data"):
                return base64.b64decode(item["data"])
        return None

    def screenshot_to(self, dest: Path, timeout: float = 60) -> bool:
        shot = self.call("screenshot", timeout=timeout)
        data = self.extract_image_bytes(shot)
        if not data:
            return False
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        return True

    def app_paths(self) -> dict[str, str]:
        info = self.call("get_app_info", {"bundle_id": self.bundle_id})
        if not isinstance(info, dict):
            return {}
        paths: dict[str, str] = {}
        inner = info.get("paths", {})
        if isinstance(inner, dict):
            paths.update({k: v for k, v in inner.items() if isinstance(v, str)})
        for key in ("bundle_path", "bundlePath", "data_container", "executable_path"):
            val = info.get(key)
            if isinstance(val, str) and val:
                paths[key] = val
                if key == "bundle_path":
                    paths.setdefault("bundle", val)
        return paths

    @staticmethod
    def _extract_read_file_text(result: Any) -> str:
        if not isinstance(result, dict):
            return str(result) if result else ""
        if result.get("isError"):
            return ""
        content = result.get("content")
        if isinstance(content, str):
            return content
        return ""

    def read_file_at(self, path: str, max_bytes: int = 65536) -> str:
        if not path:
            return ""
        try:
            res = self.call("read_file", {"path": path, "max_bytes": max_bytes}, timeout=30)
            return self._extract_read_file_text(res)
        except McpError:
            return ""

    def open_once_candidates(self, paths: dict[str, str] | None = None) -> list[str]:
        paths = paths or self.app_paths()
        doc = paths.get("documents", "")
        caches = paths.get("caches", "")
        lib = paths.get("library", "")
        out: list[str] = []
        if doc:
            out.append(f"{doc}/legado_native_open_once.txt")
        if caches:
            out.append(f"{caches}/legado_native_open_once.txt")
        elif lib:
            out.append(f"{lib}/Caches/legado_native_open_once.txt")
        return out

    def file_exists(self, path: str) -> bool:
        if not path:
            return False
        try:
            res = self.call(
                "run_command",
                {"command": f"test -f '{path}' && echo yes || echo no", "timeout_sec": 10},
                timeout=20,
            )
            text = json.dumps(res, ensure_ascii=False) if not isinstance(res, str) else res
            return "yes" in text
        except McpError:
            return False

    def read_sandbox_text(self, rel_or_abs: str, max_bytes: int = 65536) -> str:
        if rel_or_abs.startswith("/"):
            path = rel_or_abs
        else:
            doc = self.app_paths().get("documents", "")
            if not doc:
                return ""
            path = f"{doc}/{rel_or_abs}"
        return self.read_file_at(path, max_bytes=max_bytes)

    def read_build_manifest(self) -> dict[str, Any] | None:
        """从已安装 App 的 Bundle 或 Documents 读取 reader-build-manifest.json。"""
        paths = self.app_paths()
        candidates: list[str] = []
        for key in ("bundle_path", "bundle", "bundlePath"):
            base = paths.get(key, "")
            if base:
                candidates.append(f"{base.rstrip('/')}/reader-build-manifest.json")
        doc = paths.get("documents", "")
        if doc:
            candidates.append(f"{doc}/reader-build-manifest.json")

        for path in candidates:
            text = self.read_file_at(path, max_bytes=16384).strip()
            if not text:
                continue
            try:
                data = json.loads(text)
                if isinstance(data, dict):
                    return data
            except json.JSONDecodeError:
                continue

        bundle = paths.get("bundle_path") or paths.get("bundle", "")
        if bundle:
            cmd = f"cat '{bundle.rstrip('/')}/reader-build-manifest.json' 2>/dev/null"
            try:
                res = self.call("run_command", {"command": cmd, "timeout_sec": 10}, timeout=20)
                text = ""
                if isinstance(res, dict):
                    text = (res.get("output") or res.get("content") or "").strip()
                elif isinstance(res, str):
                    text = res.strip()
                if text:
                    data = json.loads(text)
                    if isinstance(data, dict):
                        return data
            except (McpError, json.JSONDecodeError):
                pass
        return None


def call(tool: str, arguments: dict | None = None, timeout: float = 180, base_url: str | None = None) -> Any:
    """模块级快捷调用（默认端点）。"""
    return McpClient(base_url).call(tool, arguments, timeout=timeout)
