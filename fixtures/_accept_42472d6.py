#!/usr/bin/env python3
"""Install 42472d6 CI IPA + nativeRead acceptance."""
import base64
import json
import time
import urllib.request
from pathlib import Path

MCP = "http://192.168.1.6:8090/mcp"
BUNDLE = "com.appbox.StandarReader"
SRC = "http://192.168.1.4:8765/legado-local-mock.runtime.json"
BOOK = "http://192.168.1.4:8765/book/doupo.html"
IPA_PATH_ON_DEVICE = (
    "/var/mobile/Library/Caches/ios-mcp-uploads/"
    "43355249-2B3C-4AB3-A7D0-368B45E4BC2F-StandarReader-legado-bridge.ipa"
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
    ins = call("install_app", {"path": IPA_PATH_ON_DEVICE})
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
    steps.append(f"front={front.get('bundleId') if isinstance(front, dict) else front}")
    shot = call("screenshot")
    img_path = OUT_DIR / "_accept_screenshot_16969f1.png"
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
        trace = call("read_file", {"path": f"{doc}/legado_openreader_trace.txt", "max_bytes": 65536})
        marker = call("read_file", {"path": f"{doc}/legado_catalog_openreader.txt", "max_bytes": 4096})
        trace_text = trace.get("content", "") if isinstance(trace, dict) else str(trace)
        marker_text = marker.get("content", "") if isinstance(marker, dict) else str(marker)
    keys = []
    markers = [
        "wrapRPM", "ctFrame", "divisionResponse", "drOK", "postDR", "safePath",
        "setPageModelPostDR", "setPageModelAfterDR", "probeOnlyPostDR",
        "tvHasNeedle", "nativePaged", "SIGNAL", "drInvoked",
    ]
    for line in trace_text.splitlines():
        if any(k in line for k in markers):
            keys.append(line.split("|", 1)[-1].strip() if "|" in line else line.strip())
    out = {
        "commit": "16969f1",
        "steps": steps,
        "xiaoyan_passed": xiaoyan.get("passed") if isinstance(xiaoyan, dict) else False,
        "screenshot": str(img_path) if img_path.exists() else None,
        "frontmost": front,
        "marker": marker_text,
        "key_logs": keys[-40:],
        "trace_tail": trace_text[-5000:],
    }
    out_path = OUT_DIR / "_accept_result_16969f1.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
