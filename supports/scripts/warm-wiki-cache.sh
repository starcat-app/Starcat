#!/usr/bin/env bash
# =============================================================================
# warm-wiki-cache.sh — 预热 wiki-api 缓存
# =============================================================================
#
# 用法:
#   ./scripts/warm-wiki-cache.sh              # 全量预热（trending + 阮一峰 + zread）
#   ./scripts/warm-wiki-cache.sh --trending   # 仅预热 trending 数据
#   ./scripts/warm-wiki-cache.sh --weekly     # 仅预热 阮一峰 weekly 数据
#   ./scripts/warm-wiki-cache.sh --zread      # 仅预热 zread weekly 数据
#   ./scripts/warm-wiki-cache.sh --dry-run    # 只统计数量，不实际调用 wiki-api
#
# 流程（v2 简化）:
#   1. 从 SQLite 提取 repos，若不够 min 条则触发同步 + 等待
#   2. 分批调用 wiki-api POST /api/v1/wikis/batch（每批 50 个，接口秒返异步探测）
#   3. 打印预热统计
#
# 前置条件:
#   - trending-api (5002)、weekly-api (5003)、wiki-api (5004) 已启动
#   - sqlite3 已安装
#   - 各服务项目根目录 `.env` 已填 API_KEYS，或导出 TRENDING_KEY / WEEKLY_KEY / WIKI_KEY
#     禁止把真实 key 写进本脚本，避免与 start-all.sh 两套真源，也避免提交进 Git。
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORTS_DIR="$(dirname "$SCRIPT_DIR")"

# ---- 配置 ----
TRENDING_API="http://127.0.0.1:5002"
WEEKLY_API="http://127.0.0.1:5003"
WIKI_API="http://127.0.0.1:5004"
WIKI_BATCH_URL="$WIKI_API/api/v1/wikis/batch"

# 参数
POLL_INTERVAL=5
POLL_TIMEOUT=600
BATCH_SIZE=50
MIN_ROWS=5  # 少于这个数就触发同步

# ---- 参数解析 ----
DO_TRENDING=0
DO_WEEKLY=0
DO_ZREAD=0
DRY_RUN=0

case "${1:-}" in
  --trending) DO_TRENDING=1 ;;
  --weekly)   DO_WEEKLY=1 ;;
  --zread)    DO_ZREAD=1 ;;
  --dry-run)  DRY_RUN=1; DO_TRENDING=1; DO_WEEKLY=1; DO_ZREAD=1 ;;
  ""|--all)   DO_TRENDING=1; DO_WEEKLY=1; DO_ZREAD=1 ;;
  -h|--help)
    sed -n '2,23p' "$0"
    exit 0
    ;;
  *)
    echo "未知参数: $1" >&2
    sed -n '2,23p' "$0" >&2
    exit 1
    ;;
esac

# ---- 工具函数 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[warm]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
err()  { echo -e "${RED}  ✘${NC} $1"; }

auth_header() { echo "Authorization: Bearer $1"; }

# 从服务 `.env` 读 API_KEYS 的第一项；环境变量同名覆盖，避免脚本再持有第二份真源。
read_env_api_key() {
  local env_file="$1"
  local line val
  [[ -f "$env_file" ]] || return 1
  line="$(grep -E '^API_KEYS=' "$env_file" | head -1 || true)"
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  val="${val%$'\r'}"
  val="${val#\"}"
  val="${val%\"}"
  val="${val#\'}"
  val="${val%\'}"
  val="${val%%,*}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  [[ -n "$val" ]] || return 1
  printf '%s' "$val"
}

require_service_key() {
  local env_name="$1"
  local service_dir="$2"
  local label="$3"
  local val=""
  if [[ -n "${!env_name:-}" ]]; then
    val="${!env_name}"
  else
    val="$(read_env_api_key "$SUPPORTS_DIR/$service_dir/.env" || true)"
  fi
  if [[ -z "$val" ]]; then
    err "缺少 $label API Key。请导出 $env_name，或在 $service_dir/.env 填写 API_KEYS"
    exit 1
  fi
  printf '%s' "$val"
}

# ---- ensure_data: 确保 DB 有足够数据 ----
# 用法: ensure_data <label> <api_url> <key> <sync_endpoint> <db_path> <sql_count> <poll_url>
ensure_data() {
  local label="$1" api="$2" key="$3" sync_ep="$4" db="$5" sql="$6" poll_url="$7"

  # 1. 先查 DB
  local count=0
  if [ -f "$db" ]; then
    count=$(sqlite3 "$db" "$sql" 2>/dev/null || echo "0")
  fi

  if [ "$count" -ge "$MIN_ROWS" ]; then
    ok "$label DB 已有 $count 条可用记录，跳过同步"
    return 0
  fi

  # 2. 不够 → 触发同步
  log "$label 仅 $count 条，触发同步..."
  curl -s -X POST -H "$(auth_header "$key")" "$api$sync_ep" > /dev/null 2>&1 || true

  # 3. 轮询等待
  log "等待 $label 数据就绪（至少 $MIN_ROWS 条，最长 ${POLL_TIMEOUT}s）..."
  local waited=0
  while [ $waited -lt $POLL_TIMEOUT ]; do
    if [ -f "$db" ]; then
      count=$(sqlite3 "$db" "$sql" 2>/dev/null || echo "0")
      if [ "${count:-0}" -ge "$MIN_ROWS" ]; then
        ok "$label 已就绪: $count 条"
        return 0
      fi
    fi

    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
    if [ $((waited % 30)) -eq 0 ]; then
      log "  仍在等待 $label... (已等 ${waited}s, 当前 $count 条)"
    fi
  done

  warn "$label 等待超时 (${POLL_TIMEOUT}s)，继续预热已有数据"
}

# ---- warm_wiki: 分批调 wiki-api ----
warm_wiki() {
  local label="$1" repos_file="$2"
  local total
  total=$(wc -l < "$repos_file" | tr -d ' ')

  if [ "$total" -eq 0 ]; then
    warn "$label: 没有 repo 需要预热"
    return
  fi

  log "预热 $label: 共 $total 个 repo，每批 $BATCH_SIZE 个（wiki-api 异步探测，秒返）"

  if [ "$DRY_RUN" -eq 1 ]; then
    warn "[dry-run] 跳过实际调用，前 5 个:"
    head -5 "$repos_file" | while read -r r; do echo "    $r"; done
    echo "    ... 共 $total 个"
    return
  fi

  local batch_file batch_json count=0 success=0 fail=0
  batch_file=$(mktemp)
  trap "rm -f $batch_file" RETURN

  while IFS= read -r full_name; do
    [ -z "$full_name" ] && continue
    echo "\"$full_name\"" >> "$batch_file"
    count=$((count + 1))

    if [ $count -eq "$BATCH_SIZE" ] || [ $count -eq "$total" ]; then
      batch_json="{ \"repos\": [$(paste -sd ',' "$batch_file")] }"

      local resp http_code
      resp=$(curl -s -w "\n%{http_code}" -X POST \
        -H "$(auth_header "$WIKI_KEY")" \
        -H "Content-Type: application/json" \
        -d "$batch_json" \
        "$WIKI_BATCH_URL" 2>&1)
      http_code=$(echo "$resp" | tail -1)

      if [ "$http_code" = "200" ]; then
        success=$((success + count))
      else
        fail=$((fail + count))
        warn "batch 失败 (HTTP $http_code): $(echo "$resp" | head -1 | cut -c1-200)"
        sleep 2
      fi

      local done_count=$((success + fail))
      echo -ne "\r  进度: $done_count/$total (成功: $success, 失败: $fail)"

      > "$batch_file"
      count=0
      sleep 1
    fi
  done < "$repos_file"

  echo ""
  ok "$label 预热完成: 成功 $success / 失败 $fail / 总计 $total"
}

TRENDING_KEY="$(require_service_key TRENDING_KEY starcat-trending-api Trending)"
WEEKLY_KEY="$(require_service_key WEEKLY_KEY starcat-weekly-api Weekly)"
WIKI_KEY="$(require_service_key WIKI_KEY starcat-wiki-api Wiki)"

# =============================================================================
# 主流程
# =============================================================================
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  Wiki 缓存预热${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

ALL_REPOS_FILE=$(mktemp)
trap "rm -f $ALL_REPOS_FILE" EXIT

# ---- Trending ----
if [ "$DO_TRENDING" -eq 1 ]; then
  TRENDING_DB="$SUPPORTS_DIR/starcat-trending-api/trending.db"

  ensure_data \
    "Trending" "$TRENDING_API" "$TRENDING_KEY" \
    "/internal/sync/repos" "$TRENDING_DB" \
    "SELECT COUNT(*) FROM trending_repos WHERE is_available=1;" \
    "/api/v1/repos?since=daily"

  TRENDING_REPOS=$(mktemp)
  sqlite3 -separator '/' "$TRENDING_DB" \
    "SELECT DISTINCT owner, name FROM trending_repos WHERE is_available=1;" 2>/dev/null | sort -u > "$TRENDING_REPOS"

  trending_count=$(wc -l < "$TRENDING_REPOS" | tr -d ' ')
  log "从 trending 提取了 $trending_count 个唯一 repo"

  warm_wiki "Trending" "$TRENDING_REPOS"
  cat "$TRENDING_REPOS" >> "$ALL_REPOS_FILE"
  rm -f "$TRENDING_REPOS"
  echo ""
fi

# ---- 阮一峰 Weekly ----
if [ "$DO_WEEKLY" -eq 1 ]; then
  WEEKLY_DB="$SUPPORTS_DIR/starcat-weekly-api/weekly.db"

  ensure_data \
    "阮一峰 Weekly" "$WEEKLY_API" "$WEEKLY_KEY" \
    "/internal/sync/weekly" "$WEEKLY_DB" \
    "SELECT COUNT(*) FROM projects WHERE is_available=1;" \
    "/api/v1/issues"

  WEEKLY_REPOS=$(mktemp)
  sqlite3 -separator '/' "$WEEKLY_DB" \
    "SELECT DISTINCT repo_owner, repo_name FROM projects WHERE is_available=1;" 2>/dev/null | sort -u > "$WEEKLY_REPOS"

  weekly_count=$(wc -l < "$WEEKLY_REPOS" | tr -d ' ')
  log "从阮一峰 Weekly 提取了 $weekly_count 个唯一 repo"

  warm_wiki "阮一峰 Weekly" "$WEEKLY_REPOS"
  cat "$WEEKLY_REPOS" >> "$ALL_REPOS_FILE"
  rm -f "$WEEKLY_REPOS"
  echo ""
fi

# ---- Zread Weekly ----
if [ "$DO_ZREAD" -eq 1 ]; then
  WEEKLY_DB="$SUPPORTS_DIR/starcat-weekly-api/weekly.db"

  ensure_data \
    "Zread Weekly" "$WEEKLY_API" "$WEEKLY_KEY" \
    "/internal/sync/zread" "$WEEKLY_DB" \
    "SELECT COUNT(*) FROM zread_trending;" \
    "/api/v1/zread"

  ZREAD_REPOS=$(mktemp)
  sqlite3 -separator '/' "$WEEKLY_DB" \
    "SELECT DISTINCT owner, name FROM zread_trending;" 2>/dev/null | sort -u > "$ZREAD_REPOS"

  zread_count=$(wc -l < "$ZREAD_REPOS" | tr -d ' ')
  log "从 Zread Weekly 提取了 $zread_count 个唯一 repo"

  warm_wiki "Zread Weekly" "$ZREAD_REPOS"
  cat "$ZREAD_REPOS" >> "$ALL_REPOS_FILE"
  rm -f "$ZREAD_REPOS"
  echo ""
fi

# ---- 汇总 ----
if [ "$DRY_RUN" -eq 0 ]; then
  sort -u "$ALL_REPOS_FILE" -o "$ALL_REPOS_FILE"
  final_count=$(wc -l < "$ALL_REPOS_FILE" | tr -d ' ')
  echo -e "${GREEN}=========================================${NC}"
  echo -e "${GREEN}  预热完成！去重后共 $final_count 个唯一 repo${NC}"
  echo -e "${GREEN}=========================================${NC}"

  WIKI_DB="$SUPPORTS_DIR/starcat-wiki-api/wiki.db"
  if [ -f "$WIKI_DB" ]; then
    wiki_count=$(sqlite3 "$WIKI_DB" "SELECT COUNT(*) FROM doc_probes;" 2>/dev/null || echo "0")
    echo ""
    log "wiki.db 当前 doc_probes 条数: $wiki_count"
    echo "  (3 个 source × $final_count repos = 预期 $((final_count * 3)) 条)"
  fi
fi
