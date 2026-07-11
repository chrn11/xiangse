#!/usr/bin/env bash
# 校验注入后 IPA：LC_LOAD_DYLIB、arm64、URL Scheme、关键文件、SHA-256
set -euo pipefail

IPA="${1:-}"
EXPECT_DYLIB="${2:-1}"  # 1=必须注入成功；0=允许仅 manifest（无 dylib 时）

if [[ -z "$IPA" || ! -f "$IPA" ]]; then
  echo "用法: verify_ipa.sh <ipa> [expect_dylib=1]"
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/legado-verify.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> 校验 IPA: $IPA"
unzip -q "$IPA" -d "$WORK"
APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
if [[ -z "$APP" ]]; then
  echo "FAIL: IPA 内无 Payload/*.app"
  exit 1
fi
BIN="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null || basename "$APP" .app)"
if [[ ! -f "$BIN" ]]; then
  BIN="$APP/StandarReader"
fi
if [[ ! -f "$BIN" ]]; then
  echo "FAIL: 找不到主可执行文件"
  exit 1
fi

FAIL=0

# 架构
if command -v lipo >/dev/null 2>&1; then
  ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
  echo "    主程序架构: ${ARCHS:-unknown}"
  if [[ "$ARCHS" != *arm64* ]]; then
    echo "FAIL: 主程序缺少 arm64"
    FAIL=1
  fi
fi

BRIDGE="$APP/Frameworks/LegadoBridge"
BRIDGE_FW="$APP/Frameworks/LegadoBridge.framework/LegadoBridge"
BRIDGE_BIN=""
if [[ -f "$BRIDGE" ]]; then
  BRIDGE_BIN="$BRIDGE"
elif [[ -f "$BRIDGE_FW" ]]; then
  BRIDGE_BIN="$BRIDGE_FW"
fi

if [[ -n "$BRIDGE_BIN" ]]; then
  echo "    Bridge 产物: $BRIDGE_BIN"
  if command -v lipo >/dev/null 2>&1; then
    BARCHS="$(lipo -archs "$BRIDGE_BIN" 2>/dev/null || true)"
    echo "    Bridge 架构: ${BARCHS:-unknown}"
    if [[ "$BARCHS" != *arm64* ]]; then
      echo "FAIL: LegadoBridge 缺少 arm64"
      FAIL=1
    fi
  fi
elif [[ "$EXPECT_DYLIB" == "1" ]]; then
  echo "FAIL: 未找到 Frameworks/LegadoBridge（expect_dylib=1）"
  FAIL=1
else
  echo "WARN: 未找到 LegadoBridge 二进制（允许跳过）"
fi

# LC_LOAD_DYLIB
if command -v otool >/dev/null 2>&1; then
  LOADS="$(otool -L "$BIN" 2>/dev/null || true)"
  if echo "$LOADS" | grep -q 'Frameworks/LegadoBridge'; then
    echo "    LC_LOAD_DYLIB: 已包含 @executable_path/Frameworks/LegadoBridge"
  else
    if [[ "$EXPECT_DYLIB" == "1" && -n "$BRIDGE_BIN" ]]; then
      echo "FAIL: 主程序未注入 LC_LOAD_DYLIB → Frameworks/LegadoBridge"
      FAIL=1
    else
      echo "WARN: 主程序未见 LC_LOAD_DYLIB LegadoBridge"
    fi
  fi
else
  echo "WARN: otool 不可用，跳过 LC_LOAD_DYLIB 检查"
fi

# URL Scheme
PLIST="$APP/Info.plist"
if [[ -f "$PLIST" ]] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
  SCHEMES="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$PLIST" 2>/dev/null || true)"
  if echo "$SCHEMES" | grep -q 'legado' && echo "$SCHEMES" | grep -q 'yuedu'; then
    echo "    URL Scheme: legado + yuedu 已注入"
  else
    echo "FAIL: Info.plist 缺少 legado/yuedu URL Scheme"
    FAIL=1
  fi
fi

# 关键文件
if [[ ! -f "$APP/legado-bridge-manifest.plist" ]]; then
  echo "FAIL: 缺少 legado-bridge-manifest.plist"
  FAIL=1
else
  echo "    manifest: 存在"
fi

# SHA-256
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$IPA" | tee "$IPA.sha256"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$IPA" | tee "$IPA.sha256"
else
  echo "WARN: 无 shasum/sha256sum"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "==> 校验失败"
  exit 1
fi
echo "==> 校验通过"
exit 0
