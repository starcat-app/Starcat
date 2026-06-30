#!/usr/bin/env bash
# =============================================================================
# start-all.sh — 一键构建并启动 supports/ 下全部 Go API 服务
# =============================================================================
#
# 用法:
#   ./start-all.sh                # 编译 + 后台启动所有服务
#   ./start-all.sh --rebuild      # 强制先 rm 旧二进制再编译 (默认就是删)
#   ./start-all.sh --no-build     # 跳过编译, 直接启动 (要求二进制已存在)
#   ./start-all.sh --stop         # 停止已运行的所有服务并退出
#   ./start-all.sh --status       # 打印所有服务运行状态并退出
#
# 前置依赖:
#   - go (>= 1.25.0, 与各项目 go.mod 对齐)
#   - 端口 5001 / 5002 / 5003 / 5004 / 5006 未被占用
#
# 流程:
#   1. 定位脚本所在目录 = supports/ 根, 校验各项目目录都在
#   2. 逐个项目执行 `go build -v -o bin/starcat-xxx-api ./cmd/server/`
#   3. 在后台 (nohup) 启动各服务二进制, 日志写到 logs/starcat-xxx-api.log
#   4. 等所有 /healthz 通过 (最多 10s), 打印最终状态
#   5. 注册 SIGINT/SIGTERM trap: 退出时一并 kill 所有子进程
#
# 端口与默认 env 变量 (与各项目 cmd/server/main.go 默认值保持一致):
#   - starcat-sharing-api  : 5001  (BASE_URL / STORE_FILE 走 main.go fallback)
#   - starcat-trending-api : 5002
#   - starcat-weekly-api   : 5003  (STORE_FILE / REPO_DIR 走 main.go fallback)
#   - starcat-wiki-api     : 5004  (STORE_FILE 走 main.go fallback)
#   - starcat-discovery-api: 5006  (STORE_FILE / SYNC_ENABLED 走 main.go fallback)
#   每个服务的 API_KEYS / GitHub Token / Wiki Key 由各自项目根目录 `.env` 提供。
#   start-all.sh 不再硬编码密钥，避免脚本与 `.env` 出现两套真源导致本地 401。
#
# 设计取舍:
#   - 编译产物放各项目的 bin/ 子目录, 不污染项目根, 也方便 .gitignore 兜底
#   - 永远不覆盖 PID: 用 bin/starcat-xxx-api.pid 记录, 二次启动前会读它 stop
#   - stop/status 不需要 build, --stop / --status 早返回
#   - 不引入 Makefile / Taskfile, 单文件 shell 即可, 与 deploy.sh 风格一致
#
# ⚠️ 启动必须 cd 到项目根, 不能从 bin/ 启, 原因:
#   sharing 的 main.go 用 template.ParseGlob("templates/*.html") (相对路径)
#   sharing 的 STORE_FILE 默认 "data.json" (相对路径)
#   weekly 的 REPO_DIR 默认 ".weekly-repo" (相对路径)
#   从 bin/ 启动会全部找不到 → template.ParseGlob 直接 log.Fatal
#   修复方式: ( cd $project && exec env ... $bin ) &
#             subshell 让 cd 只影响子进程, exec 让 $! 拿到真实二进制 PID
#             (而不是 nohup 的 PID), --stop 时 kill 才不会泄漏进程
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径与常量
# =============================================================================
# BASH_SOURCE[0] 是脚本自身, cd 到它的目录 = supports/ 根, 兼容软链
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 服务统一用数组, 顺序 = 构建/启动顺序
# 格式: <目录名>|<二进制名>|<端口>|<额外 env (空格分隔)>
SERVICES=(
  "starcat-sharing-api|sharing|5001|BASE_URL=http://127.0.0.1:5001 STORE_FILE"
  "starcat-trending-api|trending|5002|STORE_FILE"
  "starcat-weekly-api|weekly|5003|STORE_FILE REPO_DIR ZREAD_TRENDING_CRON"
  "starcat-wiki-api|wiki|5004|STORE_FILE ENABLE_CODEWIKI_BATCHEXECUTE=true"
  "starcat-discovery-api|discovery|5006|STORE_FILE SYNC_ENABLED"
)

# /healthz 健康检查超时 (秒): 启动到第一次 200 OK 之间等待
HEALTH_TIMEOUT=10

# =============================================================================
# --stop / --status 早返回分支 (放在颜色初始化之前, 减少无关输出)
# =============================================================================
ACTION="${1:-start}"

stop_all() {
  echo "停止所有服务..."
  local stopped=0
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r dir bin port _ <<<"$entry"
    local pid_file="$SCRIPT_DIR/$dir/bin/$bin.pid"
    if [[ -f "$pid_file" ]]; then
      local pid
      pid="$(cat "$pid_file")"
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        echo "  [$bin] stopped (pid=$pid)"
        stopped=$((stopped + 1))
      else
        echo "  [$bin] pid=$pid 已不存在, 清理 pid 文件"
      fi
      rm -f "$pid_file"
    else
      echo "  [$bin] 未运行 (无 pid 文件)"
    fi
  done
  echo "共停止 $stopped 个服务"
}

status_all() {
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r dir bin port _ <<<"$entry"
    local pid_file="$SCRIPT_DIR/$dir/bin/$bin.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
      printf "  %-22s port=%s pid=%s  UP\n" "$bin" "$port" "$(cat "$pid_file")"
    else
      printf "  %-22s port=%s           DOWN\n" "$bin" "$port"
    fi
  done
}

case "$ACTION" in
  --stop)   stop_all; exit 0 ;;
  --status) status_all; exit 0 ;;
esac

# =============================================================================
# 颜色 (仅 TTY, 避免污染管道日志)
# =============================================================================
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# =============================================================================
# 参数解析
# =============================================================================
DO_BUILD=1
case "$ACTION" in
  --no-build) DO_BUILD=0 ;;
  --rebuild)  DO_BUILD=1 ;;
  start|"")   DO_BUILD=1 ;;
  -h|--help)
    sed -n '2,15p' "$0"
    exit 0
    ;;
  *)
    echo -e "${RED}未知参数: $ACTION${NC}" >&2
    sed -n '2,15p' "$0" >&2
    exit 1
    ;;
esac

# =============================================================================
# 预检: 项目目录 / go / 端口
# =============================================================================
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  Starcat 后端服务 一键启动${NC}"
echo -e "${BLUE}=========================================${NC}"

command -v go >/dev/null 2>&1 || { echo -e "${RED}✘ go 未安装${NC}" >&2; exit 1; }
GO_VERSION="$(go version | awk '{print $3}')"
echo -e "  go:           ${GREEN}$GO_VERSION${NC}"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r dir bin port _ <<<"$entry"
  if [[ ! -d "$SCRIPT_DIR/$dir/cmd/server" ]]; then
    echo -e "${RED}✘ 缺目录: $dir/cmd/server${NC}" >&2
    exit 1
  fi
done

# 端口占用检查 (lsof 不可用时降级为 ss/netstat)
check_port() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    # 任意 lsof 之外的工具找不到就放行 (macOS 默认有 lsof, Linux 上不一定)
    return 1
  fi
}
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r dir bin port _ <<<"$entry"
  if check_port "$port"; then
    echo -e "${RED}✘ 端口 $port ($bin) 已被占用, 请先停掉或用 --stop 清理旧实例${NC}" >&2
    exit 1
  fi
done
echo -e "  ports:        ${GREEN}5001 5002 5003 5004 5006 全部空闲${NC}"
echo ""

# =============================================================================
# 1) 编译阶段
# =============================================================================
if [[ "$DO_BUILD" -eq 1 ]]; then
  echo -e "${YELLOW}[1/2] 编译所有服务${NC}"
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r dir bin port _ <<<"$entry"
    local_bin_dir="$SCRIPT_DIR/$dir/bin"
    local_bin="$local_bin_dir/$bin"
    mkdir -p "$local_bin_dir"

    # 旧二进制清掉, 避免 stale 代码 (尤其是 main.go 改名/删除时)
    rm -f "$local_bin" "$local_bin_dir/$bin.pid"

    echo -n "  build $bin ... "
    start_t=$(date +%s)
    # -v 打印被编译的包; -o 写到项目 bin/ 下, 避免污染项目根
    if ( cd "$SCRIPT_DIR/$dir" && go build -v -o "$local_bin" ./cmd/server/ ) >"$local_bin_dir/$bin.build.log" 2>&1; then
      end_t=$(date +%s)
      size=$(du -h "$local_bin" | cut -f1)
      echo -e "${GREEN}OK${NC} (${size}, $((end_t - start_t))s)"
    else
      echo -e "${RED}FAIL${NC}"
      echo -e "${RED}---- $dir build log ----${NC}"
      cat "$local_bin_dir/$bin.build.log" >&2
      exit 1
    fi
  done
  echo ""
else
  echo -e "${YELLOW}[1/2] 跳过编译 (--no-build), 校验二进制存在${NC}"
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r dir bin port _ <<<"$entry"
    [[ -x "$SCRIPT_DIR/$dir/bin/$bin" ]] || {
      echo -e "${RED}✘ 缺二进制: $dir/bin/$bin (请先不带 --no-build 跑一次)${NC}" >&2
      exit 1
    }
  done
  echo ""
fi

# =============================================================================
# 2) 启动阶段 (后台 nohup, 立即返回)
# =============================================================================
echo -e "${YELLOW}[2/2] 启动所有服务 (后台)${NC}"

# 启动后统一 kill 用的 PID 列表, trap 用
PIDS=()
# trap 在脚本退出 (正常 / Ctrl-C / 错误) 时一并收尾
cleanup() {
  echo ""
  echo -e "${YELLOW}收到退出信号, 正在停止所有服务...${NC}"
  for pid in "${PIDS[@]:-}"; do
    [[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null || true
  done
  # 等 2s, 还活着就 SIGKILL
  sleep 2
  for pid in "${PIDS[@]:-}"; do
    [[ -n "${pid:-}" ]] && kill -9 "$pid" 2>/dev/null || true
  done
  exit 0
}
trap cleanup INT TERM EXIT

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r dir bin port extras <<<"$entry"
  local_bin_dir="$SCRIPT_DIR/$dir/bin"
  local_bin="$local_bin_dir/$bin"
  log_file="$SCRIPT_DIR/$dir/logs/$bin.log"
  pid_file="$local_bin_dir/$bin.pid"
  mkdir -p "$SCRIPT_DIR/$dir/logs"

  # 先把"上一次的进程"清掉, 避免 pid 文件残留
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$pid_file"

  # 构造 env: 基础 PORT 必传, 其它从 extras 列表里逐个读
  # extras 语法支持两种形式:
  #   VAR              → 只在 shell 已有该 env 时透传 (例: STORE_FILE / GITHUB_TOKEN)
  #   VAR=default      → shell 有则用 shell 的, 没有则用 default (例: BASE_URL=http://127.0.0.1:5001)
  env_args=( "PORT=$port" )
  for spec in $extras; do
    if [[ "$spec" == *"="* ]]; then
      name="${spec%%=*}"
      default="${spec#*=}"
      if [[ -n "${!name:-}" ]]; then
        env_args+=( "$name=${!name}" )
      else
        env_args+=( "$name=$default" )
      fi
    else
      if [[ -n "${!spec:-}" ]]; then
        env_args+=( "$spec=${!spec}" )
      fi
    fi
  done

  echo -n "  start $bin (port=$port) ... "
  # 关键: cd 到项目根, 否则 sharing 的 templates/*.html 找不到
  # 用 ( subshell ) 让 cd 只影响子进程, 不污染父 shell 的 cwd
  # 用 exec nohup env 让服务脱离启动终端；env 再 exec 到二进制
  #   → $! 拿到的是真实二进制 PID (不是 nohup / subshell 的 PID)
  #   → --stop / cleanup 里的 kill 才会真正命中服务进程
  # < /dev/null 切断 stdin, 防止后台进程绑在终端上
  ( cd "$SCRIPT_DIR/$dir" && exec nohup env "${env_args[@]}" "$local_bin" ) >"$log_file" 2>&1 < /dev/null &
  pid=$!
  disown "$pid" 2>/dev/null || true
  PIDS+=("$pid")
  echo "$pid" > "$pid_file"
  echo -e "${GREEN}pid=$pid${NC}, log=$log_file"
done

echo ""
echo -e "${YELLOW}等待 /healthz 通过 (最多 ${HEALTH_TIMEOUT}s)...${NC}"

# =============================================================================
# 3) 健康检查轮询
# =============================================================================
all_healthy=1
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
while [[ $(date +%s) -lt $deadline ]]; do
  all_healthy=1
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r dir bin port _ <<<"$entry"
    if ! curl -fsS --max-time 1 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
      all_healthy=0
      break
    fi
  done
  [[ "$all_healthy" -eq 1 ]] && break
  sleep 0.5
done

echo ""
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  启动结果${NC}"
echo -e "${BLUE}=========================================${NC}"
status_all

if [[ "$all_healthy" -eq 1 ]]; then
  echo ""
  echo -e "${GREEN}✔ 全部服务已就绪${NC}"
  echo ""

  # =====================================================================
  # API 链接 (从 SERVICES 数组读端口, 与实际启动端口保持一致)
  # =====================================================================
  echo -e "${YELLOW}API 链接 (本地):${NC}"
  echo ""
  IFS='|' read -r _ _ p1 e1 <<<"${SERVICES[0]}"
  IFS='|' read -r _ _ p2 e2 <<<"${SERVICES[1]}"
  IFS='|' read -r _ _ p3 e3 <<<"${SERVICES[2]}"
  IFS='|' read -r _ _ p4 e4 <<<"${SERVICES[3]}"
  IFS='|' read -r _ _ p5 e5 <<<"${SERVICES[4]}"

  printf "  ${BLUE}%-9s${NC} base  ${GREEN}http://127.0.0.1:%s${NC}\n" "sharing" "$p1"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/share\n"         "POST" "$p1"
  printf "             %-5s  http://127.0.0.1:%s/s/{id}\n"              "GET"  "$p1"
  printf "             %-5s  http://127.0.0.1:%s/healthz\n"             "GET"  "$p1"
  printf "             %-5s  API Key 见 starcat-sharing-api/.env\n"  "TIP"
  echo ""

  printf "  ${BLUE}%-9s${NC} base  ${GREEN}http://127.0.0.1:%s${NC}\n" "trending" "$p2"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/repos?since=daily&lang=go\n" "GET" "$p2"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/languages\n"      "GET" "$p2"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/users?since=daily&lang=go\n" "GET" "$p2"
  printf "             %-5s  http://127.0.0.1:%s/healthz\n"              "GET" "$p2"
  printf "             %-5s  API Key 见 starcat-trending-api/.env\n"  "TIP"
  echo ""

  printf "  ${BLUE}%-9s${NC} base  ${GREEN}http://127.0.0.1:%s${NC}\n" "weekly" "$p3"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/repos?page=1&page_size=20\n" "GET" "$p3"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/repos/{gh_repo_id}\n" "GET" "$p3"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/repos/languages\n" "GET" "$p3"
  printf "             %-5s  http://127.0.0.1:%s/internal/sync/weekly\n"        "POST" "$p3"
  printf "             %-5s  http://127.0.0.1:%s/internal/sync/zread\n"         "POST" "$p3"
  printf "             %-5s  http://127.0.0.1:%s/healthz\n"              "GET" "$p3"
  printf "             %-5s  API Key 见 starcat-weekly-api/.env\n"  "TIP"
  echo ""

  printf "  ${BLUE}%-9s${NC} base  ${GREEN}http://127.0.0.1:%s${NC}\n" "wiki" "$p4"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/wikis?owner=facebook&repo=react\n" "GET" "$p4"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/wikis/batch\n" "POST" "$p4"
  printf "             %-5s  http://127.0.0.1:%s/healthz\n"              "GET" "$p4"
  printf "             %-5s  API Key 见 starcat-wiki-api/.env\n"  "TIP"
  echo ""

  printf "  ${BLUE}%-9s${NC} base  ${GREEN}http://127.0.0.1:%s${NC}\n" "discovery" "$p5"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/discovery/feed\n" "GET" "$p5"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/discovery/categories/most-popular\n" "GET" "$p5"
  printf "             %-5s  http://127.0.0.1:%s/api/v1/discovery/categories/new-releases\n" "GET" "$p5"
  printf "             %-5s  http://127.0.0.1:%s/internal/sync/discovery\n" "POST" "$p5"
  printf "             %-5s  http://127.0.0.1:%s/healthz\n"              "GET" "$p5"
  printf "             %-5s  API Key 见 starcat-discovery-api/.env\n"  "TIP"
  echo ""


  echo "查看日志:"
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r dir bin port _ <<<"$entry"
    echo "  tail -f $dir/logs/$bin.log"
  done
  echo ""
  echo "停止全部:  $0 --stop"
  echo "查看状态:  $0 --status"
  # 全部健康后, 把 trap 改成空, 不要再 kill 已正常运行的进程
  trap - INT TERM EXIT
  # 服务已通过 nohup + disown 脱离当前终端，健康检查成功后脚本立即返回。
else
  echo ""
  echo -e "${RED}✘ 部分服务未在 ${HEALTH_TIMEOUT}s 内通过 /healthz, 请查看日志${NC}"
  exit 1
fi
