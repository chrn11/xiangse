#!/usr/bin/env bash
# 校验 forensics 双包：LC_LOAD_DYLIB 变体、reader-build-manifest.json
set -euo pipefail

IPA="${1:-}"
VARIANT="${2:-}"  # baseline-debug | legado-debug

if [[ -z "$IPA" || ! -f "$IPA" ]]; then
  echo "用法: verify_forensics_ipa.sh <ipa> <baseline-debug|legado-debug>"
  exit 2
fi
if [[ "$VARIANT" != "baseline-debug" && "$VARIANT" != "legado-debug" ]]; then
  echo "FAIL: variant 必须是 baseline-debug 或 legado-debug"
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/forensics-verify.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> 校验 forensics IPA: $IPA variant=$VARIANT"
unzip -q "$IPA" -d "$WORK"
APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
if [[ -z "$APP" ]]; then
  echo "FAIL: IPA 内无 Payload/*.app"
  exit 1
fi
BIN="$APP/StandarReader"
if [[ ! -f "$BIN" ]]; then
  BIN="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null || true)"
fi
if [[ ! -f "$BIN" ]]; then
  echo "FAIL: 找不到主可执行文件"
  exit 1
fi

FAIL=0
MANIFEST_JSON="$APP/reader-build-manifest.json"
if [[ ! -f "$MANIFEST_JSON" ]]; then
  echo "FAIL: 缺少 reader-build-manifest.json"
  FAIL=1
else
  echo "    reader-build-manifest.json: 存在"
  if command -v python3 >/dev/null 2>&1; then
    INLINE_ERR="$(python3 -c "
import json, sys
from pathlib import Path
p=Path('$MANIFEST_JSON')
m=json.loads(p.read_text())
req=['schema_version','variant','git_commit','github_run_id','base_ipa_sha256','app_binary_sha256','legado_bridge_sha256','legado_debug_sha256','built_at_utc']
errs=[f'missing:{k}' for k in req if k not in m]
if m.get('variant')!='$VARIANT': errs.append('variant_mismatch')
if '$VARIANT'=='baseline-debug' and m.get('legado_bridge_sha256') is not None: errs.append('bridge_should_be_null')
if '$VARIANT'=='legado-debug' and not m.get('legado_bridge_sha256'): errs.append('bridge_missing')
if errs:
    print(';'.join(errs)); sys.exit(1)
print('manifest_ok')
" 2>&1 || true)"
    if [[ "$INLINE_ERR" != "manifest_ok" ]]; then
      echo "FAIL: manifest 校验: $INLINE_ERR"
      FAIL=1
    else
      echo "    manifest 字段校验通过"
    fi
  fi
fi

DEBUG_BIN="$APP/Frameworks/LegadoBridgeDebug"
BRIDGE_BIN="$APP/Frameworks/LegadoBridge"
[[ -f "$DEBUG_BIN" ]] || DEBUG_BIN="$APP/Frameworks/LegadoBridgeDebug.framework/LegadoBridgeDebug"
[[ -f "$BRIDGE_BIN" ]] || BRIDGE_BIN="$APP/Frameworks/LegadoBridge.framework/LegadoBridge"

if [[ ! -f "$DEBUG_BIN" ]]; then
  echo "FAIL: 缺少 LegadoBridgeDebug"
  FAIL=1
else
  echo "    LegadoBridgeDebug: 存在"
fi

if [[ "$VARIANT" == "baseline-debug" ]]; then
  if [[ -f "$BRIDGE_BIN" ]]; then
    echo "FAIL: baseline-debug 不应包含 LegadoBridge 二进制"
    FAIL=1
  fi
else
  if [[ ! -f "$BRIDGE_BIN" ]]; then
    echo "FAIL: legado-debug 缺少 LegadoBridge 二进制"
    FAIL=1
  fi
fi

if command -v otool >/dev/null 2>&1; then
  LOADS="$(otool -L "$BIN" 2>/dev/null || true)"
  HAS_DEBUG=0
  HAS_BRIDGE=0
  echo "$LOADS" | grep -q 'Frameworks/LegadoBridgeDebug' && HAS_DEBUG=1 || true
  # 勿把 LegadoBridgeDebug 误判为 LegadoBridge
  if echo "$LOADS" | grep '@executable_path/Frameworks/LegadoBridge' | grep -qv 'LegadoBridgeDebug'; then
    HAS_BRIDGE=1
  fi

  if [[ "$HAS_DEBUG" -ne 1 ]]; then
    echo "FAIL: LC_LOAD_DYLIB 缺少 LegadoBridgeDebug"
    FAIL=1
  else
    echo "    LC_LOAD_DYLIB: LegadoBridgeDebug ✓"
  fi

  if [[ "$VARIANT" == "baseline-debug" ]]; then
    if [[ "$HAS_BRIDGE" -eq 1 ]]; then
      echo "FAIL: baseline-debug LC_LOAD_DYLIB 不应包含 LegadoBridge"
      FAIL=1
    else
      echo "    LC_LOAD_DYLIB: 无 LegadoBridge ✓"
    fi
  else
    if [[ "$HAS_BRIDGE" -ne 1 ]]; then
      echo "FAIL: legado-debug LC_LOAD_DYLIB 缺少 LegadoBridge"
      FAIL=1
    else
      echo "    LC_LOAD_DYLIB: LegadoBridge + LegadoBridgeDebug ✓"
    fi
  fi
else
  echo "WARN: otool 不可用"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "==> forensics 校验失败"
  exit 1
fi
echo "==> forensics 校验通过"
exit 0
