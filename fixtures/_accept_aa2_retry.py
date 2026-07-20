# -*- coding: utf-8 -*-
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.ios_mcp_client import McpClient

MCP = "http://192.168.1.6:8090"
MOCK = "http://192.168.1.4:8765"
BUNDLE = "com.appbox.StandarReader"
OUT = ROOT / "fixtures" / "_accept_aa2_retry.json"


def main() -> int:
    c = McpClient(MCP, BUNDLE)
    c.call("wake_and_home")
    try:
        c.call("kill_app", {"bundle_id": BUNDLE})
    except Exception:
        pass
    time.sleep(1)
    c.call("launch_app", {"bundle_id": BUNDLE})
    time.sleep(3)
    doc = (c.app_paths() or {}).get("documents", "")
    for n in (
        "legado_loadcurcp_state.txt",
        "legado_openreader_trace.txt",
        "legado_debug_dump.txt",
    ):
        try:
            c.call(
                "run_command",
                {"command": f"rm -f '{doc}/{n}'", "timeout_sec": 8},
                timeout=15,
            )
        except Exception:
            pass
    c.call(
        "open_url",
        {
            "url": f"legado://import/bookSource?src={MOCK}/legado-local-mock.runtime.json?t={int(time.time())}"
        },
    )
    time.sleep(3)
    c.call(
        "open_url",
        {
            "url": (
                f"legado://nativeRead?bookUrl={MOCK}/book/doupo.html"
                f"&sourceUrl={MOCK}&idx=0"
            )
        },
    )
    polls = []
    for i in range(22):
        time.sleep(1)
        st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=120000) or ""
        row = {
            "t": i + 1,
            "n": len(st.splitlines()),
            "inv": "invoke_orig_OK" in st,
            "aa_next": "hypothesis_AA call_next" in st,
            "dont": "inject_dontFormat" in st,
            "z": "fileExists=1" in st,
            "tail": (st.splitlines()[-1] if st else "")[:160],
        }
        polls.append(row)
        print(row, flush=True)
        if row["inv"] and (row["aa_next"] or row["dont"] or i >= 14):
            break
    try:
        c.call("open_url", {"url": "legado://debugDump?phase=aa2_retry"})
        time.sleep(2)
    except Exception as exc:
        print("dump_err", exc, flush=True)
    st = c.read_sandbox_text("legado_loadcurcp_state.txt", max_bytes=250000) or ""
    dump = c.read_sandbox_text("legado_debug_dump.txt", max_bytes=250000) or ""
    aa = [ln for ln in st.splitlines() if "hypothesis_AA" in ln]
    qf = [
        ln
        for ln in dump.splitlines()
        if "lpNetWorkDelegateQueryFinish" in ln
        and ("before" in ln or "after" in ln)
        and " enc=" not in ln
    ]
    cb = [
        ln
        for ln in dump.splitlines()
        if "callBackResponse:config:userInfo:" in ln
        and ("before" in ln or "after" in ln)
        and " enc=" not in ln
    ]
    out = {
        "polls": polls,
        "aa": aa,
        "qf_n": len(qf),
        "cb_n": len(cb),
        "qf": qf[-5:],
        "cb": cb[-5:],
        "state_tail": st.splitlines()[-30:],
        "invoke": "invoke_orig_OK" in st,
        "call_next": any("call_next" in ln for ln in aa),
        "dontFormat": any("dontFormat" in ln for ln in aa),
    }
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(
        json.dumps(
            {
                "invoke": out["invoke"],
                "call_next": out["call_next"],
                "dontFormat": out["dontFormat"],
                "qf": out["qf_n"],
                "cb": out["cb_n"],
                "aa_n": len(aa),
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
