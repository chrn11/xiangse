#!/usr/bin/env python3
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient

c = McpClient("http://192.168.1.6:8090")
B = "com.appbox.StandarReader"
c.call("wake_and_home")
time.sleep(1)
c.call("kill_app", {"bundle_id": B})
time.sleep(2)
c.call("launch_app", {"bundle_id": B})
time.sleep(5)
c.call("tap_screen", {"x": 195, "y": 360})
time.sleep(2)
c.call("tap_screen", {"x": 195, "y": 240})
time.sleep(8)
stack = c.get_vc_stack()
print("VC", stack)
ui = c.call("get_ui_elements", {"limit": 40}, timeout=30)
print("UI", [e.get("text", "")[:40] for e in ui.get("elements", []) if e.get("text")][:12])
results = []
for i in range(10):
    c.call("open_url", {"url": f"legado://debugDump?phase=stability_{i}"})
    time.sleep(2.5)
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=300000)
    results.append({
        "i": i,
        "len": len(dump),
        "v2": "forensics dump v2" in dump,
        "textread": "TextReadVC3" in dump,
        "nonempty": "Attr len=" in dump or "NSString len=" in dump or "txtLen=" in dump,
        "head": dump[:160],
    })
crash = c.read_sandbox_text("legado_debug_crash.txt", max_bytes=4000)
out = {"results": results, "crash_tail": crash[-500:] if crash else ""}
Path(ROOT / "fixtures/_devkit/forensics_verify_once.json").write_text(
    json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8"
)
print(json.dumps(out, ensure_ascii=False, indent=2))
