#!/usr/bin/env bash
#
# 把 Sparkle.framework 的更新 UI 固定为英文：移除非英文 *.lproj，只保留 Base/en。
#
# 用法:
#   ./scripts/strip-sparkle-non-english-localizations.sh /path/to/Starcat.app
#
# 关键约束:
#   - 必须在 codesign Sparkle / App 之前调用；改完 Resources 后需要重新签名。
#   - 只动 Sparkle.framework，不影响 App 自身 Localizable.xcstrings / *.lproj。
#   - 产品决策：Direct 更新弹窗不做 i18n，标题/按钮/说明一律英文。
#

set -euo pipefail

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
  echo "用法: $0 /path/to/Starcat.app" >&2
  exit 1
fi
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: 找不到 App: $APP_PATH" >&2
  exit 1
fi

SPARKLE_FRAMEWORK_PATH="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK_PATH" ]; then
  echo "ERROR: App 缺少 Sparkle.framework: $SPARKLE_FRAMEWORK_PATH" >&2
  exit 1
fi

# Versions/Current 在正式框架里是符号链接；Resources 也可能直接挂在根上。
RESOURCES_DIR=""
for candidate in \
  "${SPARKLE_FRAMEWORK_PATH}/Versions/Current/Resources" \
  "${SPARKLE_FRAMEWORK_PATH}/Resources"
do
  if [ -d "$candidate" ]; then
    RESOURCES_DIR="$candidate"
    break
  fi
done
if [ -z "$RESOURCES_DIR" ]; then
  echo "ERROR: Sparkle.framework 缺少 Resources" >&2
  exit 1
fi
if [ ! -d "${RESOURCES_DIR}/Base.lproj" ]; then
  echo "ERROR: Sparkle.framework 缺少 Base.lproj（英文文案源）" >&2
  exit 1
fi

removed=0
while IFS= read -r -d '' lproj; do
  case "$(basename "$lproj")" in
    Base.lproj|en.lproj|en_*.lproj)
      ;;
    *)
      rm -rf "$lproj"
      removed=$((removed + 1))
      ;;
  esac
done < <(find "$RESOURCES_DIR" -maxdepth 1 -type d -name '*.lproj' -print0)

echo "Sparkle UI pinned to English (removed ${removed} non-English .lproj) in:"
echo "  $SPARKLE_FRAMEWORK_PATH"
