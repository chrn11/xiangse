#!/usr/bin/env python3
"""Acceptance: legado://nativeRead deep link + assert 萧炎 + screenshot."""
import base64
import json
import time
import urllib.request
from pathlib import Path

MCP = "http://192.168.1.6:8090/mcp"
BUNDLE = "com.appbox.StandarReader"
DOC = "/var/mobile/Containers/Data/Application/F68CEBC8-BFC4-4E6C-92E3-C2B6DE4464CD/Documents"
BOOK = "http://192.168.1.4:8765/book/doupo.html"
SRC = "http://192.168.1.4:8765/legado-local-mock.runtime.json"
OUT_DIR = Path(__file__).resolve().parent


def call(tool, arguments=None, timeout=120):
    req = urllib.request.Request(
        MCP,
        data=json.dumps({
            "jsonrpc": "2.0",
            "id": int(time.time() * 1000) % 100000,
            "method": "tools/call",
            "params": {"name": tool, "arguments": arguments or {}},
        }).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode())
    if "error" in body:
        raise RuntimeError(body["error"])
    sc = body.get("result", {}).get("structuredContent")
    if sc is not None:
        return sc
    content = body.get("result", {}).get("content", [])
    if content and content[0].get("type") == "text":
        try:
            return json.loads(content[0]["text"])
        except json.JSONDecodeError:
            return content[0]["text"]
    return body


def main():
    steps = []
    call("wake_and_home")
    steps.append("wake_and_home")
    call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    call("launch_app", {"bundle_id": BUNDLE})
    steps.append("launch_app")
    time.sleep(2)
    # import source if needed
    call("open_url", {"url": f"legado://import/bookSource?src={SRC}"})
    steps.append("import_source")
    time.sleep(2)
    call("open_url", {
        "url": "legado://read?chapterUrl=http://192.168.1.4:8765/chapter/doupo_1.html"
               "&bookUrl=http://192.168.1.4:8765/book/doupo.html&title=第一章"
    })
    steps.append("legado_read deeplink")
    time.sleep(10)
    shot = call("screenshot")
    steps.append("screenshot")
    img_path = OUT_DIR / "_accept_screenshot.png"
    if isinstance(shot, dict):
        content = shot.get("content") or []
        for item in content:
            if item.get("type") == "image" and item.get("data"):
                img_path.write_bytes(base64.b64decode(item["data"]))
                steps.append(f"saved={img_path.name}")
                break
    xiaoyan = call("assert_text_present", {"text": "萧炎", "timeout_ms": 10000})
    steps.append(f"assert_xiaoyan={xiaoyan.get('passed')}")
    trace = call("read_file", {"path": f"{DOC}/legado_openreader_trace.txt", "max_bytes": 65536})
    marker = call("read_file", {"path": f"{DOC}/legado_catalog_openreader.txt", "max_bytes": 4096})
    trace_text = trace.get("content", "") if isinstance(trace, dict) else str(trace)
    keys = []
    for line in trace_text.splitlines():
        if any(k in line for k in [
            "divisionText@", "divisionResponse", "wrapRPM", "nativePaged",
            "tvHasNeedle", "overlay92011", "noSel divisionResponse",
        ]):
            keys.append(line.split("|", 1)[-1].strip() if "|" in line else line.strip())
    out = {
        "steps": steps,
        "xiaoyan_passed": xiaoyan.get("passed"),
        "screenshot": str(img_path) if img_path.exists() else None,
        "marker": marker.get("content", "") if isinstance(marker, dict) else marker,
        "key_logs": keys[-30:],
        "trace_tail": trace_text[-4000:],
    }
    out_path = OUT_DIR / "_accept_result_v2.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
