#!/usr/bin/env bash
# =============================================================================
# fly-secrets-sync.sh — 从各 API 项目本地 .env 同步 Fly.io secrets
# =============================================================================
#
# 用途：
#   把 supports/starcat-*-api/.env 里的生产相关变量，通过 `fly secrets set`
#   推到对应 Fly App。避免手抄 key 出错。
#
# 设计约束：
#   - 只读取「Fly 生产必须/建议配置」的 key，不 source 整个 .env（wiki 的
#     PROBE_USER_AGENT 含括号，bash source 会 parse error）。
#   - STORE_FILE / REPO_DIR 在 Fly 上强制覆盖为 /data/*（与 fly.toml volume 挂载一致）。
#   - sharing 的 BASE_URL 在 Fly 上强制为 https://starcat-sharing-api.fly.dev
#     （本地 .env 常见 localhost，不能直接同步）。
#   - trending / weekly 的 WIKI_API_URL 在 Fly 上强制为
#     https://starcat-wiki-api.fly.dev（本地 .env 常见 127.0.0.1:5004，不能直接同步）。
#     仅当 .env 配置了 WIKI_API_KEY 时才同步 wiki 预热相关 secrets。
#   - 密钥值只传给 fly CLI，脚本不 echo 明文。
#
# 用法：
#   bash supports/scripts/fly-secrets-sync.sh starcat-sharing-api
#   bash supports/scripts/fly-secrets-sync.sh starcat-trending-api
#   bash supports/scripts/fly-secrets-sync.sh starcat-weekly-api
#   bash supports/scripts/fly-secrets-sync.sh starcat-wiki-api
#   bash supports/scripts/fly-secrets-sync.sh starcat-discovery-api
#
# 依赖：flyctl、各项目目录下已有 .env（从 .env.example 复制并填值）
# =============================================================================

set -euo pipefail

# wiki-api 在 Fly 上是独立 App；trending / weekly 预热时不能沿用本地 127.0.0.1:5004。
FLY_WIKI_API_URL="https://starcat-wiki-api.fly.dev"

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "Usage: $0 <fly-app-name>" >&2
  echo "  e.g. starcat-trending-api" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SUPPORTS_DIR/$APP/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found" >&2
  echo "  cp $SUPPORTS_DIR/$APP/.env.example $ENV_FILE" >&2
  exit 1
fi

# 从 .env 读取单个 key（取首个匹配行，保留 = 后的完整值）
read_env_val() {
  local key="$1"
  local line
  line="$(grep -E "^${key}=" "$ENV_FILE" | head -1 || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi
  printf '%s' "${line#*=}"
}

require_env_val() {
  local key="$1"
  local val
  if ! val="$(read_env_val "$key")"; then
    echo "Error: $ENV_FILE missing required key: $key" >&2
    exit 1
  fi
  if [[ -z "${val// }" ]]; then
    echo "Error: $ENV_FILE has empty value for: $key" >&2
    exit 1
  fi
  printf '%s' "$val"
}

echo ">>> Syncing fly secrets for $APP (from .env, values redacted in output)"

case "$APP" in
  starcat-sharing-api)
    API_KEYS="$(require_env_val API_KEYS)"
    fly secrets set -a "$APP" \
      "API_KEYS=$API_KEYS" \
      "STORE_FILE=/data/sharing.db" \
      "BASE_URL=https://starcat-sharing-api.fly.dev"
    ;;
  starcat-trending-api)
    API_KEYS="$(require_env_val API_KEYS)"
    GITHUB_TOKENS="$(require_env_val GITHUB_TOKENS)"
    fly secrets set -a "$APP" \
      "API_KEYS=$API_KEYS" \
      "GITHUB_TOKENS=$GITHUB_TOKENS" \
      "STORE_FILE=/data/trending.db"
    # 可选：wiki 预热（.env 有 WIKI_API_KEY 则同步；URL 强制 Fly 生产地址）
    if WIKI_API_KEY="$(read_env_val WIKI_API_KEY 2>/dev/null || true)" && [[ -n "$WIKI_API_KEY" ]]; then
      fly secrets set -a "$APP" \
        "WIKI_API_URL=$FLY_WIKI_API_URL" \
        "WIKI_API_KEY=$WIKI_API_KEY"
    fi
    ;;
  starcat-weekly-api)
    API_KEYS="$(require_env_val API_KEYS)"
    if GITHUB_TOKENS="$(read_env_val GITHUB_TOKENS 2>/dev/null || true)" && [[ -n "$GITHUB_TOKENS" ]]; then
      GH_SECRET_NAME="GITHUB_TOKENS"
      GH_SECRET_VAL="$GITHUB_TOKENS"
    elif GITHUB_TOKEN="$(read_env_val GITHUB_TOKEN 2>/dev/null || true)" && [[ -n "$GITHUB_TOKEN" ]]; then
      GH_SECRET_NAME="GITHUB_TOKENS"
      GH_SECRET_VAL="$GITHUB_TOKEN"
    else
      echo "Error: $ENV_FILE needs GITHUB_TOKENS or GITHUB_TOKEN" >&2
      exit 1
    fi
    fly secrets set -a "$APP" \
      "API_KEYS=$API_KEYS" \
      "${GH_SECRET_NAME}=${GH_SECRET_VAL}" \
      "STORE_FILE=/data/weekly.db" \
      "REPO_DIR=/data/weekly-repo"
    # 可选 admin key
    if ADMIN_API_KEYS="$(read_env_val ADMIN_API_KEYS 2>/dev/null || true)" && [[ -n "$ADMIN_API_KEYS" ]]; then
      fly secrets set -a "$APP" "ADMIN_API_KEYS=$ADMIN_API_KEYS"
    fi
    # 可选 wiki 预热（.env 有 WIKI_API_KEY 则同步；URL 强制 Fly 生产地址）
    if WIKI_API_KEY="$(read_env_val WIKI_API_KEY 2>/dev/null || true)" && [[ -n "$WIKI_API_KEY" ]]; then
      fly secrets set -a "$APP" \
        "WIKI_API_URL=$FLY_WIKI_API_URL" \
        "WIKI_API_KEY=$WIKI_API_KEY"
    fi
    ;;
  starcat-wiki-api)
    API_KEYS="$(require_env_val API_KEYS)"
    fly secrets set -a "$APP" \
      "API_KEYS=$API_KEYS" \
      "STORE_FILE=/data/wiki.db"
    ;;
  starcat-discovery-api)
    API_KEYS="$(require_env_val API_KEYS)"
    ADMIN_API_KEYS="$(require_env_val ADMIN_API_KEYS)"
    GITHUB_TOKENS="$(require_env_val GITHUB_TOKENS)"
    args=(
      "API_KEYS=$API_KEYS"
      "ADMIN_API_KEYS=$ADMIN_API_KEYS"
      "GITHUB_TOKENS=$GITHUB_TOKENS"
      "STORE_FILE=/data/discovery.db"
    )
    if SYNC_ENABLED="$(read_env_val SYNC_ENABLED 2>/dev/null || true)" && [[ -n "$SYNC_ENABLED" ]]; then
      args+=("SYNC_ENABLED=$SYNC_ENABLED")
    fi
    fly secrets set -a "$APP" "${args[@]}"
    ;;
  *)
    echo "Error: unknown app '$APP'" >&2
    exit 1
    ;;
esac

echo "✓ fly secrets set completed for $APP"
echo "  Verify: fly secrets list -a $APP"
