#!/usr/bin/env python3
"""Acceptance 671ec71: nativeRead + assert 萧炎 + trace."""
import base64
import json
import time
import urllib.request
from pathlib import Path

MCP = "http://192.168.1.6:8090/mcp"
BUNDLE = "com.appbox.StandarReader"
SRC = "http://192.168.1.4:8765/legado-local-mock.runtime.json"
BOOK = "http://192.168.1.4:8765/book/doupo.html"
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
    call("open_url", {"url": f"legado://import/bookSource?src={SRC}"})
    steps.append("import_source")
    time.sleep(2)
    call("open_url", {
        "url": f"legado://nativeRead?bookUrl={BOOK}"
               "&sourceUrl=http://192.168.1.4:8765&idx=0"
    })
    steps.append("nativeRead")
    time.sleep(12)
    front = call("get_frontmost_app")
    steps.append(f"front={front.get('bundleId') if isinstance(front, dict) else front}")
    shot = call("screenshot")
    steps.append("screenshot")
    img_path = OUT_DIR / "_accept_screenshot_671ec71.png"
    if isinstance(shot, dict):
        for item in shot.get("content") or []:
            if item.get("type") == "image" and item.get("data"):
                img_path.write_bytes(base64.b64decode(item["data"]))
                break
    xiaoyan = call("assert_text_present", {"text": "萧炎", "timeout_ms": 15000})
    steps.append(f"assert_xiaoyan={xiaoyan.get('passed')}")
    info = call("get_app_info", {"bundle_id": BUNDLE})
    doc = info.get("paths", {}).get("documents", "") if isinstance(info, dict) else ""
    trace_text = ""
    if doc:
        trace = call("read_file", {
            "path": f"{doc}/legado_openreader_trace.txt",
            "max_bytes": 65536,
        })
        trace_text = trace.get("content", "") if isinstance(trace, dict) else str(trace)
    keys = []
    markers = [
        "wrapRPM", "ctFrame", "divisionResponse", "drOK", "PostDR",
        "nativePaged", "tvHasNeedle", "processPageData", "setPageModel",
        "pushNativeFull skip", "noSel", "onDivisionTextFinish",
    ]
    for line in trace_text.splitlines():
        if any(k in line for k in markers):
            keys.append(line.split("|", 1)[-1].strip() if "|" in line else line.strip())
    out = {
        "steps": steps,
        "xiaoyan_passed": xiaoyan.get("passed") if isinstance(xiaoyan, dict) else False,
        "screenshot": str(img_path) if img_path.exists() else None,
        "frontmost": front,
        "key_logs": keys[-40:],
        "trace_tail": trace_text[-5000:],
    }
    out_path = OUT_DIR / "_accept_result_671ec71.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
