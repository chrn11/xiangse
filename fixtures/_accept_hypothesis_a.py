#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假设 A2 验收：arrCatalog+attached 前置后 pageContainer getter 懒创建。"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient

MCP = "http://192.168.1.6:8090"
MOCK = "http://192.168.1.4:8765"
BUNDLE = "com.appbox.StandarReader"
OUT = ROOT / "fixtures/_accept_hypothesis_a.json"


def _head_sha() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()[:8]


def _ipa_path() -> Path:
  cands = [
      ROOT / "fixtures/_devkit/ci-artifact/dist/StandarReader-legado-debug.ipa",
      ROOT / "fixtures/_devkit/ci-artifact-9d4161d/dist/StandarReader-legado-bridge-debug.ipa",
  ]
  for p in cands:
      if p.is_file():
          return p
  raise FileNotFoundError("no legado IPA; download Reader-Forensics-IPAs artifact first")


def main() -> int:
    head = _head_sha()
    ipa = _ipa_path()
    c = McpClient(base_url=MCP, bundle_id=BUNDLE)
    print("health", c.health())
    up = c.upload_file(ipa)
    print("upload", up)
    dev = up.get("device_path") or up.get("path")
    print("install", c.call("install_app", {"path": dev}, timeout=300))
    c.call("wake_and_home", timeout=30)
    time.sleep(1)
    c.call("kill_app", {"bundle_id": BUNDLE}, timeout=20)
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE}, timeout=40)
    time.sleep(2)
    paths = c.app_paths()
    doc = paths.get("documents", "")
    for p in c.open_once_candidates(paths):
        try:
            c.call("run_command", {"command": f"rm -f '{p}'", "timeout_sec": 8}, timeout=15)
        except Exception:
            pass
    for name in (
        "legado_openreader_trace.txt",
        "legado_loadcurcp_state.txt",
        "legado_native_open_once.txt",
    ):
        try:
            c.call(
                "run_command",
                {"command": f"rm -f '{doc}/{name}'", "timeout_sec": 8},
                timeout=15,
            )
        except Exception:
            pass
    c.call(
        "open_url",
        {
            "url": f"legado://import/bookSource?src={MOCK}/legado-local-mock.runtime.json?t={int(time.time())}"
        },
        timeout=20,
    )
    time.sleep(2)
    c.call(
        "open_url",
        {
            "url": f"legado://nativeRead?bookUrl={MOCK}/book/doupo.html&sourceUrl={MOCK}&idx=0"
        },
        timeout=20,
    )
    time.sleep(14)
    tr = c.read_sandbox_text("legado_openreader_trace.txt", max_bytes=400000) or ""
    st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=200000) or ""
    blob = tr + "\n" + st
    ui = c.call("get_ui_elements", {"limit": 20}, timeout=25)
    texts = [
        str(e.get("text", ""))[:50]
        for e in (ui.get("elements") or [])
        if isinstance(e, dict)
    ]
    ui_join = "".join(texts)
    checks = {
        "hypothesis_A2_pre_lazy": "hypothesis_A2 pre_lazy" in blob,
        "hypothesis_A2_pageContainer_lazy": "hypothesis_A2 pageContainer_lazy" in blob,
        "TextRPageContainer_in_log": "TextRPageContainer" in blob,
        "invoke_orig_OK": "invoke_orig_OK" in blob,
        "invoke_skip_no_container": "invoke_skip reason=no_container" in blob,
        "pageContainer_EX": "hypothesis_A2 pageContainer_EX" in blob,
        "skip_lazy_gates": "hypothesis_A2 skip_lazy gates_not_met" in blob,
        "ORIG_OK_vdl": "hypothesis_R2 viewDidLoad ORIG_OK" in blob,
        "willAppear_noop": "hypothesis_R2 willAppear noop" in blob,
        "springboard": any(t in ui_join for t in ("日历", "钱包", "设置")),
        "bookshelf": "书架" in ui_join,
    }
    if (
        checks["hypothesis_A2_pageContainer_lazy"]
        and checks["TextRPageContainer_in_log"]
        and not checks["springboard"]
    ):
        verdict, reason = "PASS_PARTIAL", "A2 getter 命中 TextRPageContainer 且未回 SpringBoard"
    elif checks["pageContainer_EX"] or checks["springboard"]:
        verdict, reason = "FAIL_REVERT_A2", "getter 异常或回 SpringBoard"
    elif checks["invoke_skip_no_container"] and not checks["hypothesis_A2_pre_lazy"]:
        verdict, reason = "FAIL", "仍 no_container 且无 A2 前置日志"
    else:
        verdict, reason = "INCONCLUSIVE", "日志不足或 gates 未满足"
    out = {
        "verdict": verdict,
        "reason": reason,
        "checks": checks,
        "trace_tail": "\n".join(tr.splitlines()[-30:]),
        "state_tail": "\n".join(st.splitlines()[-30:]),
        "ui": texts[:10],
        "ipa": str(ipa),
        "head": head,
    }
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0 if verdict == "PASS_PARTIAL" else 1


if __name__ == "__main__":
    raise SystemExit(main())
