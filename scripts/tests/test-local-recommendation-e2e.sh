#!/usr/bin/env bash
#
# 交互式推荐 E2E 脚本的纯 Shell 回归测试。
#
# 测试只覆盖无需启动真实服务的安全边界、健康检查和 source repo 选择逻辑，
# 真实 Collection → Trainer → Recommend 流程仍由主脚本执行并生成验证报告。

set -euo pipefail

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/starcat-recommend-e2e-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

export STARCAT_E2E_RUNS_ROOT="$TEST_DIR/runs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_SCRIPT="$SCRIPT_DIR/../local-recommendation-e2e.sh"
# shellcheck source=../local-recommendation-e2e.sh
source "$E2E_SCRIPT"

fail() {
  printf '测试失败：%s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "预期 '$1'，实际 '$2'"
}

# macOS 自带 Bash 3.2 在 nounset 模式下可能把紧邻变量的中文标点继续解析为
# 变量名字节。统一要求 `${name}`，避免再次出现 `expected�: unbound variable`。
if LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$E2E_SCRIPT"; then
  fail "发现未加花括号且紧邻非 ASCII 字符的变量"
fi

mkdir -p "$RUNS_ROOT/run-safe"
: >"$RUNS_ROOT/run-safe/$RUN_MARKER"
is_safe_run_directory "$RUNS_ROOT/run-safe" || fail "合法运行目录被拒绝"

mkdir -p "$RUNS_ROOT/run-no-marker"
if is_safe_run_directory "$RUNS_ROOT/run-no-marker"; then
  fail "缺少 marker 的目录被错误接受"
fi

mkdir -p "$TEST_DIR/outside"
: >"$TEST_DIR/outside/$RUN_MARKER"
if is_safe_run_directory "$TEST_DIR/outside"; then
  fail "专用根目录外的目录被错误接受"
fi

health_is_ok $'ok\n' || fail "标准 healthz 响应未通过"
if health_is_ok '{"ok":true}'; then
  fail "JSON 被错误接受为纯文本 healthz"
fi

state_write "$RUNS_ROOT/run-safe" phase snapshot-ready
advance_phase "$RUNS_ROOT/run-safe" collection-ready
assert_equal 'snapshot-ready' "$(state_read "$RUNS_ROOT/run-safe" phase)"
advance_phase "$RUNS_ROOT/run-safe" trained
assert_equal 'trained' "$(state_read "$RUNS_ROOT/run-safe" phase)"

BUNDLE_DB="$TEST_DIR/bundle.sqlite"
STARCAT_DB="$TEST_DIR/starcat.sqlite"
sqlite3 "$BUNDLE_DB" <<'SQL'
CREATE TABLE repositories (repo_id INTEGER PRIMARY KEY, full_name TEXT);
CREATE TABLE recommendations (source_repo_id INTEGER NOT NULL, target_repo_id INTEGER NOT NULL);
INSERT INTO repositories VALUES (1, 'fixture/missing-local'), (2, 'starcat/selected');
INSERT INTO recommendations VALUES (1, 3), (1, 4), (2, 3);
SQL
sqlite3 "$STARCAT_DB" <<'SQL'
CREATE TABLE repos (
  id INTEGER PRIMARY KEY,
  is_starred INTEGER NOT NULL,
  is_private INTEGER NOT NULL,
  access_state TEXT NOT NULL
);
INSERT INTO repos VALUES (2, 1, 0, 'accessible');
SQL

selected="$(select_source_repository "$BUNDLE_DB" "$STARCAT_DB")"
assert_equal '2|starcat/selected' "$selected"

cleanup_run "$RUNS_ROOT/run-safe" >/dev/null
[ ! -e "$RUNS_ROOT/run-safe" ] || fail "合法运行目录没有被清理"
[ -d "$TEST_DIR/outside" ] || fail "清理越界删除了外部目录"

printf '✓ local-recommendation-e2e.sh 回归测试通过\n'
