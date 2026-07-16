#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解析 IMP 内 adrp+ldr x1 + bl stub 形态的 objc 调用。"""
from __future__ import annotations

import json
import re
import struct
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import lief
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

IMAGE_BASE = 0x100000000
MSG_SEND_STUBS = range(0x100201000, 0x100202000)


def va_to_off(binary, raw, va: int) -> Optional[int]:
    for seg in binary.segments:
        if seg.virtual_address <= va < seg.virtual_address + seg.virtual_size:
            return seg.file_offset + (va - seg.virtual_address)
    for sec in binary.sections:
        if sec.virtual_address <= va < sec.virtual_address + sec.size:
            return sec.offset + (va - sec.virtual_address)
    return None


def cstr(raw, off: int) -> str:
    end = raw.find(b"\x00", off)
    if end == -1:
        return ""
    return raw[end and off : end].decode("utf-8", "replace")


def build_selector_va_map(binary, raw) -> Dict[int, str]:
    """selref 解引用 + methname 区段直接映射。"""
    out: Dict[int, str] = {}
    sec = next((s for s in binary.sections if s.name == "__objc_selrefs"), None)
    if sec:
        for i in range(sec.size // 8):
            ref_va = sec.virtual_address + i * 8
            ref_off = va_to_off(binary, raw, ref_va)
            if ref_off is None:
                continue
            sel_va = struct.unpack_from("<Q", raw, ref_off)[0]
            sel_off = va_to_off(binary, raw, sel_va)
            if sel_off is not None:
                out[sel_va] = cstr(raw, sel_off)
    meth = next((s for s in binary.sections if s.name == "__objc_methname"), None)
    if meth:
        off = meth.offset
        end = off + meth.size
        while off < end:
            nul = raw.find(b"\x00", off, end)
            if nul == -1:
                break
            name = raw[off:nul].decode("utf-8", "replace")
            va = meth.virtual_address + (off - meth.offset)
            out.setdefault(va, name)
            off = nul + 1
    return out


def resolve_adrp(insn) -> Optional[int]:
    m = re.search(r"#(-?0x[0-9a-fA-F]+)", insn.op_str)
    if not m:
        return None
    page = int(m.group(1), 16)
    return page


def trace_imp(binary, raw, sel_vas: Dict[int, str], imp_va: int, max_insns: int = 1500) -> List[dict]:
    off = va_to_off(binary, raw, imp_va)
    if off is None:
        return []
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    insns = list(md.disasm(raw[off : off + max_insns * 4], imp_va))
    reg: Dict[str, int] = {}
    hits: List[dict] = []
    last_x1: Optional[int] = None

    for i, insn in enumerate(insns):
        if insn.mnemonic == "adrp":
            dst = insn.op_str.split(",")[0].strip()
            page = resolve_adrp(insn)
            if page is not None:
                reg[dst] = page

        elif insn.mnemonic == "add":
            parts = [p.strip() for p in insn.op_str.split(",")]
            if len(parts) == 3:
                dst, src, imm_s = parts
                m = re.search(r"#(-?0x[0-9a-fA-F]+)", imm_s)
                if m and src in reg:
                    reg[dst] = reg[src] + int(m.group(1), 16)

        elif insn.mnemonic == "ldr" and "[" in insn.op_str:
            m = re.match(r"(\w+),\s*\[(\w+), #(-?0x[0-9a-fA-F]+)\]", insn.op_str)
            if m:
                dst, base, disp_s = m.group(1), m.group(2), m.group(3)
                disp = int(disp_s, 16)
                if base in reg:
                    addr = reg[base] + disp
                    val_off = va_to_off(binary, raw, addr)
                    if val_off is not None and dst in ("x1", "x0", "x2", "x3", "x4", "x5"):
                        val = struct.unpack_from("<Q", raw, val_off)[0]
                        reg[dst] = val
                        if dst == "x1":
                            last_x1 = val
                    else:
                        reg[dst] = addr

        elif insn.mnemonic == "mov":
            parts = [p.strip() for p in insn.op_str.split(",")]
            if len(parts) == 2 and parts[1].startswith("x") and parts[1] in reg:
                reg[parts[0]] = reg[parts[1]]
                if parts[0] == "x1":
                    last_x1 = reg[parts[1]]

        elif insn.mnemonic == "bl":
            m = re.search(r"#(-?0x[0-9a-fA-F]+)", insn.op_str)
            if not m:
                continue
            tgt = int(m.group(1), 16)
            if tgt in MSG_SEND_STUBS and last_x1:
                sel = sel_vas.get(last_x1, "")
                hits.append(
                    {
                        "at": hex(insn.address),
                        "selector_va": hex(last_x1),
                        "selector": sel,
                    }
                )
                last_x1 = None
            elif tgt not in MSG_SEND_STUBS:
                hits.append({"at": hex(insn.address), "direct_bl": hex(tgt)})

        if insn.mnemonic == "ret" and insn.address > imp_va + 8:
            break

    return hits


CHAIN_IMPS = {
    "ReadPageContainer#loadCurCp": 0x1000D7CF4,
    "ReadPageContainer#divisionResponse:cpTitle:cpIndex:": 0x1000D886C,
    "ReadPageContainer#onDivisionTextFinish:cpIndex:": 0x1000D8870,
    "TextRPageContainer#divisionResponse:cpTitle:cpIndex:": 0x1000ABF1C,
    "TextRScrollContainer#divisionResponse:cpTitle:cpIndex:heights:": 0x1000FDD04,
    "TextRPageContainerPage#viewDidLoad": 0x1000B148C,
    "TextRPageContainerPage#showContent:title:": 0x1000B2450,
    "TextRPageContainerPage#textViewL": 0x1000B1924,
    "TextReadTV#drawRect:": 0x10005BED0,
    "ReadScrollContainerCell#setPageModel:": 0x10007957C,
    "PaibanManager#divisionText:paibanInfo:": 0x100055BFC,
    "BookDbManager#setCpCached:cpIndex:bookKey:sourceName:": 0x1000B0CA8,
}


def main() -> None:
    bin_path = Path("analysis/unpacked/Payload/StandarReader.app/StandarReader")
    raw = bin_path.read_bytes()
    binary = lief.parse(str(bin_path))
    sel_vas = build_selector_va_map(binary, raw)
    out = {}
    for label, imp in CHAIN_IMPS.items():
        out[label] = trace_imp(binary, raw, sel_vas, imp)
    out_path = Path("analysis/reader-forensics/chain-msg-hits.json")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
