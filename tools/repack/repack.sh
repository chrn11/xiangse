#!/usr/bin/env bash
# 重打包香色闺阁 IPA 并注入 LegadoBridge（macOS / CI 使用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IPA_IN_RAW="${1:-$ROOT/ipa/香色闺阁2.56.1_未加密.ipa}"
DYLIB_RAW="${2:-$ROOT/LegadoBridge/.build/Build/Products/Release-iphoneos/LegadoBridge.framework/LegadoBridge}"
OUT_RAW="${3:-$ROOT/dist/StandarReader-legado-bridge.ipa}"
DEBUG_DYLIB_RAW="${4:-${DEBUG_DYLIB:-}}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"

# 解析为绝对路径，避免 pushd 后相对路径失效
IPA_IN="$(cd "$(dirname "$IPA_IN_RAW")" 2>/dev/null && echo "$(pwd)/$(basename "$IPA_IN_RAW")")"
[[ -z "$IPA_IN" ]] && IPA_IN="$IPA_IN_RAW"
DYLIB="$DYLIB_RAW"
OUT="$(cd "$(dirname "$OUT_RAW")" 2>/dev/null && echo "$(pwd)/$(basename "$OUT_RAW")")"
[[ -z "$OUT" ]] && OUT="$OUT_RAW"
DEBUG_DYLIB="$DEBUG_DYLIB_RAW"
if [[ -n "$DEBUG_DYLIB" && ! "$DEBUG_DYLIB" = /* ]]; then
  DEBUG_DYLIB="$(cd "$(dirname "$DEBUG_DYLIB")" 2>/dev/null && echo "$(pwd)/$(basename "$DEBUG_DYLIB")")"
fi
WORK="$ROOT/analysis/repack-work"

echo "==> 输入 IPA: $IPA_IN"
echo "==> 注入库:   $DYLIB"
if [[ -n "$DEBUG_DYLIB" ]]; then
  echo "==> 调试库:   $DEBUG_DYLIB"
fi
echo "==> 输出:     $OUT"

if [[ ! -f "$IPA_IN" ]]; then
  echo "WARN: IPA 不存在，跳过重打包: $IPA_IN"
  echo "      将 IPA 放入 ipa/ 目录后重新运行"
  exit 0
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$ROOT/dist"

cp "$IPA_IN" "$WORK/payload.zip"
unzip -q "$WORK/payload.zip" -d "$WORK"

APP="$WORK/Payload/StandarReader.app"
BIN="$APP/StandarReader"
FRAMEWORKS="$APP/Frameworks"
mkdir -p "$FRAMEWORKS"

INJECTED=0
if [[ -f "$DYLIB" ]]; then
  cp "$DYLIB" "$FRAMEWORKS/LegadoBridge"
  INJECTED=1
elif [[ -d "${DYLIB%.framework}" ]] || [[ -d "$(dirname "$DYLIB")" ]]; then
  FRAME_SRC="$(dirname "$DYLIB")"
  if [[ "$(basename "$FRAME_SRC")" == "LegadoBridge.framework" ]]; then
    cp -R "$FRAME_SRC" "$FRAMEWORKS/"
    INJECTED=1
  else
    cp "$DYLIB" "$FRAMEWORKS/LegadoBridge" 2>/dev/null || true
    [[ -f "$FRAMEWORKS/LegadoBridge" ]] && INJECTED=1
  fi
else
  echo "WARN: 未找到 LegadoBridge 产物，将仅写入注入标记 manifest（需 CI 编译后重跑）"
fi

MANIFEST="$APP/legado-bridge-manifest.plist"
cat > "$MANIFEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>LegadoBridgeVersion</key><string>1.0.0-mvp</string>
  <key>InjectPath</key><string>@executable_path/Frameworks/LegadoBridge</string>
  <key>BuiltAt</key><string>$(date -u +%Y-%m-%dT%H:%M:%SZ)</string>
</dict></plist>
EOF

# 注入 URL scheme：legado:// 和 yuedu://（用于远程一键导入书源）
PLIST="$APP/Info.plist"
if command -v /usr/libexec/PlistBuddy &>/dev/null && [[ -f "$PLIST" ]]; then
  PB=/usr/libexec/PlistBuddy
  # 如果 CFBundleURLTypes 不存在则创建
  "$PB" -c "Add :CFBundleURLTypes array" "$PLIST" 2>/dev/null || true
  # legado scheme
  "$PB" -c "Add :CFBundleURLTypes:0 dict" "$PLIST"
  "$PB" -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.legado.import" "$PLIST"
  "$PB" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST"
  "$PB" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string legado" "$PLIST"
  # yuedu scheme（兼容旧格式）
  "$PB" -c "Add :CFBundleURLTypes:1 dict" "$PLIST"
  "$PB" -c "Add :CFBundleURLTypes:1:CFBundleURLName string com.yuedu.import" "$PLIST"
  "$PB" -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" "$PLIST"
  "$PB" -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string yuedu" "$PLIST"
  echo "==> PlistBuddy: 注入 legado/yuedu URL scheme 完成"
else
  echo "==> 跳过 URL scheme 注入（PlistBuddy 不可用或 Info.plist 不存在）"
fi

INSERT_OK=0
if command -v insert_dylib &>/dev/null && [[ -f "$FRAMEWORKS/LegadoBridge" || -f "$FRAMEWORKS/LegadoBridge.framework/LegadoBridge" ]]; then
  INSERT_DYLIB="$(command -v insert_dylib)"
  BACKUP="$BIN.backup"
  cp "$BIN" "$BACKUP"
  if "$INSERT_DYLIB" --inplace --all-yes --strip-codesig "@executable_path/Frameworks/LegadoBridge" "$BIN"; then
    INSERT_OK=1
    echo "==> insert_dylib LegadoBridge 完成"
  else
    echo "insert_dylib LegadoBridge 失败，恢复备份"
    mv "$BACKUP" "$BIN"
  fi
  rm -f "$BACKUP"
else
  echo "==> 跳过 insert_dylib LegadoBridge（工具或 dylib 不可用）"
fi

DEBUG_INSERT_OK=0
if [[ -n "$DEBUG_DYLIB" && -f "$DEBUG_DYLIB" ]]; then
  cp "$DEBUG_DYLIB" "$FRAMEWORKS/LegadoBridgeDebug"
  echo "==> 已复制 LegadoBridgeDebug"
  if command -v insert_dylib &>/dev/null; then
    INSERT_DYLIB="$(command -v insert_dylib)"
    BACKUP="$BIN.backup"
    cp "$BIN" "$BACKUP"
    if "$INSERT_DYLIB" --inplace --all-yes --strip-codesig "@executable_path/Frameworks/LegadoBridgeDebug" "$BIN"; then
      DEBUG_INSERT_OK=1
      echo "==> insert_dylib LegadoBridgeDebug 完成"
    else
      echo "insert_dylib LegadoBridgeDebug 失败，恢复备份"
      mv "$BACKUP" "$BIN"
    fi
    rm -f "$BACKUP"
  else
    echo "==> 跳过 insert_dylib LegadoBridgeDebug（insert_dylib 不可用）"
  fi
elif [[ -n "$DEBUG_DYLIB" ]]; then
  echo "WARN: DEBUG_DYLIB 路径不存在: $DEBUG_DYLIB"
fi

# Release 身份契约：写入 reader-build-manifest.json（无 Debug dylib）
if [[ -f "$FRAMEWORKS/LegadoBridge" || -f "$FRAMEWORKS/LegadoBridge.framework/LegadoBridge" ]]; then
  BRIDGE_BIN="$FRAMEWORKS/LegadoBridge"
  [[ -f "$FRAMEWORKS/LegadoBridge.framework/LegadoBridge" ]] && BRIDGE_BIN="$FRAMEWORKS/LegadoBridge.framework/LegadoBridge"
  GIT_COMMIT="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
  RUN_ID="${GITHUB_RUN_ID:-local}"
  if python3 "$ROOT/tools/repack/manifest.py" \
    --out "$APP/reader-build-manifest.json" \
    --variant legado-release \
    --git-commit "$GIT_COMMIT" \
    --github-run-id "$RUN_ID" \
    --base-ipa "$IPA_IN" \
    --app-binary "$BIN" \
    --legado-bridge "$BRIDGE_BIN"; then
    cp "$APP/reader-build-manifest.json" "$APP/reader-build-manifest.bundle.json"
    echo "==> reader-build-manifest.json (legado-release) 已写入"
  else
    echo "WARN: reader-build-manifest.json 写入失败"
  fi
fi

rm -rf "$APP/_CodeSignature"
pushd "$WORK" >/dev/null
zip -qr "$OUT" Payload
popd >/dev/null

if command -v shasum &>/dev/null; then
  shasum -a 256 "$OUT" | tee "$OUT.sha256"
elif command -v sha256sum &>/dev/null; then
  sha256sum "$OUT" | tee "$OUT.sha256"
fi

echo "==> 完成: $OUT"
echo "    TrollStore 安装此 IPA 即可"

# 构建后硬校验：LC_LOAD_DYLIB / arm64 / Scheme / SHA256
if [[ "$SKIP_VERIFY" != "1" ]]; then
  VERIFY="$ROOT/tools/repack/verify_ipa.sh"
  chmod +x "$VERIFY" 2>/dev/null || true
  EXPECT=0
  if [[ "$INJECTED" == "1" && "$INSERT_OK" == "1" ]]; then
    EXPECT=1
  fi
  # 有可用 dylib 输入时要求注入成功
  if [[ -n "$DYLIB" && -f "$DYLIB" ]]; then
    EXPECT=1
  fi
  bash "$VERIFY" "$OUT" "$EXPECT"
fi
