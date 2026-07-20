#!/usr/bin/env python3
"""Run ios-mcp acceptance for native divisionText path."""
import json
import time
import urllib.request

MCP = "http://192.168.1.6:8090/mcp"
BUNDLE = "com.appbox.StandarReader"
DOC = "/var/mobile/Containers/Data/Application/F68CEBC8-BFC4-4E6C-92E3-C2B6DE4464CD/Documents"


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
    call("start_capture", {"bundle_ids": [BUNDLE]})
    steps.append("start_capture")
    call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    call("launch_app", {"bundle_id": BUNDLE})
    steps.append("launch_app")
    time.sleep(2)
    call("open_url", {"url": "legado://search?keyword=斗破"})
    steps.append("open_url search")
    time.sleep(3)
    tap = call("tap_element", {"text": "斗破苍穹", "match": "contains", "timeout_ms": 8000})
    steps.append(f"tap_book={tap}")
    time.sleep(2)
    tap2 = call("tap_element", {"text": "目录", "match": "contains", "timeout_ms": 5000})
    steps.append(f"tap_toc={tap2}")
    time.sleep(2)
    tap3 = call("tap_element", {"text": "第一章", "match": "contains", "timeout_ms": 8000})
    steps.append(f"tap_ch1={tap3}")
    time.sleep(4)
    xiaoyan = call("assert_text_present", {"text": "萧炎", "timeout_ms": 8000})
    steps.append(f"assert_xiaoyan={xiaoyan.get('passed')}")
    cap = call("stop_capture")
    steps.append("stop_capture")
    trace = call("read_file", {"path": f"{DOC}/legado_openreader_trace.txt", "max_bytes": 32768})
    marker = call("read_file", {"path": f"{DOC}/legado_catalog_openreader.txt", "max_bytes": 4096})
    out = {
        "steps": steps,
        "xiaoyan_passed": xiaoyan.get("passed"),
        "marker": marker.get("content", "") if isinstance(marker, dict) else marker,
        "trace_tail": (trace.get("content", "") if isinstance(trace, dict) else str(trace))[-6000:],
        "capture_summary": {
            "syslog_count": len(cap.get("syslog", []) if isinstance(cap, dict) else []),
            "new_crashes": cap.get("new_crash_count") if isinstance(cap, dict) else None,
        },
    }
    # extract key log lines
    trace_text = trace.get("content", "") if isinstance(trace, dict) else ""
    keys = []
    for line in trace_text.splitlines():
        if any(k in line for k in [
            "divisionProbe", "divisionText@", "divisionResponse",
            "contentInject phase=", "nativePaged", "overlay92011",
            "showPageProgress", "native-page-miss", "division=1",
        ]):
            keys.append(line.split("|", 1)[-1].strip() if "|" in line else line.strip())
    out["key_logs"] = keys[-25:]
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
