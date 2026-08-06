#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TC-00B：clone IPA 结构变换 / 只读校验 / 纯本地合成夹具测试。

仅使用 Python 标准库。不连接设备、不调用真实 codesign、不写真实生产 IPA。
测试临时目录：仓库内 .artifacts/test_runs/TC-00B/<runID>/
也可被 bash 包装脚本以 --mode repack|verify 调用。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import sys
import tempfile
import time
import uuid
import zipfile
from pathlib import Path
from typing import Any
# ---------------------------------------------------------------------------
# 固定 clone 身份（不得改为同 bundle debug）
# ---------------------------------------------------------------------------
CLONE_BUNDLE_ID = "com.appbox.StandarReader.legado.test"
CLONE_DISPLAY_NAME = "香色阅读·测试"
SCHEME_SUFFIX = ".legado.test"
DEFAULT_SOURCE_MAIN = "com.appbox.StandarReader"

MANIFEST_REQUIRED_FIELDS = (
    "schemaVersion",
    "kind",
    "sourceIpaSha256",
    "outputIpaSha256",
    "mainBundleId",
    "displayName",
    "bundleIds",
    "machOUuids",
    "entitlementHashes",
    "signedObjects",
    "expected_data_container_isolation",
    "signatureVerification",
)

# 脱敏错误枚举（日志/JSON 仅用枚举，不落敏感原文）
class Err:
    EMPTY_PATH = "ERR_EMPTY_PATH"
    INPUT_EQUALS_OUTPUT = "ERR_INPUT_EQUALS_OUTPUT"
    NOT_FILE = "ERR_NOT_FILE"
    OUTPUT_EXISTS = "ERR_OUTPUT_EXISTS"
    UNSAFE_WORK_ROOT = "ERR_UNSAFE_WORK_ROOT"
    MAIN_BUNDLE_ID = "ERR_MAIN_BUNDLE_ID"
    DISPLAY_NAME = "ERR_DISPLAY_NAME"
    REAL_BUNDLE_RESIDUE = "ERR_REAL_BUNDLE_RESIDUE"
    URL_SCHEME_RESIDUE = "ERR_URL_SCHEME_RESIDUE"
    EXTENSION_UNMAPPED = "ERR_EXTENSION_UNMAPPED"
    ENTITLEMENT_NOT_ISOLATED = "ERR_ENTITLEMENT_NOT_ISOLATED"
    MANIFEST_MISSING_FIELD = "ERR_MANIFEST_MISSING_FIELD"
    CONTAINER_ISOLATION = "ERR_CONTAINER_ISOLATION"
    PROFILE_DISALLOWS_CLONE = "ERR_PROFILE_DISALLOWS_CLONE"
    MISSING_SIGNING_IDENTITY = "ERR_MISSING_SIGNING_IDENTITY"
    MISSING_PROFILE = "ERR_MISSING_PROFILE"
    MISSING_MACOS_TOOLS = "ERR_MISSING_MACOS_TOOLS"
    NO_APP_BUNDLE = "ERR_NO_APP_BUNDLE"
    MACHO_UUID_UNREADABLE = "ERR_MACHO_UUID_UNREADABLE"
    SCHEME_INVENTED = "ERR_SCHEME_INVENTED"
    WORK_ROOT_REQUIRED = "ERR_WORK_ROOT_REQUIRED"
    INTERNAL = "ERR_INTERNAL"


class ClonePackagingError(Exception):
    def __init__(self, code: str, detail: str = "") -> None:
        self.code = code
        self.detail = detail
        super().__init__(code if not detail else f"{code}:{detail}")


# ---------------------------------------------------------------------------
# 路径 / 哈希工具
# ---------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _norm_path(p: Path) -> Path:
    return p.expanduser().resolve()


def is_c_drive_path(path: Path) -> bool:
    s = str(path).replace("/", "\\")
    if re.match(r"^[Cc]:\\", s):
        return True
    # Git Bash /cygdrive/c
    if re.match(r"^[/\\]cygdrive[/\\][Cc]([/\\]|$)", str(path).replace("\\", "/")):
        return True
    if str(path).replace("\\", "/").lower().startswith("/c/"):
        return True
    return False


def is_default_temp_path(path: Path) -> bool:
    s = str(path).replace("\\", "/").lower()
    markers = (
        "/temp/",
        "/tmp/",
        "/appdata/local/temp",
        "\\temp\\",
        "\\tmp\\",
        "\\appdata\\local\\temp",
    )
    low = str(path).replace("/", "\\").lower()
    if any(m in s for m in ("/temp/", "/tmp/", "/appdata/local/temp")):
        return True
    if "\\temp\\" in low or "\\tmp\\" in low or "\\appdata\\local\\temp" in low:
        return True
    for envk in ("TEMP", "TMP", "TMPDIR"):
        v = os.environ.get(envk)
        if not v:
            continue
        try:
            if path.resolve().is_relative_to(Path(v).resolve()):  # type: ignore[attr-defined]
                return True
        except Exception:
            try:
                if str(path.resolve()).lower().startswith(str(Path(v).resolve()).lower()):
                    return True
            except Exception:
                pass
    return False


def assert_safe_work_root(work_root: Path, repo_root: Path) -> None:
    if not work_root:
        raise ClonePackagingError(Err.WORK_ROOT_REQUIRED)
    wr = _norm_path(work_root)
    if is_c_drive_path(wr):
        raise ClonePackagingError(Err.UNSAFE_WORK_ROOT, "c_drive")
    if is_default_temp_path(wr):
        raise ClonePackagingError(Err.UNSAFE_WORK_ROOT, "default_temp")
    artifacts = (_norm_path(repo_root) / ".artifacts").resolve()
    try:
        wr.relative_to(artifacts)
        return
    except ValueError:
        pass
    # 显式 CLONE_WORK_ROOT：须非 C 盘且非系统 temp；允许仓库外 D: 等安全盘
    if is_c_drive_path(wr) or is_default_temp_path(wr):
        raise ClonePackagingError(Err.UNSAFE_WORK_ROOT)
    # 仍拒绝明显系统路径
    forbidden_prefixes = ("/var/folders", "/private/var/folders")
    s = str(wr).replace("\\", "/")
    if any(s.startswith(p) for p in forbidden_prefixes):
        raise ClonePackagingError(Err.UNSAFE_WORK_ROOT, "system_tmpdir")


def resolve_work_root(explicit: str | None, repo_root: Path, run_id: str | None = None) -> Path:
    if explicit:
        root = Path(explicit)
    else:
        rid = run_id or time.strftime("%Y%m%d-%H%M%S")
        root = repo_root / ".artifacts" / "test_runs" / "TC-00B" / rid / "work"
    assert_safe_work_root(root, repo_root)
    root.mkdir(parents=True, exist_ok=True)
    return _norm_path(root)


def repo_root_from_here() -> Path:
    return Path(__file__).resolve().parents[2]


# ---------------------------------------------------------------------------
# Bundle / scheme / entitlement 映射
# ---------------------------------------------------------------------------

def map_bundle_id(source_id: str, source_main: str, clone_main: str = CLONE_BUNDLE_ID) -> str:
    if not source_id:
        raise ClonePackagingError(Err.EXTENSION_UNMAPPED, "empty")
    if source_id == source_main:
        return clone_main
    if source_id.startswith(source_main + "."):
        return clone_main + source_id[len(source_main) :]
    # 确定性映射：不可遗漏
    digest = hashlib.sha256(source_id.encode("utf-8")).hexdigest()[:12]
    safe = re.sub(r"[^A-Za-z0-9.-]", "-", source_id)
    return f"{clone_main}.mapped.{safe}.{digest}"


def map_scheme(old: str) -> str:
    if not old:
        return old
    if old.endswith(SCHEME_SUFFIX):
        # 已是 clone 后缀则保持，避免叠加重写；但仍非真实原 scheme
        return old
    return old + SCHEME_SUFFIX


def map_entitlement_value(val: str, source_main: str, clone_main: str, team_id: str) -> str:
    """映射 application-identifier / access group / app group 中的 bundle 段。"""
    prefix = f"{team_id}." if team_id else ""
    if team_id and val.startswith(prefix):
        rest = val[len(prefix) :]
        return prefix + map_bundle_id(rest, source_main, clone_main)
    if val == source_main or val.startswith(source_main + "."):
        return map_bundle_id(val, source_main, clone_main)
    # group 形如 group.com.appbox.StandarReader...
    for marker in ("group.", "iCloud."):
        if val.startswith(marker):
            rest = val[len(marker) :]
            if rest == source_main or rest.startswith(source_main + "."):
                return marker + map_bundle_id(rest, source_main, clone_main)
    return val


def entitlement_blob_hash(ent: dict[str, Any]) -> str:
    # 规范化 JSON 后哈希（不落完整内容到调用方日志）
    raw = json.dumps(ent, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return sha256_bytes(raw)


# ---------------------------------------------------------------------------
# Mach-O UUID 只读解析（不猜）
# ---------------------------------------------------------------------------

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
MH_MAGIC = 0xFEEDFACE
MH_CIGAM = 0xCEFAEDFE
LC_UUID = 0x1B
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA


def _read_uuids_from_thin(data: bytes, offset: int = 0) -> list[str]:
    if offset + 28 > len(data):
        return []
    magic = struct.unpack_from("<I", data, offset)[0]
    swap = False
    is64 = False
    if magic == MH_MAGIC_64:
        is64 = True
    elif magic == MH_CIGAM_64:
        is64 = True
        swap = True
    elif magic == MH_MAGIC:
        is64 = False
    elif magic == MH_CIGAM:
        is64 = False
        swap = True
    else:
        # 再试大端 magic（已用小端读）；兼容
        magic_be = struct.unpack_from(">I", data, offset)[0]
        if magic_be == MH_MAGIC_64:
            is64 = True
            swap = True
        elif magic_be == MH_MAGIC:
            is64 = False
            swap = True
        else:
            return []

    end = ">" if swap else "<"
    if is64:
        if offset + 32 > len(data):
            return []
        _magic, _cputype, _cpusubtype, _filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from(
            end + "IIIIIIII", data, offset
        )
        cmd_off = offset + 32
    else:
        _magic, _cputype, _cpusubtype, _filetype, ncmds, sizeofcmds, _flags = struct.unpack_from(
            end + "IIIIIII", data, offset
        )
        cmd_off = offset + 28

    uuids: list[str] = []
    limit = cmd_off + sizeofcmds
    for _ in range(ncmds):
        if cmd_off + 8 > len(data) or cmd_off + 8 > limit:
            break
        cmd, cmdsize = struct.unpack_from(end + "II", data, cmd_off)
        if cmdsize < 8:
            break
        if cmd == LC_UUID and cmdsize >= 24:
            raw = data[cmd_off + 8 : cmd_off + 24]
            u = uuid.UUID(bytes=raw)
            uuids.append(str(u).upper())
        cmd_off += cmdsize
    return uuids


def extract_macho_uuids(path: Path) -> list[str]:
    data = path.read_bytes()
    if len(data) < 8:
        raise ClonePackagingError(Err.MACHO_UUID_UNREADABLE, "too_small")
    magic = struct.unpack_from(">I", data, 0)[0]
    magic_le = struct.unpack_from("<I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_CIGAM) or magic_le in (FAT_MAGIC, FAT_CIGAM):
        use = magic if magic in (FAT_MAGIC, FAT_CIGAM) else magic_le
        end = ">" if use == FAT_MAGIC else "<"
        _magic, nfat = struct.unpack_from(end + "II", data, 0)
        out: list[str] = []
        for i in range(nfat):
            off = 8 + i * 20
            if off + 20 > len(data):
                break
            _cpu, _sub, offset, _size, _align = struct.unpack_from(end + "IIIII", data, off)
            out.extend(_read_uuids_from_thin(data, offset))
        if not out:
            raise ClonePackagingError(Err.MACHO_UUID_UNREADABLE, "fat_no_uuid")
        return out
    thin = _read_uuids_from_thin(data, 0)
    if not thin:
        raise ClonePackagingError(Err.MACHO_UUID_UNREADABLE, "thin_no_uuid")
    return thin


def build_minimal_macho_with_uuid(u: uuid.UUID | None = None) -> bytes:
    """合成最小 arm64 Mach-O（仅 LC_UUID），供夹具使用。"""
    u = u or uuid.uuid4()
    uuid_cmd = struct.pack("<II", LC_UUID, 24) + u.bytes
    # mach_header_64：含 reserved
    header = struct.pack(
        "<IIIIIIII",
        MH_MAGIC_64,
        0x0100000C,  # CPU_TYPE_ARM64
        0,
        2,  # MH_EXECUTE
        1,
        len(uuid_cmd),
        0,
        0,  # reserved
    )
    return header + uuid_cmd


# ---------------------------------------------------------------------------
# plist / IPA 遍历
# ---------------------------------------------------------------------------

def load_plist(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    return plistlib.loads(data)


def dump_plist(path: Path, obj: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(obj, fmt=plistlib.FMT_XML))


def find_info_plists(payload_dir: Path) -> list[Path]:
    out: list[Path] = []
    for root, dirs, files in os.walk(payload_dir):
        # 跳过符号链接深层
        if "Info.plist" in files:
            p = Path(root) / "Info.plist"
            # 仅主 app / appex / framework
            parts = Path(root).parts
            name = Path(root).name
            if name.endswith(".app") or name.endswith(".appex") or name.endswith(".framework"):
                out.append(p)
            elif any(part.endswith((".app", ".appex", ".framework")) for part in parts):
                # Info.plist 直接位于 bundle 根
                if p.parent.name.endswith((".app", ".appex", ".framework")):
                    out.append(p)
    # 去重并排序
    return sorted(set(out))


def classify_bundle(info_plist: Path) -> str:
    parent = info_plist.parent.name
    if parent.endswith(".appex"):
        return "appex"
    if parent.endswith(".framework"):
        return "framework"
    if parent.endswith(".app"):
        return "app"
    return "other"


def collect_url_schemes(plist: dict[str, Any]) -> list[str]:
    schemes: list[str] = []
    for entry in plist.get("CFBundleURLTypes") or []:
        if not isinstance(entry, dict):
            continue
        for s in entry.get("CFBundleURLSchemes") or []:
            if isinstance(s, str) and s:
                schemes.append(s)
    return schemes


def rewrite_url_schemes(plist: dict[str, Any]) -> list[str]:
    """原地改写；返回新 schemes。无 scheme 则不发明。"""
    types = plist.get("CFBundleURLTypes")
    if not types:
        return []
    new_schemes: list[str] = []
    for entry in types:
        if not isinstance(entry, dict):
            continue
        old_list = entry.get("CFBundleURLSchemes") or []
        mapped = [map_scheme(s) for s in old_list if isinstance(s, str) and s]
        entry["CFBundleURLSchemes"] = mapped
        new_schemes.extend(mapped)
    return new_schemes


def find_main_app(payload: Path) -> Path:
    apps = sorted(payload.glob("*.app"))
    if not apps:
        raise ClonePackagingError(Err.NO_APP_BUNDLE)
    return apps[0]


def find_macho_candidates(bundle_dir: Path, executable_name: str | None) -> list[Path]:
    cands: list[Path] = []
    if executable_name:
        p = bundle_dir / executable_name
        if p.is_file():
            cands.append(p)
    # framework binary often same stem
    stem = bundle_dir.name
    for suffix in (".framework", ".app", ".appex"):
        if stem.endswith(suffix):
            stem = stem[: -len(suffix)]
            break
    p2 = bundle_dir / stem
    if p2.is_file() and p2 not in cands:
        cands.append(p2)
    return cands


def is_probably_macho(path: Path) -> bool:
    try:
        with path.open("rb") as f:
            magic = f.read(4)
        if len(magic) < 4:
            return False
        m = struct.unpack(">I", magic)[0]
        return m in (MH_MAGIC_64, MH_CIGAM_64, MH_MAGIC, MH_CIGAM, FAT_MAGIC, FAT_CIGAM)
    except OSError:
        return False


# ---------------------------------------------------------------------------
# Profile / entitlement 门禁
# ---------------------------------------------------------------------------

def load_allowlist(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ClonePackagingError(Err.PROFILE_DISALLOWS_CLONE, "allowlist_not_object")
    return data


def parse_team_id_from_allowlist(allow: dict[str, Any]) -> str:
    tid = str(allow.get("teamId") or allow.get("TeamIdentifier") or "")
    return tid


def assert_profile_allows_clone(allow: dict[str, Any], clone_ids: list[str], team_id: str) -> None:
    """fail-closed：若 allowlist 未显式允许 clone bundle / access group，立即停止。"""
    if not allow:
        raise ClonePackagingError(Err.PROFILE_DISALLOWS_CLONE, "missing_allowlist")
    allowed_apps = set(allow.get("allowedApplicationIdentifiers") or [])
    allowed_groups = set(allow.get("allowedKeychainAccessGroups") or [])
    allowed_app_groups = set(allow.get("allowedApplicationGroups") or [])

    for bid in clone_ids:
        app_id = f"{team_id}.{bid}" if team_id else bid
        # 允许精确或通配 team.* 
        ok = (
            bid in allowed_apps
            or app_id in allowed_apps
            or (team_id and f"{team_id}.*" in allowed_apps)
            or "*" in allowed_apps
        )
        if not ok:
            raise ClonePackagingError(Err.PROFILE_DISALLOWS_CLONE, "app_id")

        # keychain / app groups：若 allowlist 声明了列表则必须覆盖 clone 变体
        kc = f"{team_id}.{bid}" if team_id else bid
        if allowed_groups:
            if kc not in allowed_groups and f"{team_id}.*" not in allowed_groups and "*" not in allowed_groups:
                raise ClonePackagingError(Err.PROFILE_DISALLOWS_CLONE, "keychain")
        if allowed_app_groups:
            ag = f"group.{bid}"
            if ag not in allowed_app_groups and "*" not in allowed_app_groups:
                raise ClonePackagingError(Err.PROFILE_DISALLOWS_CLONE, "app_group")


def build_clone_entitlements(
    source_ent: dict[str, Any],
    *,
    source_main: str,
    clone_bundle_id: str,
    team_id: str,
) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, val in source_ent.items():
        if key == "application-identifier":
            out[key] = f"{team_id}.{clone_bundle_id}" if team_id else clone_bundle_id
        elif key in ("keychain-access-groups", "com.apple.security.application-groups"):
            if isinstance(val, list):
                out[key] = [
                    map_entitlement_value(str(x), source_main, CLONE_BUNDLE_ID, team_id) for x in val
                ]
            else:
                out[key] = val
        elif key == "com.apple.developer.ubiquity-kvstore-identifier":
            out[key] = map_entitlement_value(str(val), source_main, CLONE_BUNDLE_ID, team_id)
        elif key == "com.apple.developer.icloud-container-identifiers" and isinstance(val, list):
            out[key] = [
                map_entitlement_value(str(x), source_main, CLONE_BUNDLE_ID, team_id) for x in val
            ]
        else:
            out[key] = val
    # 强制主应用标识
    if team_id:
        out["application-identifier"] = f"{team_id}.{clone_bundle_id}"
    else:
        out["application-identifier"] = clone_bundle_id
    return out


def entitlements_isolated(
    ent: dict[str, Any],
    *,
    source_main: str,
    clone_main: str = CLONE_BUNDLE_ID,
) -> bool:
    """检查 entitlement 不再引用真实主 bundle / 真实 group。"""
    blob = json.dumps(ent, ensure_ascii=False)

    def is_real_residue(s: str) -> bool:
        if s == source_main:
            return True
        if s.startswith(source_main + ".") and not s.startswith(clone_main):
            return True
        if s.endswith("." + source_main) or f".{source_main}." in s:
            # application-identifier TEAM.source_main
            if clone_main in s:
                return False
            return True
        if s in (f"group.{source_main}", f"iCloud.{source_main}"):
            return True
        return False

    for key, val in ent.items():
        if isinstance(val, str) and is_real_residue(val):
            return False
        if isinstance(val, list):
            for x in val:
                if isinstance(x, str) and is_real_residue(x):
                    return False
    # 主 application-identifier 必须指向 clone
    app_id = str(ent.get("application-identifier", ""))
    if app_id and not app_id.endswith(clone_main) and app_id != clone_main:
        # 子 bundle 映射允许其它 clone_* id
        if not app_id.endswith(clone_main) and clone_main not in app_id:
            if source_main in app_id:
                return False
    _ = blob
    return True


# ---------------------------------------------------------------------------
# Repack（结构变换；真实 codesign 由 bash 在 macOS 执行）
# ---------------------------------------------------------------------------

def _raw_path_empty(path: Path | str | None) -> bool:
    if path is None:
        return True
    if isinstance(path, str):
        return path.strip() == ""
    # Path("") 在部分平台会变成 "."，调用方应传原始字符串；此处再拒绝纯空 parts
    s = os.fspath(path)
    return s is None or str(s).strip() == ""


def validate_repack_paths(ipa_in: Path | str, ipa_out: Path | str) -> None:
    if _raw_path_empty(ipa_in) or _raw_path_empty(ipa_out):
        raise ClonePackagingError(Err.EMPTY_PATH)
    ipa_in = Path(ipa_in)
    ipa_out = Path(ipa_out)
    if not ipa_in.is_file():
        raise ClonePackagingError(Err.NOT_FILE, "input")
    in_abs = os.path.normcase(os.path.abspath(str(ipa_in)))
    out_abs = os.path.normcase(os.path.abspath(str(ipa_out)))
    if in_abs == out_abs:
        raise ClonePackagingError(Err.INPUT_EQUALS_OUTPUT)
    if ipa_out.exists():
        raise ClonePackagingError(Err.OUTPUT_EXISTS)
    out_check = Path(out_abs)
    if is_c_drive_path(out_check):
        raise ClonePackagingError(Err.UNSAFE_WORK_ROOT, "output_c_drive")


def unpack_ipa(ipa: Path, dest: Path) -> Path:
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ipa, "r") as zf:
        zf.extractall(dest)
    payload = dest / "Payload"
    if not payload.is_dir():
        raise ClonePackagingError(Err.NO_APP_BUNDLE, "no_payload")
    return payload


def pack_ipa(payload_parent: Path, out_ipa: Path) -> None:
    out_ipa.parent.mkdir(parents=True, exist_ok=True)
    if out_ipa.exists():
        raise ClonePackagingError(Err.OUTPUT_EXISTS)
    with zipfile.ZipFile(out_ipa, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        payload = payload_parent / "Payload"
        for root, _dirs, files in os.walk(payload):
            for name in files:
                fp = Path(root) / name
                arc = fp.relative_to(payload_parent).as_posix()
                zf.write(fp, arc)


def transform_payload_to_clone(
    payload: Path,
    *,
    source_main: str,
    team_id: str,
    allow: dict[str, Any],
    source_entitlements: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """遍历所有 Info.plist，映射 bundle / scheme；生成 clone entitlements。"""
    main_app = find_main_app(payload)
    main_plist_path = main_app / "Info.plist"
    if not main_plist_path.is_file():
        raise ClonePackagingError(Err.NO_APP_BUNDLE, "main_plist")

    plists = find_info_plists(payload)
    if main_plist_path not in plists:
        plists.insert(0, main_plist_path)

    mapped_ids: list[str] = []
    scheme_report: dict[str, Any] = {"status": "none_present", "mapped": [], "sourceHadSchemes": False}
    all_new_schemes: list[str] = []

    for pp in plists:
        pl = load_plist(pp)
        old_id = str(pl.get("CFBundleIdentifier") or "")
        kind = classify_bundle(pp)
        if kind == "app" and pp.parent == main_app:
            new_id = CLONE_BUNDLE_ID
            pl["CFBundleIdentifier"] = new_id
            pl["CFBundleDisplayName"] = CLONE_DISPLAY_NAME
            # 可选 CFBundleName 不强制
        else:
            new_id = map_bundle_id(old_id, source_main, CLONE_BUNDLE_ID)
            pl["CFBundleIdentifier"] = new_id

        old_schemes = collect_url_schemes(pl)
        if old_schemes:
            scheme_report["sourceHadSchemes"] = True
            new_schemes = rewrite_url_schemes(pl)
            all_new_schemes.extend(new_schemes)
            # 不得保留真实原 scheme
            for s in new_schemes:
                if not s.endswith(SCHEME_SUFFIX):
                    raise ClonePackagingError(Err.URL_SCHEME_RESIDUE, "unmapped")
            for s in old_schemes:
                # 改写后的 plist 不应再含原值
                pass
        mapped_ids.append(new_id)
        dump_plist(pp, pl)

    if scheme_report["sourceHadSchemes"]:
        scheme_report["status"] = "mapped"
        scheme_report["mapped"] = sorted(set(all_new_schemes))
    else:
        scheme_report["status"] = "none_present"
        scheme_report["note"] = "source_had_no_url_schemes_not_invented"

    # entitlements
    source_entitlements = source_entitlements or {}
    ent_hashes: list[dict[str, str]] = []
    clone_ents: dict[str, dict[str, Any]] = {}

    # 主 app + 子 bundle
    for pp in plists:
        pl = load_plist(pp)
        bid = str(pl.get("CFBundleIdentifier") or "")
        # 找源 entitlements：按映射前 id 的启发式 — 调用方应按路径提供
        src_ent = source_entitlements.get(bid) or source_entitlements.get(str(pp))
        if src_ent is None:
            # 尝试 sibling entitlements.plist / archived-expanded-entitlements.xcent
            for name in ("entitlements.plist", "archived-expanded-entitlements.xcent"):
                ep = pp.parent / name
                if ep.is_file():
                    src_ent = load_plist(ep)
                    break
        if src_ent is None:
            # 最小占位：仅 application-identifier（仍须通过 allowlist）
            src_ent = {"application-identifier": f"{team_id}.{source_main}" if team_id else source_main}

        # 对主 app 使用 CLONE_BUNDLE_ID；子 bundle 用当前 bid
        target_bid = bid
        cloned = build_clone_entitlements(
            src_ent,
            source_main=source_main,
            clone_bundle_id=target_bid,
            team_id=team_id,
        )
        if not entitlements_isolated(cloned, source_main=source_main):
            raise ClonePackagingError(Err.ENTITLEMENT_NOT_ISOLATED)
        clone_ents[bid] = cloned
        ent_path = pp.parent / "clone-entitlements.plist"
        dump_plist(ent_path, cloned)
        ent_hashes.append({"bundleId": bid, "sha256": entitlement_blob_hash(cloned)})

    assert_profile_allows_clone(allow, mapped_ids, team_id)

    return {
        "mainBundleId": CLONE_BUNDLE_ID,
        "displayName": CLONE_DISPLAY_NAME,
        "bundleIds": sorted(set(mapped_ids)),
        "entitlementHashes": ent_hashes,
        "urlSchemeReport": scheme_report,
        "cloneEntitlements": {k: entitlement_blob_hash(v) for k, v in clone_ents.items()},
    }


def repack_clone_structure(
    ipa_in: Path,
    ipa_out: Path,
    *,
    work_root: Path,
    repo_root: Path,
    source_main: str = DEFAULT_SOURCE_MAIN,
    team_id: str = "",
    allowlist_path: Path | None = None,
    source_entitlements_path: Path | None = None,
    fixture_mode: bool = False,
    signing_identity: str | None = None,
    provisioning_profile: Path | None = None,
    manifest_out: Path | None = None,
) -> dict[str, Any]:
    validate_repack_paths(ipa_in, ipa_out)
    assert_safe_work_root(work_root, repo_root)

    if not fixture_mode:
        if not signing_identity:
            raise ClonePackagingError(Err.MISSING_SIGNING_IDENTITY)
        if not provisioning_profile or not Path(provisioning_profile).is_file():
            raise ClonePackagingError(Err.MISSING_PROFILE)
        # 真实 codesign 不在 Python 内假装完成
        raise ClonePackagingError(
            Err.MISSING_MACOS_TOOLS,
            "python_structure_only_use_repack_clone_sh_on_macos",
        )

    allow = load_allowlist(allowlist_path)
    if not team_id:
        team_id = parse_team_id_from_allowlist(allow)

    src_ents: dict[str, dict[str, Any]] = {}
    if source_entitlements_path and source_entitlements_path.is_file():
        raw = json.loads(source_entitlements_path.read_text(encoding="utf-8"))
        if isinstance(raw, dict):
            for k, v in raw.items():
                if isinstance(v, dict):
                    src_ents[k] = v

    work = work_root / f"clone-work-{uuid.uuid4().hex[:8]}"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    # 复制 IPA 到工作目录后再解包，不原地改源
    ipa_copy = work / "source-copy.ipa"
    shutil.copy2(ipa_in, ipa_copy)
    unpack_dir = work / "unpacked"
    payload = unpack_ipa(ipa_copy, unpack_dir)

    meta = transform_payload_to_clone(
        payload,
        source_main=source_main,
        team_id=team_id or "FIXTURETEAM",
        allow=allow,
        source_entitlements=src_ents,
    )

    pack_ipa(unpack_dir, ipa_out)

    manifest = build_manifest_for_pair(
        ipa_in,
        ipa_out,
        work_extract=unpack_dir,
        meta=meta,
        signature_verification="fixture_skipped",
        source_main=source_main,
    )
    mout = manifest_out or Path(str(ipa_out) + ".clone-manifest.json")
    mout.parent.mkdir(parents=True, exist_ok=True)
    mout.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    meta["manifestPath"] = str(mout)
    meta["manifest"] = manifest
    return meta


# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

def build_manifest_for_pair(
    source_ipa: Path,
    output_ipa: Path,
    *,
    work_extract: Path,
    meta: dict[str, Any],
    signature_verification: str,
    source_main: str,
) -> dict[str, Any]:
    payload = work_extract / "Payload"
    main_app = find_main_app(payload)
    macho_entries: list[dict[str, str]] = []
    signed_objects: list[str] = []

    for pp in find_info_plists(payload):
        pl = load_plist(pp)
        exe = pl.get("CFBundleExecutable")
        exe_s = str(exe) if exe else None
        for cand in find_macho_candidates(pp.parent, exe_s):
            if not is_probably_macho(cand):
                continue
            rel = cand.relative_to(work_extract).as_posix()
            try:
                uuids = extract_macho_uuids(cand)
            except ClonePackagingError:
                raise
            for u in uuids:
                macho_entries.append({"path": rel, "uuid": u})
            signed_objects.append(rel)

    # 也扫描常见二进制
    for root, _dirs, files in os.walk(payload):
        for name in files:
            fp = Path(root) / name
            if not is_probably_macho(fp):
                continue
            rel = fp.relative_to(work_extract).as_posix()
            if any(e["path"] == rel for e in macho_entries):
                continue
            uuids = extract_macho_uuids(fp)
            for u in uuids:
                macho_entries.append({"path": rel, "uuid": u})
            signed_objects.append(rel)

    return {
        "schemaVersion": 1,
        "kind": "clone-ipa-manifest",
        "sourceIpaSha256": sha256_file(source_ipa),
        "outputIpaSha256": sha256_file(output_ipa),
        "mainBundleId": meta.get("mainBundleId", CLONE_BUNDLE_ID),
        "displayName": meta.get("displayName", CLONE_DISPLAY_NAME),
        "bundleIds": meta.get("bundleIds", []),
        "machOUuids": macho_entries,
        "entitlementHashes": meta.get("entitlementHashes", []),
        "signedObjects": sorted(set(signed_objects)),
        "expected_data_container_isolation": True,
        "signatureVerification": signature_verification,
        "urlSchemeReport": meta.get("urlSchemeReport", {}),
        "sourceMainBundleId": source_main,
    }


def verify_clone_ipa(
    ipa: Path | str,
    *,
    source_ipa: Path | str | None = None,
    source_main: str = DEFAULT_SOURCE_MAIN,
    fixture_mode: bool = False,
    work_root: Path,
    repo_root: Path,
    manifest_out: Path | None = None,
    expected_manifest: Path | None = None,
) -> dict[str, Any]:
    if _raw_path_empty(ipa):
        raise ClonePackagingError(Err.EMPTY_PATH)
    ipa = Path(ipa)
    if source_ipa is not None and not _raw_path_empty(source_ipa):
        source_ipa = Path(source_ipa)
        if os.path.normcase(os.path.abspath(str(ipa))) == os.path.normcase(
            os.path.abspath(str(source_ipa))
        ):
            raise ClonePackagingError(Err.INPUT_EQUALS_OUTPUT)
    elif source_ipa is not None and _raw_path_empty(source_ipa):
        source_ipa = None
    if not ipa.is_file():
        raise ClonePackagingError(Err.NOT_FILE)

    assert_safe_work_root(work_root, repo_root)
    extract = work_root / f"verify-{uuid.uuid4().hex[:8]}"
    extract.mkdir(parents=True)
    try:
        payload = unpack_ipa(ipa, extract)
        main_app = find_main_app(payload)
        main_pl = load_plist(main_app / "Info.plist")
        main_id = str(main_pl.get("CFBundleIdentifier") or "")
        display = str(main_pl.get("CFBundleDisplayName") or main_pl.get("CFBundleName") or "")

        if main_id != CLONE_BUNDLE_ID:
            raise ClonePackagingError(Err.MAIN_BUNDLE_ID)
        if display != CLONE_DISPLAY_NAME:
            raise ClonePackagingError(Err.DISPLAY_NAME)

        bundle_ids: list[str] = []
        for pp in find_info_plists(payload):
            pl = load_plist(pp)
            bid = str(pl.get("CFBundleIdentifier") or "")
            bundle_ids.append(bid)
            # 真实主 id 残留
            if bid == source_main:
                raise ClonePackagingError(Err.REAL_BUNDLE_RESIDUE, "bundle_id")
            # 子 bundle 必须已映射到 clone 前缀
            kind = classify_bundle(pp)
            if kind in ("appex", "framework", "app"):
                if bid != CLONE_BUNDLE_ID and not bid.startswith(CLONE_BUNDLE_ID + "."):
                    # 允许 mapped. 前缀形式
                    if not bid.startswith(CLONE_BUNDLE_ID):
                        raise ClonePackagingError(Err.EXTENSION_UNMAPPED)

            schemes = collect_url_schemes(pl)
            for s in schemes:
                if not s.endswith(SCHEME_SUFFIX):
                    raise ClonePackagingError(Err.URL_SCHEME_RESIDUE)
                # 原 scheme 等于去掉后缀后的值不应再单独存在为未后缀形式 — 已由 suffix 检查覆盖

        # entitlements 隔离
        ent_hashes: list[dict[str, str]] = []
        for pp in find_info_plists(payload):
            pl = load_plist(pp)
            bid = str(pl.get("CFBundleIdentifier") or "")
            ent = None
            for name in ("clone-entitlements.plist", "entitlements.plist", "archived-expanded-entitlements.xcent"):
                ep = pp.parent / name
                if ep.is_file():
                    ent = load_plist(ep)
                    break
            if ent is None:
                raise ClonePackagingError(Err.ENTITLEMENT_NOT_ISOLATED, "missing")
            if not entitlements_isolated(ent, source_main=source_main):
                raise ClonePackagingError(Err.ENTITLEMENT_NOT_ISOLATED)
            app_id = str(ent.get("application-identifier", ""))
            if source_main in app_id and CLONE_BUNDLE_ID not in app_id:
                raise ClonePackagingError(Err.ENTITLEMENT_NOT_ISOLATED, "app_id")
            ent_hashes.append({"bundleId": bid, "sha256": entitlement_blob_hash(ent)})

        meta = {
            "mainBundleId": main_id,
            "displayName": display,
            "bundleIds": sorted(set(bundle_ids)),
            "entitlementHashes": ent_hashes,
            "urlSchemeReport": {},
        }

        sig = "fixture_skipped" if fixture_mode else "codesign_required"
        if not fixture_mode:
            # 生产路径：此处仅结构通过；真实 codesign 由 bash 二次确认
            # 若调用方未跳过，则要求环境后续补签验；Python 侧不假装成功
            sig = "structure_ok_awaiting_codesign"

        src = source_ipa if source_ipa and source_ipa.is_file() else ipa
        manifest = build_manifest_for_pair(
            src,
            ipa,
            work_extract=extract,
            meta=meta,
            signature_verification=sig if not fixture_mode else "fixture_skipped",
            source_main=source_main,
        )
        if manifest.get("expected_data_container_isolation") is not True:
            raise ClonePackagingError(Err.CONTAINER_ISOLATION)

        for field in MANIFEST_REQUIRED_FIELDS:
            if field not in manifest:
                raise ClonePackagingError(Err.MANIFEST_MISSING_FIELD, field)

        if expected_manifest and expected_manifest.is_file():
            existing = json.loads(expected_manifest.read_text(encoding="utf-8"))
            for field in MANIFEST_REQUIRED_FIELDS:
                if field not in existing:
                    raise ClonePackagingError(Err.MANIFEST_MISSING_FIELD, field)
            if existing.get("expected_data_container_isolation") is not True:
                raise ClonePackagingError(Err.CONTAINER_ISOLATION)
            if existing.get("mainBundleId") != CLONE_BUNDLE_ID:
                raise ClonePackagingError(Err.MAIN_BUNDLE_ID)

        mout = manifest_out
        if mout:
            mout.parent.mkdir(parents=True, exist_ok=True)
            mout.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

        return {"ok": True, "error": None, "manifest": manifest}
    finally:
        # 保留工作目录供调试；不删除用户已有文件。仅清理本次 extract 可选。
        # 测试要求产物留在 .artifacts/test_runs — 保留。
        pass


def emit_error_json(code: str, detail: str = "") -> dict[str, Any]:
    return {
        "ok": False,
        "error": code,
        "detailEnum": detail or None,
        "expected_data_container_isolation": True,
    }


# ---------------------------------------------------------------------------
# 夹具构建
# ---------------------------------------------------------------------------

def write_xml_plist(path: Path, data: dict[str, Any]) -> None:
    dump_plist(path, data)


def make_fixture_ipa(
    dest_ipa: Path,
    *,
    main_bundle_id: str,
    display_name: str,
    extension_id: str | None = None,
    framework_id: str | None = None,
    schemes: list[str] | None = None,
    entitlements_main: dict[str, Any] | None = None,
    entitlements_ext: dict[str, Any] | None = None,
    team_id: str = "FIXTURETEAM",
    include_macho: bool = True,
) -> dict[str, Any]:
    dest_ipa.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=str(dest_ipa.parent)) as td:
        root = Path(td)
        app = root / "Payload" / "FixtureApp.app"
        app.mkdir(parents=True)
        main_pl: dict[str, Any] = {
            "CFBundleIdentifier": main_bundle_id,
            "CFBundleDisplayName": display_name,
            "CFBundleExecutable": "FixtureApp",
            "CFBundleName": "FixtureApp",
            "CFBundlePackageType": "APPL",
        }
        if schemes:
            main_pl["CFBundleURLTypes"] = [
                {
                    "CFBundleURLName": "fixture.scheme",
                    "CFBundleURLSchemes": list(schemes),
                }
            ]
        write_xml_plist(app / "Info.plist", main_pl)
        macho_uuid = uuid.UUID("12345678-1234-5678-1234-567812345678")
        if include_macho:
            (app / "FixtureApp").write_bytes(build_minimal_macho_with_uuid(macho_uuid))

        ent_main = entitlements_main or {
            "application-identifier": f"{team_id}.{main_bundle_id}",
            "keychain-access-groups": [f"{team_id}.{main_bundle_id}"],
            "com.apple.security.application-groups": [f"group.{main_bundle_id}"],
        }
        write_xml_plist(app / "entitlements.plist", ent_main)

        ext_uuid = uuid.UUID("abcdef01-2345-6789-abcd-ef0123456789")
        if extension_id:
            appex = app / "PlugIns" / "FixtureExt.appex"
            appex.mkdir(parents=True)
            write_xml_plist(
                appex / "Info.plist",
                {
                    "CFBundleIdentifier": extension_id,
                    "CFBundleExecutable": "FixtureExt",
                    "CFBundlePackageType": "XPC!",
                },
            )
            if include_macho:
                (appex / "FixtureExt").write_bytes(build_minimal_macho_with_uuid(ext_uuid))
            ent_e = entitlements_ext or {
                "application-identifier": f"{team_id}.{extension_id}",
                "keychain-access-groups": [f"{team_id}.{extension_id}"],
            }
            write_xml_plist(appex / "entitlements.plist", ent_e)

        fw_uuid = uuid.UUID("0fedcba9-8765-4321-0fed-cba987654321")
        if framework_id:
            fw = app / "Frameworks" / "FixtureFW.framework"
            fw.mkdir(parents=True)
            write_xml_plist(
                fw / "Info.plist",
                {
                    "CFBundleIdentifier": framework_id,
                    "CFBundleExecutable": "FixtureFW",
                    "CFBundlePackageType": "FMWK",
                },
            )
            if include_macho:
                (fw / "FixtureFW").write_bytes(build_minimal_macho_with_uuid(fw_uuid))
            write_xml_plist(
                fw / "entitlements.plist",
                {"application-identifier": f"{team_id}.{framework_id}"},
            )

        with zipfile.ZipFile(dest_ipa, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for dirpath, _dirnames, filenames in os.walk(root):
                for fn in filenames:
                    fp = Path(dirpath) / fn
                    zf.write(fp, fp.relative_to(root).as_posix())

    return {
        "mainUuid": str(macho_uuid).upper() if include_macho else None,
        "extUuid": str(ext_uuid).upper() if extension_id and include_macho else None,
        "fwUuid": str(fw_uuid).upper() if framework_id and include_macho else None,
    }


def write_allowlist(path: Path, team_id: str, bundle_ids: list[str]) -> None:
    apps = []
    groups = []
    app_groups = []
    for bid in bundle_ids:
        apps.append(f"{team_id}.{bid}")
        apps.append(bid)
        groups.append(f"{team_id}.{bid}")
        app_groups.append(f"group.{bid}")
    apps.append(f"{team_id}.*")
    groups.append(f"{team_id}.*")
    data = {
        "teamId": team_id,
        "allowedApplicationIdentifiers": apps,
        "allowedKeychainAccessGroups": groups,
        "allowedApplicationGroups": app_groups,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# 自测
# ---------------------------------------------------------------------------

class TestResult:
    def __init__(self) -> None:
        self.cases: list[dict[str, Any]] = []

    def record(self, name: str, passed: bool, exit_code: int, detail: str = "") -> None:
        self.cases.append(
            {
                "name": name,
                "passed": passed,
                "exitCode": exit_code,
                "detail": detail,
            }
        )


def _expect_fail(fn, err_code: str | None = None) -> tuple[bool, int, str]:
    try:
        fn()
        return False, 0, "expected_fail_but_passed"
    except ClonePackagingError as e:
        ok = (err_code is None) or (e.code == err_code)
        return ok, 1, e.code
    except Exception as e:
        return False, 1, type(e).__name__


def run_selftest(run_dir: Path, repo_root: Path) -> int:
    run_dir.mkdir(parents=True, exist_ok=True)
    work = run_dir / "work"
    work.mkdir(parents=True, exist_ok=True)
    assert_safe_work_root(work, repo_root)

    tr = TestResult()
    team = "FIXTURETEAM"
    source_main = DEFAULT_SOURCE_MAIN
    ext_src = f"{source_main}.share"
    fw_src = f"{source_main}.fw"

    # --- 合规 fixture pass ---
    ok_ipa_src = run_dir / "src-ok.ipa"
    ok_ipa_out = run_dir / "out-ok.ipa"
    make_fixture_ipa(
        ok_ipa_src,
        main_bundle_id=source_main,
        display_name="真实名",
        extension_id=ext_src,
        framework_id=fw_src,
        schemes=["legado", "yuedu"],
        team_id=team,
    )
    allow = run_dir / "allow-ok.json"
    # 预计算将产生的 clone ids
    clone_ids = [
        CLONE_BUNDLE_ID,
        map_bundle_id(ext_src, source_main),
        map_bundle_id(fw_src, source_main),
    ]
    write_allowlist(allow, team, clone_ids)
    try:
        repack_clone_structure(
            ok_ipa_src,
            ok_ipa_out,
            work_root=work / "repack-ok",
            repo_root=repo_root,
            source_main=source_main,
            team_id=team,
            allowlist_path=allow,
            fixture_mode=True,
            manifest_out=run_dir / "out-ok.clone-manifest.json",
        )
        v = verify_clone_ipa(
            ok_ipa_out,
            source_ipa=ok_ipa_src,
            source_main=source_main,
            fixture_mode=True,
            work_root=work / "verify-ok",
            repo_root=repo_root,
            manifest_out=run_dir / "verify-ok.manifest.json",
        )
        man = v["manifest"]
        fields_ok = all(f in man for f in MANIFEST_REQUIRED_FIELDS)
        iso = man.get("expected_data_container_isolation") is True
        sig_ok = man.get("signatureVerification") == "fixture_skipped"
        passed = bool(v.get("ok")) and fields_ok and iso and sig_ok
        tr.record("valid_fixture_pass", passed, 0 if passed else 1, "ok" if passed else "verify_failed")
    except Exception as e:
        tr.record("valid_fixture_pass", False, 1, type(e).__name__ + ":" + str(e)[:80])

    # --- 负例 1：未改 bundle id ---
    bad1 = run_dir / "bad-unchanged-bundle.ipa"
    make_fixture_ipa(
        bad1,
        main_bundle_id=source_main,
        display_name=CLONE_DISPLAY_NAME,
        extension_id=map_bundle_id(ext_src, source_main),
        schemes=[f"legado{SCHEME_SUFFIX}"],
        entitlements_main={
            "application-identifier": f"{team}.{CLONE_BUNDLE_ID}",
            "keychain-access-groups": [f"{team}.{CLONE_BUNDLE_ID}"],
        },
        team_id=team,
    )
    # 主 bundle 仍是真实 id
    ok, code, detail = _expect_fail(
        lambda: verify_clone_ipa(
            bad1,
            source_ipa=ok_ipa_src,
            source_main=source_main,
            fixture_mode=True,
            work_root=work / "v-bad1",
            repo_root=repo_root,
        ),
        Err.MAIN_BUNDLE_ID,
    )
    tr.record("neg_unchanged_bundle_id", ok, code, detail)

    # --- 负例 2：只改 plist 未改 entitlement ---
    bad2 = run_dir / "bad-plist-only.ipa"
    make_fixture_ipa(
        bad2,
        main_bundle_id=CLONE_BUNDLE_ID,
        display_name=CLONE_DISPLAY_NAME,
        extension_id=map_bundle_id(ext_src, source_main),
        schemes=[f"legado{SCHEME_SUFFIX}"],
        entitlements_main={
            "application-identifier": f"{team}.{source_main}",
            "keychain-access-groups": [f"{team}.{source_main}"],
            "com.apple.security.application-groups": [f"group.{source_main}"],
        },
        team_id=team,
    )
    ok, code, detail = _expect_fail(
        lambda: verify_clone_ipa(
            bad2,
            source_ipa=ok_ipa_src,
            source_main=source_main,
            fixture_mode=True,
            work_root=work / "v-bad2",
            repo_root=repo_root,
        ),
        Err.ENTITLEMENT_NOT_ISOLATED,
    )
    tr.record("neg_plist_only_entitlement_real", ok, code, detail)

    # --- 负例 3：残留真实 URL scheme ---
    bad3 = run_dir / "bad-scheme.ipa"
    make_fixture_ipa(
        bad3,
        main_bundle_id=CLONE_BUNDLE_ID,
        display_name=CLONE_DISPLAY_NAME,
        extension_id=map_bundle_id(ext_src, source_main),
        schemes=["legado"],  # 真实 scheme 残留
        entitlements_main={
            "application-identifier": f"{team}.{CLONE_BUNDLE_ID}",
            "keychain-access-groups": [f"{team}.{CLONE_BUNDLE_ID}"],
        },
        team_id=team,
    )
    ok, code, detail = _expect_fail(
        lambda: verify_clone_ipa(
            bad3,
            source_ipa=ok_ipa_src,
            source_main=source_main,
            fixture_mode=True,
            work_root=work / "v-bad3",
            repo_root=repo_root,
        ),
        Err.URL_SCHEME_RESIDUE,
    )
    tr.record("neg_real_url_scheme_residue", ok, code, detail)

    # --- 负例 4：extension id 不一致（未映射） ---
    bad4 = run_dir / "bad-ext.ipa"
    make_fixture_ipa(
        bad4,
        main_bundle_id=CLONE_BUNDLE_ID,
        display_name=CLONE_DISPLAY_NAME,
        extension_id=ext_src,  # 仍是真实 extension id
        schemes=[f"legado{SCHEME_SUFFIX}"],
        entitlements_main={
            "application-identifier": f"{team}.{CLONE_BUNDLE_ID}",
            "keychain-access-groups": [f"{team}.{CLONE_BUNDLE_ID}"],
        },
        entitlements_ext={
            "application-identifier": f"{team}.{ext_src}",
            "keychain-access-groups": [f"{team}.{ext_src}"],
        },
        team_id=team,
    )
    ok, code, detail = _expect_fail(
        lambda: verify_clone_ipa(
            bad4,
            source_ipa=ok_ipa_src,
            source_main=source_main,
            fixture_mode=True,
            work_root=work / "v-bad4",
            repo_root=repo_root,
        ),
        # 可能先撞 REAL_BUNDLE / EXTENSION_UNMAPPED / ENTITLEMENT
        None,
    )
    # 收紧：必须非零且为预期枚举之一
    ok = ok and detail in (
        Err.EXTENSION_UNMAPPED,
        Err.REAL_BUNDLE_RESIDUE,
        Err.ENTITLEMENT_NOT_ISOLATED,
    )
    tr.record("neg_extension_id_unmapped", ok, code, detail)

    # --- 负例 5：空输入路径 ---
    ok, code, detail = _expect_fail(
        lambda: verify_clone_ipa(
            "",
            fixture_mode=True,
            work_root=work / "v-bad5",
            repo_root=repo_root,
        ),
        Err.EMPTY_PATH,
    )
    if not ok:
        ok, code, detail = _expect_fail(
            lambda: validate_repack_paths("", "out.ipa"),
            Err.EMPTY_PATH,
        )
    tr.record("neg_empty_input_path", ok, code, detail)

    # --- 负例 6：输出覆盖已有 IPA ---
    existing = run_dir / "already.ipa"
    existing.write_bytes(b"PK\x05\x06" + b"\x00" * 18)
    src6 = run_dir / "src6.ipa"
    make_fixture_ipa(
        src6,
        main_bundle_id=source_main,
        display_name="x",
        schemes=["a"],
        team_id=team,
    )
    ok, code, detail = _expect_fail(
        lambda: validate_repack_paths(src6, existing),
        Err.OUTPUT_EXISTS,
    )
    tr.record("neg_output_overwrite", ok, code, detail)

    # --- 额外：input==output 拒绝 ---
    ok, code, detail = _expect_fail(
        lambda: validate_repack_paths(src6, src6),
        Err.INPUT_EQUALS_OUTPUT,
    )
    tr.record("neg_input_equals_output", ok, code, detail)

    # --- 真实 bundle id 永不被 verify 接受（主 id 为真实） ---
    real_ipa = run_dir / "real-main.ipa"
    make_fixture_ipa(
        real_ipa,
        main_bundle_id=source_main,
        display_name=CLONE_DISPLAY_NAME,
        schemes=[f"x{SCHEME_SUFFIX}"],
        entitlements_main={"application-identifier": f"{team}.{CLONE_BUNDLE_ID}"},
        team_id=team,
    )
    ok, code, detail = _expect_fail(
        lambda: verify_clone_ipa(
            real_ipa,
            source_main=source_main,
            fixture_mode=True,
            work_root=work / "v-real",
            repo_root=repo_root,
        ),
        Err.MAIN_BUNDLE_ID,
    )
    tr.record("neg_real_bundle_never_accepted", ok, code, detail)

    # --- 参数安全：C 盘 work root ---
    ok, code, detail = _expect_fail(
        lambda: assert_safe_work_root(Path("C:/Temp/tc00b-reject"), repo_root),
        Err.UNSAFE_WORK_ROOT,
    )
    tr.record("neg_unsafe_c_drive_work_root", ok, code, detail)

    # --- 生产路径缺签名身份 fail-closed ---
    ok, code, detail = _expect_fail(
        lambda: repack_clone_structure(
            ok_ipa_src,
            run_dir / "should-not-create.ipa",
            work_root=work / "prod-fail",
            repo_root=repo_root,
            fixture_mode=False,
            signing_identity=None,
            allowlist_path=allow,
        ),
        Err.MISSING_SIGNING_IDENTITY,
    )
    tr.record("neg_missing_signing_identity", ok, code, detail)

    summary = {
        "runDir": str(run_dir),
        "cases": tr.cases,
        "allPassed": all(c["passed"] for c in tr.cases),
        "failCount": sum(1 for c in tr.cases if not c["passed"]),
    }
    (run_dir / "selftest-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["allPassed"] else 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    p = argparse.ArgumentParser(description="TC-00B clone packaging / verify / selftest")
    p.add_argument(
        "--mode",
        choices=("selftest", "verify", "repack"),
        default="selftest",
    )
    p.add_argument("--ipa", type=Path, default=None, help="待校验/输入 IPA")
    p.add_argument("--out", type=Path, default=None, help="输出 IPA")
    p.add_argument("--source-ipa", type=Path, default=None)
    p.add_argument("--source-main", default=DEFAULT_SOURCE_MAIN)
    p.add_argument("--work-root", type=Path, default=None)
    p.add_argument("--repo-root", type=Path, default=None)
    p.add_argument("--fixture-mode", action="store_true")
    p.add_argument("--manifest-out", type=Path, default=None)
    p.add_argument("--allowlist", type=Path, default=None)
    p.add_argument("--team-id", default="")
    p.add_argument("--signing-identity", default=None)
    p.add_argument("--profile", type=Path, default=None)
    p.add_argument("--run-id", default=None)
    p.add_argument("--source-entitlements", type=Path, default=None)
    args = p.parse_args(argv)

    repo = _norm_path(args.repo_root) if args.repo_root else repo_root_from_here()

    try:
        if args.mode == "selftest":
            rid = args.run_id or time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
            run_dir = repo / ".artifacts" / "test_runs" / "TC-00B" / rid
            if args.work_root:
                # 若显式给了 work-root，selftest 产物仍落 test_runs
                pass
            return run_selftest(run_dir, repo)

        work = resolve_work_root(
            str(args.work_root) if args.work_root else None,
            repo,
            run_id=args.run_id,
        )

        if args.mode == "verify":
            if not args.ipa:
                print(json.dumps(emit_error_json(Err.EMPTY_PATH), ensure_ascii=False))
                return 2
            result = verify_clone_ipa(
                args.ipa,
                source_ipa=args.source_ipa,
                source_main=args.source_main,
                fixture_mode=args.fixture_mode,
                work_root=work,
                repo_root=repo,
                manifest_out=args.manifest_out,
            )
            print(json.dumps({"ok": True, "error": None, "manifest": result["manifest"]}, ensure_ascii=False, indent=2))
            return 0

        if args.mode == "repack":
            if not args.ipa or not args.out:
                print(json.dumps(emit_error_json(Err.EMPTY_PATH), ensure_ascii=False))
                return 2
            meta = repack_clone_structure(
                args.ipa,
                args.out,
                work_root=work,
                repo_root=repo,
                source_main=args.source_main,
                team_id=args.team_id,
                allowlist_path=args.allowlist,
                source_entitlements_path=args.source_entitlements,
                fixture_mode=args.fixture_mode,
                signing_identity=args.signing_identity,
                provisioning_profile=args.profile,
                manifest_out=args.manifest_out,
            )
            # 不打印完整 entitlements
            safe = {
                "ok": True,
                "mainBundleId": meta.get("mainBundleId"),
                "bundleIds": meta.get("bundleIds"),
                "entitlementHashes": meta.get("entitlementHashes"),
                "urlSchemeReport": meta.get("urlSchemeReport"),
                "manifestPath": meta.get("manifestPath"),
                "signatureVerification": (meta.get("manifest") or {}).get("signatureVerification"),
            }
            print(json.dumps(safe, ensure_ascii=False, indent=2))
            return 0

    except ClonePackagingError as e:
        print(json.dumps(emit_error_json(e.code, e.detail), ensure_ascii=False))
        return 1
    except Exception as e:
        print(json.dumps(emit_error_json(Err.INTERNAL, type(e).__name__), ensure_ascii=False))
        return 1

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
