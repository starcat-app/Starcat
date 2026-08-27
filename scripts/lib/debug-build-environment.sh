#!/usr/bin/env bash
#
# debug-build-environment.sh — Starcat 本地 Debug 构建的工具链与缓存边界。
#
# 固定 DerivedData 能加速重复构建，但 Clang 的 PCM 等中间产物不能跨 Xcode / SDK
# 复用。这里把渠道、Xcode、SDK 和架构写入缓存指纹；一旦发现目录来自其他构建
# 环境，就只清理可重建的 DerivedData，避免旧模块引用污染后续构建。

set -euo pipefail

# 选择项目约定的稳定版 Xcode，不继承全局 xcode-select（它可能指向 Beta）。
starcat_select_stable_xcode() {
  local developer_dir="${STARCAT_STABLE_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

  if [ ! -x "$developer_dir/usr/bin/xcodebuild" ]; then
    echo "ERROR: 未找到稳定版 Xcode：$developer_dir"
    echo "       请确认 /Applications/Xcode.app 已安装，或通过 STARCAT_STABLE_XCODE_DEVELOPER_DIR 显式指定。"
    return 1
  fi

  export DEVELOPER_DIR="$developer_dir"
  if ! xcrun metal --version >/dev/null 2>&1; then
    echo "ERROR: 稳定版 Xcode 的 Metal Toolchain 不可用，无法编译 .metal 文件。"
    echo "       请在 Xcode > Settings > Components 中安装 Metal Toolchain。"
    return 1
  fi
}

# 指纹只包含影响编译缓存兼容性的稳定信息，不记录用户目录或签名身份。
starcat_debug_build_fingerprint() {
  local cache_owner="$1"
  local xcode_version sdk_path sdk_version sdk_build_version

  xcode_version="$(xcodebuild -version | tr '\n' ';')" || return 1
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)" || return 1
  sdk_version="$(xcrun --sdk macosx --show-sdk-version)" || return 1
  sdk_build_version="$(xcrun --sdk macosx --show-sdk-build-version)" || return 1

  printf '%s\n' \
    "format=1" \
    "owner=$cache_owner" \
    "developer_dir=$DEVELOPER_DIR" \
    "xcode=$xcode_version" \
    "sdk_path=$sdk_path" \
    "sdk_version=$sdk_version" \
    "sdk_build_version=$sdk_build_version" \
    "arch=arm64"
}

# 防止未来调用方传错路径后扩大清理范围。这里只允许管理 build/ 下三个专用缓存：
# App Store Debug、Direct Debug、命令行单测。测试不得写入两个 Debug 目录。
starcat_assert_debug_derived_data_path() {
  local project_root="$1"
  local derived_data="$2"

  case "$derived_data" in
    "$project_root/build/DerivedData-Sandbox"|"$project_root/build/DerivedData-NoSandbox"|"$project_root/build/DerivedData-Tests")
      ;;
    *)
      echo "ERROR: 拒绝管理未登记的 DerivedData 路径：$derived_data"
      return 1
      ;;
  esac
}

# 第四个参数仅供脚本测试注入确定性指纹；生产调用会从当前 Xcode 环境计算。
starcat_prepare_debug_derived_data() {
  local project_root="$1"
  local derived_data="$2"
  local cache_owner="$3"
  local current_fingerprint="${4:-}"
  local stamp_path="$derived_data/.starcat-build-environment"
  local existing_fingerprint=""

  # Bash 在函数整体位于 `if` 条件中时会抑制 errexit，因此安全边界必须显式传递失败，
  # 不能只依赖文件顶部的 `set -e`。
  starcat_assert_debug_derived_data_path "$project_root" "$derived_data" || return 1

  if [ -z "$current_fingerprint" ]; then
    current_fingerprint="$(starcat_debug_build_fingerprint "$cache_owner")" || return 1
  fi

  if [ -f "$stamp_path" ]; then
    existing_fingerprint="$(<"$stamp_path")"
  fi

  if [ -d "$derived_data" ] && [ "$existing_fingerprint" != "$current_fingerprint" ]; then
    echo "==> 检测到 $cache_owner 的 Xcode / SDK 缓存指纹变化，重建专用 DerivedData..."
    rm -rf "$derived_data" || return 1
  fi

  mkdir -p "$derived_data" || return 1
  printf '%s\n' "$current_fingerprint" >"$stamp_path" || return 1
}
