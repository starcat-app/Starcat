#!/usr/bin/env bash
# 以假的上下游脚本验证每日编排顺序、目标日期和锁释放。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d)"
cleanup() {
  /bin/rm -rf "${fixture_root}"
}
trap cleanup EXIT

trainer_root="${fixture_root}/trainer"
history_root="${fixture_root}/history"
record_file="${fixture_root}/calls.log"
environment_file="${fixture_root}/history-daily.env"
lock_dir="${fixture_root}/daily.lock"
watch_workspace="${fixture_root}/watch"
/bin/mkdir -p \
  "${trainer_root}/scripts" \
  "${history_root}/scripts" \
  "${watch_workspace}/raw/gh_archive"

cat >"${environment_file}" <<'EOF'
HISTORY_PUBLISH_KEY=test-only-key
EOF

cat >"${trainer_root}/scripts/download-watch-events.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'watch:%s:%s\n' "\${1:-}" "\${STARCAT_WATCH_TARGET_DATE:-}" >>"${record_file}"
EOF
cat >"${history_root}/scripts/run-daily-catch-up.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'history:%s\n' "\${1:-}" >>"${record_file}"
EOF
chmod +x \
  "${trainer_root}/scripts/download-watch-events.sh" \
  "${history_root}/scripts/run-daily-catch-up.sh"

STARCAT_TRAINER_ROOT="${trainer_root}" \
STARCAT_HISTORY_API_ROOT="${history_root}" \
STARCAT_HISTORY_DAILY_ENV_FILE="${environment_file}" \
STARCAT_HISTORY_DAILY_LOCK_DIR="${lock_dir}" \
STARCAT_WATCH_WORKSPACE="${watch_workspace}" \
  "${script_dir}/run-history-daily-sync.sh" 2026-08-30 >/dev/null

expected=$'watch:catch-up:2026-08-30\nhistory:2026-08-30'
actual="$(<"${record_file}")"
if [[ "${actual}" != "${expected}" ]]; then
  echo "每日编排调用顺序不正确" >&2
  exit 1
fi
if [[ -d "${lock_dir}" ]]; then
  echo "每日编排结束后未释放互斥锁" >&2
  exit 1
fi

echo "每日增量编排测试通过"
