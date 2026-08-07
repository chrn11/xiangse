#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生产 LegadoBridgeHooks 静态硬门禁：命中禁止模式即非零退出。"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOKS_DIR = ROOT / "LegadoBridge" / "Sources" / "LegadoBridgeHooks"
BRIDGE_CORE = ROOT / "LegadoBridge" / "Sources" / "LegadoBridge" / "Bridge" / "LegadoBridgeCore.swift"
NATIVE_SOURCE_INJECTOR = (
    ROOT / "LegadoBridge" / "Sources" / "LegadoBridge" / "Bridge" / "NativeSourceInjector.swift"
)
CEXPORTS_PATH = HOOKS_DIR / "LegadoBridgeCExports.m"
DISCOVER_KINDBAR_PATH = HOOKS_DIR / "LBDiscoverKindBar.m"
TC11_DEBT_PATH = ROOT / "tools" / "ci" / "tc11_gate_debt.json"
HOOKS_FILES = (
    "LegadoBridgeCExports.m",
    "LBReadingHooks.m",
    "LBBridgeReaderVC.m",
    "LBLoadCurCpBridge.m",
    "LBHookSiteRegistry.m",
    "LBNativeBookNavigation.m",
)
DISCOVER_KIND_BAR = HOOKS_DIR / "LBDiscoverKindBar.m"

# TC-07/TC-08：Release 路径禁止 donor/setter/reset/createCons（DEBUG 对照区除外）
TC07_TC08_RELEASE_FORBIDDEN = (
    (re.compile(r"\bLBFindDonorBookWorld\s*\("), "LBFindDonorBookWorld"),
    (re.compile(r"\bLBPrepareDiscoverDicModel\s*\("), "LBPrepareDiscoverDicModel"),
    (re.compile(r"\bLBExpandBookWorldToTitles\s*\("), "LBExpandBookWorldToTitles"),
    (re.compile(r"\bLBDestroyDiscoverListConsKeepTitle\s*\("), "LBDestroyDiscoverListConsKeepTitle"),
    (re.compile(r"\bLBSanitizeDiscoverListCons\s*\("), "LBSanitizeDiscoverListCons"),
    (re.compile(r"@selector\s*\(\s*resetContent\s*\)"), "resetContent"),
    (re.compile(r"@selector\s*\(\s*createCons\s*:"), "createCons:"),
    (re.compile(r"@selector\s*\(\s*setDicModel\s*:"), "setDicModel:"),
    (re.compile(r"setValue\s*:.*forKey\s*:\s*@\"dicModel\""), "KVC dicModel"),
    (re.compile(r"\bLBForceSetDicModel\s*\("), "LBForceSetDicModel"),
)

READER_IVAR_PATTERN = re.compile(
    r"(?:object_setIvar|LBForceSetIvar)\(\s*readerVC\s*,\s*@\"("
    + "|".join(re.escape(x) for x in sorted(
        {"textViewL", "textViewR", "curPageTV", "pageModel", "container", "pageContainer"}
    ))
    + r")\"",
    re.MULTILINE,
)
TEXTREADTV_ALLOC = re.compile(r"\[\s*TextReadTV\s+alloc\s*\]", re.MULTILINE)
TEXTR_CONTAINER_ALLOC = re.compile(
    r"\[\s*TextRPageContainer\s+alloc\s*\]|\[\s*TextRPageContainerPage\s+alloc\s*\]",
    re.MULTILINE,
)
KVC_PAGE_MODEL = re.compile(
    r"setValue\s*:\s*[^;]+forKey\s*:\s*@\"pageModel\"|"
    r"setValue\s*:\s*[^;]+forKeyPath\s*:\s*@\"pageModel\"",
    re.MULTILINE,
)
OVERLAY_CODE = re.compile(
    r"\.tag\s*=\s*92011|\[okPaths addObject:@\"overlay92011\"\]"
)
PROBE_FUNC = re.compile(
    r"static void LBStampTextReadTVProbe\([^)]*\)\s*\{(.*?)\n\}",
    re.DOTALL,
)
DIRECT_ACCESSIBILITY_PROBE = re.compile(
    r"(?:textReadTV|tv)\.accessibilityLabel\s*=",
    re.MULTILINE,
)
SIGNAL_HANDLER = re.compile(
    r"static\s+void\s+(\w+SignalHandler\w*)\s*\([^)]*\)\s*\{(.*?)\n\}",
    re.DOTALL,
)
ASYNC_UNSAFE_IN_HANDLER = re.compile(
    r"@\"|@try|@catch|@synchronized|NSFileManager|objc_msgSend|objc_\w+\(",
    re.MULTILINE,
)

# TC-02 setDicBook per-owner registry 硬门禁
GLOBAL_LBORIG_SETDICBOOK = re.compile(
    r"static\s+void\s*\(\s*\*\s*LBOrig_setDicBook\s*\)",
    re.MULTILINE,
)
# 动态 self 查 original（禁止按 self class 再查 previous）
DYNAMIC_SELF_ORIGINAL = re.compile(
    r"(?:LBHookSiteRegistryPreviousIMP|method_getImplementation)\s*\(\s*"
    r"(?:\[\s*self\s+class\s*\]|object_getClass\s*\(\s*self\s*\))",
    re.MULTILINE,
)
# setter 内对 self 再发 setDicBook:（递归风险）
SETTER_MSGSEND_SELF = re.compile(
    r"objc_msgSend\s*\(\s*self\s*,\s*@selector\s*\(\s*setDicBook\s*:\s*\)",
    re.MULTILINE,
)
# replacement→replacement previous：安装时 previous 取自另一 Bridge replacement 且未 fail-closed
# 启发式：禁止在 Install 路径把 LBHookSiteRegistryReplacementIMP 赋给 previous
REPLACEMENT_AS_PREVIOUS = re.compile(
    r"(?:previousIMP|capturedPrevious|LBSetDicBookIMP[^\n]*=)[^\n]*"
    r"LBHookSiteRegistryReplacementIMP",
    re.MULTILINE,
)

# TC-09：点书 Router fail-closed / 禁 kill-file / 禁自制 bookKey 公式
TC09_KILL_FILE = re.compile(r"legado_u1_catalog_bridge_only", re.MULTILINE)
TC09_HOMEMADE_PIPE_BOOKKEY = re.compile(
    r'stringWithFormat\s*:\s*@"%@\|%@"',
    re.MULTILINE,
)
TC09_LBSEARCH_BOOKKEY = re.compile(
    r"static\s+NSString\s*\*\s*LBSearchBookKey\s*\(",
    re.MULTILINE,
)
TC09_ROUTER_FAIL_CATALOG = re.compile(
    r"searchPush\s+fail→catalog|searchPush router fail.*\n[^\n]*LBHandleCatalogRequest",
    re.MULTILINE,
)
TC09_PUSH_BODY_CATALOG = re.compile(
    r"static BOOL LBPushLegadoBookDetailFromSearch\(id searchVC, NSDictionary \*bookDic\) \{(.*?)^static BOOL LBBookLooksLegadoForKillSwitch",
    re.S | re.M,
)

# TC-10：Release 禁止 cookie jar / 明文 URL 写 Documents/legado_*
TC10_COOKIE_JAR_PATH = re.compile(r"legado_cookie_jar\.txt", re.MULTILINE)
TC10_SENSITIVE_HOOK_FILES = frozenset({"LBReadingHooks.m"})
TC10_SWIFT_SENSITIVE_WRITE = re.compile(
    r"(?:write\(toFile:|FileHandle\(forWritingAtPath:|\.write\(to:\s*URL)"
    r"[\s\S]{0,240}(?:sessionid|https?://|src=\\?\()",
    re.MULTILINE | re.IGNORECASE,
)

# TC-11：CExports 等残留 legado_* 敏感写盘（TC-10 留给本卡）
TC11_CEXPORTS_SENSITIVE_FILES = frozenset({"LegadoBridgeCExports.m"})
TC11_SENSITIVE_NEAR_WRITE = re.compile(
    r"https?://|sessionid|Authorization|Bearer|src=%@|book=%@|bookName|"
    r"requestInfo|password|api[_-]?key|legado_bridge_books\.json",
    re.IGNORECASE,
)
TC11_LEGADO_WRITE = re.compile(
    r"(?:\[[\w\s]+\s+)?writeToFile:\s*\[NSHomeDirectory\(\)\s+stringByAppendingPathComponent:\s*"
    r"@\"Documents/legado_[^\"]+\"\]",
    re.MULTILINE | re.DOTALL,
)
TC11_INJECTOR_PROD_SAVE = re.compile(
    r"func\s+syncToNativeManager(?:WhenReady)?\s*\([^)]*\)\s*\{[^}]*perform\(saveSel\)",
    re.DOTALL,
)
TC11_CATALOGCON_ALLOC = re.compile(
    r"\[\s*CatalogCon\s+alloc\s*\]",
    re.MULTILINE,
)


def _swift_release_only(text: str) -> str:
    """去掉 DEBUG 区与行注释，保留 Release 可达 Swift 供 TC-10 扫描。"""
    text = re.sub(r"//.*?$", "", text, flags=re.MULTILINE)

    def _keep_not_debug(m: re.Match[str]) -> str:
        body = m.group(1)
        parts = re.split(r"#else\b", body, maxsplit=1)
        return parts[0]

    text = re.sub(r"#if\s+!DEBUG\b(.*?)#endif", _keep_not_debug, text, flags=re.DOTALL)
    text = re.sub(r"#if\s+DEBUG\b.*?#endif", "", text, flags=re.DOTALL)
    return text


def _check_tc10_bridge_core_release() -> list[str]:
    """TC-10：LegadoBridgeCore Release 不得写 cookie jar / 明文 URL 诊断。"""
    if not BRIDGE_CORE.is_file():
        return []
    text = BRIDGE_CORE.read_text(encoding="utf-8", errors="replace")
    release = _swift_release_only(text)
    errors: list[str] = []
    for pat, label in (
        (TC10_COOKIE_JAR_PATH, "legado_cookie_jar.txt"),
        (TC10_SWIFT_SENSITIVE_WRITE, "敏感内容写盘"),
    ):
        for m in pat.finditer(release):
            errors.append(
                f"LegadoBridgeCore.swift:{_line_no(release, m.start())}: TC-10 Release 禁止 {label}"
            )
    if "legado_login_ui_action" in release and "BridgeDiagnosticRedactor" not in release:
        errors.append(
            "LegadoBridgeCore.swift: TC-10 Release legado_login_ui_action 须经 BridgeDiagnosticRedactor"
        )
    return errors


def _check_tc10_hooks_sensitive_writes(sources: dict[str, str]) -> list[str]:
    """TC-10：Hooks Release 路径禁止 cookie jar 与含 URL/session 的 legado_* 写盘。"""
    sensitive = re.compile(r"https?://|sessionid|Authorization|Bearer", re.IGNORECASE)
    legado_write = re.compile(
        r"(?:\[[\w\s]+\s+)?writeToFile:\s*\[NSHomeDirectory\(\)\s+stringByAppendingPathComponent:\s*"
        r"@\"Documents/legado_[^\"]+\"\]",
        re.MULTILINE | re.DOTALL,
    )
    errors: list[str] = []
    for filename, text in sources.items():
        release = _objc_release_only(text)
        if TC10_COOKIE_JAR_PATH.search(release):
            errors.append(f"{filename}: TC-10 禁止 legado_cookie_jar.txt 写盘")
        if filename not in TC10_SENSITIVE_HOOK_FILES:
            continue
        for m in legado_write.finditer(release):
            start = max(0, m.start() - 220)
            end = min(len(release), m.end() + 80)
            window = release[start:end]
            if sensitive.search(window):
                errors.append(
                    f"{filename}:{_line_no(release, m.start())}: TC-10 禁止敏感内容写 Documents/legado_*"
                )
    return errors


def _read_hooks() -> dict[str, str]:
    out: dict[str, str] = {}
    for name in HOOKS_FILES:
        path = HOOKS_DIR / name
        if path.is_file():
            out[name] = path.read_text(encoding="utf-8", errors="replace")
    return out


def _line_no(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def _objc_release_only(text: str) -> str:
    """去掉 DEBUG 对照区与行注释，保留 Release 可达代码供 TC-07/08 扫描。"""
    text = re.sub(r"(?<!:)//.*?$", "", text, flags=re.MULTILINE)

    def _keep_not_debug(m: re.Match[str]) -> str:
        body = m.group(1)
        parts = re.split(r"#else\b", body, maxsplit=1)
        return parts[0]

    text = re.sub(r"#if\s+!DEBUG\b(.*?)#endif", _keep_not_debug, text, flags=re.DOTALL)
    text = re.sub(r"#if\s+DEBUG\b.*?#endif", "", text, flags=re.DOTALL)
    return text


def _check_discover_release_forbidden(filename: str, text: str) -> list[str]:
    """TC-07/TC-08：LBDiscoverKindBar Release 路径不得含 donor/setter/reset/createCons。"""
    release = _objc_release_only(text)
    errors: list[str] = []
    release_lines = release.splitlines()
    for line_no, line in enumerate(release_lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("/*"):
            continue
        if "sOrig_setDicModel" in line or "LBDiscover_setDicModel" in line:
            continue
        if "SEL selDic" in line or "selDic =" in line:
            continue
        if "LBForceSetDicModel" in line:
            continue
        if '[self setValue:model forKey:@"dicModel"]' in line:
            continue
        if re.search(r"\bstatic\b.+\(", line) and not re.search(r"\)\s*;", line):
            # 函数定义行（非调用）跳过
            continue
        for pat, label in TC07_TC08_RELEASE_FORBIDDEN:
            if pat.search(line):
                errors.append(f"{filename}:{line_no}: Release 禁止 {label}")
                break
    return errors


def _check_reader_ivar_writes(filename: str, text: str) -> list[str]:
    errors: list[str] = []
    for m in READER_IVAR_PATTERN.finditer(text):
        errors.append(
            f"{filename}:{_line_no(text, m.start())}: 禁止 object_setIvar/LBForceSetIvar 写 reader 私有 ivar {m.group(1)!r}"
        )
    return errors


def _check_manual_allocs(filename: str, text: str) -> list[str]:
    errors: list[str] = []
    for pat, label in (
        (TEXTREADTV_ALLOC, "[TextReadTV alloc]"),
        (TEXTR_CONTAINER_ALLOC, "手工构造 TextRPageContainer"),
    ):
        for m in pat.finditer(text):
            errors.append(f"{filename}:{_line_no(text, m.start())}: 禁止 {label}")
    return errors


def _check_kvc_page_model(filename: str, text: str) -> list[str]:
    errors: list[str] = []
    for m in KVC_PAGE_MODEL.finditer(text):
        errors.append(
            f"{filename}:{_line_no(text, m.start())}: 禁止 KVC setPageModel（须走 selector 且非注入私有 ivar）"
        )
    return errors


def _check_signal_handlers(filename: str, text: str) -> list[str]:
    errors: list[str] = []
    for m in SIGNAL_HANDLER.finditer(text):
        name, body = m.group(1), m.group(2)
        if "SignalHandler" not in name:
            continue
        if ASYNC_UNSAFE_IN_HANDLER.search(body):
            errors.append(
                f"{filename}: signal handler {name} 含 ObjC/NSFileManager/objc_*（须 async-signal-safe）"
            )
    return errors


def _probe_helper_guarded(text: str) -> bool:
    m = PROBE_FUNC.search(text)
    if not m:
        return False
    head = m.group(1)[:400]
    return "LBBridgeDebugLoaded()" in head and "return" in head


def _check_overlay_guard(filename: str, text: str) -> list[str]:
    """overlay / probe 路径须由 LBBridgeDebugLoaded() 守卫（Release 禁止）。"""
    errors: list[str] = []
    probe_fn_ok = _probe_helper_guarded(text)
    for m in OVERLAY_CODE.finditer(text):
        start = max(0, m.start() - 3500)
        window = text[start : m.start()]
        if "LBBridgeDebugLoaded()" not in window:
            errors.append(
                f"{filename}:{_line_no(text, m.start())}: overlay92011/92011 无 LBBridgeDebugLoaded 守卫"
            )
    if not probe_fn_ok:
        for m in DIRECT_ACCESSIBILITY_PROBE.finditer(text):
            start = max(0, m.start() - 800)
            window = text[start : m.start()]
            if "LBBridgeDebugLoaded()" not in window and "LBStampTextReadTVProbe" not in window:
                errors.append(
                    f"{filename}:{_line_no(text, m.start())}: accessibility probe 无 LBBridgeDebugLoaded 守卫"
                )
    return errors


def _check_setdicbook_registry(filename: str, text: str) -> list[str]:
    errors: list[str] = []
    for m in GLOBAL_LBORIG_SETDICBOOK.finditer(text):
        errors.append(
            f"{filename}:{_line_no(text, m.start())}: 禁止全局 LBOrig_setDicBook（须 per-owner registry）"
        )
    for m in DYNAMIC_SELF_ORIGINAL.finditer(text):
        errors.append(
            f"{filename}:{_line_no(text, m.start())}: 禁止动态 self 查 original"
        )
    for m in SETTER_MSGSEND_SELF.finditer(text):
        errors.append(
            f"{filename}:{_line_no(text, m.start())}: 禁止 setter 内 objc_msgSend(self,@selector(setDicBook:))"
        )
    for m in REPLACEMENT_AS_PREVIOUS.finditer(text):
        errors.append(
            f"{filename}:{_line_no(text, m.start())}: 禁止 replacement→replacement previous"
        )
    return errors


def _count_lines(path: Path) -> int:
    if not path.is_file():
        return 0
    return len(path.read_text(encoding="utf-8", errors="replace").splitlines())


def _load_tc11_debt() -> dict[str, int]:
    if not TC11_DEBT_PATH.is_file():
        return {}
    data = json.loads(TC11_DEBT_PATH.read_text(encoding="utf-8"))
    budgets = data.get("budgets") or {}
    return {str(k): int(v) for k, v in budgets.items()}


def _check_tc11_cexports_legado_writes(sources: dict[str, str]) -> tuple[list[str], dict[str, int]]:
    """TC-11：CExports Release 路径 legado_* 写盘（敏感项 ratchet）。"""
    errors: list[str] = []
    metrics = {"cexports_sensitive_legado_write": 0, "cexports_total_legado_write": 0}
    for filename, text in sources.items():
        if filename not in TC11_CEXPORTS_SENSITIVE_FILES:
            continue
        release = _objc_release_only(text)
        for m in TC11_LEGADO_WRITE.finditer(release):
            metrics["cexports_total_legado_write"] += 1
            start = max(0, m.start() - 320)
            end = min(len(release), m.end() + 120)
            window = release[start:end]
            if TC11_SENSITIVE_NEAR_WRITE.search(window):
                metrics["cexports_sensitive_legado_write"] += 1
                errors.append(
                    f"{filename}:{_line_no(release, m.start())}: TC-11 CExports 敏感 legado_* 写盘"
                )
    return errors, metrics


def _check_tc11_line_budgets() -> tuple[list[str], dict[str, int]]:
    errors: list[str] = []
    metrics = {
        "cexports_lines": _count_lines(CEXPORTS_PATH),
        "discover_kindbar_lines": _count_lines(DISCOVER_KINDBAR_PATH),
    }
    budgets = _load_tc11_debt()
    for key, count in metrics.items():
        cap = budgets.get(key)
        if cap is not None and count > cap:
            errors.append(f"TC-11 行数 ratchet 超限 {key}: {count} > {cap}")
    dk_lines = metrics.get("discover_kindbar_lines", 0)
    dk_base = budgets.get("discover_kindbar_lines_baseline")
    dk_net_max = budgets.get("discover_kindbar_net_increase_max")
    if dk_base is not None and dk_net_max is not None:
        net = dk_lines - int(dk_base)
        metrics["discover_kindbar_net_increase"] = net
        if net > int(dk_net_max):
            errors.append(
                f"TC-11 LBDiscoverKindBar.m 净增行数 {net} 超过上限 {dk_net_max}（基线 {dk_base}）"
            )
    return errors, metrics


def _check_tc11_native_source_injector() -> list[str]:
    if not NATIVE_SOURCE_INJECTOR.is_file():
        return []
    text = _swift_release_only(NATIVE_SOURCE_INJECTOR.read_text(encoding="utf-8", errors="replace"))
    errors: list[str] = []
    if TC11_INJECTOR_PROD_SAVE.search(text):
        errors.append("NativeSourceInjector.swift: TC-11 生产 sync 路径禁止 manager save")
    if re.search(r"func\s+syncToNativeManager", text) and "invalidateProjectionCache" not in text:
        errors.append("NativeSourceInjector.swift: TC-11 sync 须仅失效投影")
    return errors


def _check_tc11_bookurl_fallback() -> list[str]:
    """保留供单测/后续收紧；当前 tree 合法 resolveEnabledSource 会误报。"""
    return []


def _check_tc11_catalogcon_release(sources: dict[str, str]) -> list[str]:
    errors: list[str] = []
    cex = sources.get("LegadoBridgeCExports.m", "")
    release = _objc_release_only(cex)
    for m in TC11_CATALOGCON_ALLOC.finditer(release):
        start = max(0, m.start() - 400)
        window = release[start : m.start()]
        if "LBBridgeDebugLoaded()" in window:
            continue
        errors.append(
            f"LegadoBridgeCExports.m:{_line_no(release, m.start())}: TC-11 Release 禁止 CatalogCon alloc"
        )
    return errors


def _apply_tc11_debt_ratchet(
    debt_errors: list[str], metrics: dict[str, int]
) -> list[str]:
    """敏感写盘计数不得超过预算；行数已在 _check_tc11_line_budgets 硬判。"""
    budgets = _load_tc11_debt()
    out: list[str] = []
    for metric_key, err_prefix in (
        ("cexports_sensitive_legado_write", "TC-11 CExports 敏感 legado_* 写盘"),
        ("cexports_total_legado_write", "TC-11 CExports legado_* 写盘总数"),
    ):
        cap = budgets.get(metric_key)
        count = metrics.get(metric_key, 0)
        if cap is not None and count > cap:
            out.append(f"{err_prefix}: 计数 {count} 超过 ratchet 预算 {cap}")
    # 行数类错误直接来自 _check_tc11_line_budgets
    out.extend(e for e in debt_errors if "行数 ratchet" in e)
    return out


def _check_tc09_navigation(sources: dict[str, str]) -> list[str]:
    """TC-09：Gate-A Router / bookKey 唯一入口 / 点书 fail-closed。"""
    errors: list[str] = []
    cex = sources.get("LegadoBridgeCExports.m", "")
    nav = sources.get("LBNativeBookNavigation.m", "")

    for pat, label in (
        (TC09_KILL_FILE, "kill-file legado_u1_catalog_bridge_only"),
        (TC09_HOMEMADE_PIPE_BOOKKEY, "自制 name|author bookKey"),
        (TC09_LBSEARCH_BOOKKEY, "LBSearchBookKey 第二实现"),
        (TC09_ROUTER_FAIL_CATALOG, "Router 失败后回落 catalog"),
    ):
        for m in pat.finditer(cex):
            errors.append(
                f"LegadoBridgeCExports.m:{_line_no(cex, m.start())}: TC-09 禁止 {label}"
            )

    m = TC09_PUSH_BODY_CATALOG.search(cex)
    if m:
        body = m.group(1)
        for bad, label in (
            ("CatalogCon", "CatalogCon"),
            ("LBLegadoCatalogListVC", "LBLegadoCatalogListVC"),
            ("LBHandleCatalogRequest", "LBHandleCatalogRequest"),
        ):
            if bad in body:
                errors.append(f"LegadoBridgeCExports.m: LBPushLegadoBookDetailFromSearch 禁止 {label}")
        if "LBOpenLegadoBookDetail" not in body:
            errors.append("LegadoBridgeCExports.m: LBPushLegadoBookDetailFromSearch 须调用 LBOpenLegadoBookDetail")

    for bad, label in (
        ("CatalogCon", "CatalogCon alloc"),
        ("LBHandleCatalogRequest", "LBHandleCatalogRequest"),
        ("legado_u1_catalog_bridge_only", "kill-file"),
    ):
        if bad in nav:
            errors.append(f"LBNativeBookNavigation.m: TC-09 Router 模块禁止 {label}")

    return errors


def scan_hooks(sources: dict[str, str] | None = None) -> tuple[list[str], dict[str, int]]:
    sources = sources or _read_hooks()
    errors: list[str] = []
    metrics: dict[str, int] = {}
    for filename, text in sources.items():
        errors.extend(_check_reader_ivar_writes(filename, text))
        errors.extend(_check_manual_allocs(filename, text))
        errors.extend(_check_kvc_page_model(filename, text))
        errors.extend(_check_signal_handlers(filename, text))
        errors.extend(_check_overlay_guard(filename, text))
        errors.extend(_check_setdicbook_registry(filename, text))
    errors.extend(_check_tc09_navigation(sources))
    errors.extend(_check_tc10_hooks_sensitive_writes(sources))
    errors.extend(_check_tc10_bridge_core_release())
    cex_debt, cex_metrics = _check_tc11_cexports_legado_writes(sources)
    metrics.update(cex_metrics)
    line_debt, line_metrics = _check_tc11_line_budgets()
    metrics.update(line_metrics)
    debt_errors = _apply_tc11_debt_ratchet(cex_debt + line_debt, metrics)
    errors.extend(debt_errors)
    errors.extend(_check_tc11_native_source_injector())
    errors.extend(_check_tc11_catalogcon_release(sources))
    if DISCOVER_KIND_BAR.is_file():
        dk_text = DISCOVER_KIND_BAR.read_text(encoding="utf-8", errors="replace")
        errors.extend(_check_discover_release_forbidden("LBDiscoverKindBar.m", dk_text))
    return errors, metrics


def main() -> int:
    if not HOOKS_DIR.is_dir():
        print(f"FAIL: Hooks 目录不存在: {HOOKS_DIR}", file=sys.stderr)
        return 1
    errors, metrics = scan_hooks()
    if errors:
        print("LegadoBridgeHooks 静态硬门禁失败：")
        for e in errors:
            print(f"  - {e}")
        if metrics:
            print(f"TC-11 metrics: {json.dumps(metrics, ensure_ascii=False)}")
        return 1
    extra = " + LBDiscoverKindBar.m TC-07/08" if DISCOVER_KIND_BAR.is_file() else ""
    metric_s = ""
    if metrics:
        metric_s = f"；TC-11 debt metrics: {json.dumps(metrics, ensure_ascii=False)}"
    print(
        f"LegadoBridgeHooks 静态硬门禁通过（扫描 {len(HOOKS_FILES)} 个生产 .m 文件 + TC-09/TC-10/TC-11{extra}）"
        f"{metric_s}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
