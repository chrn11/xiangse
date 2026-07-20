#!/usr/bin/env python3
"""Acceptance 3a0944f: install CI IPA + nativeRead + assert 萧炎 + trace gates."""
import base64
import json
import time
import urllib.request
from pathlib import Path

MCP = "http://192.168.1.6:8090/mcp"
BUNDLE = "com.appbox.StandarReader"
SRC = "http://192.168.1.4:8765/legado-local-mock.runtime.json"
BOOK = "http://192.168.1.4:8765/book/doupo.html"
IPA_PATH = (
    "/var/mobile/Library/Caches/ios-mcp-uploads/"
    "920B4762-0FB1-421B-9C51-A0C663637F8D-StandarReader-legado-bridge.ipa"
)
OUT_DIR = Path(__file__).resolve().parent


def call(tool, arguments=None, timeout=180):
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
    ins = call("install_app", {"path": IPA_PATH})
    steps.append(f"install={ins}")
    time.sleep(2)
    call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    call("launch_app", {"bundle_id": BUNDLE})
    steps.append("launch")
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
    front_bundle = front.get("bundleId") if isinstance(front, dict) else str(front)
    steps.append(f"front={front_bundle}")
    shot = call("screenshot")
    img_path = OUT_DIR / "_accept_screenshot_3a0944f.png"
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
    marker_text = ""
    if doc:
        trace = call("read_file", {
            "path": f"{doc}/legado_openreader_trace.txt",
            "max_bytes": 65536,
        })
        trace_text = trace.get("content", "") if isinstance(trace, dict) else str(trace)
        marker = call("read_file", {
            "path": f"{doc}/legado_catalog_openreader.txt",
            "max_bytes": 8192,
        })
        marker_text = marker.get("content", "") if isinstance(marker, dict) else str(marker)
    prefer_today = [ln for ln in trace_text.splitlines() if "2026-07-14" in ln and "goStart preferNativeFull" in ln]
    skip_lines = [
        ln for ln in trace_text.splitlines()
        if any(k in ln for k in [
            "skip inflight", "skip openOnce", "skipPush chapterDone",
            "tryOpen skip", "catalogUI skip", "abort push chapterDone",
            "SIGNAL sig=",
        ])
    ]
    out = {
        "commit": "ff31e27",
        "steps": steps,
        "xiaoyan_passed": xiaoyan.get("passed") if isinstance(xiaoyan, dict) else False,
        "still_in_app": front_bundle == BUNDLE,
        "preferNativeFull_today": len(prefer_today),
        "preferNativeFull_today_lines": [ln.split("|",1)[-1].strip() if "|" in ln else ln.strip() for ln in prefer_today],
        "skip_logs": [ln.split("|", 1)[-1].strip() if "|" in ln else ln.strip() for ln in skip_lines[-20:]],
        "has_signal": "SIGNAL sig=" in trace_text or "SIGNAL sig=" in marker_text,
        "screenshot": str(img_path) if img_path.exists() else None,
        "trace_tail": trace_text[-5000:],
        "marker_tail": marker_text[-2000:],
    }
    out_path = OUT_DIR / "_accept_result_3a0944f.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
