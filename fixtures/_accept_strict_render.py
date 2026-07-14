#!/usr/bin/env python3
"""Acceptance: strict render — nativeRead + assert 萧炎 + trace gates (post feb7e85)."""
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ios_mcp_client import McpClient

MCP_BASE = "http://192.168.1.6:8090"
BUNDLE = "com.appbox.StandarReader"
SRC = "http://192.168.1.4:8765/legado-local-mock.runtime.json"
BOOK = "http://192.168.1.4:8765/book/doupo.html"
OUT_DIR = Path(__file__).resolve().parent


def clear_open_once_markers(client: McpClient):
    paths = client.app_paths()
    deleted = []
    for p in client.open_once_candidates(paths):
        try:
            client.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 10})
            deleted.append(p)
        except Exception:
            pass
    doc = paths.get("documents", "")
    if doc:
        for name in ("legado_openreader_trace.txt", "legado_catalog_openreader.txt"):
            try:
                client.call("run_command", {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 10})
            except Exception:
                pass
    return deleted


def main():
    client = McpClient(base_url=MCP_BASE, bundle_id=BUNDLE)
    steps = []
    client.call("wake_and_home")
    steps.append("wake_and_home")
    for p in clear_open_once_markers(client):
        steps.append(f"deleted_{p.split('/')[-1]}@{p.rsplit('/', 1)[0][-20:]}")
    client.call("kill_app", {"bundle_id": BUNDLE})
    time.sleep(1)
    client.call("launch_app", {"bundle_id": BUNDLE})
    steps.append("launch")
    time.sleep(2)
    client.call("open_url", {"url": f"legado://import/bookSource?src={SRC}"})
    steps.append("import_source")
    time.sleep(2)
    client.call("open_url", {
        "url": f"legado://nativeRead?bookUrl={BOOK}"
               "&sourceUrl=http://192.168.1.4:8765&idx=0"
    })
    steps.append("nativeRead")
    time.sleep(14)
    front = client.call("get_frontmost_app")
    front_bundle = front.get("bundleId") if isinstance(front, dict) else str(front)
    steps.append(f"front={front_bundle}")
    img_path = OUT_DIR / "_accept_screenshot_strict.png"
    saved = client.screenshot_to(img_path)
    steps.append(f"screenshot_saved={saved}")
    xiaoyan = client.call("assert_text_present", {"text": "萧炎", "timeout_ms": 15000})
    steps.append(f"assert_xiaoyan={xiaoyan.get('passed')}")
    trace_text = client.read_sandbox_text("legado_openreader_trace.txt")
    marker_text = client.read_sandbox_text("legado_catalog_openreader.txt")
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
