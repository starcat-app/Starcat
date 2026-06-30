#!/usr/bin/env bash
# =============================================================================
# fly-restore-data.sh — 用本地 SQLite 或备份 tar 覆盖 Fly App 的 /data 卷
# =============================================================================
#
# 用途：
#   与 fly-backup-data.sh 对称。把本机开发库或此前备份的 data.tar.gz 写回
#   远端 /data（STORE_FILE 路径见 docs/fly-io-环境变量.md §4.3）。
#
# 用法（二选一）：
#   LOCAL_DB=./trending.db bash supports/scripts/fly-restore-data.sh starcat-trending-api
#   LOCAL_DB=./discovery.db bash supports/scripts/fly-restore-data.sh starcat-discovery-api
#   RESTORE_ARCHIVE=supports/backups/.../data.tar.gz bash supports/scripts/fly-restore-data.sh starcat-trending-api
#
# Makefile：
#   make fly-restore-trending LOCAL_DB=/path/to/trending.db
#   make fly-restore-trending RESTORE_ARCHIVE=supports/backups/.../data.tar.gz
#
# 流程：
#   stop machine → start（仅为 SSH）→ 清空 /data → 上传 → restart
#
# 注意：
#   - 覆盖生产卷，操作前请先 make fly-backup-<app>。
#   - LOCAL_DB 只替换主 .db；若同目录有 .db-wal / .db-shm 会一并上传。
#   - RESTORE_ARCHIVE 为 fly-backup 产出的 data.tar.gz，会整包恢复 /data（含 weekly-repo）。
#   - schema 须与当前 Fly 镜像一致，否则服务可能启动失败。
#
# 依赖：flyctl、python3、tar
# =============================================================================

set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "Usage: $0 <fly-app-name>" >&2
  echo "  Set LOCAL_DB= or RESTORE_ARCHIVE=" >&2
  exit 1
fi

LOCAL_DB="${LOCAL_DB:-}"
RESTORE_ARCHIVE="${RESTORE_ARCHIVE:-}"

if [[ -n "$LOCAL_DB" && -n "$RESTORE_ARCHIVE" ]]; then
  echo "Error: set only one of LOCAL_DB or RESTORE_ARCHIVE" >&2
  exit 1
fi
if [[ -z "$LOCAL_DB" && -z "$RESTORE_ARCHIVE" ]]; then
  echo "Error: LOCAL_DB or RESTORE_ARCHIVE is required" >&2
  exit 1
fi

remote_db_path() {
  case "$APP" in
    starcat-sharing-api) echo "/data/sharing.db" ;;
    starcat-trending-api) echo "/data/trending.db" ;;
    starcat-weekly-api) echo "/data/weekly.db" ;;
    starcat-wiki-api) echo "/data/wiki.db" ;;
    starcat-discovery-api) echo "/data/discovery.db" ;;
    *)
      echo "Error: unknown app $APP" >&2
      exit 1
      ;;
  esac
}

machine_id() {
  fly machine list -a "$APP" --json | python3 -c "
import json, sys
machines = json.load(sys.stdin)
if not machines:
    raise SystemExit('no machines')
print(machines[0]['id'])
"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MID="$(machine_id)"
REMOTE_DB="$(remote_db_path)"
TS="$(date +%Y%m%d-%H%M%S)"
REMOTE_TAR="/tmp/starcat-fly-restore-${TS}.tar.gz"
WORK_DIR=""

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "⚠️  [$APP] 将覆盖远端 /data（machine=$MID）"
if [[ -n "$LOCAL_DB" ]]; then
  if [[ ! -f "$LOCAL_DB" ]]; then
    echo "Error: LOCAL_DB not found: $LOCAL_DB" >&2
    exit 1
  fi
  LOCAL_DB="$(cd "$(dirname "$LOCAL_DB")" && pwd)/$(basename "$LOCAL_DB")"
  echo "    mode=LOCAL_DB"
  echo "    source=$LOCAL_DB"
  echo "    target=$REMOTE_DB"
else
  if [[ ! -f "$RESTORE_ARCHIVE" ]]; then
    echo "Error: RESTORE_ARCHIVE not found: $RESTORE_ARCHIVE" >&2
    exit 1
  fi
  RESTORE_ARCHIVE="$(cd "$(dirname "$RESTORE_ARCHIVE")" && pwd)/$(basename "$RESTORE_ARCHIVE")"
  echo "    mode=RESTORE_ARCHIVE"
  echo "    source=$RESTORE_ARCHIVE"
  echo "    target=/data/*"
fi

if [[ "${FLY_RESTORE_YES:-0}" != "1" ]]; then
  read -r -p "输入 ${APP} 确认覆盖: " confirm
  if [[ "$confirm" != "$APP" ]]; then
    echo "已取消（未输入匹配的 app 名）"
    exit 1
  fi
fi

echo ">>> stopping machine ..."
fly machine stop "$MID" -a "$APP"
sleep 5

echo ">>> starting machine for SSH/SFTP ..."
fly machine start "$MID" -a "$APP"
sleep 15

echo ">>> clearing /data on remote ..."
fly ssh console -a "$APP" -C "sh -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; ls -la /data'"

if [[ -n "$LOCAL_DB" ]]; then
  echo ">>> uploading SQLite files ..."
  fly ssh sftp put -a "$APP" "$LOCAL_DB" "$REMOTE_DB"
  if [[ -f "${LOCAL_DB}-wal" ]]; then
    fly ssh sftp put -a "$APP" "${LOCAL_DB}-wal" "${REMOTE_DB}-wal"
  fi
  if [[ -f "${LOCAL_DB}-shm" ]]; then
    fly ssh sftp put -a "$APP" "${LOCAL_DB}-shm" "${REMOTE_DB}-shm"
  fi
else
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/starcat-restore.XXXXXX")"
  echo ">>> extracting archive locally ..."
  tar xzf "$RESTORE_ARCHIVE" -C "$WORK_DIR"
  if [[ ! -d "$WORK_DIR/data" ]]; then
    echo "Error: archive must contain top-level data/ directory (from fly-backup)" >&2
    exit 1
  fi
  LOCAL_REPACK="${WORK_DIR}/upload.tar.gz"
  tar czf "$LOCAL_REPACK" -C "$WORK_DIR" data

  echo ">>> uploading archive to remote ..."
  fly ssh sftp put -a "$APP" "$LOCAL_REPACK" "$REMOTE_TAR"

  echo ">>> extracting on remote into / ..."
  fly ssh console -a "$APP" -C "sh -c 'tar xzf ${REMOTE_TAR} -C / && rm -f ${REMOTE_TAR} && ls -lah /data'"
fi

echo ">>> restarting machine ..."
fly machine restart "$MID" -a "$APP"

echo ""
echo "✓ Restore complete for $APP"
fly ssh console -a "$APP" -C "ls -lah /data" || true
