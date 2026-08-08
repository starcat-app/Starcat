#!/usr/bin/env bash
# =============================================================================
# fly-restore-data.sh — 用本地 SQLite 或备份 tar 恢复 Fly App 的 /data 卷
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
#   RESTORE_ARCHIVE=supports/backups/starcat-api/.../data.tar.gz bash supports/scripts/fly-restore-data.sh starcat-api
#
# Makefile：
#   make fly-restore-trending LOCAL_DB=/path/to/trending.db
#   make fly-restore-trending RESTORE_ARCHIVE=supports/backups/.../data.tar.gz
#
# 流程：
#   独立 App：stop → start（仅为 SSH）→ 清空 /data → 上传 → restart
#   聚合 App：确认 maintenance health → 清空 /data 一次 → 上传合并归档；保持维护态
#
# 注意：
#   - 覆盖生产卷，操作前请先 make fly-backup-<app>。
#   - LOCAL_DB 模式也会先清空整个 /data，再只上传主 .db；同卷其它文件不会保留。
#     若本地同目录有 .db-wal / .db-shm 会一并上传。Weekly 要保留 weekly-repo 必须用整包归档。
#   - RESTORE_ARCHIVE 为 fly-backup 产出的 data.tar.gz，会整包恢复 /data（含 weekly-repo）。
#   - starcat-api 只接受 prepare-starcat-api-restore.sh 生成的合并归档，且要求已进入维护模式。
#   - schema 须与当前 Fly 镜像一致，否则服务可能启动失败。
#
# 依赖：flyctl、python3、sqlite3、tar
# =============================================================================

set -euo pipefail
# 避免本机重打包时向 Linux /data 注入 macOS AppleDouble `._*` 元数据。
export COPYFILE_DISABLE=1

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "Usage: $0 <fly-app-name>" >&2
  echo "  Set LOCAL_DB= or RESTORE_ARCHIVE=" >&2
  exit 1
fi

LOCAL_DB="${LOCAL_DB:-}"
RESTORE_ARCHIVE="${RESTORE_ARCHIVE:-}"
IS_AGGREGATE=0
if [[ "$APP" == "starcat-api" ]]; then
  IS_AGGREGATE=1
fi

if [[ -n "$LOCAL_DB" && -n "$RESTORE_ARCHIVE" ]]; then
  echo "Error: set only one of LOCAL_DB or RESTORE_ARCHIVE" >&2
  exit 1
fi
if [[ -z "$LOCAL_DB" && -z "$RESTORE_ARCHIVE" ]]; then
  echo "Error: LOCAL_DB or RESTORE_ARCHIVE is required" >&2
  exit 1
fi
if [[ "$IS_AGGREGATE" == "1" && -n "$LOCAL_DB" ]]; then
  echo "Error: starcat-api only accepts one merged RESTORE_ARCHIVE; LOCAL_DB is unsafe" >&2
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
REMOTE_DB=""
if [[ "$IS_AGGREGATE" == "0" ]]; then
  REMOTE_DB="$(remote_db_path)"
fi
TS="$(date +%Y%m%d-%H%M%S)"
REMOTE_TAR="/tmp/starcat-fly-restore-${TS}.tar.gz"
WORK_DIR=""

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

validate_archive_paths() {
  local archive="$1"
  python3 - "$archive" <<'PY'
import pathlib
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:gz") as source:
    for member in source.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe archive path: {member.name}")
        if not path.parts or path.parts[0] != "data":
            raise SystemExit(f"archive member outside data/: {member.name}")
        if member.issym() or member.islnk():
            raise SystemExit(f"archive link is not allowed: {member.name}")
PY
}

validate_aggregate_tree() {
  local data_dir="$1"
  local db_name
  for db_name in sharing.db trending.db weekly.db wiki.db discovery.db; do
    if [[ ! -f "$data_dir/$db_name" ]]; then
      echo "Error: merged archive is missing data/$db_name" >&2
      exit 1
    fi
    if [[ "$(sqlite3 "$data_dir/$db_name" 'PRAGMA integrity_check;')" != "ok" ]]; then
      echo "Error: SQLite integrity_check failed for data/$db_name" >&2
      exit 1
    fi
  done
  if [[ ! -d "$data_dir/weekly-repo" ]]; then
    echo "Error: merged archive is missing data/weekly-repo/" >&2
    exit 1
  fi
  if find "$data_dir" -type f \( -name '*-wal' -o -name '*-shm' \) | grep -q .; then
    echo "Error: merged archive must not contain SQLite WAL/SHM files" >&2
    exit 1
  fi
}

require_aggregate_maintenance() {
  local health_url="https://starcat-api.fly.dev/healthz"
  if ! curl -fsS "$health_url" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
if payload.get("status") != "maintenance":
    raise SystemExit("health status is not maintenance")
'; then
    echo "Error: starcat-api is not confirmed in maintenance mode; refusing to touch /data" >&2
    exit 1
  fi
}

echo "⚠️  [$APP] 将覆盖远端 /data（machine=${MID}）"
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

# 所有可失败的归档结构与 SQLite 检查都必须在远端清空 /data 之前完成。
if [[ -n "$RESTORE_ARCHIVE" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/starcat-restore.XXXXXX")"
  echo ">>> validating archive locally ..."
  validate_archive_paths "$RESTORE_ARCHIVE"
  tar xzf "$RESTORE_ARCHIVE" -C "$WORK_DIR"
  if [[ ! -d "$WORK_DIR/data" ]]; then
    echo "Error: archive must contain top-level data/ directory (from fly-backup)" >&2
    exit 1
  fi
  if [[ "$IS_AGGREGATE" == "1" ]]; then
    validate_aggregate_tree "$WORK_DIR/data"
  fi
  LOCAL_REPACK="${WORK_DIR}/upload.tar.gz"
  tar czf "$LOCAL_REPACK" -C "$WORK_DIR" data
fi

if [[ "$IS_AGGREGATE" == "1" ]]; then
  echo ">>> verifying starcat-api maintenance gate ..."
  require_aggregate_maintenance
fi

if [[ "${FLY_RESTORE_YES:-0}" != "1" ]]; then
  read -r -p "输入 ${APP} 确认覆盖: " confirm
  if [[ "$confirm" != "$APP" ]]; then
    echo "已取消（未输入匹配的 app 名）"
    exit 1
  fi
fi

if [[ "$IS_AGGREGATE" == "0" ]]; then
  echo ">>> stopping machine ..."
  fly machine stop "$MID" -a "$APP"
  sleep 5

  echo ">>> starting machine for SSH/SFTP ..."
  fly machine start "$MID" -a "$APP"
  sleep 15
fi

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
  echo ">>> uploading archive to remote ..."
  fly ssh sftp put -a "$APP" "$LOCAL_REPACK" "$REMOTE_TAR"

  echo ">>> extracting on remote into / ..."
  fly ssh console -a "$APP" -C "sh -c 'tar xzf ${REMOTE_TAR} -C / && rm -f ${REMOTE_TAR} && ls -lah /data'"
fi

# 归档在 macOS 上离线解包、重打包后会携带本机 UID/GID；SFTP 上传也由 root 创建。
# 运行镜像使用非 root 的 app 用户，必须在服务恢复前统一所有权，否则 SQLite 无法创建 WAL。
echo ">>> restoring /data ownership for app user ..."
fly ssh console -a "$APP" -C "chown -R app:app /data"

if [[ "$IS_AGGREGATE" == "0" ]]; then
  echo ">>> restarting machine ..."
  fly machine restart "$MID" -a "$APP"
fi

echo ""
echo "✓ Restore complete for $APP"
fly ssh console -a "$APP" -C "ls -lah /data" || true
if [[ "$IS_AGGREGATE" == "1" ]]; then
  echo "  starcat-api remains in maintenance mode."
  echo "  Validate /data, then run: fly secrets unset STARCAT_MAINTENANCE_MODE -a starcat-api"
  echo "  Finally verify /healthz and all six service routes before stopping any legacy App."
fi
