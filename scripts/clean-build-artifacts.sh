#!/usr/bin/env bash
#
# clean-build-artifacts.sh — 清理 Starcat 各 worktree 与 Xcode 产生的可重建编译缓存。
#
# 默认只预览；必须显式传入 --apply 才会删除。脚本故意保留发布产物、依赖下载目录、
# 用户数据库和其他项目的缓存，避免“一键清理”扩大成不可恢复的数据删除。
#
# 使用说明：
#
#   # 1. 预览将要删除的内容，不执行删除
#   ./scripts/clean-build-artifacts.sh
#
#   # 2. 一键清理 Starcat 项目专属编译缓存
#   ./scripts/clean-build-artifacts.sh --apply
#
#   # 3. 项目缓存之外，再清理 Starcat 构建日志、Trace 和采样文件
#   ./scripts/clean-build-artifacts.sh --apply --include-diagnostics
#
#   # 4. 最大清理范围：再包含 Xcode、SwiftPM、Go 的跨项目共享编译缓存
#   #    该模式会让其他项目下次构建重新生成缓存，请确认没有编译任务运行。
#   ./scripts/clean-build-artifacts.sh --apply --include-diagnostics --include-shared-caches
#
#   # 查看参数帮助
#   ./scripts/clean-build-artifacts.sh --help
#
# 默认会清理约 27GB 的当前 Starcat 编译缓存，但不会删除 dist/、DMG、PKG、
# xcarchive、node_modules、.venv、用户数据库、AI 对话或其他项目的 DerivedData。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

APPLY=0
INCLUDE_DIAGNOSTICS=0
INCLUDE_SHARED_CACHES=0
CANDIDATE_COUNT=0
DELETED_COUNT=0
WORKTREES=()

usage() {
  cat <<'EOF'
用法：
  ./scripts/clean-build-artifacts.sh [选项]

选项：
  --apply                  真正删除；不传时只预览
  --include-diagnostics    同时删除 /private/tmp、$TMPDIR 下的 Starcat 构建日志、Trace 和采样文件
  --include-shared-caches  同时删除 Xcode ModuleCache、SwiftPM 和 Go 的跨项目共享编译缓存
  -h, --help               显示帮助

默认清理范围：
  - 所有 Starcat Git worktree 的 build/**/DerivedData*、dist/**/DerivedData*、.build/ 和测试结果
  - supports/、scripts/ 下可重建的 Python、SwiftPM、Rust 和前端测试缓存
  - ~/Library/Developer/Xcode/DerivedData/Starcat-*
  - /private/tmp、$TMPDIR 下具有 DerivedData 目录结构的 Starcat-DerivedData-*

明确保留：
  - dist/、*.xcarchive、*.dmg、*.pkg 等发布产物
  - node_modules/、.venv/、Go modules、npm 和 uv 下载缓存
  - Starcat 用户数据库、AI 对话、配置和源码
  - Xcode DerivedData 中其他项目的目录
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# --apply 是唯一写开关；额外范围必须再次显式选择，避免默认误删共享缓存。
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply)
        APPLY=1
        ;;
      --include-diagnostics)
        INCLUDE_DIAGNOSTICS=1
        ;;
      --include-shared-caches)
        INCLUDE_SHARED_CACHES=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "未知参数：$1"
        ;;
    esac
    shift
  done
}

# 删除 DerivedData 时不能与编译进程竞争，否则可能破坏仍在写入的 build.db。
assert_build_tools_idle() {
  local process_name
  local busy=0

  for process_name in Xcode xcodebuild swiftc swift-frontend; do
    if pgrep -x "$process_name" >/dev/null 2>&1; then
      echo "ERROR: 检测到 $process_name 正在运行。" >&2
      busy=1
    fi
  done

  if [ "$busy" -ne 0 ]; then
    fail "请关闭 Xcode 并等待当前编译/测试结束后重试。"
  fi
}

# Worktree 来源只信任 Git；不根据父目录名称猜测，避免把相邻项目纳入清理范围。
discover_worktrees() {
  local line
  local worktree

  git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "脚本必须从 Starcat Git 仓库内运行。"

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        worktree="${line#worktree }"
        [ -d "$worktree" ] || continue
        WORKTREES[${#WORKTREES[@]}]="$(cd "$worktree" && pwd -P)"
        ;;
    esac
  done < <(git -C "$PROJECT_ROOT" worktree list --porcelain)

  [ "${#WORKTREES[@]}" -gt 0 ] || fail "未发现 Starcat worktree。"
}

is_registered_worktree() {
  local expected="$1"
  local worktree

  for worktree in "${WORKTREES[@]}"; do
    if [ "$worktree" = "$expected" ]; then
      return 0
    fi
  done
  return 1
}

is_under_registered_worktree() {
  local candidate="$1"
  local worktree

  for worktree in "${WORKTREES[@]}"; do
    case "$candidate" in
      "$worktree"/*)
        return 0
        ;;
    esac
  done
  return 1
}

# 每类目标都有独立白名单。即使上游 find 或 Git 输出异常，也不能把删除范围放大。
validate_target() {
  local category="$1"
  local target="$2"
  local parent
  local name
  local tmp_base="${TMPDIR:-/private/tmp}"
  local worktree

  tmp_base="${tmp_base%/}"

  [ -n "$target" ] || fail "拒绝处理空路径。"
  [ "$target" != "/" ] || fail "拒绝处理文件系统根目录。"
  [ "$target" != "$PROJECT_ROOT" ] || fail "拒绝处理项目根目录。"
  [ "$target" != "${HOME:?}" ] || fail "拒绝处理用户主目录。"
  [ ! -L "$target" ] || fail "拒绝处理符号链接：$target"

  parent="$(dirname "$target")"
  name="$(basename "$target")"

  case "$category" in
    worktree-build)
      for worktree in "${WORKTREES[@]}"; do
        if [ "$target" = "$worktree/.build" ]; then
          return 0
        fi
        case "$target" in
          "$worktree/build/"*|"$worktree/dist/"*)
            case "$name" in
              DerivedData*) return 0 ;;
            esac
            ;;
        esac
      done
      ;;
    worktree-result)
      is_under_registered_worktree "$target" || break
      case "$name" in
        *.xcresult|test_output.txt|test_output*.txt)
          return 0
          ;;
      esac
      ;;
    worktree-cache)
      is_under_registered_worktree "$target" || break
      case "$name" in
        .build|target|.next|.turbo|coverage|.pytest_cache|.mypy_cache|.ruff_cache|__pycache__|htmlcov)
          return 0
          ;;
      esac
      ;;
    xcode-starcat)
      if [ "$parent" = "${HOME:?}/Library/Developer/Xcode/DerivedData" ]; then
        case "$name" in
          Starcat-*) return 0 ;;
        esac
      fi
      ;;
    temp-derived-data)
      case "$parent" in
        /private/tmp|"$tmp_base")
          case "$name" in
            Starcat-DerivedData-*) return 0 ;;
          esac
          ;;
      esac
      ;;
    diagnostics)
      case "$parent" in
        /private/tmp|"$tmp_base")
          case "$name" in
            starcat-*.trace|starcat-*.sample.txt|starcat-*build*.log|starcat-*test*.log|starcat-*build*.txt|starcat-*test*.txt)
              return 0
              ;;
          esac
          ;;
      esac
      ;;
    shared-cache)
      case "$target" in
        "${HOME:?}/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"|\
        "${HOME:?}/Library/Developer/Xcode/DerivedData/SDKStatCaches.noindex"|\
        "${HOME:?}/Library/Caches/com.apple.dt.Xcode"|\
        "${HOME:?}/Library/Caches/org.swift.swiftpm"|\
        "${HOME:?}/Library/Caches/go-build")
          return 0
          ;;
      esac
      ;;
  esac

  fail "目标未通过 $category 安全白名单：$target"
}

target_size() {
  local target="$1"
  local size

  size="$(du -sh "$target" 2>/dev/null | awk '{print $1}' || true)"
  printf '%s' "${size:-unknown}"
}

# 所有删除统一经过这里，确保 dry-run 与真实执行看到完全相同的目标集合。
handle_target() {
  local category="$1"
  local target="$2"
  local size

  [ -e "$target" ] || return 0
  validate_target "$category" "$target"

  size="$(target_size "$target")"
  CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))

  if [ "$APPLY" -eq 0 ]; then
    printf '[预览] %8s  %s\n' "$size" "$target"
    return 0
  fi

  printf '[删除] %8s  %s\n' "$size" "$target"
  rm -rf -- "$target"
  DELETED_COUNT=$((DELETED_COUNT + 1))
}

clean_worktree_artifacts() {
  local worktree="$1"
  local search_root
  local candidate

  is_registered_worktree "$worktree" || fail "未登记的 worktree：$worktree"

  handle_target worktree-build "$worktree/.build"

  # build/dmg 与 dist/ 可能同时保存最终产物；只删除其中的 DerivedData。
  for search_root in "$worktree/build" "$worktree/dist"; do
    [ -d "$search_root" ] || continue
    while IFS= read -r -d '' candidate; do
      handle_target worktree-build "$candidate"
    done < <(find "$search_root" -type d -name 'DerivedData*' -prune -print0 2>/dev/null)
  done

  # 根级测试报告可能由裸 xcodebuild 或第三方 AI 工具输出，不一定落在 build/ 内。
  while IFS= read -r -d '' candidate; do
    handle_target worktree-result "$candidate"
  done < <(find "$worktree" -mindepth 1 -maxdepth 1 \
    \( -name '*.xcresult' -o -name 'test_output.txt' -o -name 'test_output*.txt' \) \
    -print0 2>/dev/null)

  # supports/ 多数是独立仓库，只清明确可重建的语言/测试缓存，不碰 dist 和依赖目录。
  for search_root in "$worktree/supports" "$worktree/scripts"; do
    [ -d "$search_root" ] || continue
    while IFS= read -r -d '' candidate; do
      handle_target worktree-cache "$candidate"
    done < <(find "$search_root" \
      \( -name .git -o -name node_modules -o -name .venv -o -name dist -o -name build \) -prune -o \
      -type d \( -name .build -o -name target -o -name .next -o -name .turbo \
        -o -name coverage -o -name .pytest_cache -o -name .mypy_cache \
        -o -name .ruff_cache -o -name __pycache__ -o -name htmlcov \) \
      -prune -print0 2>/dev/null)
  done
}

clean_xcode_starcat_derived_data() {
  local derived_root="${HOME:?}/Library/Developer/Xcode/DerivedData"
  local candidate

  [ -d "$derived_root" ] || return 0
  while IFS= read -r -d '' candidate; do
    handle_target xcode-starcat "$candidate"
  done < <(find "$derived_root" -mindepth 1 -maxdepth 1 -type d -name 'Starcat-*' -print0)
}

clean_temporary_derived_data() {
  local temp_root
  local candidate

  for temp_root in /private/tmp "${TMPDIR:-/private/tmp}"; do
    temp_root="${temp_root%/}"
    [ -d "$temp_root" ] || continue
    while IFS= read -r -d '' candidate; do
      # 名称匹配还不够；至少存在一个标准 DerivedData 子目录才允许进入删除白名单。
      if [ -d "$candidate/Build" ] || [ -d "$candidate/Logs" ] || [ -d "$candidate/SourcePackages" ]; then
        handle_target temp-derived-data "$candidate"
      fi
    done < <(find "$temp_root" -mindepth 1 -maxdepth 1 -type d \
      -name 'Starcat-DerivedData-*' -print0 2>/dev/null)
  done
}

clean_diagnostics() {
  local temp_root
  local candidate

  [ "$INCLUDE_DIAGNOSTICS" -eq 1 ] || return 0
  for temp_root in /private/tmp "${TMPDIR:-/private/tmp}"; do
    temp_root="${temp_root%/}"
    [ -d "$temp_root" ] || continue
    while IFS= read -r -d '' candidate; do
      handle_target diagnostics "$candidate"
    done < <(find "$temp_root" -mindepth 1 -maxdepth 1 \
      \( -type f -o -type d \) \
      \( -name 'starcat-*.trace' -o -name 'starcat-*.sample.txt' \
        -o -name 'starcat-*build*.log' -o -name 'starcat-*test*.log' \
        -o -name 'starcat-*build*.txt' -o -name 'starcat-*test*.txt' \) \
      -print0 2>/dev/null)
  done
}

clean_shared_caches() {
  local target

  [ "$INCLUDE_SHARED_CACHES" -eq 1 ] || return 0
  for target in \
    "${HOME:?}/Library/Developer/Xcode/DerivedData/ModuleCache.noindex" \
    "${HOME:?}/Library/Developer/Xcode/DerivedData/SDKStatCaches.noindex" \
    "${HOME:?}/Library/Caches/com.apple.dt.Xcode" \
    "${HOME:?}/Library/Caches/org.swift.swiftpm" \
    "${HOME:?}/Library/Caches/go-build"; do
    handle_target shared-cache "$target"
  done
}

main() {
  local worktree

  parse_args "$@"
  discover_worktrees

  if [ "$APPLY" -eq 1 ]; then
    assert_build_tools_idle
    echo "==> 开始清理 Starcat 可重建编译缓存..."
  else
    echo "==> Dry-run：以下内容尚未删除；传入 --apply 才会执行。"
  fi

  for worktree in "${WORKTREES[@]}"; do
    clean_worktree_artifacts "$worktree"
  done
  clean_xcode_starcat_derived_data
  clean_temporary_derived_data
  clean_diagnostics
  clean_shared_caches

  if [ "$APPLY" -eq 1 ]; then
    echo "==> 清理完成：删除 $DELETED_COUNT 个目标。"
  else
    echo "==> 预览完成：发现 $CANDIDATE_COUNT 个目标。"
    echo "    执行清理：./scripts/clean-build-artifacts.sh --apply"
  fi
}

main "$@"
