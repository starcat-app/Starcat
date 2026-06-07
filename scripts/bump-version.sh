#!/bin/bash
#
# bump-version.sh
#
# 在 Xcode Build Phase 中运行，根据 git 元数据动态改写产物 Info.plist：
#   - CFBundleShortVersionString (Marketing)：取最新 git tag（去掉 v 前缀），无 tag 时保留 build settings 里现有值（兜底）。
#   - CFBundleVersion           (Build)：git commit 总数（纯整数，例 `201`），符合 App Store 规范
#                                       （period-separated 非负整数）。
#   - GitCommitHash             (自定义)：7 位短 hash（例 `f09a499`），关于页 UI 拼接成 `201.f09a499` 展示。
#
# 设计动机：
#   - 让关于页 / Finder 简介里的版本号每次 build 都能反映"是哪一份代码"。
#   - 不依赖手动改 project.yml；发版时 `git tag v0.1.1 && git push --tags` 即可让 marketing 版本随之升级。
#   - 拆 commit count 与 hash 一次性满足 App Store 规范：CFBundleVersion 保持纯整数 → 不会被 App Review 拒；
#     hash 走自定义 key（App Review 不审 plist 自定义字段），UI 层拼接展示完整信息。
#
# 关键约束：
#   - 必须放在 postBuildScripts（target 所有 phase 之后、codesign 之前），
#     否则改完 Info.plist 后 codesign 会失败 / 拿到旧版本号。
#   - 脚本只改 Xcode 已生成的产物 Info.plist (${TARGET_BUILD_DIR}/${INFOPLIST_PATH})，
#     不修改源码 / 不修改 project.yml。每次 clean build 后由 Xcode 重新生成 plist，再被本脚本改写。
#   - 在非 git 仓库 / git 工具缺失 / shallow clone 等异常情况下静默退化，不让 build 失败。
#   - GitCommitHash 是项目自定义 key，首次写入要用 `Add`，后续覆盖用 `Set` —— 脚本里 Set 失败再 Add 双 try 兼容。
#   - 关于页 UI（AboutView.AboutVersion）读取规则：hash 存在则拼成 `<count>.<hash>`，不存在（异常路径）降级到纯 `<count>`。
#
# 入口约定：
#   - 由 xcodegen 在 project.yml 的 postBuildScripts 中调用。
#   - 命令行手动跑也支持（用于本地排查），脚本会用相同逻辑。
#
# 输出：写入产物 Info.plist + 打印版本日志到 Xcode build log。
#

set -euo pipefail

# Xcode build phase 提供 SRCROOT / TARGET_BUILD_DIR / INFOPLIST_PATH。
# 命令行手动调用（无这些变量）时，假设当前工作目录就是项目根。
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# 优先使用 Xcode 提供的产物 Info.plist 路径；若不在 build 上下文中，退化为打印计算结果但不写文件。
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${INFOPLIST_PATH:-}" ]; then
    PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
else
    PLIST=""
fi

# ---- 读 git 元数据，全部带 fallback，git 不可用时不让 build 失败 ----
GIT_BIN="$(command -v git || true)"
if [ -z "$GIT_BIN" ]; then
    echo "warning: git not found in PATH, skip auto-version"
    exit 0
fi

# commit 总数。shallow clone 时这个值会偏小，不致命，仍然单调。
COUNT="$("$GIT_BIN" -C "$SRCROOT" rev-list --count HEAD 2>/dev/null || echo "0")"

# 短 hash，固定 7 位，与 GitHub Web 默认显示一致。
HASH="$("$GIT_BIN" -C "$SRCROOT" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"

# 最近的 tag。`git describe --tags --abbrev=0` 只取 tag 名，不带提交距离后缀；
# 失败（无 tag / 不在 git 仓库）时输出空串。
TAG="$("$GIT_BIN" -C "$SRCROOT" describe --tags --abbrev=0 2>/dev/null || true)"

# 把 tag 里常见的 v / V 前缀剥掉：v0.1.3 → 0.1.3。
MARKETING="${TAG#v}"
MARKETING="${MARKETING#V}"

echo "==> Auto Bump Version"
echo "    git commit count : $COUNT"
echo "    git short hash   : $HASH"
echo "    git latest tag   : ${TAG:-<none>}"
echo "    -> CFBundleVersion              = $COUNT"
echo "    -> GitCommitHash                = $HASH"
if [ -n "$MARKETING" ]; then
    echo "    -> CFBundleShortVersionString   = $MARKETING (from tag)"
else
    echo "    -> CFBundleShortVersionString   = (keep existing, no git tag yet)"
fi

# ---- 写入产物 Info.plist ----
if [ -z "$PLIST" ]; then
    echo "info: not in Xcode build phase (TARGET_BUILD_DIR/INFOPLIST_PATH unset), exit without writing plist"
    exit 0
fi

if [ ! -f "$PLIST" ]; then
    echo "warning: Info.plist not found at $PLIST, skip auto-version"
    exit 0
fi

PLISTBUDDY="/usr/libexec/PlistBuddy"

# CFBundleVersion 写纯 commit count（App Store 规范：period-separated 非负整数）。
"$PLISTBUDDY" -c "Set :CFBundleVersion $COUNT" "$PLIST"

# GitCommitHash 是项目自定义 key —— Xcode `GENERATE_INFOPLIST_FILE` 不会生成它，首次必须 Add。
# 用 Set 失败再 Add 的双 try 写法兼容首次 / 后续两种情况，即便 plist 来源变化也能正确处理。
"$PLISTBUDDY" -c "Set :GitCommitHash $HASH" "$PLIST" 2>/dev/null \
    || "$PLISTBUDDY" -c "Add :GitCommitHash string $HASH" "$PLIST"

# CFBundleShortVersionString 只在拿到 git tag 时覆盖，没 tag 就保留 build settings 里现有值（兜底 0.1.0）。
if [ -n "$MARKETING" ]; then
    "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $MARKETING" "$PLIST"
fi

echo "==> Info.plist updated: $PLIST"
