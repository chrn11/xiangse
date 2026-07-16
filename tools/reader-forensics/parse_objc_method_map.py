#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 Mach-O ObjC 元数据解析 reader 类 method map 与静态 xref。"""
from __future__ import annotations

import argparse
import json
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

try:
    import lief
except ImportError as e:
    raise SystemExit("需要 lief: pip install lief") from e

try:
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
except ImportError as e:
    raise SystemExit("需要 capstone: pip install capstone") from e

IMAGE_BASE = 0x100000000

TARGET_CLASSES = [
    "TextReadVC3",
    "TextRPageContainer",
    "TextRPageContainerPage",
    "TextRScrollContainer",
    "TextReadTV",
    "ReadPageModel",
    "ReadPageContainer",
    "ReadScrollContainer",
]

CHAIN_SELECTORS = [
    "loadCurCp",
    "setCpCached:cpIndex:bookKey:sourceName:",
    "ResetContent",
    "divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:",
    "divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:paibanInfo:",
    "divisionResponse:cpIndex:",
    "divisionResponse:cpTitle:cpIndex:",
    "divisionResponse:cpTitle:cpIndex:heights:",
    "onDivisionTextFinish:cpIndex:",
    "showContent:",
    "showContent:title:",
    "setPageModel:",
    "drawRect:",
    "textViewL",
    "setTextViewL:",
    "pageModel",
    "setPageModel:",
]

REL_METHOD_MASK = 0x80000000


@dataclass
class MethodEntry:
    selector: str
    type_encoding: str
    imp_va: int
    imp_offset: int
    is_class_method: bool = False


@dataclass
class IvarEntry:
    name: str
    type_encoding: str
    offset: int


@dataclass
class PropertyEntry:
    name: str
    attributes: str


@dataclass
class ClassInfo:
    name: str
    superclass: Optional[str]
    cls_va: int
    ro_va: int
    ivars: List[IvarEntry] = field(default_factory=list)
    properties: List[PropertyEntry] = field(default_factory=list)
    instance_methods: List[MethodEntry] = field(default_factory=list)
    class_methods: List[MethodEntry] = field(default_factory=list)


class MachOObjCParser:
    def __init__(self, bin_path: Path):
        self.bin_path = bin_path
        self.raw = bin_path.read_bytes()
        self.binary = lief.parse(str(bin_path))
        if self.binary is None:
            raise ValueError(f"无法解析 Mach-O: {bin_path}")
        self._va_cache: Dict[int, int] = {}
        self._class_by_name: Dict[str, ClassInfo] = {}
        self._imp_to_method: Dict[int, Tuple[str, str, bool]] = {}
        self._selref_to_sel: Dict[int, str] = {}
        self._text_range: Tuple[int, int] = (0, 0)
        self._init_ranges()

    def _init_ranges(self) -> None:
        for seg in self.binary.segments:
            if seg.name == "__TEXT":
                self._text_range = (
                    seg.virtual_address,
                    seg.virtual_address + seg.virtual_size,
                )
                break

    def va_to_off(self, va: int) -> Optional[int]:
        if va in self._va_cache:
            return self._va_cache[va]
        for seg in self.binary.segments:
            start = seg.virtual_address
            end = start + seg.virtual_size
            if start <= va < end:
                off = seg.file_offset + (va - start)
                self._va_cache[va] = off
                return off
        for sec in self.binary.sections:
            start = sec.virtual_address
            end = start + sec.size
            if start <= va < end:
                off = sec.offset + (va - start)
                self._va_cache[va] = off
                return off
        return None

    def u32(self, va: int) -> int:
        off = self.va_to_off(va)
        if off is None:
            raise ValueError(f"u32 bad va {hex(va)}")
        return struct.unpack_from("<I", self.raw, off)[0]

    def u64(self, va: int) -> int:
        off = self.va_to_off(va)
        if off is None:
            raise ValueError(f"u64 bad va {hex(va)}")
        return struct.unpack_from("<Q", self.raw, off)[0]

    def cstr(self, va: int) -> Optional[str]:
        off = self.va_to_off(va)
        if off is None or off < 0 or off >= len(self.raw):
            return None
        end = self.raw.find(b"\x00", off)
        if end == -1:
            return None
        return self.raw[off:end].decode("utf-8", "replace")

    def read_relative(self, base_va: int, field_va: int) -> int:
        off = self.va_to_off(field_va)
        if off is None:
            return 0
        rel = struct.unpack_from("<i", self.raw, off)[0]
        return field_va + rel

    def resolve_ro(self, data_va: int) -> int:
        data_off = self.va_to_off(data_va)
        if data_off is None:
            return 0
        flags = struct.unpack_from("<I", self.raw, data_off)[0]
        if flags & 0x1:
            return self.u64(data_va + 8)
        return data_va

    def class_name_at(self, cls_va: int) -> Optional[str]:
        cls_off = self.va_to_off(cls_va)
        if cls_off is None:
            return None
        data_va = self.u64(cls_va + 32)
        ro_va = self.resolve_ro(data_va)
        ro_off = self.va_to_off(ro_va)
        if ro_off is None:
            return None
        name_va = self.u64(ro_va + 24)
        return self.cstr(name_va)

    def superclass_name(self, cls_va: int) -> Optional[str]:
        sup_va = self.u64(cls_va + 8)
        if sup_va == 0:
            return None
        return self.class_name_at(sup_va)

    def parse_method_list(
        self, list_va: int, is_class_method: bool
    ) -> List[MethodEntry]:
        if list_va == 0:
            return []
        list_off = self.va_to_off(list_va)
        if list_off is None:
            return []
        entsize_and_flags, count = struct.unpack_from("<II", self.raw, list_off)
        entsize = entsize_and_flags & ~REL_METHOD_MASK
        is_relative = bool(entsize_and_flags & REL_METHOD_MASK)
        if entsize == 0:
            entsize = 3 * 8
        methods: List[MethodEntry] = []
        entry_va = list_va + 8
        for _ in range(count):
            if is_relative:
                name_va = self.read_relative(entry_va, entry_va)
                types_va = self.read_relative(entry_va, entry_va + 4)
                imp_va = self.read_relative(entry_va, entry_va + 8)
            else:
                name_va = self.u64(entry_va)
                types_va = self.u64(entry_va + 8)
                imp_va = self.u64(entry_va + 16)
            sel = self.cstr(name_va) or ""
            types = self.cstr(types_va) or ""
            imp_offset = imp_va - IMAGE_BASE if imp_va else 0
            methods.append(
                MethodEntry(
                    selector=sel,
                    type_encoding=types,
                    imp_va=imp_va,
                    imp_offset=imp_offset,
                    is_class_method=is_class_method,
                )
            )
            entry_va += entsize
        return methods

    def parse_ivar_list(self, list_va: int) -> List[IvarEntry]:
        if list_va == 0:
            return []
        list_off = self.va_to_off(list_va)
        if list_off is None:
            return []
        entsize, count = struct.unpack_from("<II", self.raw, list_off)
        if entsize == 0:
            entsize = 32
        ivars: List[IvarEntry] = []
        entry_va = list_va + 8
        for _ in range(count):
            offset_ptr_va = self.u64(entry_va)
            name_va = self.u64(entry_va + 8)
            type_va = self.u64(entry_va + 16)
            name = self.cstr(name_va) or ""
            typ = self.cstr(type_va) or ""
            off = 0
            if offset_ptr_va:
                off_off = self.va_to_off(offset_ptr_va)
                if off_off is not None:
                    off = struct.unpack_from("<i", self.raw, off_off)[0]
            ivars.append(IvarEntry(name=name, type_encoding=typ, offset=off))
            entry_va += entsize
        return ivars

    def parse_property_list(self, list_va: int) -> List[PropertyEntry]:
        if list_va == 0:
            return []
        list_off = self.va_to_off(list_va)
        if list_off is None:
            return []
        entsize, count = struct.unpack_from("<II", self.raw, list_off)
        if entsize == 0:
            entsize = 16
        props: List[PropertyEntry] = []
        entry_va = list_va + 8
        for _ in range(count):
            name_va = self.u64(entry_va)
            attr_va = self.u64(entry_va + 8)
            name = self.cstr(name_va) or ""
            attr = self.cstr(attr_va) or ""
            props.append(PropertyEntry(name=name, attributes=attr))
            entry_va += entsize
        return props

    def parse_class(self, cls_va: int) -> Optional[ClassInfo]:
        name = self.class_name_at(cls_va)
        if not name:
            return None
        data_va = self.u64(cls_va + 32)
        ro_va = self.resolve_ro(data_va)
        ro_off = self.va_to_off(ro_va)
        if ro_off is None:
            return None
        base_methods_va = self.u64(ro_va + 32)
        ivars_va = self.u64(ro_va + 48)
        props_va = self.u64(ro_va + 64)
        info = ClassInfo(
            name=name,
            superclass=self.superclass_name(cls_va),
            cls_va=cls_va,
            ro_va=ro_va,
            ivars=self.parse_ivar_list(ivars_va),
            properties=self.parse_property_list(props_va),
            instance_methods=self.parse_method_list(base_methods_va, False),
        )
        isa_va = self.u64(cls_va)
        if isa_va:
            meta_data_va = self.u64(isa_va + 32)
            meta_ro_va = self.resolve_ro(meta_data_va)
            meta_ro_off = self.va_to_off(meta_ro_va)
            if meta_ro_off is not None:
                cm_va = self.u64(meta_ro_va + 32)
                info.class_methods = self.parse_method_list(cm_va, True)
        return info

    def load_all_target_classes(self) -> None:
        sec = next(
            (s for s in self.binary.sections if s.name == "__objc_classlist"), None
        )
        if sec is None:
            raise ValueError("缺少 __objc_classlist")
        count = sec.size // 8
        targets = set(TARGET_CLASSES)
        for i in range(count):
            cls_va = self.u64(sec.virtual_address + i * 8)
            info = self.parse_class(cls_va)
            if info is None:
                continue
            for m in info.instance_methods + info.class_methods:
                if m.imp_va:
                    self._imp_to_method[m.imp_va] = (
                        info.name,
                        m.selector,
                        m.is_class_method,
                    )
            if info.name in targets:
                self._class_by_name[info.name] = info

    def build_selref_map(self) -> None:
        sec = next(
            (s for s in self.binary.sections if s.name == "__objc_selrefs"), None
        )
        if sec is None:
            return
        count = sec.size // 8
        for i in range(count):
            ref_va = sec.virtual_address + i * 8
            sel_va = self.u64(ref_va)
            sel = self.cstr(sel_va)
            if sel:
                self._selref_to_sel[ref_va] = sel

    @staticmethod
    def _bl_target(insn) -> Optional[int]:
        if insn.mnemonic != "bl":
            return None
        # capstone 在部分环境禁用 detail 时，从 op_str 解析 #0x...
        op = getattr(insn, "op_str", "") or ""
        if op.startswith("#"):
            try:
                return int(op[1:], 16)
            except ValueError:
                return None
        if insn.operands:
            oper = insn.operands[0]
            if oper.type == 2:
                return oper.imm
        return None

    def disasm_bl_targets(self, imp_va: int, max_insns: int = 400) -> Set[int]:
        off = self.va_to_off(imp_va)
        if off is None:
            return set()
        code = self.raw[off : off + max_insns * 4]
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        targets: Set[int] = set()
        for insn in md.disasm(code, imp_va):
            tgt = self._bl_target(insn)
            if tgt is not None:
                targets.add(tgt)
        return targets

    def build_caller_index(self, imp_set: Set[int]) -> Dict[int, List[str]]:
        """单次扫描 __TEXT，建立 imp -> callers 索引。"""
        index: Dict[int, Set[str]] = {imp: set() for imp in imp_set}
        text_start, text_end = self._text_range
        off_start = self.va_to_off(text_start)
        off_end = self.va_to_off(text_end)
        if off_start is None or off_end is None:
            return {k: [] for k in imp_set}
        code = self.raw[off_start:off_end]
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        for insn in md.disasm(code, text_start):
            tgt = self._bl_target(insn)
            if tgt is None or tgt not in index:
                continue
            owner = self._imp_to_method.get(insn.address)
            if owner:
                cls, sel, _ = owner
                index[tgt].add(f"{cls}#{sel}")
            else:
                index[tgt].add(f"unknown@{hex(insn.address)}")
        return {k: sorted(v) for k, v in index.items()}

    def find_callers_of_imp(self, imp_va: int) -> List[str]:
        """在 __TEXT 中扫描 bl 到 imp_va 的调用方。"""
        callers: Set[str] = set()
        text_start, text_end = self._text_range
        off_start = self.va_to_off(text_start)
        off_end = self.va_to_off(text_end)
        if off_start is None or off_end is None:
            return []
        code = self.raw[off_start:off_end]
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        for insn in md.disasm(code, text_start):
            tgt = self._bl_target(insn)
            if tgt is None or tgt != imp_va:
                continue
            owner = self._imp_to_method.get(insn.address)
            if owner:
                cls, sel, _ = owner
                callers.add(f"{cls}#{sel}")
            else:
                callers.add(f"unknown@{hex(insn.address)}")
        return sorted(callers)

    def resolve_bl_to_selector(self, target_va: int) -> Optional[str]:
        owner = self._imp_to_method.get(target_va)
        if owner:
            return f"{owner[0]}#{owner[1]}"
        return None

    def analyze_method_body(
        self, imp_va: int, max_insns: int = 600
    ) -> Tuple[List[str], List[str], List[str], List[str]]:
        off = self.va_to_off(imp_va)
        if off is None:
            return [], [], [], []
        code = self.raw[off : off + max_insns * 4]
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        callees: Set[str] = set()
        ivars_read: Set[str] = set()
        ivars_written: Set[str] = set()
        for insn in md.disasm(code, imp_va):
            tgt = self._bl_target(insn)
            if tgt is not None:
                resolved = self.resolve_bl_to_selector(tgt)
                if resolved:
                    callees.add(resolved)
                else:
                    callees.add(f"sub_{tgt - IMAGE_BASE:x}")
            if insn.mnemonic in ("ret", "b") and insn.address > imp_va + 16:
                break
        return (
            sorted(callees),
            sorted(ivars_read),
            sorted(ivars_written),
            [],
        )

    def find_method_owner(self, selector: str) -> List[Tuple[str, MethodEntry]]:
        hits: List[Tuple[str, MethodEntry]] = []
        for cls_name, info in self._class_by_name.items():
            for m in info.instance_methods + info.class_methods:
                if m.selector == selector:
                    hits.append((cls_name, m))
        return hits

    def export_method_map(self) -> dict:
        entries = []
        chain_imp_set: Set[int] = set()
        for cls_name, info in sorted(self._class_by_name.items()):
            for m in info.instance_methods + info.class_methods:
                if m.selector in CHAIN_SELECTORS:
                    chain_imp_set.add(m.imp_va)

        caller_cache: Dict[int, List[str]] = {}
        if chain_imp_set:
            caller_cache = self.build_caller_index(chain_imp_set)

        for cls_name, info in sorted(self._class_by_name.items()):
            for m in info.instance_methods + info.class_methods:
                if m.selector in CHAIN_SELECTORS:
                    callees, ivr, ivw, _ = self.analyze_method_body(m.imp_va, 800)
                    callers = caller_cache.get(m.imp_va, [])
                else:
                    callees, ivr, ivw, callers = [], [], [], []
                conf = "confirmed"
                evidence = [
                    f"__objc_classlist->{cls_name}",
                    f"class_ro_t.baseMethods imp={hex(m.imp_va)}",
                ]
                if not callers and m.selector in CHAIN_SELECTORS:
                    conf = "probable" if callees else "unknown"
                entries.append(
                    {
                        "class": cls_name,
                        "selector": m.selector,
                        "type_encoding": m.type_encoding,
                        "imp_offset": m.imp_offset,
                        "imp_va": hex(m.imp_va),
                        "is_class_method": m.is_class_method,
                        "callers": callers,
                        "callees": callees,
                        "ivars_read": ivr,
                        "ivars_written": ivw,
                        "tool": "parse_objc_method_map.py",
                        "confidence": conf,
                        "evidence_reference": evidence,
                    }
                )
        # chain selectors possibly on superclass — mark unresolved
        for sel in CHAIN_SELECTORS:
            if not any(e["selector"] == sel for e in entries):
                owners = []
                for cls_name, info in self._class_by_name.items():
                    pass
                entries.append(
                    {
                        "class": "unknown",
                        "selector": sel,
                        "type_encoding": "",
                        "imp_offset": None,
                        "imp_va": None,
                        "is_class_method": None,
                        "callers": [],
                        "callees": [],
                        "ivars_read": [],
                        "ivars_written": [],
                        "tool": "parse_objc_method_map.py",
                        "confidence": "unknown",
                        "evidence_reference": [
                            f"selector '{sel}' 不在目标 8 类 method list 中"
                        ],
                    }
                )
        return {
            "schema_version": 1,
            "binary": str(self.bin_path),
            "image_base": hex(IMAGE_BASE),
            "base_ipa_sha256": "ed35e2734ef9d75ab8700921ec2819bb329c679ea508ba88e6d9576ae7be1631",
            "executable_sha256": "04f780eb59f86c9104f8c8c3c04fb24278f521d0a43e401b3773d2a47890dea7",
            "classes": {
                name: {
                    "superclass": info.superclass,
                    "cls_va": hex(info.cls_va),
                    "ro_va": hex(info.ro_va),
                    "ivars": [
                        {
                            "name": iv.name,
                            "type_encoding": iv.type_encoding,
                            "offset": iv.offset,
                        }
                        for iv in info.ivars
                    ],
                    "properties": [
                        {"name": p.name, "attributes": p.attributes}
                        for p in info.properties
                    ],
                    "instance_method_count": len(info.instance_methods),
                    "class_method_count": len(info.class_methods),
                }
                for name, info in sorted(self._class_by_name.items())
            },
            "methods": entries,
        }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "binary",
        nargs="?",
        default="analysis/unpacked/Payload/StandarReader.app/StandarReader",
    )
    ap.add_argument(
        "-o",
        "--output",
        default="analysis/reader-forensics/method-map.json",
    )
    args = ap.parse_args()
    parser = MachOObjCParser(Path(args.binary))
    parser.load_all_target_classes()
    parser.build_selref_map()
    doc = parser.export_method_map()
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {out} classes={len(doc['classes'])} methods={len(doc['methods'])}")


if __name__ == "__main__":
    main()
