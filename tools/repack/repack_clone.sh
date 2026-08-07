#!/usr/bin/env bash
# TC-00B：独立 clone identity 重打包（禁止同 bundle debug 退化）
# 固定：CFBundleIdentifier=com.appbox.StandarReader.legado.test
#       CFBundleDisplayName=香色阅读·测试
# 真实 codesign 仅在 macOS + 显式 identity/profile 下执行；Windows/缺工具 → blocker。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || PYTHON_BIN="python"

CLONE_BUNDLE_ID="com.appbox.StandarReader.legado.test"
ERR_MISSING_MACOS_TOOLS="ERR_MISSING_MACOS_TOOLS"
ERR_MISSING_SIGNING_IDENTITY="ERR_MISSING_SIGNING_IDENTITY"
ERR_MISSING_PROFILE="ERR_MISSING_PROFILE"
ERR_EMPTY_PATH="ERR_EMPTY_PATH"
ERR_UNSAFE_WORK_ROOT="ERR_UNSAFE_WORK_ROOT"
ERR_PROFILE_DISALLOWS_CLONE="ERR_PROFILE_DISALLOWS_CLONE"

usage() {
  cat <<'EOF'
用法:
  repack_clone.sh --ipa <in.ipa> --out <out.ipa> \
    --identity <codesigning-identity> --profile <embedded.mobileprovision|allowlist.json> \
    [--allowlist <allowlist.json>] [--source-main <bundleid>] [--team-id <TEAM>] \
    [--work-root <dir>] [--manifest-out <path>] [--fixture-mode] [--source-entitlements <json>]

环境:
  CLONE_WORK_ROOT  显式工作根（须非 C 盘、非系统默认 temp；推荐仓库 .artifacts/...）
  PYTHON_BIN       Python 解释器（默认 python3）

说明:
  - 输入 IPA 只读复制到唯一工作目录后解包；不得原地改源、不得覆盖已存在输出。
  - 遍历 Payload 下主 app / appex / framework 的 Info.plist。
  - URL scheme：每个源 scheme → <old>.legado.test；源无 scheme 则不发明。
  - profile/allowlist 不允许 clone bundle 或 access group 时立即停止（不复用真实 group）。
  - 重签名顺序：嵌套 framework/extension → 主 app。
  - 完成后调用 verify_clone_ipa.sh。
EOF
}

emit_err() {
  local code="$1"
  local detail="${2:-}"
  printf '{"ok":false,"error":"%s","detailEnum":%s}\n' "$code" "$( [[ -n "$detail" ]] && printf '"%s"' "$detail" || echo null )"
}

IPA_IN=""
IPA_OUT=""
IDENTITY=""
PROFILE=""
ALLOWLIST=""
SOURCE_MAIN="com.appbox.StandarReader"
TEAM_ID=""
WORK_ROOT="${CLONE_WORK_ROOT:-}"
MANIFEST_OUT=""
FIXTURE_MODE=0
SOURCE_ENTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipa) IPA_IN="${2:-}"; shift 2 ;;
    --out) IPA_OUT="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --allowlist) ALLOWLIST="${2:-}"; shift 2 ;;
    --source-main) SOURCE_MAIN="${2:-}"; shift 2 ;;
    --team-id) TEAM_ID="${2:-}"; shift 2 ;;
    --work-root) WORK_ROOT="${2:-}"; shift 2 ;;
    --manifest-out) MANIFEST_OUT="${2:-}"; shift 2 ;;
    --source-entitlements) SOURCE_ENTS="${2:-}"; shift 2 ;;
    --fixture-mode) FIXTURE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) emit_err "ERR_INTERNAL" "unknown_arg"; usage; exit 2 ;;
  esac
done

if [[ -z "$IPA_IN" || -z "$IPA_OUT" ]]; then
  emit_err "$ERR_EMPTY_PATH"
  usage
  exit 2
fi

# 工作根：显式或仓库 .artifacts
if [[ -z "$WORK_ROOT" ]]; then
  RUN_TS="$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo local)"
  WORK_ROOT="$ROOT/.artifacts/test_runs/TC-00B/repack-${RUN_TS}-$$"
fi

# 拒绝 C 盘 / 默认 temp（bash 侧初筛；Python 再校验）
norm_wr="$(printf '%s' "$WORK_ROOT" | tr '\\\\' '/')"
case "$norm_wr" in
  [Cc]:/*|/c/*|/cygdrive/[Cc]/*)
    emit_err "$ERR_UNSAFE_WORK_ROOT" "c_drive"
    exit 1
    ;;
esac
case "$norm_wr" in
  */AppData/Local/Temp*|*/AppData/Local/temp*|*/tmp/*|/tmp/*|/var/folders/*)
    emit_err "$ERR_UNSAFE_WORK_ROOT" "default_temp"
    exit 1
    ;;
esac

mkdir -p "$WORK_ROOT"

PY_ARGS=(
  "$PYTHON_BIN" "$ROOT/tools/ci/test_clone_packaging.py"
  --mode repack
  --ipa "$IPA_IN"
  --out "$IPA_OUT"
  --source-main "$SOURCE_MAIN"
  --work-root "$WORK_ROOT"
  --repo-root "$ROOT"
)
[[ -n "$TEAM_ID" ]] && PY_ARGS+=(--team-id "$TEAM_ID")
[[ -n "$ALLOWLIST" ]] && PY_ARGS+=(--allowlist "$ALLOWLIST")
[[ -n "$MANIFEST_OUT" ]] && PY_ARGS+=(--manifest-out "$MANIFEST_OUT")
[[ -n "$SOURCE_ENTS" ]] && PY_ARGS+=(--source-entitlements "$SOURCE_ENTS")
[[ -n "$IDENTITY" ]] && PY_ARGS+=(--signing-identity "$IDENTITY")
[[ -n "$PROFILE" ]] && PY_ARGS+=(--profile "$PROFILE")

if [[ "$FIXTURE_MODE" -eq 1 ]]; then
  PY_ARGS+=(--fixture-mode)
  echo "==> fixture-mode：仅结构变换，跳过真实 codesign" >&2
  "${PY_ARGS[@]}"
  VERIFY_ARGS=(
    bash "$ROOT/tools/repack/verify_clone_ipa.sh"
    --ipa "$IPA_OUT"
    --source-ipa "$IPA_IN"
    --source-main "$SOURCE_MAIN"
    --work-root "$WORK_ROOT/verify"
    --fixture-mode
  )
  [[ -n "$MANIFEST_OUT" ]] && VERIFY_ARGS+=(--manifest-out "$MANIFEST_OUT")
  "${VERIFY_ARGS[@]}"
  exit $?
fi

# 生产路径：必须显式 identity + profile
if [[ -z "$IDENTITY" ]]; then
  emit_err "$ERR_MISSING_SIGNING_IDENTITY"
  exit 1
fi
if [[ -z "$PROFILE" || ! -f "$PROFILE" ]]; then
  emit_err "$ERR_MISSING_PROFILE"
  exit 1
fi

# allowlist：若 --allowlist 未给，尝试用 profile 旁路 JSON；.mobileprovision 需 macOS security
if [[ -z "$ALLOWLIST" ]]; then
  if [[ "$PROFILE" == *.json ]]; then
    ALLOWLIST="$PROFILE"
  else
    ALLOWLIST="$WORK_ROOT/derived-allowlist.json"
  fi
fi

# macOS 工具门禁
NEED_TOOLS=(codesign security /usr/libexec/PlistBuddy unzip zip)
MISSING=0
for t in "${NEED_TOOLS[@]}"; do
  if [[ "$t" == /* ]]; then
    [[ -x "$t" ]] || MISSING=1
  else
    command -v "$t" >/dev/null 2>&1 || MISSING=1
  fi
done
if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]] || [[ "$MISSING" -eq 1 ]]; then
  emit_err "$ERR_MISSING_MACOS_TOOLS" "production_codesign_unavailable"
  echo "BLOCKER: 生产 clone 重签名需要 macOS codesign/security；当前环境不可用。不得退化为同 bundle debug。" >&2
  exit 1
fi

# 若 profile 为 mobileprovision，导出 entitlements 摘要到 allowlist（不写私钥）
if [[ "$PROFILE" == *.mobileprovision || "$PROFILE" == *.provisionprofile ]]; then
  DEC="$WORK_ROOT/profile.decoded.plist"
  security cms -D -i "$PROFILE" > "$DEC" 2>/dev/null || {
    emit_err "$ERR_PROFILE_DISALLOWS_CLONE" "profile_decode"
    exit 1
  }
  # 由 Python 结构阶段消费 allowlist；此处生成最小 allowlist
  if [[ ! -f "$ALLOWLIST" ]]; then
    "$PYTHON_BIN" - <<PY
import json, plistlib, pathlib
p = plistlib.loads(pathlib.Path(r"$DEC").read_bytes())
ents = p.get("Entitlements") or {}
team = (p.get("TeamIdentifier") or [""])[0]
app_id = ents.get("application-identifier", "")
allowed = []
if app_id:
    allowed.append(app_id)
# 通配仅当 profile 本身为 team.* 
if app_id.endswith(".*"):
    allowed.append(app_id)
kc = ents.get("keychain-access-groups") or []
ag = ents.get("com.apple.security.application-groups") or []
# fail-closed：必须显式包含 clone id，不得自动加入真实 id 冒充允许
clone = "$CLONE_BUNDLE_ID"
team = team or ""
data = {
  "teamId": team,
  "allowedApplicationIdentifiers": list(allowed),
  "allowedKeychainAccessGroups": list(kc),
  "allowedApplicationGroups": list(ag),
}
# 若 profile 未包含 clone，保留原样 → Python assert 将失败
pathlib.Path(r"$ALLOWLIST").write_text(json.dumps(data, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
print("allowlist_derived")
PY
  fi
fi

PY_ARGS+=(--allowlist "$ALLOWLIST")
# 生产路径：先做结构（仍走 fixture 结构引擎），再 codesign
# 注意：Python repack 在非 fixture 会因 MISSING_MACOS_TOOLS 失败；此处强制结构阶段用 fixture 标志，签名由本脚本负责
STRUCT_OUT="$WORK_ROOT/struct-out.ipa"
rm -f "$STRUCT_OUT"
STRUCT_ARGS=(
  "$PYTHON_BIN" "$ROOT/tools/ci/test_clone_packaging.py"
  --mode repack
  --ipa "$IPA_IN"
  --out "$STRUCT_OUT"
  --source-main "$SOURCE_MAIN"
  --work-root "$WORK_ROOT/struct"
  --repo-root "$ROOT"
  --allowlist "$ALLOWLIST"
  --fixture-mode
)
[[ -n "$TEAM_ID" ]] && STRUCT_ARGS+=(--team-id "$TEAM_ID")
[[ -n "$SOURCE_ENTS" ]] && STRUCT_ARGS+=(--source-entitlements "$SOURCE_ENTS")
"${STRUCT_ARGS[@]}"

# 解包结构产物并按嵌套→主 重签
SIGN_ROOT="$WORK_ROOT/sign"
rm -rf "$SIGN_ROOT"
mkdir -p "$SIGN_ROOT"
unzip -q "$STRUCT_OUT" -d "$SIGN_ROOT"
PAYLOAD="$SIGN_ROOT/Payload"
APP="$(find "$PAYLOAD" -maxdepth 1 -name '*.app' -type d | head -1)"
if [[ -z "$APP" ]]; then
  emit_err "ERR_NO_APP_BUNDLE"
  exit 1
fi

# 收集签名对象：framework → appex → app
mapfile -t FW_BUNDLES < <(find "$APP" -type d -name '*.framework' 2>/dev/null | sort)
mapfile -t EXT_BUNDLES < <(find "$APP" -type d -name '*.appex' 2>/dev/null | sort)

sign_one() {
  local bundle="$1"
  local ent="$bundle/clone-entitlements.plist"
  if [[ ! -f "$ent" ]]; then
    ent="$bundle/entitlements.plist"
  fi
  if [[ ! -f "$ent" ]]; then
    emit_err "ERR_ENTITLEMENT_NOT_ISOLATED" "missing_for_sign"
    exit 1
  fi
  # 不打印 entitlement 内容
  codesign --force --sign "$IDENTITY" --entitlements "$ent" --timestamp=none "$bundle"
}

for b in "${FW_BUNDLES[@]:-}"; do
  [[ -n "${b:-}" ]] || continue
  sign_one "$b"
done
for b in "${EXT_BUNDLES[@]:-}"; do
  [[ -n "${b:-}" ]] || continue
  sign_one "$b"
done
sign_one "$APP"

# 嵌入 profile（不输出私钥）
cp "$PROFILE" "$APP/embedded.mobileprovision" 2>/dev/null || true

if [[ -e "$IPA_OUT" ]]; then
  emit_err "ERR_OUTPUT_EXISTS"
  exit 1
fi
mkdir -p "$(dirname "$IPA_OUT")"
( cd "$SIGN_ROOT" && zip -qr "$IPA_OUT" Payload )

VERIFY=(
  bash "$ROOT/tools/repack/verify_clone_ipa.sh"
  --ipa "$IPA_OUT"
  --source-ipa "$IPA_IN"
  --source-main "$SOURCE_MAIN"
  --work-root "$WORK_ROOT/verify"
)
[[ -n "$MANIFEST_OUT" ]] && VERIFY+=(--manifest-out "$MANIFEST_OUT")
"${VERIFY[@]}"
echo "==> clone repack 完成（identity=$CLONE_BUNDLE_ID）" >&2
