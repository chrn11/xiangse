#!/usr/bin/env bash
# TC-00B：只读校验 clone IPA + 生成/核对 manifest
# 生产默认不可跳过 codesign；--fixture-mode 仅供纯本地合成测试。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || PYTHON_BIN="python"

CLONE_BUNDLE_ID="com.appbox.StandarReader.legado.test"
CLONE_DISPLAY_NAME="香色阅读·测试"

usage() {
  cat <<'EOF'
用法:
  verify_clone_ipa.sh --ipa <clone.ipa> [--source-ipa <src.ipa>] \
    [--source-main <bundleid>] [--work-root <dir>] [--manifest-out <path>] \
    [--fixture-mode]

拒绝：空路径、非文件、input==source、主 bundle 非固定 clone id、
      display name 不匹配、真实 bundle/scheme/entitlement 残留、
      extension/framework 未映射、manifest 缺字段、
      expected_data_container_isolation != true。

--fixture-mode：跳过真实 codesign 校验，manifest.signatureVerification=fixture_skipped。
EOF
}

emit_err() {
  local code="$1"
  local detail="${2:-}"
  printf '{"ok":false,"error":"%s","detailEnum":%s,"expected_data_container_isolation":true}\n' \
    "$code" "$( [[ -n "$detail" ]] && printf '"%s"' "$detail" || echo null )"
}

IPA=""
SOURCE_IPA=""
SOURCE_MAIN="com.appbox.StandarReader"
WORK_ROOT="${CLONE_WORK_ROOT:-}"
MANIFEST_OUT=""
FIXTURE_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipa) IPA="${2:-}"; shift 2 ;;
    --source-ipa) SOURCE_IPA="${2:-}"; shift 2 ;;
    --source-main) SOURCE_MAIN="${2:-}"; shift 2 ;;
    --work-root) WORK_ROOT="${2:-}"; shift 2 ;;
    --manifest-out) MANIFEST_OUT="${2:-}"; shift 2 ;;
    --fixture-mode) FIXTURE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      # 兼容位置参数：verify_clone_ipa.sh <ipa>
      if [[ -z "$IPA" && -f "$1" ]]; then IPA="$1"; shift; else emit_err "ERR_INTERNAL" "unknown_arg"; exit 2; fi
      ;;
  esac
done

if [[ -z "$IPA" ]]; then
  emit_err "ERR_EMPTY_PATH"
  exit 2
fi
if [[ ! -f "$IPA" ]]; then
  emit_err "ERR_NOT_FILE"
  exit 1
fi
if [[ -n "$SOURCE_IPA" ]]; then
  in_abs="$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"
  src_abs="$(cd "$(dirname "$SOURCE_IPA")" && pwd)/$(basename "$SOURCE_IPA")"
  if [[ "$in_abs" == "$src_abs" ]]; then
    emit_err "ERR_INPUT_EQUALS_OUTPUT"
    exit 1
  fi
fi

if [[ -z "$WORK_ROOT" ]]; then
  RUN_TS="$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo local)"
  WORK_ROOT="$ROOT/.artifacts/test_runs/TC-00B/verify-${RUN_TS}-$$"
fi

norm_wr="$(printf '%s' "$WORK_ROOT" | tr '\\\\' '/')"
case "$norm_wr" in
  [Cc]:/*|/c/*|/cygdrive/[Cc]/*)
    emit_err "ERR_UNSAFE_WORK_ROOT" "c_drive"
    exit 1
    ;;
esac
case "$norm_wr" in
  */AppData/Local/Temp*|*/tmp/*|/tmp/*|/var/folders/*)
    emit_err "ERR_UNSAFE_WORK_ROOT" "default_temp"
    exit 1
    ;;
esac
mkdir -p "$WORK_ROOT"

PY=(
  "$PYTHON_BIN" "$ROOT/tools/ci/test_clone_packaging.py"
  --mode verify
  --ipa "$IPA"
  --source-main "$SOURCE_MAIN"
  --work-root "$WORK_ROOT"
  --repo-root "$ROOT"
)
[[ -n "$SOURCE_IPA" ]] && PY+=(--source-ipa "$SOURCE_IPA")
[[ -n "$MANIFEST_OUT" ]] && PY+=(--manifest-out "$MANIFEST_OUT")
[[ "$FIXTURE_MODE" -eq 1 ]] && PY+=(--fixture-mode)

set +e
OUT="$("${PY[@]}" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
if [[ "$RC" -ne 0 ]]; then
  exit "$RC"
fi

# 生产路径：额外 codesign 校验（非 fixture）
if [[ "$FIXTURE_MODE" -eq 0 ]]; then
  if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]] || ! command -v codesign >/dev/null 2>&1; then
    emit_err "ERR_MISSING_MACOS_TOOLS" "codesign_verify_unavailable"
    echo "BLOCKER: 生产校验需要 macOS codesign；fixture 结果不能当作生产 packaging pass。" >&2
    exit 1
  fi
  VERIFY_DIR="$WORK_ROOT/cs-extract"
  rm -rf "$VERIFY_DIR"
  mkdir -p "$VERIFY_DIR"
  unzip -q "$IPA" -d "$VERIFY_DIR"
  APP="$(find "$VERIFY_DIR/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
  if [[ -z "$APP" ]]; then
    emit_err "ERR_NO_APP_BUNDLE"
    exit 1
  fi
  # 深度校验签名对象；失败则非零。不打印完整 entitlements。
  if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
    emit_err "ERR_INTERNAL" "codesign_verify_failed"
    exit 1
  fi
  # 主 identity 摘要（仅标识符，无证书私钥）
  CS_ID="$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/.*Identifier=\(.*\)/\1/p' | head -1 || true)"
  if [[ -n "$CS_ID" && "$CS_ID" != "$CLONE_BUNDLE_ID" ]]; then
    emit_err "ERR_MAIN_BUNDLE_ID" "codesign_identifier"
    exit 1
  fi
  # 若有 manifest-out，将 signatureVerification 升为 codesign_ok（不写完整 profile）
  if [[ -n "$MANIFEST_OUT" && -f "$MANIFEST_OUT" ]]; then
    "$PYTHON_BIN" - <<PY
import json
from pathlib import Path
p = Path(r"$MANIFEST_OUT")
m = json.loads(p.read_text(encoding="utf-8"))
m["signatureVerification"] = "codesign_ok"
req = [
  "schemaVersion","kind","sourceIpaSha256","outputIpaSha256","mainBundleId",
  "displayName","bundleIds","machOUuids","entitlementHashes","signedObjects",
  "expected_data_container_isolation","signatureVerification"
]
missing = [k for k in req if k not in m]
if missing:
    raise SystemExit(1)
if m.get("expected_data_container_isolation") is not True:
    raise SystemExit(2)
if m.get("mainBundleId") != "$CLONE_BUNDLE_ID":
    raise SystemExit(3)
p.write_text(json.dumps(m, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
print("manifest_signatureVerification=codesign_ok")
PY
  fi
fi

echo "==> verify_clone_ipa 通过 (bundle=$CLONE_BUNDLE_ID display=$CLONE_DISPLAY_NAME fixture=$FIXTURE_MODE)" >&2
exit 0
