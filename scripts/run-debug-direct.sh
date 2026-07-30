#!/usr/bin/env bash
#
# run-debug-direct.sh — 本地 Debug 构建并启动 StarcatDirect（Direct / 非 App Store 模式）。
#
# 这个入口用于验证非 App Store / Direct 分发行为。它使用 StarcatDirect
# scheme，覆盖 Direct 独立 bundle id、Info.plist、Sparkle 依赖和 Direct
# entitlements，而不是把 App Store target 临时去沙箱。
#
# 关键约束：
# - 非沙箱模式不等价于 App Store 行为；不要用它判断 security-scoped bookmark。
# - 使用 Apple Development 签名并保留 StarcatDirect.entitlements，确保 Direct
#   签名边界和 App Store target 分离。
# - 显式关闭 ENABLE_DEBUG_DYLIB，避免需要构建后 deep re-sign。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData-NoSandbox"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Starcat.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Starcat"
WIDGET_EXTENSION_PATH="$APP_PATH/Contents/PlugIns/StarcatDirectWidgets.appex"
DIRECT_DEBUG_BUNDLE_ID="com.starcat.app.direct.debug"
DIRECT_RELEASE_BUNDLE_ID="com.starcat.app.direct"
DIRECT_DEBUG_WIDGET_BUNDLE_ID="com.starcat.app.direct.debug.widgets"

# 正式 Apple Developer Team ID。后续如果换账号，可用环境变量覆盖：
#   STARCAT_DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/run-debug-direct.sh
DEVELOPMENT_TEAM_ID="${STARCAT_DEVELOPMENT_TEAM:-8WCUMGCWMB}"

BUILD_VERSION="$(git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || true)"
if ! [[ "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: 无法从 git commit count 生成有效的 Direct Debug build version。"
  exit 1
fi

# App Store 与 Direct 的可执行文件都叫 Starcat，不能用进程名判断渠道。
# Direct Debug 为规避 WidgetKit 误绑定正式宿主使用独立 bundle id；启动新调试实例前
# 同时关闭 Debug / Release Direct，避免两个渠道实例争用同一份 Direct 本地数据。
running_direct_pids() {
  /usr/bin/osascript -l JavaScript -e "
ObjC.import('AppKit');
var bundleIdentifiers = ['$DIRECT_DEBUG_BUNDLE_ID', '$DIRECT_RELEASE_BUNDLE_ID'];
var processIdentifiers = [];
bundleIdentifiers.forEach(function(bundleIdentifier) {
  $.NSRunningApplication
    .runningApplicationsWithBundleIdentifier(bundleIdentifier)
    .js
    .forEach(function(app) {
      processIdentifiers.push(Number(app.processIdentifier));
    });
});
processIdentifiers.join('\n');
"
}

# 裸可执行文件启动的异常实例不一定能被 NSRunningApplication 稳定枚举。把
# bundle id 与本次构建产物的完整 executable path 合并，避免旧进程漏清理后
# 与新实例争用 AppKit state restoration。
running_target_pids() {
  local bundle_pids executable_pids
  bundle_pids="$(running_direct_pids)" || return 1
  executable_pids="$(pgrep -f -x "$APP_EXECUTABLE" || true)"
  printf '%s\n%s\n' "$bundle_pids" "$executable_pids" \
    | awk 'NF' \
    | sort -u
}

cd "$PROJECT_ROOT"

echo "==> 关闭已运行的 StarcatDirect（如有）..."
if ! DIRECT_PIDS="$(running_target_pids)"; then
  echo "ERROR: 无法查询 Direct bundle id / executable 进程，拒绝继续。"
  exit 1
fi
if [ -n "$DIRECT_PIDS" ]; then
  while IFS= read -r pid; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  done <<<"$DIRECT_PIDS"
fi

# `kill` 只向 Direct PID 发送终止信号，数据库收尾等异步清理可能明显超过固定 0.3 秒。
# 如果旧实例仍在退出，普通 `open` 会把启动请求误判为“激活已有实例”，随后旧实例
# 退出，最终表现为构建成功但没有应用进程。这里等待真实退出，超时则保留现场并报错，
# 不升级成 SIGKILL，避免强杀时损坏用户数据。
for _ in {1..100}; do
  if ! DIRECT_PIDS="$(running_target_pids)"; then
    echo "ERROR: 无法查询 Direct bundle id / executable 进程，拒绝继续启动。"
    exit 1
  fi
  if [ -z "$DIRECT_PIDS" ]; then
    break
  fi
  sleep 0.1
done
if [ -n "$DIRECT_PIDS" ]; then
  echo "ERROR: 等待旧 StarcatDirect 退出超时，拒绝启动新实例。"
  echo "       Direct PID:"
  while IFS= read -r pid; do
    printf '       %s\n' "$pid"
  done <<<"$DIRECT_PIDS"
  exit 1
fi

echo "==> 生成 Xcode 工程..."
xcodegen generate

echo "==> 构建 StarcatDirect Debug（Direct / 非 App Store 模式）..."
xcodebuild \
  -scheme StarcatDirect \
  -configuration Debug \
  -sdk macosx \
  -arch arm64 \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
  CODE_SIGN_IDENTITY="Apple Development" \
  CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
  ENABLE_DEBUG_DYLIB=NO \
  build

echo "==> 校验 Direct 构建产物..."
if [ ! -d "$WIDGET_EXTENSION_PATH" ]; then
  echo "ERROR: Direct 构建产物缺少 StarcatDirectWidgets.appex，拒绝启动。"
  exit 1
fi
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
if grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS"; then
  echo "ERROR: 检测到沙箱 entitlement，非沙箱脚本拒绝启动。"
  exit 1
fi
ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleIdentifier" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
if [ "$ACTUAL_BUNDLE_ID" != "$DIRECT_DEBUG_BUNDLE_ID" ]; then
  echo "ERROR: Direct Debug bundle id 应为 $DIRECT_DEBUG_BUNDLE_ID，当前为 ${ACTUAL_BUNDLE_ID:-<missing>}，拒绝启动。"
  exit 1
fi
ACTUAL_WIDGET_BUNDLE_ID=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleIdentifier" \
  "$WIDGET_EXTENSION_PATH/Contents/Info.plist" 2>/dev/null || true)
if [ "$ACTUAL_WIDGET_BUNDLE_ID" != "$DIRECT_DEBUG_WIDGET_BUNDLE_ID" ]; then
  echo "ERROR: Direct Debug Widget bundle id 应为 $DIRECT_DEBUG_WIDGET_BUNDLE_ID，当前为 ${ACTUAL_WIDGET_BUNDLE_ID:-<missing>}，拒绝启动。"
  exit 1
fi

# WidgetKit 会按 Extension 自身的 CFBundleVersion 判断是否复用旧时间线和视图归档。
# 只在宿主 post-build 阶段改版本不够：增量构建可能保留版本仍为 1 的扩展，表现为
# 二进制已经更新，但桌面仍渲染旧 UI。因此构建参数统一注入版本，并在启动前同时
# 校验宿主与扩展，任何一边未更新都直接失败，避免继续污染系统缓存。
ACTUAL_APP_BUILD=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
ACTUAL_WIDGET_BUILD=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" \
  "$WIDGET_EXTENSION_PATH/Contents/Info.plist" 2>/dev/null || true)
if [ "$ACTUAL_APP_BUILD" != "$BUILD_VERSION" ]; then
  echo "ERROR: Direct Debug App build version 应为 $BUILD_VERSION，当前为 ${ACTUAL_APP_BUILD:-<missing>}，拒绝启动。"
  exit 1
fi
if [ "$ACTUAL_WIDGET_BUILD" != "$BUILD_VERSION" ]; then
  echo "ERROR: Direct Debug Widget build version 应为 $BUILD_VERSION，当前为 ${ACTUAL_WIDGET_BUILD:-<missing>}，拒绝启动。"
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
  echo "ERROR: Direct Info.plist 缺少 SUFeedURL，拒绝启动。"
  exit 1
fi
LICENSE_API_ENV=$(/usr/libexec/PlistBuddy -c "Print :STARCAT_LICENSE_API_ENVIRONMENT" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
if [ "$LICENSE_API_ENV" != "test" ]; then
  echo "ERROR: Direct Debug 必须连接测试 License API，当前 STARCAT_LICENSE_API_ENVIRONMENT=$LICENSE_API_ENV"
  exit 1
fi
if [ ! -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
  echo "ERROR: Direct 构建产物缺少 Sparkle.framework，拒绝启动。"
  exit 1
fi
if ! codesign --verify --deep --strict "$APP_PATH"; then
  echo "ERROR: Direct App 或内嵌 Widget Extension 签名校验失败，拒绝启动。"
  exit 1
fi

echo "==> 注册当前 Direct Debug Widget Extension..."
# 本地 DerivedData 路径会被反复覆盖。显式移除该路径的旧注册后再登记当前产物，
# 让 pluginkit 解析到刚完成签名的扩展；失败时不启动宿主，避免桌面继续绑定旧副本。
pluginkit -r "$WIDGET_EXTENSION_PATH" >/dev/null 2>&1 || true
if ! pluginkit -a "$WIDGET_EXTENSION_PATH"; then
  echo "ERROR: 无法注册 Direct Debug Widget Extension，拒绝启动。"
  exit 1
fi

echo "==> 签名摘要:"
codesign -dv --verbose=2 "$APP_PATH" 2>&1 | sed -n '1,12p'
echo "==> 当前模式: direct"
echo "    build version: $BUILD_VERSION"
echo "    widget: $WIDGET_EXTENSION_PATH"
echo "    license api: test"
echo "    preferences: ~/Library/Preferences/${DIRECT_DEBUG_BUNDLE_ID}.plist"
echo "    data: ~/Library/Application Support/com.starcat.app"
echo "    app support: ~/Library/Application Support/com.starcat.app"
echo "    app: $APP_PATH"

echo "==> 启动 StarcatDirect..."
if ! open "$APP_PATH"; then
  echo "ERROR: LaunchServices 拒绝启动 StarcatDirect。"
  echo "       app: $APP_PATH"
  exit 1
fi

# `open` 成功只代表 LaunchServices 接收了请求，不代表目标进程已真正建立。按完整
# executable path 校验，避免误把另一个渠道或另一个 DerivedData 下的 Starcat 算作成功。
# 这里不能使用 `open -n`：Direct Debug 已显式保持单实例，强制创建新实例会破坏
# AppKit window restoration 的唯一所有者约束。
DIRECT_PID=""
for _ in {1..100}; do
  DIRECT_PID="$(pgrep -f -x "$APP_EXECUTABLE" | head -n 1 || true)"
  if [ -n "$DIRECT_PID" ]; then
    break
  fi
  sleep 0.1
done

if [ -z "$DIRECT_PID" ]; then
  echo "ERROR: LaunchServices 未建立目标 StarcatDirect 进程。"
  echo "       executable: $APP_EXECUTABLE"
  echo "       为避免出现 Dock 有运行点但没有窗口，不再回退为直接执行 GUI binary。"
  exit 1
fi

# 冷启动刚建立进程并不等于启动完成。此前 `open -n` 产生的异常进程会在约 1 秒后
# 被 LaunchServices 回收，因此再观察 2 秒，只有持续存活才向调用方报告成功。
for _ in {1..20}; do
  if ! kill -0 "$DIRECT_PID" 2>/dev/null; then
    echo "ERROR: StarcatDirect 进程在启动后提前退出（PID: ${DIRECT_PID}）。"
    exit 1
  fi
  sleep 0.1
done

if ! DIRECT_PIDS="$(running_target_pids)"; then
  echo "ERROR: 无法执行启动后的 Direct 单实例校验。"
  exit 1
fi
DIRECT_PID_COUNT="$(printf '%s\n' "$DIRECT_PIDS" | awk 'NF { count += 1 } END { print count + 0 }')"
if [ "$DIRECT_PID_COUNT" -ne 1 ] || [ "$DIRECT_PIDS" != "$DIRECT_PID" ]; then
  echo "ERROR: StarcatDirect 启动后不是唯一目标实例，拒绝报告成功。"
  echo "       expected PID: $DIRECT_PID"
  echo "       detected PID:"
  while IFS= read -r pid; do
    if [ -n "$pid" ]; then
      printf '       %s\n' "$pid"
    fi
  done <<<"$DIRECT_PIDS"
  exit 1
fi

echo "==> StarcatDirect 已稳定启动（PID: ${DIRECT_PID}，方式: LaunchServices，单实例）"
exit 0
