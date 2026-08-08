#!/usr/bin/env bash
# =============================================================================
# prepare-starcat-api-restore.sh — 离线合并五个独立 App 备份
# =============================================================================
#
# 该脚本只在本机读取 fly-backup-data.sh 生成的 data.tar.gz，不连接 Fly，
# 不修改任何来源备份。产物是可一次性恢复到 starcat-api /data 的合并归档。
#
# 必填环境变量：
#   SHARING_BACKUP / TRENDING_BACKUP / WEEKLY_BACKUP / WIKI_BACKUP /
#   DISCOVERY_BACKUP
# 可选：OUTPUT_ARCHIVE（默认 backups/starcat-api/<timestamp>/data.tar.gz）
#
# 关键约束：
#   - 每个 SQLite 主库都必须通过 PRAGMA integrity_check。
#   - weekly-repo 必须随 weekly.db 一起迁移。
#   - 不复制任何 -wal / -shm；五份备份先合成一包，远端只清空一次。
# =============================================================================

set -euo pipefail
# macOS bsdtar 默认写入 AppleDouble `._*`；恢复归档必须只含真实 data/ 内容。
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUTPUT_ARCHIVE="${OUTPUT_ARCHIVE:-$SUPPORTS_DIR/backups/starcat-api/$TS/data.tar.gz}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/starcat-api-restore-merge.XXXXXX")"
MERGED_DATA="$WORK_DIR/merged/data"

cleanup() {
  # WORK_DIR 是本脚本通过 mktemp 创建的精确目录，不接受外部覆盖。
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

require_archive() {
  local env_name="$1"
  local value="${!env_name:-}"
  if [[ -z "$value" ]]; then
    echo "Error: required environment variable is empty: $env_name" >&2
    exit 1
  fi
  if [[ ! -f "$value" ]]; then
    echo "Error: backup archive not found for $env_name: $value" >&2
    exit 1
  fi
  local absolute_dir
  absolute_dir="$(cd "$(dirname "$value")" && pwd)"
  printf '%s/%s\n' "$absolute_dir" "$(basename "$value")"
}

validate_archive_paths() {
  local archive="$1"
  # 拒绝绝对路径、..、链接和 data/ 外成员，避免解包覆盖临时目录之外的文件。
  python3 - "$archive" <<'PY'
import pathlib
import sys
import tarfile

archive = sys.argv[1]
with tarfile.open(archive, "r:gz") as source:
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

merge_service_backup() {
  local service="$1"
  local archive="$2"
  local db_name="$3"
  local extract_dir="$WORK_DIR/$service"
  local source_db="$extract_dir/data/$db_name"

  validate_archive_paths "$archive"
  mkdir -p "$extract_dir"
  tar xzf "$archive" -C "$extract_dir"
  if [[ ! -f "$source_db" ]]; then
    echo "Error: $service backup is missing data/$db_name: $archive" >&2
    exit 1
  fi

  local integrity
  integrity="$(sqlite3 "$source_db" 'PRAGMA integrity_check;')"
  if [[ "$integrity" != "ok" ]]; then
    echo "Error: SQLite integrity_check failed for $service: $integrity" >&2
    exit 1
  fi
  cp "$source_db" "$MERGED_DATA/$db_name"

  if [[ "$service" == "weekly" ]]; then
    if [[ ! -d "$extract_dir/data/weekly-repo" ]]; then
      echo "Error: weekly backup is missing data/weekly-repo/: $archive" >&2
      exit 1
    fi
    cp -R "$extract_dir/data/weekly-repo" "$MERGED_DATA/weekly-repo"
  fi
}

SHARING_ARCHIVE="$(require_archive SHARING_BACKUP)"
TRENDING_ARCHIVE="$(require_archive TRENDING_BACKUP)"
WEEKLY_ARCHIVE="$(require_archive WEEKLY_BACKUP)"
WIKI_ARCHIVE="$(require_archive WIKI_BACKUP)"
DISCOVERY_ARCHIVE="$(require_archive DISCOVERY_BACKUP)"

if [[ -e "$OUTPUT_ARCHIVE" ]]; then
  echo "Error: output already exists; refusing to overwrite: $OUTPUT_ARCHIVE" >&2
  exit 1
fi

mkdir -p "$MERGED_DATA"
merge_service_backup sharing "$SHARING_ARCHIVE" sharing.db
merge_service_backup trending "$TRENDING_ARCHIVE" trending.db
merge_service_backup weekly "$WEEKLY_ARCHIVE" weekly.db
merge_service_backup wiki "$WIKI_ARCHIVE" wiki.db
merge_service_backup discovery "$DISCOVERY_ARCHIVE" discovery.db

if find "$MERGED_DATA" -type f \( -name '*-wal' -o -name '*-shm' \) | grep -q .; then
  echo "Error: merged archive unexpectedly contains SQLite WAL/SHM files" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_ARCHIVE")"
tar czf "$OUTPUT_ARCHIVE" -C "$WORK_DIR/merged" data

MANIFEST="$(dirname "$OUTPUT_ARCHIVE")/MANIFEST.txt"
{
  echo "app=starcat-api"
  echo "timestamp=$TS"
  echo "archive=$(basename "$OUTPUT_ARCHIVE")"
  echo "sharing_backup=$SHARING_ARCHIVE"
  echo "trending_backup=$TRENDING_ARCHIVE"
  echo "weekly_backup=$WEEKLY_ARCHIVE"
  echo "wiki_backup=$WIKI_ARCHIVE"
  echo "discovery_backup=$DISCOVERY_ARCHIVE"
  echo "sqlite_integrity_check=ok"
  echo "contains=data/sharing.db,data/trending.db,data/weekly.db,data/weekly-repo/,data/wiki.db,data/discovery.db"
  echo "excluded=*-wal,*-shm"
} >"$MANIFEST"

echo "✓ starcat-api restore archive prepared: $OUTPUT_ARCHIVE"
echo "  manifest: $MANIFEST"
