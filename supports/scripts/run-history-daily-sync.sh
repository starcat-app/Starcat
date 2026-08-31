#!/usr/bin/env bash
# 串联 WatchEvent Raw 追赶与 History Delta 发布，供人工执行和 launchd 共用。
set -euo pipefail

# launchd 默认 PATH 不包含 Homebrew；同时保留 Apple Silicon 与 Intel 的标准安装位置。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
supports_root="$(cd "${script_dir}/.." && pwd)"
trainer_root="${STARCAT_TRAINER_ROOT:-${supports_root}/starcat-recsys-trainer}"
history_api_root="${STARCAT_HISTORY_API_ROOT:-${supports_root}/starcat-history-api}"
environment_file="${STARCAT_HISTORY_DAILY_ENV_FILE:-${HOME}/.config/starcat/history-daily.env}"
lock_dir="${STARCAT_HISTORY_DAILY_LOCK_DIR:-${TMPDIR:-/tmp}/starcat-history-daily-sync.lock}"
target_date="${1:-$(date -u -v-1d +%F)}"

if [[ ! -f "${environment_file}" ]]; then
  echo "每日增量环境文件不存在: ${environment_file}" >&2
  exit 2
fi

# 密钥保存在仓库外的 0600 文件中。launchd 不继承交互式 shell 环境，因此统一在这里加载。
set -a
# shellcheck disable=SC1090
source "${environment_file}"
set +a

if [[ -z "${HISTORY_PUBLISH_KEY:-}" ]]; then
  keychain_service="${STARCAT_HISTORY_KEYCHAIN_SERVICE:-com.starcat.history-publish-key}"
  keychain_account="${STARCAT_HISTORY_KEYCHAIN_ACCOUNT:-$(id -un)}"
  HISTORY_PUBLISH_KEY="$(
    /usr/bin/security find-generic-password \
      -a "${keychain_account}" \
      -s "${keychain_service}" \
      -w 2>/dev/null
  )" || true
  export HISTORY_PUBLISH_KEY
fi
if [[ -z "${HISTORY_PUBLISH_KEY:-}" ]]; then
  echo "History Publish Key 未配置到环境文件或 macOS Keychain" >&2
  exit 2
fi
if [[ ! -x "${trainer_root}/scripts/download-watch-events.sh" ]]; then
  echo "Trainer WatchEvent 脚本不可执行: ${trainer_root}" >&2
  exit 2
fi
if [[ ! -x "${history_api_root}/scripts/run-daily-catch-up.sh" ]]; then
  echo "History 追赶脚本不可执行: ${history_api_root}" >&2
  exit 2
fi

watch_volume_root="${STARCAT_WATCH_VOLUME_ROOT:-/Volumes/T0}"
watch_workspace="${STARCAT_WATCH_WORKSPACE:-${watch_volume_root}/Starcat/bigquery/watch-events-2016-2026}"
probe_directory="${watch_workspace}/raw/gh_archive"
probe_file="${probe_directory}/.starcat-daily-write-probe.$$"
if [[ ! -d "${probe_directory}" ]] || ! /usr/bin/touch "${probe_file}" 2>/dev/null; then
  echo "后台任务无法写入 WatchEvent Raw，请检查 T0 挂载与 macOS 完全磁盘访问权限" >&2
  exit 2
fi
/bin/rm "${probe_file}"

if ! /bin/mkdir "${lock_dir}" 2>/dev/null; then
  echo "每日增量任务已在运行，跳过本次触发。"
  exit 0
fi
cleanup_lock() {
  /bin/rmdir "${lock_dir}" 2>/dev/null || true
}
trap cleanup_lock EXIT HUP INT TERM

printf '%s INFO 开始 WatchEvent/History 每日增量，目标水位 %s。\n' \
  "$(date '+%F %T')" "${target_date}"

(
  cd "${trainer_root}"
  STARCAT_WATCH_TARGET_DATE="${target_date}" \
    ./scripts/download-watch-events.sh catch-up
)

(
  cd "${history_api_root}"
  ./scripts/run-daily-catch-up.sh "${target_date}"
)

printf '%s INFO WatchEvent/History 每日增量完成，目标水位 %s。\n' \
  "$(date '+%F %T')" "${target_date}"
