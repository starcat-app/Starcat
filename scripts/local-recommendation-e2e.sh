#!/usr/bin/env bash
#
# local-recommendation-e2e.sh — Starcat 本地自研推荐全链路交互式验证工具。
#
# 该脚本只编排本机 Collection、Recommend、Trainer 和 Starcat Direct 的真实数据链路。
# Starcat 上传仍由用户在客户端触发，脚本负责等待并验证快照、训练产物和服务结果，
# 避免手工复制大量命令时跳过空数据、复用旧进程或丢失 Shell 环境变量。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STARCAT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COLLECTION_ROOT="$STARCAT_ROOT/supports/starcat-collection-api"
RECOMMEND_ROOT="$STARCAT_ROOT/supports/starcat-recommend-api"
TRAINER_ROOT="$STARCAT_ROOT/supports/starcat-recsys-trainer"

RUNS_ROOT="${STARCAT_E2E_RUNS_ROOT:-${TMPDIR:-/tmp}/starcat-recommend-e2e}"
CURRENT_RUN_FILE="$RUNS_ROOT/current-run"
RUN_MARKER=".starcat-recommend-e2e-run"
COLLECTION_PORT=5011
RECOMMEND_PORT=5005

# 这些 key 只用于 127.0.0.1 本机验证，与生产凭据完全隔离。固定值让 Starcat
# Info.plist 和设置页可以跨多次临时运行复用，不需要把凭据写入运行状态文件。
COLLECTION_CLIENT_KEY="local-collection-client-key"
COLLECTION_ADMIN_KEY="local-collection-admin-key"
RECOMMEND_CLIENT_KEY="local-recommend-client-key"
RECOMMEND_PUBLISH_KEY="local-trainer-publish-key"
PARTICIPANT_HMAC_KEY="local-collection-hmac-key-at-least-32-bytes"

info() { printf '\n==> %s\n' "$*"; }
success() { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; return 1; }

pause() {
  printf '\n按 Enter 返回菜单...'
  IFS= read -r _
}

confirm() {
  local prompt="$1" answer
  printf '%s [y/N] ' "$prompt"
  IFS= read -r answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

canonical_directory() {
  (cd -P "$1" 2>/dev/null && pwd)
}

# 删除前必须同时满足：位于专用根目录、名称为 run-*、不是符号链接、存在标识文件。
# 该约束比依赖 glob 更严格，防止变量为空或状态文件损坏时误删其它目录。
is_safe_run_directory() {
  local directory="$1" root_path directory_path
  [ -d "$directory" ] || return 1
  [ ! -L "$directory" ] || return 1
  [ -f "$directory/$RUN_MARKER" ] || return 1
  root_path="$(canonical_directory "$RUNS_ROOT")" || return 1
  directory_path="$(canonical_directory "$directory")" || return 1
  case "$directory_path" in
    "$root_path"/run-*) return 0 ;;
    *) return 1 ;;
  esac
}

state_write() {
  local run_directory="$1" key="$2" value="$3"
  case "$key" in
    *[!a-z0-9-]*) die "非法状态 key：$key" ;;
  esac
  case "$value" in
    *$'\n'*) die "状态值不能包含换行：$key" ;;
  esac
  printf '%s' "$value" >"$run_directory/.state-$key"
}

state_read() {
  local run_directory="$1" key="$2"
  [ -f "$run_directory/.state-$key" ] || return 1
  sed -n '1p' "$run_directory/.state-$key"
}

set_current_run() {
  mkdir -p "$RUNS_ROOT"
  chmod 700 "$RUNS_ROOT"
  printf '%s' "$1" >"$CURRENT_RUN_FILE"
}

current_run() {
  local directory
  [ -f "$CURRENT_RUN_FILE" ] || return 1
  directory="$(sed -n '1p' "$CURRENT_RUN_FILE")"
  is_safe_run_directory "$directory" || return 1
  printf '%s\n' "$directory"
}

phase_rank() {
  case "$1" in
    created) printf '0' ;;
    built) printf '1' ;;
    collection-ready) printf '2' ;;
    snapshot-ready) printf '3' ;;
    recommend-ready) printf '4' ;;
    trained) printf '5' ;;
    complete) printf '6' ;;
    *) printf '%s' '-1' ;;
  esac
}

phase_at_least() {
  local run_directory="$1" expected="$2" actual
  actual="$(state_read "$run_directory" phase 2>/dev/null || printf 'created')"
  [ "$(phase_rank "$actual")" -ge "$(phase_rank "$expected")" ]
}

advance_phase() {
  local run_directory="$1" expected="$2"
  if ! phase_at_least "$run_directory" "$expected"; then
    state_write "$run_directory" phase "$expected"
  fi
}

create_run() {
  local directory model_version
  mkdir -p "$RUNS_ROOT"
  chmod 700 "$RUNS_ROOT"
  directory="$(mktemp -d "$RUNS_ROOT/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
  chmod 700 "$directory"
  : >"$directory/$RUN_MARKER"
  mkdir -p "$directory/logs"
  model_version="local-recommend-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  state_write "$directory" phase created
  state_write "$directory" model-version "$model_version"
  state_write "$directory" created-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set_current_run "$directory"
  printf '%s\n' "$directory"
}

pid_is_running() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

pid_belongs_to_run() {
  local pid="$1" run_directory="$2" command_line
  pid_is_running "$pid" || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    "$run_directory"/*) return 0 ;;
    *) return 1 ;;
  esac
}

stop_run_process() {
  local run_directory="$1" service="$2" pid
  pid="$(state_read "$run_directory" "$service-pid" 2>/dev/null || true)"
  [ -n "$pid" ] || return 0
  if ! pid_is_running "$pid"; then
    return 0
  fi
  if ! pid_belongs_to_run "$pid" "$run_directory"; then
    warn "$service PID $pid 不属于本次运行，拒绝停止。"
    return 1
  fi
  kill "$pid"
  local attempt
  for attempt in {1..50}; do
    pid_is_running "$pid" || break
    sleep 0.1
  done
  if pid_is_running "$pid"; then
    warn "$service PID $pid 未在 5 秒内退出；未使用 SIGKILL。"
    return 1
  fi
  success "$service 已停止（PID ${pid}）"
}

stop_run_services() {
  local run_directory="$1"
  stop_run_process "$run_directory" recommend || true
  stop_run_process "$run_directory" collection || true
}

port_listeners() {
  lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | sort -u
}

ensure_port_available() {
  local port="$1" listeners pid
  listeners="$(port_listeners "$port" || true)"
  [ -z "$listeners" ] && return 0

  warn "端口 $port 已被占用："
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    ps -p "$pid" -o pid=,lstart=,command= 2>/dev/null || true
  done <<<"$listeners"

  if ! confirm "是否向以上进程发送普通终止信号并重新开始？"; then
    die "端口 $port 仍被占用。"
    return 1
  fi
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done <<<"$listeners"
  local attempt
  for attempt in {1..100}; do
    [ -z "$(port_listeners "$port" || true)" ] && return 0
    sleep 0.1
  done
  die "端口 $port 的进程未在 10 秒内退出。"
}

health_is_ok() {
  local body
  body="$(printf '%s' "$1" | tr -d '[:space:]')"
  [ "$body" = "ok" ]
}

wait_for_health() {
  local url="$1" pid="$2" service="$3" body attempt
  for attempt in {1..60}; do
    pid_is_running "$pid" || die "$service 已提前退出，请查看日志。"
    body="$(curl -fsS "$url" 2>/dev/null || true)"
    if health_is_ok "$body"; then
      success "$service 健康检查通过"
      return 0
    fi
    sleep 0.5
  done
  die "$service 健康检查超时：$url"
}

check_prerequisites() {
  local command_name repository
  for command_name in bash curl find git go jq lsof make pgrep sed shasum sqlite3 uv xcodebuild xcodegen; do
    require_command "$command_name"
  done
  for repository in "$COLLECTION_ROOT" "$RECOMMEND_ROOT" "$TRAINER_ROOT"; do
    [ -d "$repository/.git" ] || [ -f "$repository/.git" ] \
      || die "缺少独立仓库：$repository"
  done
}

select_starcat_database() {
  local run_directory="$1" database count index choice
  local databases=() counts=()

  while IFS= read -r database; do
    case "$database" in
      */_anonymous/*) continue ;;
    esac
    count="$(sqlite3 -readonly "$database" \
      "SELECT COUNT(*) FROM repos WHERE is_starred=1 AND is_private=0 AND access_state='accessible';" \
      2>/dev/null || printf '0')"
    databases+=("$database")
    counts+=("$count")
  done < <(find "$HOME/Library/Application Support/com.starcat.app/users" \
    -mindepth 2 -maxdepth 2 -name starcat.sqlite -print 2>/dev/null | sort)

  [ "${#databases[@]}" -gt 0 ] || die "没有找到已登录账号的 Starcat 数据库。"
  info "选择用于验证的 Starcat 账号数据库"
  for ((index = 0; index < ${#databases[@]}; index++)); do
    printf '%d. %6s 条公开 Star  %s\n' "$((index + 1))" "${counts[$index]}" "${databases[$index]}"
  done
  while true; do
    printf '请输入序号：'
    IFS= read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] \
      && [ "$choice" -ge 1 ] \
      && [ "$choice" -le "${#databases[@]}" ]; then
      index=$((choice - 1))
      state_write "$run_directory" starcat-db "${databases[$index]}"
      state_write "$run_directory" starcat-public-stars "${counts[$index]}"
      success "已选择 ${counts[$index]} 条公开 Star 的数据库"
      return 0
    fi
    warn "请输入有效序号。"
  done
}

build_components() {
  local run_directory="$1"
  info "检查并构建 Collection API"
  (cd "$COLLECTION_ROOT" && make check && go build -o "$run_directory/collection-server" ./cmd/server)

  info "检查并构建 Recommend API"
  (cd "$RECOMMEND_ROOT" && make check && go build -o "$run_directory/recommend-server" ./cmd/server)

  info "同步并检查 Trainer"
  (cd "$TRAINER_ROOT" && uv sync --all-groups && make check)

  advance_phase "$run_directory" built
}

start_collection() {
  local run_directory="$1" pid
  ensure_port_available "$COLLECTION_PORT"
  (
    cd "$COLLECTION_ROOT"
    exec env \
      PORT="$COLLECTION_PORT" \
      STORE_FILE="$run_directory/collection.sqlite" \
      API_KEYS="$COLLECTION_CLIENT_KEY" \
      ADMIN_API_KEYS="$COLLECTION_ADMIN_KEY" \
      PARTICIPANT_HMAC_KEY="$PARTICIPANT_HMAC_KEY" \
      "$run_directory/collection-server"
  ) >"$run_directory/logs/collection.log" 2>&1 &
  pid=$!
  state_write "$run_directory" collection-pid "$pid"
  wait_for_health "http://127.0.0.1:$COLLECTION_PORT/healthz" "$pid" "Collection API"
  curl -fsS -H "Authorization: Bearer $COLLECTION_CLIENT_KEY" \
    "http://127.0.0.1:$COLLECTION_PORT/api/v1/ping" \
    | jq -e '.data.service == "collection" and .data.ok == true' >/dev/null
  advance_phase "$run_directory" collection-ready
}

ensure_collection_running() {
  local run_directory="$1" pid body
  pid="$(state_read "$run_directory" collection-pid 2>/dev/null || true)"
  body="$(curl -fsS "http://127.0.0.1:$COLLECTION_PORT/healthz" 2>/dev/null || true)"
  if [ -n "$pid" ] && pid_belongs_to_run "$pid" "$run_directory" && health_is_ok "$body"; then
    return 0
  fi
  start_collection "$run_directory"
}

sqlite_escape_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

snapshot_overlap_summary() {
  local run_directory="$1" database="$2" escaped_database
  escaped_database="$(sqlite_escape_literal "$database")"
  sqlite3 -readonly -separator '|' "$run_directory/collection.sqlite" <<SQL
ATTACH DATABASE '$escaped_database' AS starcat;
SELECT COALESCE(MAX(overlap_count), 0) || '|' || COALESCE(MAX(snapshot_count), 0)
FROM (
  SELECT
    SUM(CASE WHEN r.id IS NOT NULL THEN 1 ELSE 0 END) AS overlap_count,
    COUNT(i.repo_id) AS snapshot_count
  FROM active_snapshots a
  JOIN snapshot_items i ON i.snapshot_id = a.snapshot_id
  LEFT JOIN starcat.repos r
    ON r.id = i.repo_id
   AND r.is_starred = 1
   AND r.is_private = 0
   AND r.access_state = 'accessible'
  GROUP BY a.snapshot_id
);
SQL
}

check_direct_configuration() {
  local run_directory="$1" database app_plist configured_url key_length contribution_enabled
  database="$(state_read "$run_directory" starcat-db)"
  app_plist="$STARCAT_ROOT/build/DerivedData-NoSandbox/Build/Products/Debug/Starcat.app/Contents/Info.plist"
  if [ -f "$app_plist" ]; then
    configured_url="$(/usr/libexec/PlistBuddy -c 'Print :STARCAT_COLLECTION_API_BASE_URL' "$app_plist" 2>/dev/null || true)"
    key_length="$(/usr/libexec/PlistBuddy -c 'Print :STARCAT_COLLECTION_API_KEY' "$app_plist" 2>/dev/null | awk '{print length($0)}' || true)"
    if [ "$configured_url" != "http://127.0.0.1:$COLLECTION_PORT" ] || [ "${key_length:-0}" -eq 0 ]; then
      warn "当前 Direct 构建产物没有指向本机 Collection API。"
      printf '%s\n' \
        "请在 Configs/Secrets.xcconfig 中设置：" \
        "STARCAT_COLLECTION_API_KEY = $COLLECTION_CLIENT_KEY" \
        "STARCAT_COLLECTION_API_BASE_URL = http:/\$()/127.0.0.1:$COLLECTION_PORT" \
        "然后执行 make run-direct，再回到本脚本等待。"
    else
      success "当前 Direct 构建产物已指向本机 Collection API"
    fi
  else
    warn "尚未找到 Direct Debug 构建产物；请配置 Collection 后执行 make run-direct。"
  fi

  contribution_enabled="$(sqlite3 -readonly "$database" \
    'SELECT COALESCE(MAX(is_enabled), 0) FROM data_contribution_preferences;' 2>/dev/null || printf '0')"
  if [ "$contribution_enabled" = "1" ]; then
    success "所选账号已开启匿名贡献公开 Star"
  else
    warn "所选账号尚未开启匿名贡献公开 Star，请在客户端设置中开启。"
  fi
}

wait_for_real_snapshot() {
  local run_directory="$1" database expected minimum summary overlap snapshot_count attempt
  database="$(state_read "$run_directory" starcat-db)"
  expected="$(state_read "$run_directory" starcat-public-stars)"
  minimum=$((expected * 80 / 100))
  [ "$minimum" -ge 2 ] || minimum=2

  info "等待 Starcat Direct 上传真实快照"
  printf '%s\n' \
    "请在 Starcat Direct 中确认：" \
    "1. 设置 → 通用 → 隐私与推荐 → 开启匿名贡献公开 Star 数据" \
    "2. 回到 Manage/Stars，执行一次完整的“刷新仓库列表/详情”" \
    "3. 保持本脚本运行；收到快照后会自动继续" \
    "" \
    "目标数据库公开 Star：${expected}；最低有效交集：${minimum}"

  for attempt in {1..360}; do
    summary="$(snapshot_overlap_summary "$run_directory" "$database" 2>/dev/null || printf '0|0')"
    overlap="${summary%%|*}"
    snapshot_count="${summary##*|}"
    if [ "$overlap" -ge "$minimum" ]; then
      state_write "$run_directory" snapshot-overlap "$overlap"
      state_write "$run_directory" snapshot-repositories "$snapshot_count"
      advance_phase "$run_directory" snapshot-ready
      success "收到真实快照：$snapshot_count 条，主库有效交集 $overlap 条"
      return 0
    fi
    if (( attempt % 6 == 1 )); then
      printf '等待中：当前最大快照 %s 条，与主库交集 %s 条（最长等待 30 分钟）\n' \
        "$snapshot_count" "$overlap"
    fi
    sleep 5
  done
  die "30 分钟内未收到真实快照。可从菜单查看 Collection 日志后继续验证。"
}

export_repository_metadata() {
  local run_directory="$1" database output count
  database="$(state_read "$run_directory" starcat-db)"
  output="$run_directory/github-repositories.jsonl"
  sqlite3 -readonly "$database" <<'SQL' >"$output"
.headers off
.mode list
SELECT json_object(
  'fetched_at', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
  'repository', json_object(
    'id', id,
    'full_name', full_name,
    'description', description,
    'topics', json(CASE WHEN topics IS NOT NULL AND json_valid(topics) THEN topics ELSE '[]' END),
    'language', language,
    'license', json_object('spdx_id', license),
    'stargazers_count', stars_count,
    'forks_count', forks_count,
    'archived', is_archived,
    'disabled', 0,
    'private', is_private,
    'visibility', CASE WHEN is_private = 1 THEN 'private' ELSE 'public' END,
    'pushed_at', pushed_at
  )
)
FROM repos
WHERE is_starred = 1
  AND is_private = 0
  AND access_state = 'accessible'
ORDER BY id;
SQL
  count="$(wc -l <"$output" | tr -d '[:space:]')"
  [ "$count" -gt 0 ] || die "Starcat metadata 导出为空。"
  state_write "$run_directory" metadata-repositories "$count"
  success "已只读导出 $count 条公开仓库 metadata"
}

start_recommend() {
  local run_directory="$1" pid
  ensure_port_available "$RECOMMEND_PORT"
  mkdir -p "$run_directory/recommend-registry"
  (
    cd "$RECOMMEND_ROOT"
    exec env \
      PORT="$RECOMMEND_PORT" \
      API_KEYS="$RECOMMEND_CLIENT_KEY" \
      SIMREPO_API_KEY='unused-for-local-v2-verification' \
      MODEL_PUBLISH_KEYS="$RECOMMEND_PUBLISH_KEY" \
      MODEL_REGISTRY_DIR="$run_directory/recommend-registry" \
      MAX_BUNDLE_BYTES=536870912 \
      "$run_directory/recommend-server"
  ) >"$run_directory/logs/recommend.log" 2>&1 &
  pid=$!
  state_write "$run_directory" recommend-pid "$pid"
  wait_for_health "http://127.0.0.1:$RECOMMEND_PORT/healthz" "$pid" "Recommend API"
  curl -fsS -H "Authorization: Bearer $RECOMMEND_CLIENT_KEY" \
    "http://127.0.0.1:$RECOMMEND_PORT/api/v1/ping" \
    | jq -e '.data.ok == true' >/dev/null
  advance_phase "$run_directory" recommend-ready
}

ensure_recommend_running() {
  local run_directory="$1" pid body
  pid="$(state_read "$run_directory" recommend-pid 2>/dev/null || true)"
  body="$(curl -fsS "http://127.0.0.1:$RECOMMEND_PORT/healthz" 2>/dev/null || true)"
  if [ -n "$pid" ] && pid_belongs_to_run "$pid" "$run_directory" && health_is_ok "$body"; then
    return 0
  fi
  start_recommend "$run_directory"
}

write_trainer_config() {
  local run_directory="$1" model_version
  model_version="$(state_read "$run_directory" model-version)"
  # reference_time 与 train_end 必须相同，防止时间衰减读取未来信息。
  # 这里沿用项目基线切分，保证本地验证结果可与既有报告横向比较。
  sed \
    -e "s|__RUN_ID__|$model_version|g" \
    -e "s|__RUN_DIR__|$run_directory|g" \
    >"$run_directory/trainer.yaml" <<'YAML'
run_id: __RUN_ID__
workspace: __RUN_DIR__/trainer-workspace
registry: __RUN_DIR__/trainer-registry
random_seed: 42

sources:
  - type: starcat_collection_api
    base_url: http://127.0.0.1:5011
    admin_key_env: STARCAT_COLLECTION_ADMIN_KEY
    timeout_seconds: 60
    maximum_snapshots: 100
    maximum_repositories_per_snapshot: 100000
    maximum_response_bytes: 536870912
  - type: local_file
    path: __RUN_DIR__/github-repositories.jsonl
    source: github_api
    kind: raw_repositories

dataset:
  train_end: "2025-06-01T00:00:00Z"
  validation_end: "2026-01-01T00:00:00Z"
  minimum_repositories_per_subject: 2

training:
  reference_time: "2025-06-01T00:00:00Z"
  top_k: 20
  svd_components: 64
  half_life_days: 365
  legacy_time_weight: 0.35
  shrinkage: 1
  minimum_support: 0
  maximum_repositories_per_subject: 100
  run_ablations: true

evaluation:
  split: validation
  k: 20

publish:
  model_version: __RUN_ID__
  selected_model: costar
  metric_gates: {}
  recommend_api:
    base_url: http://127.0.0.1:5005
    publish_key_env: STARCAT_RECOMMEND_PUBLISH_KEY
    timeout_seconds: 120
    maximum_bundle_bytes: 536870912
    activate: true
YAML
}

run_training() {
  local run_directory="$1" model_version
  model_version="$(state_read "$run_directory" model-version)"
  write_trainer_config "$run_directory"
  info "执行离线训练并发布 ServingBundle"
  (
    cd "$TRAINER_ROOT"
    STARCAT_COLLECTION_ADMIN_KEY="$COLLECTION_ADMIN_KEY" \
    STARCAT_RECOMMEND_PUBLISH_KEY="$RECOMMEND_PUBLISH_KEY" \
      uv run starcat-recsys pipeline run --config "$run_directory/trainer.yaml"
    uv run starcat-recsys bundle verify \
      "$run_directory/trainer-registry/versions/$model_version"
  ) 2>&1 | tee "$run_directory/logs/trainer.log"
  advance_phase "$run_directory" trained
}

select_source_repository() {
  local bundle_database="$1" starcat_database="$2" escaped_database
  escaped_database="$(sqlite_escape_literal "$starcat_database")"
  sqlite3 -readonly -separator '|' "$bundle_database" <<SQL
ATTACH DATABASE '$escaped_database' AS starcat;
SELECT r.repo_id || '|' || r.full_name
FROM repositories r
JOIN (
  SELECT source_repo_id, COUNT(*) AS edge_count
  FROM recommendations
  GROUP BY source_repo_id
) e ON e.source_repo_id = r.repo_id
JOIN starcat.repos sr ON sr.id = r.repo_id
WHERE sr.is_starred = 1
  AND sr.is_private = 0
  AND sr.access_state = 'accessible'
  AND r.full_name IS NOT NULL
  AND trim(r.full_name) <> ''
ORDER BY e.edge_count DESC, r.repo_id
LIMIT 1;
SQL
}

validate_training_result() {
  local run_directory="$1" model_version run_path bundle_path database
  local final_rows recommendation_count source source_id source_name get_count post_count active_version
  model_version="$(state_read "$run_directory" model-version)"
  database="$(state_read "$run_directory" starcat-db)"
  run_path="$run_directory/trainer-workspace/runs/$model_version"
  bundle_path="$run_directory/trainer-registry/versions/$model_version"

  final_rows="$(jq -r '.final_rows // 0' "$run_path/dataset/quality-report.json")"
  [[ "$final_rows" =~ ^[0-9]+$ ]] && [ "$final_rows" -gt 0 ] \
    || die "Trainer final_rows=${final_rows}，拒绝接受空数据集。"
  [ "$(sqlite3 -readonly "$bundle_path/recommendations.sqlite" 'PRAGMA quick_check;')" = "ok" ] \
    || die "ServingBundle SQLite quick_check 失败。"
  recommendation_count="$(sqlite3 -readonly "$bundle_path/recommendations.sqlite" \
    'SELECT COUNT(*) FROM recommendations;')"
  [ "$recommendation_count" -gt 0 ] || die "ServingBundle recommendations=0，拒绝发布空推荐结果。"

  source="$(select_source_repository "$bundle_path/recommendations.sqlite" "$database")"
  [ -n "$source" ] || die "没有找到同时存在于 Bundle 和 Starcat 本地 Star 中的 source repo。"
  source_id="${source%%|*}"
  source_name="${source#*|}"

  active_version="$(curl -fsS \
    -H "Authorization: Bearer $RECOMMEND_PUBLISH_KEY" \
    "http://127.0.0.1:$RECOMMEND_PORT/internal/v1/model-bundles/active" \
    | jq -r '.data.model_version // .model_version // empty')"
  [ "$active_version" = "$model_version" ] \
    || die "Recommend active version=${active_version}，预期 ${model_version}。"

  curl -fsS \
    -H "Authorization: Bearer $RECOMMEND_CLIENT_KEY" \
    "http://127.0.0.1:$RECOMMEND_PORT/api/v2/repos/$source_id/recommendations?limit=10&offset=0" \
    >"$run_directory/recommend-v2-get.json"
  curl -fsS \
    -H "Authorization: Bearer $RECOMMEND_CLIENT_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"positive_repo_ids\":[$source_id],\"negative_repo_ids\":[],\"exclude_repo_ids\":[$source_id],\"limit\":10}" \
    "http://127.0.0.1:$RECOMMEND_PORT/api/v2/recommendations/query" \
    >"$run_directory/recommend-v2-post.json"
  get_count="$(jq -r '.data.items | length' "$run_directory/recommend-v2-get.json")"
  post_count="$(jq -r '.data.items | length' "$run_directory/recommend-v2-post.json")"
  [ "$get_count" -gt 0 ] || die "Recommend GET 返回空列表。"
  [ "$post_count" -gt 0 ] || die "Recommend POST 返回空列表。"

  state_write "$run_directory" final-rows "$final_rows"
  state_write "$run_directory" recommendation-count "$recommendation_count"
  state_write "$run_directory" source-repo-id "$source_id"
  state_write "$run_directory" source-repo-name "$source_name"
  state_write "$run_directory" get-items "$get_count"
  state_write "$run_directory" post-items "$post_count"
}

run_swift_live_test() {
  local run_directory="$1" model_version source_id derived_data
  model_version="$(state_read "$run_directory" model-version)"
  source_id="$(state_read "$run_directory" source-repo-id)"
  derived_data="$run_directory/starcat-live-derived"
  if pgrep -x Xcode >/dev/null 2>&1; then
    die "Xcode IDE 正在运行。请 Cmd+Q 退出 Xcode 后从菜单继续验证。"
  fi
  [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ] \
    || die "未找到稳定版 /Applications/Xcode.app。"

  info "执行 Starcat Recommend API live integration test"
  (
    cd "$STARCAT_ROOT"
    xcodegen generate
    STARCAT_RECOMMEND_LIVE_REQUIRED=1 \
    STARCAT_RECOMMEND_LIVE_BASE_URL="http://127.0.0.1:$RECOMMEND_PORT" \
    STARCAT_RECOMMEND_LIVE_API_KEY="$RECOMMEND_CLIENT_KEY" \
    STARCAT_RECOMMEND_LIVE_REPO_ID="$source_id" \
    STARCAT_RECOMMEND_LIVE_MODEL_VERSION="$model_version" \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild \
        -scheme Starcat \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$derived_data" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGN_ENTITLEMENTS= \
        -only-testing:StarcatTests/RecommendAPILiveIntegrationTests \
        test
  ) 2>&1 | tee "$run_directory/logs/starcat-live-test.log"
  state_write "$run_directory" swift-live-test passed
}

verify_recommend_restart() {
  local run_directory="$1" model_version active_version
  model_version="$(state_read "$run_directory" model-version)"
  stop_run_process "$run_directory" recommend
  start_recommend "$run_directory"
  active_version="$(curl -fsS \
    -H "Authorization: Bearer $RECOMMEND_PUBLISH_KEY" \
    "http://127.0.0.1:$RECOMMEND_PORT/internal/v1/model-bundles/active" \
    | jq -r '.data.model_version // .model_version // empty')"
  [ "$active_version" = "$model_version" ] \
    || die "Recommend 重启后没有恢复 active model：$active_version"
  success "Recommend 重启后恢复模型 $model_version"
}

write_results() {
  local run_directory="$1" model_version source_id source_name final_rows recommendation_count
  local overlap snapshot_count metadata_count get_items post_items swift_live_test
  model_version="$(state_read "$run_directory" model-version)"
  source_id="$(state_read "$run_directory" source-repo-id)"
  source_name="$(state_read "$run_directory" source-repo-name)"
  final_rows="$(state_read "$run_directory" final-rows)"
  recommendation_count="$(state_read "$run_directory" recommendation-count)"
  overlap="$(state_read "$run_directory" snapshot-overlap)"
  snapshot_count="$(state_read "$run_directory" snapshot-repositories)"
  metadata_count="$(state_read "$run_directory" metadata-repositories)"
  get_items="$(state_read "$run_directory" get-items)"
  post_items="$(state_read "$run_directory" post-items)"
  swift_live_test="$(state_read "$run_directory" swift-live-test)"

  {
    printf 'E2E_DIR=%q\n' "$run_directory"
    printf 'E2E_MODEL_VERSION=%q\n' "$model_version"
    printf 'E2E_SOURCE_REPO_ID=%q\n' "$source_id"
    printf 'E2E_SOURCE_REPO_NAME=%q\n' "$source_name"
  } >"$run_directory/result.env"

  jq -n \
    --arg run_directory "$run_directory" \
    --arg model_version "$model_version" \
    --arg source_repo_id "$source_id" \
    --arg source_repo_name "$source_name" \
    --argjson snapshot_repositories "$snapshot_count" \
    --argjson snapshot_overlap "$overlap" \
    --argjson metadata_repositories "$metadata_count" \
    --argjson final_rows "$final_rows" \
    --argjson recommendation_count "$recommendation_count" \
    --argjson get_items "$get_items" \
    --argjson post_items "$post_items" \
    --arg swift_live_test "$swift_live_test" \
    '{
      run_directory: $run_directory,
      model_version: $model_version,
      source_repo_id: $source_repo_id,
      source_repo_name: $source_repo_name,
      checks: {
        snapshot_repositories: $snapshot_repositories,
        snapshot_overlap: $snapshot_overlap,
        metadata_repositories: $metadata_repositories,
        final_rows: $final_rows,
        recommendation_count: $recommendation_count,
        get_items: $get_items,
        post_items: $post_items,
        swift_live_test: $swift_live_test
      }
    }' >"$run_directory/result.json"

  sed \
    -e "s|__CREATED_AT__|$(date '+%Y-%m-%d %H:%M:%S %Z')|g" \
    -e "s|__MODEL_VERSION__|$model_version|g" \
    -e "s|__SOURCE_ID__|$source_id|g" \
    -e "s|__SOURCE_NAME__|$source_name|g" \
    -e "s|__SNAPSHOT_COUNT__|$snapshot_count|g" \
    -e "s|__OVERLAP__|$overlap|g" \
    -e "s|__METADATA_COUNT__|$metadata_count|g" \
    -e "s|__FINAL_ROWS__|$final_rows|g" \
    -e "s|__RECOMMENDATION_COUNT__|$recommendation_count|g" \
    -e "s|__GET_ITEMS__|$get_items|g" \
    -e "s|__POST_ITEMS__|$post_items|g" \
    -e "s|__SWIFT_LIVE_TEST__|$swift_live_test|g" \
    >"$run_directory/validation-report.md" <<'REPORT'
# Starcat 本地推荐全链路验证报告

- 验证时间：__CREATED_AT__
- 模型版本：`__MODEL_VERSION__`
- 客户端验收仓库：`__SOURCE_NAME__`（repo ID：`__SOURCE_ID__`）

## 自动检查

| 检查项 | 结果 |
|---|---:|
| Collection 快照仓库 | __SNAPSHOT_COUNT__ |
| 与 Starcat 主库交集 | __OVERLAP__ |
| Metadata 仓库 | __METADATA_COUNT__ |
| Dataset final rows | __FINAL_ROWS__ |
| ServingBundle 推荐边 | __RECOMMENDATION_COUNT__ |
| Recommend GET items | __GET_ITEMS__ |
| Recommend POST items | __POST_ITEMS__ |
| Swift live integration test | __SWIFT_LIVE_TEST__ |
| Recommend 重启恢复 | 通过 |

## 客户端验收

在 Starcat Direct 全局搜索中选择“本地”，搜索 `__SOURCE_NAME__`，打开仓库后点击“相似仓库”。
应展示非空推荐卡片，推荐理由应来自自研公开 Star 共现模型。
REPORT

  advance_phase "$run_directory" complete
}

show_client_instructions() {
  local run_directory source_name
  run_directory="$(current_run)" || { warn "当前没有可用验证运行。"; return 0; }
  if ! phase_at_least "$run_directory" complete; then
    warn "当前验证尚未完成，请先选择“继续未完成的验证”。"
    return 0
  fi
  source_name="$(state_read "$run_directory" source-repo-name)"
  info "Starcat Direct 客户端验收"
  printf '%s\n' \
    "1. 设置 → 服务：Recommend URL = http://127.0.0.1:$RECOMMEND_PORT" \
    "2. Recommend API Key = $RECOMMEND_CLIENT_KEY" \
    "3. 打开全局搜索，选择“本地”（不是“仓库”Tab）" \
    "4. 搜索并打开：$source_name" \
    "5. 点击“相似仓库”，确认出现非空的自研推荐卡片" \
    "" \
    "自动验证报告：$run_directory/validation-report.md"
}

run_validation() {
  local run_directory="$1"
  check_prerequisites
  if [ -z "$(state_read "$run_directory" starcat-db 2>/dev/null || true)" ]; then
    select_starcat_database "$run_directory"
  fi
  if ! phase_at_least "$run_directory" built; then
    build_components "$run_directory"
  fi
  ensure_collection_running "$run_directory"
  if ! phase_at_least "$run_directory" snapshot-ready; then
    check_direct_configuration "$run_directory"
    wait_for_real_snapshot "$run_directory"
    export_repository_metadata "$run_directory"
  elif [ ! -s "$run_directory/github-repositories.jsonl" ]; then
    export_repository_metadata "$run_directory"
  fi
  ensure_recommend_running "$run_directory"
  if ! phase_at_least "$run_directory" trained; then
    run_training "$run_directory"
  fi
  if ! phase_at_least "$run_directory" complete; then
    validate_training_result "$run_directory"
    run_swift_live_test "$run_directory"
    verify_recommend_restart "$run_directory"
    write_results "$run_directory"
  fi
  show_client_instructions
}

start_new_validation() {
  local existing run_directory
  existing="$(current_run 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    warn "已有验证运行：$existing"
    if ! confirm "是否停止其服务、保留文件并创建新运行？"; then
      return 0
    fi
    stop_run_services "$existing"
  fi
  run_directory="$(create_run)"
  info "新运行目录：$run_directory"
  run_validation "$run_directory"
}

continue_validation() {
  local run_directory
  run_directory="$(current_run)" || { warn "没有可继续的验证运行。"; return 0; }
  run_validation "$run_directory"
}

show_status() {
  local run_directory phase collection_pid recommend_pid
  run_directory="$(current_run)" || { warn "当前没有验证运行。"; return 0; }
  phase="$(state_read "$run_directory" phase 2>/dev/null || printf 'unknown')"
  collection_pid="$(state_read "$run_directory" collection-pid 2>/dev/null || true)"
  recommend_pid="$(state_read "$run_directory" recommend-pid 2>/dev/null || true)"
  info "当前验证状态"
  printf '运行目录：%s\n阶段：%s\n' "$run_directory" "$phase"
  if [ -n "$collection_pid" ] && pid_belongs_to_run "$collection_pid" "$run_directory"; then
    printf 'Collection：运行中（PID %s）\n' "$collection_pid"
  else
    printf 'Collection：未运行\n'
  fi
  if [ -n "$recommend_pid" ] && pid_belongs_to_run "$recommend_pid" "$run_directory"; then
    printf 'Recommend：运行中（PID %s）\n' "$recommend_pid"
  else
    printf 'Recommend：未运行\n'
  fi
  [ ! -f "$run_directory/result.json" ] || jq . "$run_directory/result.json"
}

show_logs() {
  local run_directory log_file
  run_directory="$(current_run)" || { warn "当前没有验证运行。"; return 0; }
  for log_file in collection recommend trainer; do
    printf '\n===== %s.log =====\n' "$log_file"
    if [ -f "$run_directory/logs/$log_file.log" ]; then
      tail -80 "$run_directory/logs/$log_file.log"
    else
      printf '尚未生成。\n'
    fi
  done
}

directory_size() {
  du -sh "$1" 2>/dev/null | awk '{print $1}'
}

cleanup_run() {
  local run_directory="$1" directory_path
  is_safe_run_directory "$run_directory" || die "拒绝清理不安全的目录：$run_directory"
  stop_run_services "$run_directory"
  directory_path="$(canonical_directory "$run_directory")"
  rm -rf -- "$directory_path"
  if [ -f "$CURRENT_RUN_FILE" ] && [ "$(sed -n '1p' "$CURRENT_RUN_FILE")" = "$run_directory" ]; then
    rm -f -- "$CURRENT_RUN_FILE"
  fi
  success "已清理：$directory_path"
}

cleanup_current_run() {
  local run_directory
  run_directory="$(current_run)" || { warn "当前没有验证运行。"; return 0; }
  printf '目录：%s\n大小：%s\n' "$run_directory" "$(directory_size "$run_directory")"
  confirm "确认停止服务并删除本次全部临时文件？" || return 0
  cleanup_run "$run_directory"
}

cleanup_history() {
  local directory index choice
  local directories=()
  mkdir -p "$RUNS_ROOT"
  while IFS= read -r directory; do
    is_safe_run_directory "$directory" && directories+=("$directory")
  done < <(find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -print | sort)
  [ "${#directories[@]}" -gt 0 ] || { warn "没有可清理的历史运行。"; return 0; }
  info "历史验证运行"
  for ((index = 0; index < ${#directories[@]}; index++)); do
    printf '%d. %s  %s\n' "$((index + 1))" "$(directory_size "${directories[$index]}")" "${directories[$index]}"
  done
  printf '输入序号清理单次，输入 a 清理全部，输入 0 取消：'
  IFS= read -r choice
  case "$choice" in
    0|'') return 0 ;;
    a|A)
      confirm "确认停止服务并删除以上全部验证目录？" || return 0
      for directory in "${directories[@]}"; do cleanup_run "$directory"; done
      ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#directories[@]}" ]; then
        directory="${directories[$((choice - 1))]}"
        confirm "确认删除 ${directory}？" && cleanup_run "$directory"
      else
        warn "无效选择。"
      fi
      ;;
  esac
}

stop_current_services() {
  local run_directory
  run_directory="$(current_run)" || { warn "当前没有验证运行。"; return 0; }
  confirm "确认停止本次 Collection 和 Recommend 服务？" || return 0
  stop_run_services "$run_directory"
}

print_menu() {
  cat <<'MENU'

Starcat 本地推荐全链路验证

1. 开始新的全链路验证
2. 查看当前验证状态
3. 继续未完成的验证
4. 查看服务日志
5. 查看客户端验收指引
6. 停止本次验证服务
7. 清理本次临时文件
8. 清理历史验证文件
0. 退出
MENU
}

interactive_menu() {
  local choice
  while true; do
    print_menu
    printf '请选择操作：'
    IFS= read -r choice
    case "$choice" in
      1) start_new_validation; pause ;;
      2) show_status; pause ;;
      3) continue_validation; pause ;;
      4) show_logs; pause ;;
      5) show_client_instructions; pause ;;
      6) stop_current_services; pause ;;
      7) cleanup_current_run; pause ;;
      8) cleanup_history; pause ;;
      0) return 0 ;;
      *) warn "无效选择：$choice" ;;
    esac
  done
}

main() {
  case "${1:-}" in
    '') interactive_menu ;;
    --status) show_status ;;
    --help|-h)
      printf '用法：%s\n默认无参数进入交互式菜单；--status 仅输出当前状态。\n' "$0"
      ;;
    *) die "未知参数：$1" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
