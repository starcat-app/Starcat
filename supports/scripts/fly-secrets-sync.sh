#!/usr/bin/env bash
# =============================================================================
# fly-secrets-sync.sh — 从本地 .env 同步 Fly.io secrets
# =============================================================================
#
# 用途：
#   把 supports/ 下对应项目的 .env 生产相关变量，通过 `fly secrets set`
#   推到对应 Fly App。避免手抄 key 出错。
#
# 设计约束：
#   - 只读取「Fly 生产必须/建议配置」的 key，不 source 整个 .env（wiki 的
#     PROBE_USER_AGENT 含括号，bash source 会 parse error）。
#   - STORE_FILE / REPO_DIR 在 Fly 上强制覆盖为 /data/*（与 fly.toml volume 挂载一致）。
#     recommend-api 无持久化卷，不同步 STORE_FILE。
#   - sharing 的 BASE_URL 在 Fly 上强制为 https://starcat.ink；公开仓库、OG 与既有
#     AI 分享链接都由阿里云 Nginx 统一代理（本地 .env 常见 localhost，不能直接同步）。
#   - **目标生产架构**：聚合 App `starcat-api`（前缀环境变量 + 分库路径）。
#   - **当前生产**：独立 `starcat-*-api` App 仍需同步；迁移后继续供自托管；
#     trending/weekly 的 WIKI_API_URL 在独立部署时强制为 https://starcat-wiki-api.fly.dev。
#   - 密钥值只传给 fly CLI，脚本不 echo 明文。
#
# 用法：
#   bash supports/scripts/fly-secrets-sync.sh starcat-api
#   bash supports/scripts/fly-secrets-sync.sh starcat-sharing-api   # 当前生产独立 App
#   bash supports/scripts/fly-secrets-sync.sh starcat-trending-api
#   bash supports/scripts/fly-secrets-sync.sh starcat-weekly-api
#   bash supports/scripts/fly-secrets-sync.sh starcat-wiki-api
#   bash supports/scripts/fly-secrets-sync.sh starcat-recommend-api
#   bash supports/scripts/fly-secrets-sync.sh starcat-discovery-api
#
# 依赖：flyctl、目标项目目录下已有 .env（从 .env.example 复制并填值）
# =============================================================================

set -euo pipefail

# 当前独立部署：wiki 仍是单独 App 时，trending/weekly 预热打独立域名。
FLY_WIKI_API_URL_LEGACY="https://starcat-wiki-api.fly.dev"
# 聚合部署：同进程内 wiki；notifier 打本机 loopback + X-SC-Svc（见 trending notifier）。
FLY_AGG_WIKI_API_URL="http://127.0.0.1:8080"

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "Usage: $0 <fly-app-name>" >&2
  echo "  e.g. starcat-api   (目标聚合架构)" >&2
  echo "  e.g. starcat-trending-api   (当前生产独立 App)" >&2
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

first_csv() {
  local raw="$1"
  raw="${raw%%,*}"
  raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$raw"
}

echo ">>> Syncing fly secrets for $APP (from .env, values redacted in output)"

case "$APP" in
  starcat-api)
    SHARED="$(first_csv "$(require_env_val STARCAT_SHARED_API_KEY)")"
    TRENDING_GH="$(require_env_val TRENDING_GITHUB_TOKENS)"
    WEEKLY_GH="$(require_env_val WEEKLY_GITHUB_TOKENS)"
    DISCOVERY_GH="$(require_env_val DISCOVERY_GITHUB_TOKENS)"
    DISCOVERY_ADMIN="$(require_env_val DISCOVERY_ADMIN_API_KEYS)"
    SHARING_GH="$(require_env_val SHARING_GITHUB_TOKENS)"
    RECOMMEND_SIM="$(require_env_val RECOMMEND_SIMREPO_API_KEY)"

    args=(
      "STARCAT_API_SERVICES=all"
      "STARCAT_SHARED_API_KEY=$SHARED"
      "WIKI_API_KEYS=$SHARED"
      "SHARING_API_KEYS=$SHARED"
      "TRENDING_API_KEYS=$SHARED"
      "WEEKLY_API_KEYS=$SHARED"
      "RECOMMEND_API_KEYS=$SHARED"
      "DISCOVERY_API_KEYS=$SHARED"
      "WIKI_STORE_FILE=/data/wiki.db"
      "SHARING_STORE_FILE=/data/sharing.db"
      "TRENDING_STORE_FILE=/data/trending.db"
      "WEEKLY_STORE_FILE=/data/weekly.db"
      "WEEKLY_REPO_DIR=/data/weekly-repo"
      "DISCOVERY_STORE_FILE=/data/discovery.db"
      "SHARING_BASE_URL=https://starcat.ink"
      "SHARING_GITHUB_TOKENS=$SHARING_GH"
      "TRENDING_GITHUB_TOKENS=$TRENDING_GH"
      "WEEKLY_GITHUB_TOKENS=$WEEKLY_GH"
      "DISCOVERY_GITHUB_TOKENS=$DISCOVERY_GH"
      "DISCOVERY_ADMIN_API_KEYS=$DISCOVERY_ADMIN"
      "RECOMMEND_SIMREPO_API_KEY=$RECOMMEND_SIM"
      "TRENDING_WIKI_API_URL=$FLY_AGG_WIKI_API_URL"
      "TRENDING_WIKI_API_KEY=$SHARED"
      "WEEKLY_WIKI_API_URL=$FLY_AGG_WIKI_API_URL"
      "WEEKLY_WIKI_API_KEY=$SHARED"
    )

    if WEEKLY_ADMIN="$(read_env_val WEEKLY_ADMIN_API_KEYS 2>/dev/null || true)" && [[ -n "$WEEKLY_ADMIN" ]]; then
      args+=("WEEKLY_ADMIN_API_KEYS=$WEEKLY_ADMIN")
    fi
    if RECOMMEND_EP="$(read_env_val RECOMMEND_SIMREPO_ENDPOINT 2>/dev/null || true)" && [[ -n "$RECOMMEND_EP" ]]; then
      args+=("RECOMMEND_SIMREPO_ENDPOINT=$RECOMMEND_EP")
    fi

    fly secrets set -a "$APP" "${args[@]}"
    ;;
  starcat-sharing-api)
    # 当前生产：独立部署 App（迁移后仍可自托管）
    API_KEYS="$(require_env_val API_KEYS)"
    GITHUB_TOKENS="$(require_env_val GITHUB_TOKENS)"
    fly secrets set -a "$APP" \
      "API_KEYS=$API_KEYS" \
      "GITHUB_TOKENS=$GITHUB_TOKENS" \
      "STORE_FILE=/data/sharing.db" \
      "BASE_URL=https://starcat.ink"
    ;;
  starcat-trending-api)
    API_KEYS="$(require_env_val API_KEYS)"
    GITHUB_TOKENS="$(require_env_val GITHUB_TOKENS)"
    fly secrets set -a "$APP" \
      "API_KEYS=$API_KEYS" \
      "GITHUB_TOKENS=$GITHUB_TOKENS" \
      "STORE_FILE=/data/trending.db"
    if WIKI_API_KEY="$(read_env_val WIKI_API_KEY 2>/dev/null || true)" && [[ -n "$WIKI_API_KEY" ]]; then
      fly secrets set -a "$APP" \
        "WIKI_API_URL=$FLY_WIKI_API_URL_LEGACY" \
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
    if ADMIN_API_KEYS="$(read_env_val ADMIN_API_KEYS 2>/dev/null || true)" && [[ -n "$ADMIN_API_KEYS" ]]; then
      fly secrets set -a "$APP" "ADMIN_API_KEYS=$ADMIN_API_KEYS"
    fi
    if WIKI_API_KEY="$(read_env_val WIKI_API_KEY 2>/dev/null || true)" && [[ -n "$WIKI_API_KEY" ]]; then
      fly secrets set -a "$APP" \
        "WIKI_API_URL=$FLY_WIKI_API_URL_LEGACY" \
        "WIKI_API_KEY=$WIKI_API_KEY"
    fi
    ;;
  starcat-wiki-api)
    API_KEYS="$(require_env_val API_KEYS)"
    fly secrets set -a "$APP" \
      "API_KEYS=$API_KEYS" \
      "STORE_FILE=/data/wiki.db"
    ;;
  starcat-recommend-api)
    API_KEYS="$(require_env_val API_KEYS)"
    SIMREPO_API_KEY="$(require_env_val SIMREPO_API_KEY)"
    args=(
      "API_KEYS=$API_KEYS"
      "SIMREPO_API_KEY=$SIMREPO_API_KEY"
    )
    for optional_key in SIMREPO_ENDPOINT CACHE_TTL_SUCCESS_SECONDS CACHE_TTL_EMPTY_SECONDS CACHE_TTL_ERROR_SECONDS; do
      if optional_value="$(read_env_val "$optional_key" 2>/dev/null || true)" && [[ -n "$optional_value" ]]; then
        args+=("${optional_key}=${optional_value}")
      fi
    done
    fly secrets set -a "$APP" "${args[@]}"
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
