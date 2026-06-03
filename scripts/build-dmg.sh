#!/usr/bin/env bash
#
# build-dmg.sh — Starcat 内测 DMG 打包脚本
#
# 用途:
#   一行命令把当前 Starcat 项目编译成 Release .app,打包成 DMG,
#   附带 SHA256 校验和 + 朋友的安装说明 (INSTALL.md)。
#
# 用法:
#   ./scripts/build-dmg.sh                  # 默认版本 0.0.1
#   ./scripts/build-dmg.sh 0.0.2            # 自定义版本号 (严格 X.Y.Z 三段纯数字)
#   ./scripts/build-dmg.sh 0.1.0            # OK
#   ./scripts/build-dmg.sh 1.0.0            # OK
#
# 版本号约束 (强制):
#   - 必须是 X.Y.Z 三段纯数字 (Apple CFBundleShortVersionString 要求)
#   - 不支持 -alpha / -beta / -rc 之类 SemVer 预发布后缀,传了会直接报错
#   - 想标记 "alpha 阶段"?在 INSTALL.md 的标题/正文里手动写"内测/alpha"即可;
#     版本号字段不背这个语义,避免 Xcode warning 或 codesign 拒绝
#
# 产物 (位于 build/dmg/):
#   Starcat-<X.Y.Z>-arm64.dmg          DMG 安装包
#   Starcat-<X.Y.Z>-arm64.dmg.sha256   SHA256 校验和 (给朋友核对)
#   INSTALL-<X.Y.Z>.md                 朋友的安装说明 (含 Gatekeeper 绕过教程)
#
# 设计取舍:
#   - 保留 ad-hoc 签名 (你没办 Apple Developer 账号),朋友首次打开需右键 → 打开
#   - MARKETING_VERSION = 传入的 X.Y.Z,不做任何拆分/正则提取 (失败模式更可预测)
#   - CURRENT_PROJECT_VERSION 用时间戳避免重复构建撞号 (CFBundleVersion 必须单调递增)
#   - 优先用 create-dmg 出"专业感"DMG (带 Applications 拖拽箭头),无则 hdiutil 兜底
#   - strip debug symbols 减少 30-50% 体积 (Release build 默认不 strip Swift 框架)
#
# 已知约束:
#   - 只 build arm64 (Apple Silicon)。给 Intel Mac 朋友需要改 destination 为 'arch=x86_64'
#     或改成 'generic/platform=macOS' 出 universal binary
#   - 跑脚本前**关闭 Xcode IDE**,否则可能锁住 derived data (跟 xcodebuild test 一样)
#

set -euo pipefail

# ============================================================================
# 参数解析 + 严格校验
# ============================================================================
VERSION="${1:-0.0.1}"

# 强制 X.Y.Z 三段纯数字 (Apple CFBundleShortVersionString 限制)。
# 不允许 -alpha / -beta / -rc 等 SemVer 预发布标识 — 这些会让 Xcode 警告
# 或 codesign 拒绝,运行时也无法通过 App Store Connect / TestFlight 校验。
# 失败模式选择:严格 fail-fast 而不是"宽松提取",让用户在调用层就修正版本号。
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "\033[0;31m✗\033[0m 版本号格式错误: '$VERSION'" >&2
    echo "  → 必须是 X.Y.Z 三段纯数字 (如 0.0.1, 0.1.0, 1.2.3)" >&2
    echo "  → 不支持 -alpha / -beta / -rc 等后缀 (Apple 限制)" >&2
    echo "  → 想标记 alpha 阶段?在 INSTALL.md 文案里手动写 '内测/alpha' 即可" >&2
    exit 1
fi

MARKETING_VERSION="$VERSION"

# Build number 用时间戳: yyyymmddHHMM。CFBundleVersion 必须单调递增,
# 时间戳保证多次构建不冲突 (跟 git commit / CI build id 切换很方便)。
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

# ============================================================================
# 路径
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/dmg"
DERIVED_DIR="$BUILD_DIR/DerivedData"
STAGING_DIR="$BUILD_DIR/staging"
DMG_PATH="$BUILD_DIR/Starcat-${VERSION}-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
README_PATH="$BUILD_DIR/INSTALL-${VERSION}.md"
BUILD_LOG="$BUILD_DIR/xcodebuild-${VERSION}.log"

# ============================================================================
# 日志工具
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
RESET='\033[0m'

log_step() { echo -e "\n${BLUE}▶${RESET} ${1}"; }
log_ok()   { echo -e "  ${GREEN}✓${RESET} ${1}"; }
log_warn() { echo -e "  ${YELLOW}⚠${RESET} ${1}"; }
log_err()  { echo -e "  ${RED}✗${RESET} ${1}" >&2; }
log_dim()  { echo -e "  ${GRAY}${1}${RESET}"; }

# ============================================================================
# 0. 环境检查
# ============================================================================
log_step "环境检查"

command -v xcodegen >/dev/null 2>&1 || {
    log_err "xcodegen 未安装"
    log_dim "→ brew install xcodegen"
    exit 1
}
log_ok "xcodegen 可用"

command -v xcodebuild >/dev/null 2>&1 || {
    log_err "xcodebuild 不在 PATH (检查 Xcode 是否安装)"
    exit 1
}
log_ok "xcodebuild 可用"

# create-dmg 可选: 有则生成带 Applications 拖拽箭头的专业 DMG,无则 hdiutil 兜底
USE_CREATE_DMG=0
if command -v create-dmg >/dev/null 2>&1; then
    USE_CREATE_DMG=1
    log_ok "create-dmg 可用,将生成带视觉引导的 DMG"
else
    log_warn "create-dmg 未安装,将用 hdiutil 出裸 DMG"
    log_dim "→ brew install create-dmg 可获得带 Applications 箭头的专业版"
fi

# 提醒关闭 Xcode (避免抢 derived data)
if pgrep -x "Xcode" >/dev/null 2>&1; then
    log_warn "Xcode 正在运行 — 如遇 'database is locked' 请 Cmd+Q 关闭后重跑"
fi

cd "$PROJECT_ROOT"

# ============================================================================
# 1. xcodegen 同步 project
# ============================================================================
log_step "同步 Xcode project"
xcodegen generate >/dev/null
log_ok "Starcat.xcodeproj 已与 project.yml 同步"

# ============================================================================
# 2. Release configuration build
# ============================================================================
log_step "编译 Release configuration (1-3 分钟)"
log_dim "MARKETING_VERSION = $MARKETING_VERSION"
log_dim "CURRENT_PROJECT_VERSION (build) = $BUILD_NUMBER"
log_dim "日志: $BUILD_LOG"

mkdir -p "$BUILD_DIR"
rm -rf "$DERIVED_DIR"

# 把完整日志重定向到文件,屏幕上只显示 tail。
# 失败时把日志末尾 30 行 dump 出来方便定位。
# ⚠️ 用 -sdk macosx -arch arm64 而不是 -destination 'platform=macOS,arch=arm64':
# 后者会让 xcodebuild 枚举所有已连接的设备(包括 USB/WiFi iPhone),如果有锁屏的
# iPhone 连着,会 hang 在 "The device is passcode protected" 上几十分钟不出错也不 build。
# -sdk + -arch 是老式语法,xcodebuild 直接走 macOS SDK,跳过 device discovery。
set +e
xcodebuild \
    -scheme Starcat \
    -configuration Release \
    -sdk macosx \
    -arch arm64 \
    -derivedDataPath "$DERIVED_DIR" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    clean build \
    >"$BUILD_LOG" 2>&1
BUILD_EXIT=$?
set -e

if [ $BUILD_EXIT -ne 0 ]; then
    log_err "Release build 失败 (exit code $BUILD_EXIT)"
    log_dim "── 日志末尾 30 行 ──"
    tail -30 "$BUILD_LOG"
    log_dim "── 完整日志: $BUILD_LOG ──"
    exit 1
fi

APP_PATH="$DERIVED_DIR/Build/Products/Release/Starcat.app"
if [ ! -d "$APP_PATH" ]; then
    log_err ".app 未生成: $APP_PATH"
    exit 1
fi

APP_SIZE=$(du -sh "$APP_PATH" | awk '{print $1}')
log_ok "Starcat.app 生成成功 ($APP_SIZE)"

# ============================================================================
# 3. Strip debug symbols (减体积)
# ============================================================================
log_step "Strip debug symbols"
STARCAT_BIN="$APP_PATH/Contents/MacOS/Starcat"
if [ -f "$STARCAT_BIN" ]; then
    # -x: 保留全局符号,只删除非全局 (Swift unwinding 信息需要保留,所以不能用 strip -S)
    strip -x "$STARCAT_BIN" 2>/dev/null || log_warn "strip 失败 (不影响功能,继续)"
    APP_SIZE_AFTER=$(du -sh "$APP_PATH" | awk '{print $1}')
    log_ok "体积: $APP_SIZE → $APP_SIZE_AFTER"
fi

# ============================================================================
# 4. DMG staging (拷贝 .app + Applications 符号链接)
# ============================================================================
log_step "准备 DMG staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
# Applications 软链接: 朋友打开 DMG 后可以直接拖拽到这个图标安装
ln -s /Applications "$STAGING_DIR/Applications"
log_ok "staging 完成"

# ============================================================================
# 5. 打 DMG
# ============================================================================
log_step "打 DMG"
rm -f "$DMG_PATH"

if [ "$USE_CREATE_DMG" = "1" ]; then
    # create-dmg: 600x400 窗口,左 Starcat 图标 / 右 Applications 箭头,视觉引导清晰
    create-dmg \
        --volname "Starcat $VERSION" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "Starcat.app" 150 200 \
        --hide-extension "Starcat.app" \
        --app-drop-link 450 200 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$STAGING_DIR/Starcat.app" >/dev/null 2>&1 || {
            log_warn "create-dmg 失败,回退到 hdiutil"
            USE_CREATE_DMG=0
        }
fi

if [ "$USE_CREATE_DMG" = "0" ]; then
    # hdiutil UDZO: zlib 压缩,通用兼容,体积适中
    hdiutil create \
        -volname "Starcat $VERSION" \
        -srcfolder "$STAGING_DIR" \
        -ov -format UDZO \
        "$DMG_PATH" >/dev/null
fi

DMG_SIZE=$(du -sh "$DMG_PATH" | awk '{print $1}')
log_ok "DMG 生成: $(basename "$DMG_PATH") ($DMG_SIZE)"

# ============================================================================
# 6. SHA256 校验和
# ============================================================================
log_step "计算 SHA256 (给朋友校验完整性)"
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "$SHA256  $(basename "$DMG_PATH")" > "$SHA_PATH"
log_ok "SHA256: ${SHA256:0:16}...${SHA256: -16}"
log_dim "→ $SHA_PATH"

# ============================================================================
# 7. 生成朋友的安装说明
# ============================================================================
log_step "生成朋友的安装说明 (Markdown)"
cat > "$README_PATH" <<EOF
# Starcat ${VERSION} · 内测安装说明

> dong4j 在做的 GitHub Star 管理工具 — 把扁平的 GitHub 收藏变成可搜索、AI 驱动的知识库。
> 这个版本是 alpha 内测,不稳定,期待你的 bug 反馈 :)

---

## 你拿到了什么

- \`Starcat-${VERSION}-arm64.dmg\` — DMG 安装包 (Apple Silicon 专用)
- \`Starcat-${VERSION}-arm64.dmg.sha256\` — 校验和 (可选)
- \`INSTALL-${VERSION}.md\` — 本文件

### 系统要求

- macOS **15 Sequoia** 或更高
- **Apple Silicon** (M1/M2/M3/M4),不支持 Intel Mac

### 校验文件完整性 (可选)

终端跑下面命令,确认 SHA256 跟 dong4j 给的一致 (防中间人篡改):

\`\`\`bash
shasum -a 256 Starcat-${VERSION}-arm64.dmg
# 应该输出: ${SHA256}
\`\`\`

---

## 安装步骤

1. **双击 DMG** → 弹出 Starcat 安装窗口
2. **拖 Starcat 图标到 Applications 文件夹** (DMG 右侧那个箭头)
3. **退出 DMG**: 右键 Starcat (磁盘图标) → 推出

---

## ⚠️ 首次打开 (重要 — 不读会以为 app 坏了)

这是 dong4j **本地开发签名** (ad-hoc) 的版本,**没经过 Apple 公证**。
macOS Gatekeeper 默认会拦截,弹窗 *"Apple 无法验证 Starcat 不包含恶意软件"*。

**这不是 app 有问题,是 macOS 对未公证 app 的标准防护。**

### 方法 1 (推荐 — 一行命令最快)

**前提**:先把 Starcat 拖到 Applications 文件夹。然后终端跑:

\`\`\`bash
sudo xattr -dr com.apple.quarantine /Applications/Starcat.app
\`\`\`

输入开机密码 → 完成。之后双击就能打开,**不会再弹任何警告**。

> **原理**:macOS 给所有"从浏览器/AirDrop/邮件下载"的文件自动打上 \`com.apple.quarantine\` 扩展属性,Gatekeeper 只拦截带这个属性的文件。这条命令 (\`-d\` 删除 / \`-r\` 递归 app bundle 所有文件) 把属性删掉,Gatekeeper 直接跳过检查。不影响 app 本身的签名,安全。

### 方法 2: 右键打开 (GUI 党)

1. 去 Launchpad **或** Applications 文件夹
2. **右键 (Control + 单击)** Starcat 图标
3. 在弹出菜单里点 **"打开"**
4. 弹窗 *"无法验证开发者"* → 点 **"打开"** 按钮 (灰色那个,**不是**红色的"移到废纸篓")
5. ✅ 完成,之后正常双击就能打开

### 方法 3: 系统设置允许 (兜底)

如果方法 2 还是被拦 (macOS 14+ 偶尔):

1. 先尝试双击 (会被拦,关掉对话框)
2. **系统设置** → **隐私与安全性**
3. 滚到底部,找到 *"已阻止使用 Starcat"* 提示
4. 点 **"仍要打开"**
5. Touch ID / 密码确认

---

## 反馈

任何 crash / bug / 体验问题:

- 截图 + 复现步骤发给 dong4j (微信)
- 重大 crash 顺手打开 \`Console.app\` → 搜 "Starcat" → 把 crash log 一起发

---

<sub>Build ${BUILD_NUMBER} · Generated $(date '+%Y-%m-%d %H:%M:%S %Z')</sub>
EOF
log_ok "$(basename "$README_PATH")"

# ============================================================================
# 8. 清理中间产物
# ============================================================================
log_step "清理中间产物"
rm -rf "$DERIVED_DIR" "$STAGING_DIR"
log_ok "DerivedData / staging 已清理"

# ============================================================================
# 完成
# ============================================================================
echo
echo -e "${GREEN}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}  ✓ DMG 打包完成${RESET}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${RESET}"
echo
echo "  ${BLUE}DMG    ${RESET} $DMG_PATH"
echo "  ${BLUE}       ${RESET} ($DMG_SIZE)"
echo
echo "  ${BLUE}SHA256 ${RESET} $SHA_PATH"
echo "  ${BLUE}README ${RESET} $README_PATH"
echo "  ${BLUE}日志   ${RESET} $BUILD_LOG (可删)"
echo
echo "  ${YELLOW}发给朋友 3 个文件:${RESET}"
echo "    1) Starcat-${VERSION}-arm64.dmg"
echo "    2) Starcat-${VERSION}-arm64.dmg.sha256 (可选)"
echo "    3) INSTALL-${VERSION}.md ${YELLOW}← 务必让朋友先看这个,有 Gatekeeper 绕过教程${RESET}"
echo
