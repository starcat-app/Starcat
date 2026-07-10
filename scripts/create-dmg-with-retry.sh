#!/usr/bin/env bash
#
# create-dmg-with-retry.sh — Starcat Direct DMG 生成保护层。
#
# create-dmg 为了写入背景图、图标位置和窗口大小，会通过 Finder AppleScript
# 操作临时挂载卷。Finder 属于 GUI 进程，偶发繁忙时会触发 AppleEvent timeout
# (-1712)。这里不修改 Homebrew 安装的 create-dmg，而是在临时目录复制它的
# support template，给 AppleScript 包一层更长的 timeout，并对 Finder 超时做
# 有限重试。

set -euo pipefail

fail() {
  printf '[create-dmg-retry] ERROR: %s\n' "$1" >&2
  exit 1
}

command -v create-dmg >/dev/null 2>&1 || fail "create-dmg 未安装"

REAL_CREATE_DMG="$(command -v create-dmg)"
SCRIPT_DIR="$(cd "$(dirname "$REAL_CREATE_DMG")" && pwd)"
PREFIX_DIR="$(dirname "$SCRIPT_DIR")"
SUPPORT_DIR="${PREFIX_DIR}/share/create-dmg/support"
TEMPLATE_FILE="${SUPPORT_DIR}/template.applescript"

[ -f "$REAL_CREATE_DMG" ] || fail "找不到 create-dmg: $REAL_CREATE_DMG"
[ -f "$TEMPLATE_FILE" ] || fail "找不到 create-dmg AppleScript template: $TEMPLATE_FILE"
[ "$#" -ge 2 ] || fail "参数不足：需要 create-dmg 原始参数"

ARGS=("$@")
ARG_COUNT="${#ARGS[@]}"
DMG_PATH="${ARGS[$((ARG_COUNT - 2))]}"

ATTEMPTS="${STARCAT_DMG_RETRY_COUNT:-3}"
RETRY_SLEEP_SECONDS="${STARCAT_DMG_RETRY_SLEEP_SECONDS:-60}"
APPLESCRIPT_TIMEOUT_SECONDS="${STARCAT_DMG_APPLESCRIPT_TIMEOUT_SECONDS:-600}"

if ! [[ "$ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$ATTEMPTS" -lt 1 ]; then
  fail "STARCAT_DMG_RETRY_COUNT 必须是大于 0 的整数，当前: $ATTEMPTS"
fi
if ! [[ "$RETRY_SLEEP_SECONDS" =~ ^[0-9]+$ ]]; then
  fail "STARCAT_DMG_RETRY_SLEEP_SECONDS 必须是非负整数，当前: $RETRY_SLEEP_SECONDS"
fi
if ! [[ "$APPLESCRIPT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$APPLESCRIPT_TIMEOUT_SECONDS" -lt 60 ]; then
  fail "STARCAT_DMG_APPLESCRIPT_TIMEOUT_SECONDS 必须是 >= 60 的整数，当前: $APPLESCRIPT_TIMEOUT_SECONDS"
fi

TMP_ROOT="$(mktemp -d -t starcat-create-dmg.XXXXXXXXXX)"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/share/create-dmg"
cp "$REAL_CREATE_DMG" "$TMP_ROOT/bin/create-dmg"
cp -R "$SUPPORT_DIR" "$TMP_ROOT/share/create-dmg/support"

# create-dmg 运行时会从自身 prefix 读取 support/template.applescript。
# 只 patch 临时副本，避免污染 Homebrew 管理的文件。
python3 - "$TMP_ROOT/share/create-dmg/support/template.applescript" "$APPLESCRIPT_TIMEOUT_SECONDS" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
timeout = sys.argv[2]
text = path.read_text()

needle = 'tell application "Finder"'
replacement = f'with timeout of {timeout} seconds\n\t\ttell application "Finder"'
if needle not in text:
    raise SystemExit(f"template 中找不到 {needle!r}")

text = text.replace(needle, replacement, 1)
ending = "\n\tend tell\nend run"
if ending not in text:
    raise SystemExit("template 中找不到 Finder tell 结尾")
text = text.replace(ending, "\n\tend tell\n\tend timeout\nend run", 1)
path.write_text(text)
PY

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  attempt_log="$TMP_ROOT/create-dmg-attempt-${attempt}.log"
  printf '[create-dmg-retry] create-dmg attempt %s/%s, Finder AppleScript timeout=%ss\n' \
    "$attempt" "$ATTEMPTS" "$APPLESCRIPT_TIMEOUT_SECONDS" >&2

  rm -f "$DMG_PATH"
  set +e
  "$TMP_ROOT/bin/create-dmg" "${ARGS[@]}" >"$attempt_log" 2>&1
  status="$?"
  set -e

  if [ "$status" -eq 0 ]; then
    exit 0
  fi

  cat "$attempt_log" >&2
  if [ "$attempt" -ge "$ATTEMPTS" ]; then
    exit "$status"
  fi

  if ! grep -Eqi 'AppleEvent|AppleScript|timed out|已超时|Resource busy|hdiutil.*detach' "$attempt_log"; then
    exit "$status"
  fi

  printf '[create-dmg-retry] create-dmg failed with exit %s; retrying after %ss\n' \
    "$status" "$RETRY_SLEEP_SECONDS" >&2
  sleep "$RETRY_SLEEP_SECONDS"
  attempt=$((attempt + 1))
done
