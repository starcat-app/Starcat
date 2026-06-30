#!/usr/bin/env bash
# =============================================================================
# fly-backup-data.sh — 从 Fly App 的 /data 卷拉取备份到本地
# =============================================================================
#
# 用途：
#   starcat-*-api 的 SQLite（及 weekly 的 weekly-repo 目录）都在容器
#   内 /data（fly.toml [[mounts]] destination）。本脚本通过 SSH 在远端打 tar 包
#   再 SFTP 下载，避免手抄路径。
#
# 用法：
#   bash supports/scripts/fly-backup-data.sh starcat-trending-api
#   bash supports/scripts/fly-backup-data.sh starcat-discovery-api
#   FLY_BACKUP_STOP=1 bash supports/scripts/fly-backup-data.sh starcat-trending-api
#
# 环境变量：
#   FLY_BACKUP_ROOT  本地备份根目录（默认 supports/backups）
#   FLY_BACKUP_STOP  设为 1 时先 stop machine 再 start（短暂停机，SQLite 更一致）
#
# 注意：
#   - 默认「热备份」：服务不停机，打包时 SQLite 可能处于 WAL 活跃写入态；
#     tar 内含 .db + .db-wal + .db-shm，恢复时三文件同目录即可。
#   - weekly 的 /data/weekly-repo 体积可能较大，首次备份会久一些。
#
# 依赖：flyctl（已 login）、python3、目标 App 至少一台 machine
# =============================================================================

set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "Usage: $0 <fly-app-name>" >&2
  echo "  e.g. starcat-trending-api" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_ROOT="${FLY_BACKUP_ROOT:-$SUPPORTS_DIR/backups}"
TS="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$APP/$TS"
REMOTE_TAR="/tmp/starcat-fly-backup-${TS}.tar.gz"

mkdir -p "$DEST"

machine_id() {
  fly machine list -a "$APP" --json | python3 -c "
import json, sys
machines = json.load(sys.stdin)
if not machines:
    sys.exit('no machines')
print(machines[0]['id'])
"
}

machine_state() {
  local mid="$1"
  fly machine list -a "$APP" --json | python3 -c "
import json, sys
mid = sys.argv[1]
for m in json.load(sys.stdin):
    if m['id'] == mid:
        print(m.get('state', ''))
        break
" "$mid"
}

MID="$(machine_id)"
STATE="$(machine_state "$MID")"

echo ">>> [$APP] machine=$MID state=$STATE"

if [[ "${FLY_BACKUP_STOP:-0}" == "1" ]]; then
  echo ">>> stopping machine for consistent SQLite snapshot ..."
  fly machine stop "$MID" -a "$APP"
  sleep 5
  fly machine start "$MID" -a "$APP"
  sleep 15
  STATE="$(machine_state "$MID")"
fi

if [[ "$STATE" != "started" ]]; then
  echo ">>> starting machine for SSH/SFTP ..."
  fly machine start "$MID" -a "$APP"
  sleep 15
fi

echo ">>> packing /data on remote ..."
fly ssh console -a "$APP" -C "sh -c 'tar czf ${REMOTE_TAR} -C / data && ls -lah ${REMOTE_TAR}'"

echo ">>> downloading to ${DEST} ..."
fly ssh sftp get -a "$APP" "$REMOTE_TAR" "$DEST/data.tar.gz"

echo ">>> cleaning remote temp archive ..."
fly ssh console -a "$APP" -C "rm -f ${REMOTE_TAR}"

{
  echo "app=${APP}"
  echo "timestamp=${TS}"
  echo "machine=${MID}"
  echo "fly_backup_stop=${FLY_BACKUP_STOP:-0}"
  echo "remote_path=/data"
  echo "archive=data.tar.gz"
  echo "restore_hint=tar xzf data.tar.gz -C <empty-dir>   # 得到 data/ 子目录"
} >"$DEST/MANIFEST.txt"

echo ""
echo "✓ Backup saved: $DEST/data.tar.gz"
echo "  manifest:     $DEST/MANIFEST.txt"
ls -lah "$DEST"
