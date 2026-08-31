#!/usr/bin/env bash
# 安装或卸载本机每日 WatchEvent/History 增量 LaunchAgent。
set -euo pipefail

readonly LABEL="com.starcat.history-daily-sync"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="${script_dir}/run-history-daily-sync.sh"
plist="${HOME}/Library/LaunchAgents/${LABEL}.plist"
environment_file="${STARCAT_HISTORY_DAILY_ENV_FILE:-${HOME}/.config/starcat/history-daily.env}"
log_file="${STARCAT_HISTORY_DAILY_LOG_FILE:-${HOME}/Library/Logs/Starcat/history-daily-sync.log}"
domain="gui/$(id -u)"

xml_escape() {
  printf '%s' "$1" | /usr/bin/sed \
    -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

render_plist() {
  local escaped_runner escaped_environment escaped_log
  escaped_runner="$(xml_escape "${runner}")"
  escaped_environment="$(xml_escape "${environment_file}")"
  escaped_log="$(xml_escape "${log_file}")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${escaped_runner}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>STARCAT_HISTORY_DAILY_ENV_FILE</key>
    <string>${escaped_environment}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>10</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>${escaped_log}</string>
  <key>StandardErrorPath</key>
  <string>${escaped_log}</string>
</dict>
</plist>
EOF
}

install_agent() {
  if [[ ! -x "${runner}" ]]; then
    echo "每日增量脚本不可执行: ${runner}" >&2
    exit 2
  fi
  if [[ ! -f "${environment_file}" ]]; then
    echo "请先创建环境文件: ${environment_file}" >&2
    exit 2
  fi
  local permissions
  permissions="$(stat -f '%Lp' "${environment_file}")"
  if [[ "${permissions}" != "600" ]]; then
    echo "环境文件权限必须是 600，当前为 ${permissions}: ${environment_file}" >&2
    exit 2
  fi
  /bin/mkdir -p "$(dirname "${plist}")" "$(dirname "${log_file}")"
  render_plist >"${plist}"
  /usr/bin/plutil -lint "${plist}" >/dev/null
  /bin/launchctl bootout "${domain}" "${plist}" 2>/dev/null || true
  /bin/launchctl bootstrap "${domain}" "${plist}"
  echo "已安装每日增量任务：${LABEL}（每天 10:00）"
}

uninstall_agent() {
  /bin/launchctl bootout "${domain}" "${plist}" 2>/dev/null || true
  if [[ -f "${plist}" ]]; then
    /bin/rm "${plist}"
  fi
  echo "已卸载每日增量任务：${LABEL}"
}

case "${1:-}" in
  install) install_agent ;;
  uninstall) uninstall_agent ;;
  status) /bin/launchctl print "${domain}/${LABEL}" ;;
  render) render_plist ;;
  *)
    echo "用法: $0 {install|uninstall|status|render}" >&2
    exit 2
    ;;
esac
