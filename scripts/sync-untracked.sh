#!/usr/bin/env bash
# =============================================================================
# sync-untracked.sh
# =============================================================================
#
# 在 MBP / Studio 之间同步"git 不管理但两台机器都要用"的文件。
#
# 与 sync-production-api-keys-from-env.sh 区别：
#   - 后者把 supports/*/.env 的 production key 写入 Configs/Secrets.xcconfig
#     （本机操作，git 已跟踪 Configs/Secrets.xcconfig.template）
#   - 本脚本跨主机同步"git 不管的"那批文件，靠显式清单而非自动扫描
#
# 用法（Starcat 主仓库根目录）：
#   ./scripts/sync-untracked.sh --to studio                 # dry-run（默认）
#   ./scripts/sync-untracked.sh --to studio --apply         # 真同步
#   ./scripts/sync-untracked.sh --to studio --list-only     # 只列清单
#   ./scripts/sync-untracked.sh --to studio --apply --yes   # 跳过二次确认
#
# 设计原则：
#   - 同步源 = 显式清单（scripts/sync-manifest.list），不自动扫未跟踪文件
#   - 排除规则 = scripts/sync-exclude.list（兜底；显式清单应避免命中）
#   - 默认 dry-run，--apply 必须走 y/N 二次确认（除非 --yes）
#   - 同步完成后对 Secrets.xcconfig / notes.md 自动 chmod 600（缓解决策 3c 风险）
# =============================================================================

set -euo pipefail

# ---------- 路径常量 ----------
# 关键约束：跟现有 sync-production-api-keys-from-env.sh 一样，用 BASH_SOURCE 推
# ROOT_DIR，避免硬编码。这样脚本被软链到其他位置也仍能定位仓库根。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${SCRIPT_DIR}/sync-manifest.list"
EXCLUDE_LIST="${SCRIPT_DIR}/sync-exclude.list"
HOSTS_FILE="${SCRIPT_DIR}/sync-hosts.json"
HOSTS_EXAMPLE="${SCRIPT_DIR}/sync-hosts.example.json"

# ---------- 参数解析 ----------
ALIAS=""
APPLY=0
YES=0
LIST_ONLY=0

usage() {
  cat <<EOF
Usage: $0 --to <alias> [--apply] [--yes] [--list-only]

  --to <alias>   目标机器别名（取自 sync-hosts.json 的 key）
  --apply        真同步；不传 = dry-run
  --yes          --apply 模式下跳过 y/N 二次确认
  --list-only    只列清单 + 总大小，不做 git status / SSH 检查
  -h, --help     显示本帮助
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)        ALIAS="${2:-}"; shift 2 ;;
    --apply)     APPLY=1; shift ;;
    --yes)       YES=1; shift ;;
    --list-only) LIST_ONLY=1; shift ;;
    -h|--help)   usage 0 ;;
    *)           echo "Error: 未知参数: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$ALIAS" ]]; then
  echo "Error: 缺 --to <alias>" >&2
  usage 1
fi
if [[ $LIST_ONLY -eq 1 && $APPLY -eq 1 ]]; then
  echo "Error: --list-only 与 --apply 互斥" >&2
  exit 1
fi

# ---------- 加载配置 ----------
if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "Error: $HOSTS_FILE 不存在" >&2
  echo "  解决：cp $HOSTS_EXAMPLE $HOSTS_FILE 后填真实 SSH 别名 + 远端路径" >&2
  exit 1
fi

# 用 jq 读 alias 对应的 ssh / remote_path。
# 已踩过的坑：jq -r 输出不带引号；如果 alias 在 JSON 里是 null，输出 "null"
# 字符串，要兜底成 empty 串。
SSH_HOST=$(jq -r --arg a "$ALIAS" '.[$a].ssh // empty' "$HOSTS_FILE")
REMOTE_PATH=$(jq -r --arg a "$ALIAS" '.[$a].remote_path // empty' "$HOSTS_FILE")

if [[ -z "$SSH_HOST" || -z "$REMOTE_PATH" ]]; then
  echo "Error: sync-hosts.json 里没有别名 \"$ALIAS\" 的 ssh / remote_path" >&2
  exit 1
fi

# ---------- 预检查（list-only 跳过） ----------
# 设计意图：list-only 是离线场景（"我想先看看要传什么再决定"），不应被网络
# 挡住；所以仅在 apply / dry-run 时做 SSH 连通性检查。本机 / 对端 git status
# 故意不检查——脚本是按显式清单同步，不关心你 git 状态怎么样，你清楚就行。
if [[ $LIST_ONLY -eq 0 ]]; then
  echo ">>> SSH 连通性: $SSH_HOST ..."
  # BatchMode=yes 避免卡在密码输入；ConnectTimeout 5s 避免挂死。
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_HOST" true 2>/dev/null; then
    echo "Error: SSH 连不上 $SSH_HOST（检查 ~/.ssh/config / ssh-agent）" >&2
    exit 1
  fi
fi

# ---------- 解析 manifest ----------
# 已踩过的坑：必须先过滤空行 + 纯注释行（行首可有空格）。awk 'NF && !/^#/' 会
# 漏掉缩进的注释行；用 !/^[[:space:]]*#/ 才完整。
if [[ ! -f "$MANIFEST" ]]; then
  echo "Error: 同步清单不存在: $MANIFEST" >&2
  exit 1
fi

# 关键约束：bash 3.2（macOS /usr/bin/bash）不支持 mapfile，用 while-read 替代。
ENTRIES=()
while IFS= read -r line; do
  ENTRIES+=("$line")
done < <(awk 'NF && !/^[[:space:]]*#/' "$MANIFEST")

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  echo "Info: 同步清单为空，无文件可同步"
  exit 0
fi

# ---------- 计算清单里实际存在的文件 ----------
# 关键设计：清单里写了但本机不存在的路径 → 警告 + 跳过，不让脚本 fail。
# 因为同步是双向通用的，可能你是在 Studio 上跑（清单里有 MBP 独有的文件）。
EXISTING=()
MISSING=()
for entry in "${ENTRIES[@]}"; do
  src="$ROOT_DIR/$entry"
  if [[ -e "$src" ]]; then
    EXISTING+=("$entry")
  else
    MISSING+=("$entry")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Warning: 清单里有 ${#MISSING[@]} 个路径在本机不存在（已跳过）：" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
fi

if [[ ${#EXISTING[@]} -eq 0 ]]; then
  echo "Info: 清单里没有任何文件实际存在，退出"
  exit 0
fi

# 总大小：macOS BSD du 不支持 -b（仅 KB/MB 模式），且 du -h 会打 verbose 进度条
# 到 stdout（污染 dry-run 输出）。改用 du -skc 拿 KB 数字（无 verbose），再自己换算
# human readable。已踩过的坑：du -shc 在 macOS 上输出形如 "64M  total" + 进度
# 条；du -skc 是干净的 "<kb>\t<path>" + 最后一行 "<kb>\ttotal"。
TOTAL_KB=$(du -skc "${EXISTING[@]/#/$ROOT_DIR/}" 2>/dev/null | tail -1 | awk '{print $1}')
TOTAL_HUMAN=$(awk -v kb="$TOTAL_KB" 'BEGIN {
  units[0]="K"; units[1]="M"; units[2]="G"; units[3]="T"
  v=kb; u=0
  while (v >= 1024 && u < 3) { v /= 1024; u++ }
  if (u == 0) printf "%d%s\n", v, units[u]
  else printf "%.1f%s\n", v, units[u]
}')

echo ""
echo "=========================================="
echo "  源   : $ROOT_DIR"
echo "  目标 : $ALIAS:$REMOTE_PATH/"
echo "  模式 : $([[ $APPLY -eq 1 ]] && echo "APPLY（真传）" || echo "DRY-RUN（仅预演）")"
echo "  条目 : ${#EXISTING[@]} 个（清单 ${#ENTRIES[@]} - 不存在 ${#MISSING[@]}）"
echo "  体积 : 约 $TOTAL_HUMAN"
echo "=========================================="
echo "将同步："
printf '  • %s\n' "${EXISTING[@]}"
echo ""

# ---------- list-only 直接退出 ----------
[[ $LIST_ONLY -eq 1 ]] && exit 0

# ---------- dry-run 退出 ----------
if [[ $APPLY -eq 0 ]]; then
  echo "Info: 这是 dry-run。要真传请加 --apply"
  exit 0
fi

# ---------- apply 二次确认 ----------
# 已踩过的坑：read -p 在 macOS /bin/sh 下没有，但本脚本 #!/usr/bin/env bash
# 一定走 bash，所以 OK。
if [[ $YES -eq 0 ]]; then
  read -r -p "确认同步到 $ALIAS ? [y/N] " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
  fi
fi

# ---------- 真同步 ----------
echo ""
echo ">>> 开始同步 ..."
# 设计：每个 EXISTING 单独跑一次 rsync。
# 原因 1：rsync --files-from 在某些路径不存在时会整体失败，单独跑更鲁棒。
# 原因 2：可以分别处理"文件 vs 目录"——目录要带尾 / 同步内容，文件不要。
# 原因 3：--exclude-from 只对目录递归生效，对单文件无效——对单文件加也无所谓。
for entry in "${EXISTING[@]}"; do
  src="$ROOT_DIR/$entry"
  if [[ -d "$src" ]]; then
    rsync -az --exclude-from="$EXCLUDE_LIST" \
      "$src/" "$SSH_HOST:$REMOTE_PATH/$entry/"
  else
    rsync -az --exclude-from="$EXCLUDE_LIST" \
      "$src" "$SSH_HOST:$REMOTE_PATH/$entry"
  fi
  echo "  ok $entry"
done

# ---------- 同步后风险缓解 ----------
# 决策 3c：Secrets.xcconfig / notes.md 含明文密钥。chmod 600 至少让其他用户
# 读不到。两端磁盘上仍是明文，但 SSH 传输本身已加密。
echo ""
echo ">>> 对端 chmod 600 Secrets.xcconfig / notes.md ..."
ssh "$SSH_HOST" "cd '$REMOTE_PATH' && \
  chmod 600 Configs/Secrets.xcconfig notes.md 2>/dev/null || true"

echo ""
echo "ok 同步完成"
