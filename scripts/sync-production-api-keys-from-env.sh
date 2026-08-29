#!/usr/bin/env bash
# =============================================================================
# sync-production-api-keys-from-env.sh
# =============================================================================
#
# 聚合时代（starcat-api）：从 supports/starcat-api/.env 的 STARCAT_SHARED_API_KEY
# （或 TRENDING_API_KEYS 的第一个）读取**同一把** key，**只更新**
# Configs/Secrets.xcconfig 里七个 STARCAT_PRODUCTION_API_KEY_* 行。
#
# ⚠️ 禁止整文件重写：License / OAuth / Aptabase / Sparkle / DEVELOPMENT_TEAM 等
# 其它配置必须原样保留。
#
# 独立部署的 starcat-*-api/.env **不读、不改**。
#
# 用法（Starcat 主仓库根目录）：
#   bash scripts/sync-production-api-keys-from-env.sh
#   make setup-production-api-keys
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORTS_DIR="${ROOT_DIR}/supports"
AGG_ENV="${SUPPORTS_DIR}/starcat-api/.env"
CONFIG="${ROOT_DIR}/Configs/Secrets.xcconfig"
TEMPLATE="${ROOT_DIR}/Configs/Secrets.xcconfig.template"

KEY_RE='^sk-starcat-[A-Z2-7]{32}$'
KEY_NAMES=(
  STARCAT_PRODUCTION_API_KEY_TRENDING
  STARCAT_PRODUCTION_API_KEY_WEEKLY
  STARCAT_PRODUCTION_API_KEY_SHARING
  STARCAT_PRODUCTION_API_KEY_WIKI
  STARCAT_PRODUCTION_API_KEY_RECOMMEND
  STARCAT_PRODUCTION_API_KEY_DISCOVERY
  STARCAT_PRODUCTION_API_KEY_HISTORY
)

# --- 旧逻辑（独立 *.fly.dev / 每仓一把 Key；整文件重写）已废弃，保留注释勿删 ---
# read_first_api_key() { ... 读 supports/starcat-*-api/.env 的 API_KEYS ... }
# cat > "${CONFIG}" <<EOF ... 会冲掉其它 secrets，禁止再启用 ...

read_env_value() {
  local env_file="$1"
  local key="$2"
  local line val
  if [[ ! -f "${env_file}" ]]; then
    echo "Error: missing ${env_file}" >&2
    return 1
  fi
  line="$(grep -E "^${key}=" "${env_file}" | head -1 || true)"
  if [[ -z "${line}" ]]; then
    return 1
  fi
  val="${line#${key}=}"
  val="$(printf '%s' "${val}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  val="${val%%,*}"
  val="$(printf '%s' "${val}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "${val}" ]]; then
    return 1
  fi
  printf '%s' "${val}"
}

read_shared_api_key() {
  local key=""
  if key="$(read_env_value "${AGG_ENV}" "STARCAT_SHARED_API_KEY" 2>/dev/null)"; then
    :
  elif key="$(read_env_value "${AGG_ENV}" "TRENDING_API_KEYS" 2>/dev/null)"; then
    :
  else
    echo "Error: ${AGG_ENV} 缺少 STARCAT_SHARED_API_KEY 或 TRENDING_API_KEYS" >&2
    return 1
  fi
  if ! printf '%s' "${key}" | grep -qE "${KEY_RE}"; then
    echo "Error: invalid shared API key in ${AGG_ENV} (want sk-starcat- + 32 base32 chars)" >&2
    return 1
  fi
  printf '%s' "${key}"
}

upsert_key_line() {
  # 在已有文件中原地替换或追加某一个 KEY = value；不动其它行。
  local file="$1"
  local name="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  python3 - "$file" "$name" "$value" "$tmp" <<'PY'
import re, sys
path, name, value, out = sys.argv[1:5]
text = open(path, encoding="utf-8").read()
lines = text.splitlines(keepends=True)
pat = re.compile(rf"^(\s*){re.escape(name)}\s*=")
found = False
out_lines = []
for line in lines:
    if pat.match(line) and not line.lstrip().startswith("//"):
        # 保留原缩进；写新值
        indent = pat.match(line).group(1)
        out_lines.append(f"{indent}{name} = {value}\n")
        found = True
    else:
        out_lines.append(line if line.endswith("\n") else line + "\n")
if not found:
    if out_lines and not out_lines[-1].endswith("\n"):
        out_lines[-1] += "\n"
    out_lines.append(f"\n{name} = {value}\n")
open(out, "w", encoding="utf-8").writelines(out_lines)
PY
  mv "${tmp}" "${file}"
}

echo ">>> 从 starcat-api/.env 更新 Secrets.xcconfig 七个 API Key（原地替换，保留其它配置）"

SHARED_KEY="$(read_shared_api_key)"

if [[ ! -f "${CONFIG}" ]]; then
  if [[ -f "${TEMPLATE}" ]]; then
    echo "  Secrets.xcconfig 不存在，从 template 复制骨架（其它 secrets 仍需你自行填回）"
    cp "${TEMPLATE}" "${CONFIG}"
  else
    echo "Error: missing ${CONFIG} and template" >&2
    exit 1
  fi
fi

# 备份再改，防再次事故
backup="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
cp "${CONFIG}" "${backup}"
echo "  backup -> ${backup}"

for name in "${KEY_NAMES[@]}"; do
  upsert_key_line "${CONFIG}" "${name}" "${SHARED_KEY}"
done

echo "  ok 七个 STARCAT_PRODUCTION_API_KEY_* <- starcat-api 共用 Key（原地更新）"
echo "ok 其它配置未改动"
echo "  下一步: xcodegen generate && 重新 build App"
