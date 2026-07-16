#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在指定 IMP 反汇编窗口内提取 objc_msgSend 目标 selector（静态近似）。"""
from __future__ import annotations

import argparse
import json
import re
import struct
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

import lief
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

IMAGE_BASE = 0x100000000


class MsgSendTracer:
    def __init__(self, bin_path: Path):
        self.raw = bin_path.read_bytes()
        self.binary = lief.parse(str(bin_path))
        self._va_cache: Dict[int, int] = {}
        self.selrefs: Dict[int, str] = {}
        self.classrefs: Dict[int, str] = {}
        self._build_ref_maps()

    def _build_ref_maps(self) -> None:
        for sec in self.binary.sections:
            if sec.name == "__objc_selrefs":
                for i in range(sec.size // 8):
                    ref_va = sec.virtual_address + i * 8
                    sel_va = self.u64(ref_va)
                    s = self.cstr(sel_va)
                    if s:
                        self.selrefs[ref_va] = s
            if sec.name == "__objc_classrefs":
                for i in range(sec.size // 8):
                    ref_va = sec.virtual_address + i * 8
                    cls_va = self.u64(ref_va)
                    name = self._class_name_at(cls_va)
                    if name:
                        self.classrefs[ref_va] = name

    def va_to_off(self, va: int) -> Optional[int]:
        if va in self._va_cache:
            return self._va_cache[va]
        for seg in self.binary.segments:
            if seg.virtual_address <= va < seg.virtual_address + seg.virtual_size:
                off = seg.file_offset + (va - seg.virtual_address)
                self._va_cache[va] = off
                return off
        for sec in self.binary.sections:
            if sec.virtual_address <= va < sec.virtual_address + sec.size:
                off = sec.offset + (va - sec.virtual_address)
                self._va_cache[va] = off
                return off
        return None

    def u64(self, va: int) -> int:
        off = self.va_to_off(va)
        if off is None:
            return 0
        return struct.unpack_from("<Q", self.raw, off)[0]

    def cstr(self, va: int) -> Optional[str]:
        if not va:
            return None
        off = self.va_to_off(va)
        if off is None:
            return None
        end = self.raw.find(b"\x00", off)
        if end == -1:
            return None
        return self.raw[off:end].decode("utf-8", "replace")

    def _class_name_at(self, cls_va: int) -> Optional[str]:
        data_va = self.u64(cls_va + 32)
        data_off = self.va_to_off(data_va)
        if data_off is None:
            return None
        flags = struct.unpack_from("<I", self.raw, data_off)[0]
        ro_va = self.u64(data_va + 8) if flags & 1 else data_va
        name_va = self.u64(ro_va + 24)
        return self.cstr(name_va)

    def _page_off(self, addr: int, op_str: str) -> Optional[int]:
        m = re.search(r"#(-?0x[0-9a-fA-F]+)", op_str)
        if not m:
            return None
        return (addr & ~0xFFF) + int(m.group(1), 16)

    def _resolve_adrp_add(self, insns, idx: int) -> Optional[int]:
        if idx < 0 or idx >= len(insns):
            return None
        cur = insns[idx]
        if cur.mnemonic != "adrp":
            return None
        base = self._page_off(cur.address, cur.op_str)
        if base is None:
            return None
        if idx + 1 < len(insns) and insns[idx + 1].mnemonic == "add":
            add_m = re.search(r"#(-?0x[0-9a-fA-F]+)", insns[idx + 1].op_str)
            if add_m:
                return base + int(add_m.group(1), 16)
        return base

    def trace_imp(self, imp_va: int, max_insns: int = 1200) -> List[dict]:
        off = self.va_to_off(imp_va)
        if off is None:
            return []
        code = self.raw[off : off + max_insns * 4]
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        insns = list(md.disasm(code, imp_va))
        hits: List[dict] = []
        reg_val: Dict[str, int] = {}
        for i, insn in enumerate(insns):
            if insn.mnemonic == "adrp":
                val = self._resolve_adrp_add(insns, i)
                dst = insn.op_str.split(",")[0].strip()
                if val is not None:
                    reg_val[dst] = val
            elif insn.mnemonic == "add" and "sp" not in insn.op_str:
                parts = [p.strip() for p in insn.op_str.split(",")]
                if len(parts) == 3:
                    dst, src, imm = parts
                    if src in reg_val:
                        m = re.search(r"#(-?0x[0-9a-fA-F]+)", imm)
                        if m:
                            reg_val[dst] = reg_val[src] + int(m.group(1), 16)
            elif insn.mnemonic == "ldr" and "[" in insn.op_str:
                parts = [p.strip() for p in insn.op_str.split(",")]
                dst = parts[0]
                m = re.search(r"\[(\w+)(?:, #(-?0x[0-9a-fA-F]+))?\]", parts[1])
                if m:
                    base = m.group(1)
                    disp = int(m.group(2), 16) if m.group(2) else 0
                    if base in reg_val:
                        reg_val[dst] = reg_val[base] + disp
            elif insn.mnemonic == "mov" and "#" in insn.op_str:
                parts = [p.strip() for p in insn.op_str.split(",")]
                if len(parts) == 2:
                    m = re.search(r"#(-?0x[0-9a-fA-F]+)", parts[1])
                    if m:
                        reg_val[parts[0]] = int(m.group(1), 16)

            if insn.mnemonic != "bl":
                continue
            tgt_m = re.search(r"#(-?0x[0-9a-fA-F]+)", insn.op_str)
            if not tgt_m:
                continue
            tgt = int(tgt_m.group(1), 16)
            # stub 区常见 bl _objc_msgSend / _$objc_msgSend$...
            sel = reg_val.get("x1")
            recv = reg_val.get("x0")
            sel_name = self.selrefs.get(sel) or self.cstr(sel)
            recv_name = self.classrefs.get(recv)
            if sel_name or recv_name:
                hits.append(
                    {
                        "at": hex(insn.address),
                        "selector": sel_name,
                        "selector_va": hex(sel) if sel else None,
                        "receiver_classref": recv_name,
                        "receiver_va": hex(recv) if recv else None,
                    }
                )
            if insn.mnemonic == "ret":
                break
        return hits


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("binary", nargs="?", default="analysis/unpacked/Payload/StandarReader.app/StandarReader")
    ap.add_argument("--imp", action="append", default=[], help="IMP VA 如 0x1000d7cf4")
    ap.add_argument("-o", default="analysis/reader-forensics/objc-msg-trace.json")
    args = ap.parse_args()
    tracer = MsgSendTracer(Path(args.binary))
    out: Dict[str, list] = {}
    for imp_s in args.imp:
        imp = int(imp_s, 16) if imp_s.startswith("0x") else int(imp_s) + IMAGE_BASE
        out[imp_s] = tracer.trace_imp(imp)
    Path(args.o).parent.mkdir(parents=True, exist_ok=True)
    Path(args.o).write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {args.o}")


if __name__ == "__main__":
    main()
