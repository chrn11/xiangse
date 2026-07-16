#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合并 ObjC method map 与 chain-msg-hits，写出最终产物。"""
from __future__ import annotations

import json
from pathlib import Path

CHAIN_HITS = Path("analysis/reader-forensics/chain-msg-hits.json")
METHOD_MAP = Path("analysis/reader-forensics/method-map.json")


def owner_key(class_name: str, selector: str) -> str:
    return f"{class_name}#{selector}"


def main() -> None:
    chain = json.loads(CHAIN_HITS.read_text(encoding="utf-8"))
    doc = json.loads(METHOD_MAP.read_text(encoding="utf-8"))

    # 将 chain 命中写入对应 method 条目
    chain_by_label = chain
    label_to_method = {
        "ReadPageContainer#loadCurCp": ("ReadPageContainer", "loadCurCp"),
        "ReadPageContainer#onDivisionTextFinish:cpIndex:": (
            "ReadPageContainer",
            "onDivisionTextFinish:cpIndex:",
        ),
        "TextRPageContainer#divisionResponse:cpTitle:cpIndex:": (
            "TextRPageContainer",
            "divisionResponse:cpTitle:cpIndex:",
        ),
        "TextRScrollContainer#divisionResponse:cpTitle:cpIndex:heights:": (
            "TextRScrollContainer",
            "divisionResponse:cpTitle:cpIndex:heights:",
        ),
        "TextRPageContainerPage#viewDidLoad": ("TextRPageContainerPage", "viewDidLoad"),
        "TextRPageContainerPage#showContent:title:": (
            "TextRPageContainerPage",
            "showContent:title:",
        ),
        "TextRPageContainerPage#textViewL": ("TextRPageContainerPage", "textViewL"),
        "TextReadTV#drawRect:": ("TextReadTV", "drawRect:"),
        "ReadScrollContainerCell#setPageModel:": ("ReadScrollContainerCell", "setPageModel:"),
    }

    extra_methods = []
    for label, (cls, sel) in label_to_method.items():
        hits = chain_by_label.get(label, [])
        sels = [h["selector"] for h in hits if h.get("selector")]
        entry = {
            "class": cls,
            "selector": sel,
            "type_encoding": "",
            "imp_offset": None,
            "imp_va": None,
            "is_class_method": False,
            "callers": [],
            "callees": sorted(set(sels)),
            "ivars_read": [],
            "ivars_written": [],
            "tool": "build_chain_msgs.py",
            "confidence": "confirmed" if sels else "probable",
            "evidence_reference": [
                f"IMP msgSend trace: {label}",
                "analysis/reader-forensics/chain-msg-hits.json",
            ],
        }
        extra_methods.append(entry)

    # 外部 owner（不在目标 8 类）作为补充节点
    external = [
        {
            "class": "PaibanManager",
            "selector": "divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:paibanInfo:",
            "imp_offset": 0x55BFC,
            "callees": chain_by_label.get("PaibanManager#divisionText:paibanInfo:", []),
            "confidence": "confirmed",
            "evidence_reference": ["__objc_classlist method_list", "chain-msg-hits"],
        },
        {
            "class": "BookDbManager",
            "selector": "setCpCached:cpIndex:bookKey:sourceName:",
            "imp_offset": 0xB0CA8,
            "callees": chain_by_label.get(
                "BookDbManager#setCpCached:cpIndex:bookKey:sourceName:", []
            ),
            "confidence": "confirmed",
            "evidence_reference": ["__objc_classlist method_list", "chain-msg-hits"],
        },
        {
            "class": "ReadPageContainer",
            "selector": "lpNetWorkDelegateQueryFinish:config:userInfo:",
            "imp_offset": 0xD8278,
            "callees": ["divisionResponse:cpTitle:cpIndex:"],
            "confidence": "confirmed",
            "evidence_reference": ["IMP msgSend trace lpNetWorkDelegateQueryFinish"],
        },
        {
            "class": "TextReadTVBase",
            "selector": "setAttString:",
            "imp_offset": 0x5B6A4,
            "callees": ["setNeedsDisplay"],
            "confidence": "confirmed",
            "evidence_reference": ["IMP msgSend trace setAttString"],
        },
        {
            "class": "TextReadTVBase",
            "selector": "resetFrameRef",
            "imp_offset": 0x5B5D4,
            "callees": ["setNeedsDisplay"],
            "confidence": "confirmed",
            "evidence_reference": ["IMP msgSend trace resetFrameRef"],
        },
        {
            "class": "ReadScrollContainerCell",
            "selector": "setPageModel:",
            "imp_offset": 0x7957C,
            "callees": [],
            "ivars_written": ["ReadScrollContainerCell._pageModel"],
            "confidence": "confirmed",
            "evidence_reference": [
                "synthesized setter IMP 0x10007957c stores _pageModel ivar"
            ],
        },
    ]

    for ext in external:
        callees = ext.get("callees", [])
        if isinstance(callees, list) and callees and isinstance(callees[0], dict):
            callees = [h.get("selector", "") for h in callees if h.get("selector")]
        extra_methods.append(
            {
                "class": ext["class"],
                "selector": ext["selector"],
                "type_encoding": "",
                "imp_offset": ext.get("imp_offset"),
                "imp_va": hex(0x100000000 + ext["imp_offset"])
                if ext.get("imp_offset")
                else None,
                "is_class_method": False,
                "callers": [],
                "callees": callees,
                "ivars_read": ext.get("ivars_read", []),
                "ivars_written": ext.get("ivars_written", []),
                "tool": "finalize_method_map.py",
                "confidence": ext["confidence"],
                "evidence_reference": ext["evidence_reference"],
            }
        )

    # 更新已有 method 条目的 callees
    for m in doc["methods"]:
        key = owner_key(m["class"], m["selector"])
        for label, (cls, sel) in label_to_method.items():
            if m["class"] == cls and m["selector"] == sel:
                hits = chain_by_label.get(label, [])
                m["callees"] = sorted(
                    {h["selector"] for h in hits if h.get("selector")} | set(m.get("callees", []))
                )
                m["confidence"] = "confirmed"
                m["evidence_reference"] = list(
                    dict.fromkeys(
                        (m.get("evidence_reference") or [])
                        + [f"chain-msg: {label}"]
                    )
                )

    doc["methods"].extend(extra_methods)
    doc["chain_summary"] = {
        "textViewL_owner": "TextRPageContainerPage",
        "textViewL_creator_imp": "0x1000b1924",
        "ctframe_ivar": "TextReadTVBase.frameRef",
        "pageModel_scroll_cell": "ReadScrollContainerCell._pageModel",
        "divisionText_owner": "PaibanManager",
        "setCpCached_owner": "BookDbManager",
        "loadCurCp_owner": "ReadPageContainer",
    }

    METHOD_MAP.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"updated {METHOD_MAP}")


if __name__ == "__main__":
    main()
