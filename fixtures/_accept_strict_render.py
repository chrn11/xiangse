#!/usr/bin/env python3
"""Acceptance: strict render — nativeRead + assert 萧炎 + trace gates (post feb7e85)."""
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


def clear_open_once_markers():
    info = call("get_app_info", {"bundle_id": BUNDLE})
    paths = info.get("paths", {}) if isinstance(info, dict) else {}
    deleted = []
    doc = paths.get("documents", "")
    caches = paths.get("caches", "")
    lib = paths.get("library", "")
    candidates = []
    if doc:
        candidates.append(f"{doc}/legado_native_open_once.txt")
    if caches:
        candidates.append(f"{caches}/legado_native_open_once.txt")
    elif lib:
        candidates.append(f"{lib}/Caches/legado_native_open_once.txt")
    for p in candidates:
        if not p:
            continue
        try:
            call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10})
            deleted.append(p)
        except Exception:
            pass
    info = call("get_app_info", {"bundle_id": BUNDLE})
    doc = info.get("paths", {}).get("documents", "") if isinstance(info, dict) else ""
    if doc:
        for name in ("legado_openreader_trace.txt", "legado_catalog_openreader.txt"):
            try:
                call("run_command", {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 10})
            except Exception:
                pass
    return deleted


def main():
    steps = []
    call("wake_and_home")
    steps.append("wake_and_home")
    for p in clear_open_once_markers():
        steps.append(f"deleted_{p.split('/')[-1]}@{p.rsplit('/', 1)[0][-20:]}")
    call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    call("launch_app", {"bundle_id": BUNDLE})
    steps.append("launch")
    time.sleep(2)
    info = call("get_app_info", {"bundle_id": BUNDLE})
    doc = info.get("paths", {}).get("documents", "") if isinstance(info, dict) else ""
    call("open_url", {"url": f"legado://import/bookSource?src={SRC}"})
    steps.append("import_source")
    time.sleep(2)
    call("open_url", {
        "url": f"legado://nativeRead?bookUrl={BOOK}"
               "&sourceUrl=http://192.168.1.4:8765&idx=0"
    })
    steps.append("nativeRead")
    time.sleep(14)
    front = call("get_frontmost_app")
    front_bundle = front.get("bundleId") if isinstance(front, dict) else str(front)
    steps.append(f"front={front_bundle}")
    shot = call("screenshot")
    img_path = OUT_DIR / "_accept_screenshot_strict.png"
    saved = False
    if isinstance(shot, dict):
        for item in shot.get("content") or []:
            if item.get("type") == "image" and item.get("data"):
                img_path.write_bytes(base64.b64decode(item["data"]))
                saved = True
                break
    steps.append(f"screenshot_saved={saved}")
    xiaoyan = call("assert_text_present", {"text": "萧炎", "timeout_ms": 15000})
    steps.append(f"assert_xiaoyan={xiaoyan.get('passed')}")
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
    prefer_lines = [ln for ln in trace_text.splitlines() if "goStart preferNativeFull" in ln]
    prefer_after_clean = prefer_lines
    strict_hits = [ln for ln in trace_text.splitlines() if "tvHasNeedleStrict" in ln]
    probe_only = [ln for ln in trace_text.splitlines() if "tvHasNeedleProbeOnly" in ln or "probeOnly" in ln]
    false_paged = [
        ln for ln in trace_text.splitlines()
        if "nativePaged=1" in ln and "tvHasNeedle+" in ln and "tvHasNeedleStrict" not in ln
    ]
    out = {
        "steps": steps,
        "xiaoyan_passed": xiaoyan.get("passed") if isinstance(xiaoyan, dict) else False,
        "still_in_app": front_bundle == BUNDLE,
        "preferNativeFull_count": len(prefer_after_clean),
        "preferNativeFull_all": len(prefer_lines),
        "tvHasNeedleStrict_lines": len(strict_hits),
        "tvHasNeedleProbeOnly_lines": len(probe_only),
        "false_nativePaged_probe_only": len(false_paged),
        "has_signal": "SIGNAL sig=" in trace_text or "SIGNAL sig=" in marker_text,
        "screenshot": str(img_path) if img_path.exists() else None,
        "trace_tail": trace_text[-6000:],
        "marker_tail": marker_text[-2000:],
    }
    out_path = OUT_DIR / "_accept_result_strict.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
