#!/usr/bin/env bash
# 从 legado-ios 同步引擎源码到 LegadoBridge/Vendor
set -euo pipefail

LEGADO_IOS_ROOT="${LEGADO_IOS_ROOT:-../legado-ios}"
VENDOR_ROOT="$(cd "$(dirname "$0")/.." && pwd)/LegadoBridge/Sources/LegadoBridge/Vendor"

paths=(
  "Core/RuleEngine"
  "Core/Network/AnalyzeUrl.swift"
  "Core/Network/DecompressInterceptor.swift"
  "Core/Network/BackstageWebView.swift"
  "Core/Network/ConcurrentRateLimiter.swift"
  "Core/Network/CookieManager.swift"
  "Core/Network/StrResponse.swift"
  "Core/Model/BookSourcePart.swift"
  "Core/Utils/LegadoExceptions.swift"
  "Core/Utils/ChineseUtils.swift"
)

mkdir -p "$VENDOR_ROOT"
for rel in "${paths[@]}"; do
  src="$LEGADO_IOS_ROOT/$rel"
  if [[ ! -e "$src" ]]; then
    echo "WARN: 跳过缺失 $src" >&2
    continue
  fi
  dest="$VENDOR_ROOT/$rel"
  mkdir -p "$(dirname "$dest")"
  if [[ -d "$src" ]]; then
    rm -rf "$dest"
    cp -R "$src" "$dest"
  else
    cp "$src" "$dest"
  fi
  echo "已同步: $rel"
done
echo "同步完成 -> $VENDOR_ROOT"
