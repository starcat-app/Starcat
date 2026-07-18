#!/usr/bin/env bash
# =============================================================================
# fly-backup-data.sh — 一致性备份某个 Fly App 的 /data 卷到本地目录
# =============================================================================
#
# 用途：
#   有状态 starcat-*-api 的 SQLite（及 weekly 的 weekly-repo 目录）都在容器
#   内 /data（fly.toml [[mounts]] destination）。脚本先创建 Fly Volume Snapshot
#   并等待其完成，再用 VACUUM INTO 在远端 /tmp 生成一致的 SQLite 副本，最后下载归档。
#
# 用法：
#   bash supports/scripts/fly-backup-data.sh starcat-weekly-api
#   bash supports/scripts/fly-backup-data.sh starcat-discovery-api
#
# 环境变量：
#   FLY_BACKUP_ROOT        本地备份根目录（默认 supports/backups）
#   FLY_BACKUP_MACHINE_ID  多 Machine App 时明确指定挂载目标 Volume 的 Machine
#
# 一致性说明：
#   - 平台级 Volume Snapshot 是本地归档的硬前置条件；创建失败、超时或状态非 created 时
#     不会继续生成本地备份。
#   - 归档内的主库来自 SQLite VACUUM INTO；它是源库的单一一致性视图，不包含源库的
#     -wal / -shm 文件。
#   - weekly-repo 等非数据库文件仍是在线打包，只保证文件可恢复，不提供跨文件事务一致性。
#
# 依赖：flyctl（已 login）、python3（解析 App machine）、Go（构建临时快照工具）
# =============================================================================

set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "Usage: $0 <fly-app-name>" >&2
  echo "  e.g. starcat-weekly-api" >&2
  exit 1
fi

if [[ "${FLY_BACKUP_STOP:-0}" == "1" ]]; then
  echo "Error: FLY_BACKUP_STOP=1 已废弃；备份改用在线 SQLite 一致性快照，不会停止生产服务。" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_ROOT="${FLY_BACKUP_ROOT:-$SUPPORTS_DIR/backups}"
TS="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$APP/$TS"
HELPER_DIR="$SCRIPT_DIR/sqlite-backup-helper"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/starcat-fly-backup.XXXXXX")"
REMOTE_ROOT="/tmp/starcat-fly-backup-${TS}"
REMOTE_HELPER="$REMOTE_ROOT/sqlite-backup-helper"
REMOTE_STAGE="$REMOTE_ROOT/stage"
REMOTE_TAR="$REMOTE_ROOT/data.tar.gz"
REMOTE_DB=""
RELATIVE_DB=""
VOLUME_ID=""
VOLUME_SNAPSHOT_ID=""
VOLUME_SNAPSHOT_STATUS=""
BEFORE_SNAPSHOT_IDS=""
SNAPSHOT_TIMEOUT_SECONDS=300
SNAPSHOT_POLL_SECONDS=5

cleanup() {
  # 临时目录是脚本生成的精确 /tmp 路径；清理失败不能掩盖原始备份错误。
  fly ssh console -a "$APP" -C "rm -rf $REMOTE_ROOT" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

remote_db_path() {
  case "$APP" in
    starcat-sharing-api) echo "/data/sharing.db" ;;
    starcat-trending-api) echo "/data/trending.db" ;;
    starcat-weekly-api) echo "/data/weekly.db" ;;
    starcat-wiki-api) echo "/data/wiki.db" ;;
    starcat-discovery-api) echo "/data/discovery.db" ;;
    *)
      echo "Error: unsupported stateful app: $APP" >&2
      exit 1
      ;;
  esac
}

machine_id() {
  fly machine list -a "$APP" --json | python3 -c "
import json, os, sys
machines = json.load(sys.stdin)
if not machines:
    sys.exit('no machines')
requested = os.environ.get('FLY_BACKUP_MACHINE_ID')
if requested:
    if not any(machine['id'] == requested for machine in machines):
        sys.exit(f'machine not found: {requested}')
    print(requested)
elif len(machines) == 1:
    print(machines[0]['id'])
else:
    sys.exit('multiple machines found; set FLY_BACKUP_MACHINE_ID to the machine attached to the target volume')
"
}

machine_state() {
  local mid="$1"
  fly machine list -a "$APP" --json | python3 -c "
import json, sys
mid = sys.argv[1]
for machine in json.load(sys.stdin):
    if machine['id'] == mid:
        print(machine.get('state', ''))
        break
" "$mid"
}

machine_goarch() {
  local machine_arch
  machine_arch="$(fly ssh console -a "$APP" -C "uname -m" | awk 'NF { value = $NF } END { print value }')"
  case "$machine_arch" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      echo "Error: unsupported remote architecture: $machine_arch" >&2
      exit 1
      ;;
  esac
}

volume_id() {
  fly volumes list -a "$APP" --json | python3 -c "
import json, sys
mid = sys.argv[1]
volumes = [volume for volume in json.load(sys.stdin) if volume.get('attached_machine_id') == mid]
if len(volumes) != 1:
    sys.exit(f'expected exactly one volume attached to machine {mid}, found {len(volumes)}')
print(volumes[0]['id'])
" "$MID"
}

snapshot_ids() {
  fly volumes snapshots list "$VOLUME_ID" -a "$APP" --json | python3 -c "
import json, sys
seen = set()
for snapshot in json.load(sys.stdin):
    snapshot_id = snapshot.get('id')
    if snapshot_id and snapshot_id not in seen:
        print(snapshot_id)
        seen.add(snapshot_id)
"
}

create_volume_snapshot() {
  # fly v0.4.59 的 --json 创建命令会成功但不输出 JSON，故只依赖退出码；新增 ID
  # 统一由后续 snapshots list 发现，避免因 CLI 输出格式差异误判创建失败。
  fly volumes snapshots create "$VOLUME_ID" -a "$APP"
}

new_volume_snapshot_id() {
  fly volumes snapshots list "$VOLUME_ID" -a "$APP" --json | BEFORE_SNAPSHOT_IDS="$BEFORE_SNAPSHOT_IDS" python3 -c "
import json, os, sys
known_ids = set(os.environ.get('BEFORE_SNAPSHOT_IDS', '').splitlines())
candidates = []
seen = set()
for snapshot in json.load(sys.stdin):
    snapshot_id = snapshot.get('id')
    if not snapshot_id or snapshot_id in seen:
        continue
    seen.add(snapshot_id)
    if snapshot_id not in known_ids:
        candidates.append(snapshot_id)
if len(candidates) > 1:
    sys.exit('multiple new snapshots found: ' + ', '.join(candidates))
if candidates:
    print(candidates[0])
"
}

volume_snapshot_status() {
  fly volumes snapshots list "$VOLUME_ID" -a "$APP" --json | python3 -c "
import json, sys
snapshot_id = sys.argv[1]
statuses = []
for snapshot in json.load(sys.stdin):
    if snapshot.get('id') == snapshot_id:
        status = snapshot.get('status', '')
        if status:
            statuses.append(status)
if not statuses:
    sys.exit(f'snapshot not found: {snapshot_id}')
if 'created' in statuses:
    print('created')
elif 'failed' in statuses or 'error' in statuses:
    print('failed')
else:
    print(statuses[0])
" "$VOLUME_SNAPSHOT_ID"
}

wait_for_volume_snapshot() {
  local deadline
  deadline=$((SECONDS + SNAPSHOT_TIMEOUT_SECONDS))

  while true; do
    if [[ -z "$VOLUME_SNAPSHOT_ID" ]]; then
      VOLUME_SNAPSHOT_ID="$(new_volume_snapshot_id)"
      if [[ -n "$VOLUME_SNAPSHOT_ID" ]]; then
        echo ">>> discovered volume snapshot=$VOLUME_SNAPSHOT_ID"
      fi
    else
      VOLUME_SNAPSHOT_STATUS="$(volume_snapshot_status)"
      echo ">>> volume snapshot=$VOLUME_SNAPSHOT_ID status=$VOLUME_SNAPSHOT_STATUS"
      if [[ "$VOLUME_SNAPSHOT_STATUS" == "created" ]]; then
        return
      fi
      if [[ "$VOLUME_SNAPSHOT_STATUS" == "failed" || "$VOLUME_SNAPSHOT_STATUS" == "error" ]]; then
        echo "Error: Fly Volume Snapshot failed: $VOLUME_SNAPSHOT_ID" >&2
        exit 1
      fi
    fi
    if (( SECONDS >= deadline )); then
      echo "Error: Fly Volume Snapshot did not reach created within ${SNAPSHOT_TIMEOUT_SECONDS}s: ${VOLUME_SNAPSHOT_ID:-not-discovered}" >&2
      exit 1
    fi
    sleep "$SNAPSHOT_POLL_SECONDS"
  done
}

MID="$(machine_id)"
STATE="$(machine_state "$MID")"
REMOTE_DB="$(remote_db_path)"
RELATIVE_DB="${REMOTE_DB#/}"

echo ">>> [$APP] machine=$MID state=$STATE"
if [[ "$STATE" != "started" ]]; then
  echo "Error: backup refuses to start a stopped machine; start $MID explicitly, then retry." >&2
  exit 1
fi

GOARCH="$(machine_goarch)"
LOCAL_HELPER="$WORK_DIR/sqlite-backup-helper"
if [[ ! -f "$HELPER_DIR/go.mod" ]]; then
  echo "Error: SQLite backup helper is missing: $HELPER_DIR" >&2
  exit 1
fi

echo ">>> building temporary SQLite snapshot helper for linux/$GOARCH ..."
(
  cd "$HELPER_DIR"
  CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build -ldflags="-s -w" -o "$LOCAL_HELPER" .
)

VOLUME_ID="$(volume_id)"
BEFORE_SNAPSHOT_IDS="$(snapshot_ids)"
echo ">>> creating Fly Volume Snapshot for volume=$VOLUME_ID ..."
create_volume_snapshot
wait_for_volume_snapshot

mkdir -p "$DEST"

echo ">>> preparing remote temporary workspace ..."
fly ssh console -a "$APP" -C "mkdir -p $REMOTE_ROOT"
fly ssh sftp put -a "$APP" "$LOCAL_HELPER" "$REMOTE_HELPER"

echo ">>> creating consistent SQLite snapshot and packing /data ..."
# 排除正在被服务写入的三个 SQLite 文件，避免把非原子的 .db/-wal/-shm 混入归档。
# helper 在 staged data/ 中写入新的主库并执行 integrity_check；任何一步失败都会退出。
fly ssh console -a "$APP" -C "sh -ceu '
  set -o pipefail
  chmod 700 \"$REMOTE_HELPER\"
  mkdir -p \"$REMOTE_STAGE\"
  tar --exclude=\"$RELATIVE_DB\" --exclude=\"$RELATIVE_DB-wal\" --exclude=\"$RELATIVE_DB-shm\" -C / -cf - data | tar -C \"$REMOTE_STAGE\" -xf -
  \"$REMOTE_HELPER\" \"$REMOTE_DB\" \"$REMOTE_STAGE/$RELATIVE_DB\"
  tar czf \"$REMOTE_TAR\" -C \"$REMOTE_STAGE\" data
  ls -lah \"$REMOTE_TAR\"
'"

echo ">>> downloading to ${DEST} ..."
fly ssh sftp get -a "$APP" "$REMOTE_TAR" "$DEST/data.tar.gz"

{
  echo "app=${APP}"
  echo "timestamp=${TS}"
  echo "machine=${MID}"
  echo "machine_arch=${GOARCH}"
  echo "remote_path=/data"
  echo "volume_id=${VOLUME_ID}"
  echo "volume_snapshot_id=${VOLUME_SNAPSHOT_ID}"
  echo "volume_snapshot_status=${VOLUME_SNAPSHOT_STATUS}"
  echo "remote_db=${REMOTE_DB}"
  echo "sqlite_snapshot=vacuum_into"
  echo "excluded_live_files=${RELATIVE_DB},${RELATIVE_DB}-wal,${RELATIVE_DB}-shm"
  echo "archive=data.tar.gz"
  echo "restore_hint=tar xzf data.tar.gz -C <empty-dir>   # 得到 data/ 子目录"
} >"$DEST/MANIFEST.txt"

echo ""
echo "✓ Backup saved: $DEST/data.tar.gz"
echo "  manifest:     $DEST/MANIFEST.txt"
ls -lah "$DEST"
