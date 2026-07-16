#!/usr/bin/env bash
# forensics 重打包：baseline-debug（仅 Debug）或 legado-debug（Bridge+Debug）
set -euo pipefail

VARIANT="${1:-}"          # baseline-debug | legado-debug
IPA_IN_RAW="${2:-}"
BRIDGE_DYLIB_RAW="${3:-}"
DEBUG_DYLIB_RAW="${4:-}"
OUT_RAW="${5:-}"

if [[ "$VARIANT" != "baseline-debug" && "$VARIANT" != "legado-debug" ]]; then
  echo "用法: repack_forensics.sh <baseline-debug|legado-debug> <ipa> <bridge_dylib|-> <debug_dylib> <out.ipa>"
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IPA_IN="$(cd "$(dirname "$IPA_IN_RAW")" 2>/dev/null && echo "$(pwd)/$(basename "$IPA_IN_RAW")")"
OUT="$(cd "$(dirname "$OUT_RAW")" 2>/dev/null && echo "$(pwd)/$(basename "$OUT_RAW")")"
DEBUG_DYLIB="$DEBUG_DYLIB_RAW"
BRIDGE_DYLIB=""
if [[ "$VARIANT" == "legado-debug" ]]; then
  BRIDGE_DYLIB="$BRIDGE_DYLIB_RAW"
fi

GIT_COMMIT="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-local}"
BUILT_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "==> forensics repack variant=$VARIANT"
echo "    IPA: $IPA_IN"
echo "    Bridge: ${BRIDGE_DYLIB:-（跳过）}"
echo "    Debug: $DEBUG_DYLIB"
echo "    Out: $OUT"

if [[ ! -f "$IPA_IN" ]]; then
  echo "FAIL: IPA 不存在: $IPA_IN"
  exit 1
fi
if [[ ! -f "$DEBUG_DYLIB" ]]; then
  echo "FAIL: LegadoBridgeDebug 不存在: $DEBUG_DYLIB"
  exit 1
fi
if [[ "$VARIANT" == "legado-debug" && ! -f "$BRIDGE_DYLIB" ]]; then
  echo "FAIL: LegadoBridge 不存在: $BRIDGE_DYLIB"
  exit 1
fi

WORK="$ROOT/analysis/repack-work-${VARIANT}"
rm -rf "$WORK"
mkdir -p "$WORK" "$(dirname "$OUT")"

cp "$IPA_IN" "$WORK/payload.zip"
unzip -q "$WORK/payload.zip" -d "$WORK"

APP="$WORK/Payload/StandarReader.app"
BIN="$APP/StandarReader"
FRAMEWORKS="$APP/Frameworks"
mkdir -p "$FRAMEWORKS"

# URL scheme（与 repack.sh 一致）
PLIST="$APP/Info.plist"
if command -v /usr/libexec/PlistBuddy &>/dev/null && [[ -f "$PLIST" ]]; then
  PB=/usr/libexec/PlistBuddy
  "$PB" -c "Add :CFBundleURLTypes array" "$PLIST" 2>/dev/null || true
  "$PB" -c "Add :CFBundleURLTypes:0 dict" "$PLIST" 2>/dev/null || true
  "$PB" -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.legado.import" "$PLIST" 2>/dev/null || true
  "$PB" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST" 2>/dev/null || true
  "$PB" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string legado" "$PLIST" 2>/dev/null || true
  "$PB" -c "Add :CFBundleURLTypes:1 dict" "$PLIST" 2>/dev/null || true
  "$PB" -c "Add :CFBundleURLTypes:1:CFBundleURLName string com.yuedu.import" "$PLIST" 2>/dev/null || true
  "$PB" -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" "$PLIST" 2>/dev/null || true
  "$PB" -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string yuedu" "$PLIST" 2>/dev/null || true
fi

# 注入 LegadoBridge（仅 legado-debug）
if [[ "$VARIANT" == "legado-debug" ]]; then
  cp "$BRIDGE_DYLIB" "$FRAMEWORKS/LegadoBridge"
  if command -v insert_dylib &>/dev/null; then
    INSERT_DYLIB="$(command -v insert_dylib)"
    BACKUP="$BIN.backup"
    cp "$BIN" "$BACKUP"
    if ! "$INSERT_DYLIB" --inplace --all-yes --strip-codesig "@executable_path/Frameworks/LegadoBridge" "$BIN"; then
      echo "FAIL: insert_dylib LegadoBridge"
      mv "$BACKUP" "$BIN"
      exit 1
    fi
    rm -f "$BACKUP"
    echo "==> insert_dylib LegadoBridge OK"
  else
    echo "FAIL: insert_dylib 不可用"
    exit 1
  fi
fi

# 注入 LegadoBridgeDebug（两变体均有）
cp "$DEBUG_DYLIB" "$FRAMEWORKS/LegadoBridgeDebug"
if command -v insert_dylib &>/dev/null; then
  INSERT_DYLIB="$(command -v insert_dylib)"
  BACKUP="$BIN.backup"
  cp "$BIN" "$BACKUP"
  if ! "$INSERT_DYLIB" --inplace --all-yes --strip-codesig "@executable_path/Frameworks/LegadoBridgeDebug" "$BIN"; then
    echo "FAIL: insert_dylib LegadoBridgeDebug"
    mv "$BACKUP" "$BIN"
    exit 1
  fi
  rm -f "$BACKUP"
  echo "==> insert_dylib LegadoBridgeDebug OK"
else
  echo "FAIL: insert_dylib 不可用"
  exit 1
fi

# 写入身份 manifest（Bundle + Documents 预置副本供 MCP 读取）
MANIFEST_ARGS=(
  python3 "$ROOT/tools/repack/manifest.py"
  --out "$APP/reader-build-manifest.json"
  --variant "$VARIANT"
  --git-commit "$GIT_COMMIT"
  --github-run-id "$GITHUB_RUN_ID"
  --base-ipa "$IPA_IN"
  --app-binary "$BIN"
  --legado-debug "$FRAMEWORKS/LegadoBridgeDebug"
  --built-at-utc "$BUILT_AT_UTC"
)
if [[ "$VARIANT" == "legado-debug" ]]; then
  MANIFEST_ARGS+=(--legado-bridge "$FRAMEWORKS/LegadoBridge")
fi
"${MANIFEST_ARGS[@]}"

# Documents 副本：随包装入，首次启动前 MCP 可通过 data container 读到（若存在预置路径则跳过）
# 实际设备上通过 Bundle 路径读取；此处额外写入 app 内固定名供 unzip 校验
cp "$APP/reader-build-manifest.json" "$APP/reader-build-manifest.bundle.json"

rm -rf "$APP/_CodeSignature"
pushd "$WORK" >/dev/null
zip -qr "$OUT" Payload
popd >/dev/null

if command -v shasum &>/dev/null; then
  shasum -a 256 "$OUT" | tee "$OUT.sha256"
elif command -v sha256sum &>/dev/null; then
  sha256sum "$OUT" | tee "$OUT.sha256"
fi

VERIFY="$ROOT/tools/repack/verify_forensics_ipa.sh"
chmod +x "$VERIFY"
bash "$VERIFY" "$OUT" "$VARIANT"

echo "==> forensics 完成: $OUT"
