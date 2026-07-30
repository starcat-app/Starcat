#!/usr/bin/env bash
# =============================================================================
# setup-macos-development.sh
# =============================================================================
#
# Starcat 新 Mac 开发 / 打包 / 分发环境准备脚本。
#
# 设计目标：
#   1. 默认走交互流程，只在用户明确确认后安装工具或写本地配置。
#   2. `--check` 只读审计当前 Mac，不安装、不写文件、不执行构建或发布。
#   3. 只准备环境：绝不 archive、notarize、创建 tag、上传 DMG 或发布网站。
#   4. Starcat 已有线上 Sparkle 用户，禁止在新 Mac 自动生成另一组 EdDSA key；
#      这里只验证 Keychain 私钥，或从原 Mac 导出的私钥文件导入。
#
# 用法：
#   ./scripts/setup-macos-development.sh
#   ./scripts/setup-macos-development.sh --check
#
# 完整说明：
#   docs/6-发版与上架/SOP-新Mac开发发布环境搭建.md
# =============================================================================

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRETS_TEMPLATE="${PROJECT_ROOT}/Configs/Secrets.xcconfig.template"
SECRETS_FILE="${PROJECT_ROOT}/Configs/Secrets.xcconfig"
CODEBASE_BINARY="${PROJECT_ROOT}/Starcat/Resources/Codebase/codebase.bin"
STARCAT_PRO_DIR="${PROJECT_ROOT}/supports/starcat-pro"
SPARKLE_EXPORT_DEFAULT="${PROJECT_ROOT}/sparkle-private-key"
STORE_ENTITLEMENTS="${PROJECT_ROOT}/Starcat/Starcat.entitlements"
DIRECT_ENTITLEMENTS="${PROJECT_ROOT}/Starcat/StarcatDirect.entitlements"
GENERATED_PROJECT_FILE="${PROJECT_ROOT}/Starcat.xcodeproj/project.pbxproj"
DIRECT_PROVISIONING_APP="${PROJECT_ROOT}/build/DerivedData-DirectProvisioning/Build/Products/Debug/Starcat.app"
DIRECT_DEBUG_APP="${PROJECT_ROOT}/build/DerivedData-NoSandbox/Build/Products/Debug/Starcat.app"
AASA_URL="https://starcat.ink/.well-known/apple-app-site-association"

DEFAULT_TEAM_ID="8WCUMGCWMB"
DEFAULT_NOTARY_PROFILE="starcat-notary"
DEFAULT_RELEASE_HOST="aliyun2"

CHECK_ONLY=0
DEV_ISSUES=0
RELEASE_ISSUES=0

usage() {
  cat <<'EOF'
Starcat 新 Mac 开发 / 发布环境准备

Usage:
  ./scripts/setup-macos-development.sh          # 交互式准备
  ./scripts/setup-macos-development.sh --check  # 只读审计
  ./scripts/setup-macos-development.sh --help

脚本不会执行 build、archive、notarization submit、tag、上传或发布。
EOF
}

log() {
  printf '\n==> %s\n' "$1"
}

ok() {
  printf '  [OK] %s\n' "$1"
}

warn() {
  printf '  [WARN] %s\n' "$1" >&2
}

dev_issue() {
  DEV_ISSUES=$((DEV_ISSUES + 1))
  printf '  [DEV-MISSING] %s\n' "$1" >&2
}

release_issue() {
  RELEASE_ISSUES=$((RELEASE_ISSUES + 1))
  printf '  [RELEASE-MISSING] %s\n' "$1" >&2
}

ask_yes_no() {
  local prompt="$1"
  local default_answer="${2:-N}"
  local answer

  if [ ! -t 0 ]; then
    warn "当前不是交互式终端，跳过：${prompt}"
    return 1
  fi

  if [ "$default_answer" = "Y" ]; then
    read -r -p "${prompt} [Y/n] " answer
    answer="${answer:-Y}"
  else
    read -r -p "${prompt} [y/N] " answer
    answer="${answer:-N}"
  fi

  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_ssh_session() {
  [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]
}

# Finder / Terminal 通常会通过 shell profile 注入 Homebrew PATH，但 `ssh host cmd`
# 这类非交互会话不会读取相同配置。审计阶段主动加载标准安装路径，避免把“已安装
# 但不在 PATH”误报为缺失；不执行安装，也不修改远端 shell 配置。
activate_homebrew_path() {
  if command_exists brew; then
    return
  fi

  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# 只读取指定 xcconfig key，不打印其他私密配置。值可能包含 `=`，因此不能简单
# 依赖 `awk -F= '$2'`，必须从第一个等号之后截取完整内容。
xcconfig_value() {
  local key="$1"
  local file_path="${2:-$SECRETS_FILE}"

  [ -f "$file_path" ] || return 1
  awk -v wanted="$key" '
    $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$file_path"
}

# 只改一个配置项并保留模板其余注释与顺序。这里不用 `sed -i`，因为 BSD/GNU
# 参数不一致，而且临时文件 + 原子替换能避免中途中断留下半截 Secrets 文件。
set_xcconfig_value() {
  local key="$1"
  local value="$2"
  local temp_file

  temp_file="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")" || return 1
  if ! awk -v wanted="$key" -v replacement="$value" '
    BEGIN { replaced = 0 }
    $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      print wanted " = " replacement
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print wanted " = " replacement
      }
    }
  ' "$SECRETS_FILE" >"$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi

  mv "$temp_file" "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
}

find_sparkle_tool() {
  find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys' \
    -type f 2>/dev/null | head -1
}

audit_host_and_xcode() {
  log "macOS 与 Xcode"

  if [ "$(uname -s)" != "Darwin" ]; then
    dev_issue "Starcat 只能在 macOS 上开发和打包"
    return
  fi

  ok "macOS $(sw_vers -productVersion) ($(uname -m))"
  if [ "$(uname -m)" != "arm64" ]; then
    release_issue "当前 Direct 打包脚本固定生成 arm64 DMG，需要 Apple Silicon Mac"
  fi

  if ! command_exists xcodebuild; then
    dev_issue "未安装完整 Xcode"
    return
  fi

  local developer_dir
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$developer_dir" != */Xcode.app/Contents/Developer ]]; then
    dev_issue "xcode-select 未指向完整 Xcode.app：${developer_dir:-未设置}"
  else
    ok "Developer directory: $developer_dir"
  fi

  xcodebuild -version 2>/dev/null | sed 's/^/       /'
  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    ok "Xcode license / first-launch components 已完成"
  else
    dev_issue "Xcode 首次启动组件或 license 尚未完成"
  fi
}

audit_tools() {
  log "项目工具"

  activate_homebrew_path

  local tool_name
  for tool_name in git python3 rsync ssh curl codesign security plutil xcrun; do
    if command_exists "$tool_name"; then
      ok "$tool_name: $(command -v "$tool_name")"
    else
      dev_issue "$tool_name 不在 PATH"
    fi
  done

  if command_exists brew; then
    ok "Homebrew: $(command -v brew)"
  else
    dev_issue "Homebrew 未安装"
  fi

  if command_exists xcodegen; then
    ok "XcodeGen: $(xcodegen --version 2>/dev/null || command -v xcodegen)"
  else
    dev_issue "XcodeGen 未安装（项目不提交 Starcat.xcodeproj）"
  fi

  if command_exists create-dmg; then
    ok "create-dmg: $(command -v create-dmg)"
  else
    release_issue "create-dmg 未安装（Direct DMG 必需）"
  fi

  if ! command_exists jq; then
    warn "jq 未安装；不影响构建，但 scripts/sync-untracked.sh 需要它"
  else
    ok "jq: $(command -v jq)"
  fi
}

audit_local_files() {
  log "本地文件与独立仓库"

  if [ -d "$PROJECT_ROOT/Starcat.xcodeproj" ]; then
    ok "Starcat.xcodeproj 已由 XcodeGen 生成"
  else
    dev_issue "缺少 Starcat.xcodeproj；运行 xcodegen generate 重新生成"
  fi

  if [ -f "$SECRETS_FILE" ]; then
    local secrets_mode
    secrets_mode="$(stat -f '%Lp' "$SECRETS_FILE" 2>/dev/null || true)"
    if [ "$secrets_mode" = "600" ]; then
      ok "Configs/Secrets.xcconfig 存在且权限为 600"
    else
      release_issue "Configs/Secrets.xcconfig 权限应为 600，当前为 ${secrets_mode:-未知}"
    fi
  else
    dev_issue "缺少 Configs/Secrets.xcconfig"
  fi

  local team_id
  team_id="$(xcconfig_value DEVELOPMENT_TEAM 2>/dev/null || true)"
  if [ -n "$team_id" ]; then
    ok "DEVELOPMENT_TEAM 已配置"
  else
    dev_issue "Secrets.xcconfig 中 DEVELOPMENT_TEAM 为空"
  fi

  local required_dev_key
  for required_dev_key in \
    STARCAT_OAUTH_CLIENT_SECRET \
    STARCAT_LICENSE_API_TEST_BASE_URL \
    STARCAT_LICENSE_API_TEST_KEY; do
    if [ -n "$(xcconfig_value "$required_dev_key" 2>/dev/null || true)" ]; then
      ok "${required_dev_key} 已配置（值已隐藏）"
    else
      dev_issue "${required_dev_key} 未配置"
    fi
  done

  local required_release_key
  for required_release_key in \
    STARCAT_SPARKLE_PUBLIC_ED_KEY \
    STARCAT_LICENSE_API_LIVE_BASE_URL \
    STARCAT_LICENSE_API_LIVE_KEY \
    STARCAT_PRODUCTION_API_KEY_TRENDING \
    STARCAT_PRODUCTION_API_KEY_WEEKLY \
    STARCAT_PRODUCTION_API_KEY_SHARING \
    STARCAT_PRODUCTION_API_KEY_WIKI \
    STARCAT_PRODUCTION_API_KEY_RECOMMEND \
    STARCAT_PRODUCTION_API_KEY_DISCOVERY; do
    if [ -n "$(xcconfig_value "$required_release_key" 2>/dev/null || true)" ]; then
      ok "${required_release_key} 已配置（值已隐藏）"
    else
      release_issue "${required_release_key} 未配置"
    fi
  done

  if [ -n "$(xcconfig_value STARCAT_APTABASE_APP_KEY 2>/dev/null || true)" ]; then
    ok "STARCAT_APTABASE_APP_KEY 已配置（值已隐藏）"
  else
    warn "STARCAT_APTABASE_APP_KEY 未配置；不阻断构建，但生产遥测会保持 no-op"
  fi

  if [ -x "$CODEBASE_BINARY" ]; then
    ok "CodebaseMemory 内置二进制存在且可执行"
  elif [ -f "$CODEBASE_BINARY" ]; then
    dev_issue "CodebaseMemory 二进制存在但没有执行权限"
  else
    dev_issue "缺少 Starcat/Resources/Codebase/codebase.bin（该文件不在 Git 中）"
  fi

  if [ -d "$STARCAT_PRO_DIR/.git" ]; then
    ok "supports/starcat-pro 独立仓库存在"
  else
    release_issue "缺少 supports/starcat-pro；Direct Release 构建需要它的双语 changelog"
  fi

  if [ -f "$SPARKLE_EXPORT_DEFAULT" ]; then
    local export_mode
    export_mode="$(stat -f '%Lp' "$SPARKLE_EXPORT_DEFAULT" 2>/dev/null || true)"
    if [ "$export_mode" = "600" ]; then
      warn "仓库根目录仍有 Sparkle 私钥导出文件；导入后应移入加密存储"
    else
      release_issue "sparkle-private-key 是敏感文件，当前权限不是 600"
    fi
  fi
}

has_identity() {
  local identity_prefix="$1"
  local team_id="$2"
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -E "${identity_prefix}:.*\\(${team_id}\\)" >/dev/null 2>&1
}

has_any_identity() {
  local identity_prefix="$1"
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "${identity_prefix}:" >/dev/null 2>&1
}

has_certificate() {
  local certificate_name="$1"
  security find-certificate -c "$certificate_name" >/dev/null 2>&1
}

audit_signing() {
  log "Apple 签名身份"

  local team_id
  team_id="$(xcconfig_value DEVELOPMENT_TEAM 2>/dev/null || true)"
  team_id="${team_id:-$DEFAULT_TEAM_ID}"

  # Apple Development identity 显示名末尾的括号可能是个人证书标识，并不等于
  # DEVELOPMENT_TEAM。实际 Team 归属由 build settings + provisioning profile
  # 共同约束；这里先确认本机确实有一把可用的 Development 私钥。
  if has_any_identity "Apple Development"; then
    ok "Apple Development（Team 由 build settings / provisioning 绑定）"
  elif has_certificate "Apple Development"; then
    dev_issue "Apple Development 证书存在，但私钥在当前会话不可用（可能未导入或 login Keychain 被锁定）"
  else
    dev_issue "缺少带私钥的 Apple Development identity"
  fi

  if has_identity "Apple Distribution" "$team_id"; then
    ok "Apple Distribution (${team_id})"
  elif has_certificate "Apple Distribution"; then
    release_issue "Apple Distribution 证书存在，但 Team ${team_id} 的私钥在当前会话不可用（可能未导入或 login Keychain 被锁定）"
  else
    release_issue "缺少带私钥的 Apple Distribution (${team_id})"
  fi

  if has_identity "Developer ID Application" "$team_id"; then
    ok "Developer ID Application (${team_id})"
  else
    release_issue "缺少带私钥的 Developer ID Application (${team_id})"
  fi

  printf '       可用 identity：\n'
  security find-identity -v -p codesigning 2>&1 | sed 's/^/       /'
}

audit_notary() {
  log "Apple notarization"

  local notary_output
  if notary_output="$(xcrun notarytool history --keychain-profile "$DEFAULT_NOTARY_PROFILE" 2>&1)"; then
    ok "notarytool Keychain profile '${DEFAULT_NOTARY_PROFILE}' 有效"
  else
    release_issue "notary profile '${DEFAULT_NOTARY_PROFILE}' 不可用"
    printf '%s\n' "$notary_output" | head -3 | sed 's/^/       /' >&2
  fi
}

audit_sparkle() {
  log "Sparkle EdDSA"

  local sparkle_tool
  sparkle_tool="$(find_sparkle_tool)"
  if [ -z "$sparkle_tool" ]; then
    release_issue "尚未找到 Sparkle generate_keys；先解析 StarcatDirect 的 SPM 依赖"
    return
  fi
  ok "generate_keys 已就绪"

  local keychain_public configured_public
  if ! keychain_public="$("$sparkle_tool" -p 2>/dev/null)"; then
    release_issue "Keychain 中没有可读取的 Sparkle 私钥，或当前 Keychain 被锁定"
    return
  fi

  configured_public="$(xcconfig_value STARCAT_SPARKLE_PUBLIC_ED_KEY 2>/dev/null || true)"
  if [ -z "$configured_public" ]; then
    release_issue "Secrets.xcconfig 中 Sparkle 公钥为空"
  elif printf '%s' "$keychain_public" | grep -Fq "$configured_public"; then
    ok "Keychain 私钥与 STARCAT_SPARKLE_PUBLIC_ED_KEY 匹配"
  else
    release_issue "Keychain Sparkle 私钥与项目公钥不匹配；禁止生成新 key 覆盖"
  fi
}

source_entitlements_include_domain() {
  local entitlements_path="$1"

  [ -f "$entitlements_path" ] || return 1
  # entitlement key 自身包含点号；`plutil -extract` 会把它误解为嵌套 key path。
  # 先解析整个 plist，再匹配域名值，既确认文件有效，也避免字符串裸 grep。
  plutil -p "$entitlements_path" 2>/dev/null \
    | grep -Fq '"applinks:starcat.ink"'
}

# Universal Links 有四个独立边界：仓库 entitlements、生成工程 capability、
# 线上 AASA、最终签名产物。前三项可只读核对；最后一项只有在开发者已经人工
# 执行 provisioning build 时才检查，脚本不会为了审计而登记设备或触发 build。
audit_universal_links() {
  log "Universal Links / Associated Domains"

  if source_entitlements_include_domain "$STORE_ENTITLEMENTS"; then
    ok "Starcat.entitlements 包含 applinks:starcat.ink"
  else
    dev_issue "Starcat.entitlements 缺少 applinks:starcat.ink"
  fi

  if source_entitlements_include_domain "$DIRECT_ENTITLEMENTS"; then
    ok "StarcatDirect.entitlements 包含 applinks:starcat.ink"
  else
    dev_issue "StarcatDirect.entitlements 缺少 applinks:starcat.ink"
  fi

  if [ -f "$GENERATED_PROJECT_FILE" ]; then
    local capability_count
    capability_count="$(grep -c 'com.apple.SafariKeychain' "$GENERATED_PROJECT_FILE" 2>/dev/null || true)"
    if [ "${capability_count:-0}" -ge 2 ]; then
      ok "生成工程已为 Starcat / StarcatDirect 写入 Associated Domains capability"
    else
      dev_issue "生成工程没有同时包含两个 Associated Domains capability；重新运行 xcodegen generate"
    fi
  else
    warn "尚无生成工程，跳过 capability 检查；先运行 xcodegen generate"
  fi

  local aasa_json
  if aasa_json="$(curl -fsSL --connect-timeout 8 --max-time 20 "$AASA_URL" 2>/dev/null)"; then
    if printf '%s' "$aasa_json" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
details = payload.get("applinks", {}).get("details", [])
expected = {
    "8WCUMGCWMB.com.starcat.app.store",
    "8WCUMGCWMB.com.starcat.app.direct",
}
actual = set()
has_repo_path = False
for detail in details:
    app_id = detail.get("appID")
    if app_id:
        actual.add(app_id)
    actual.update(detail.get("appIDs", []))
    for component in detail.get("components", []):
        if component.get("/") == "/r/*":
            has_repo_path = True

sys.exit(0 if expected.issubset(actual) and has_repo_path else 1)
'; then
      ok "线上 AASA 已授权两个 Starcat Bundle ID 处理 /r/*"
    else
      release_issue "线上 AASA 未同时授权两个 Bundle ID 和 /r/*"
    fi
  else
    release_issue "无法读取线上 AASA：${AASA_URL}"
  fi

  local direct_app strict_provisioning_validation
  direct_app="$DIRECT_PROVISIONING_APP"
  strict_provisioning_validation=1
  if [ ! -d "$direct_app" ] && [ -d "$DIRECT_DEBUG_APP" ]; then
    direct_app="$DIRECT_DEBUG_APP"
    strict_provisioning_validation=0
    warn "未找到专用 provisioning 产物，改为核对现有 run-direct Debug App"
  fi

  if [ ! -d "$direct_app" ]; then
    warn "未找到 Direct provisioning 验收产物；请按 SOP 人工执行一次签名 build"
    return
  fi

  if codesign --verify --deep --strict --verbose=2 "$direct_app" >/dev/null 2>&1; then
    ok "Direct Debug App 通过 codesign --verify --deep --strict"
  elif [ "$strict_provisioning_validation" -eq 1 ]; then
    dev_issue "Direct provisioning App 签名校验失败"
  else
    warn "现有 run-direct Debug App 签名校验失败；它不能替代专用 provisioning 验收"
  fi

  local signed_entitlements
  signed_entitlements="$(codesign -d --entitlements :- "$direct_app" 2>/dev/null || true)"
  if printf '%s' "$signed_entitlements" | grep -Fq 'applinks:starcat.ink'; then
    ok "Direct Debug App 最终签名包含 applinks:starcat.ink"
  elif [ "$strict_provisioning_validation" -eq 1 ]; then
    dev_issue "Direct provisioning App 最终签名缺少 applinks:starcat.ink"
  else
    warn "现有 run-direct Debug App 不含 applinks:starcat.ink；请按 SOP 生成专用 provisioning 产物验收"
  fi

  local embedded_profile profile_expiration
  embedded_profile="${direct_app}/Contents/embedded.provisionprofile"
  if [ -f "$embedded_profile" ]; then
    profile_expiration="$(security cms -D -i "$embedded_profile" 2>/dev/null \
      | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)"
    if [ -n "$profile_expiration" ]; then
      ok "Direct Development Profile 有效期至 ${profile_expiration}"
    else
      warn "Direct Development Profile 存在，但未能读取有效期"
    fi
  elif [ "$strict_provisioning_validation" -eq 1 ]; then
    warn "Direct provisioning App 未嵌入可读取的 Development Profile"
  else
    warn "现有 run-direct Debug App 未嵌入 Development Profile；它不能替代专用 provisioning 验收"
  fi
}

audit_ssh() {
  log "GitHub 与 Direct 发布服务器 SSH"

  local github_output
  github_output="$(ssh -T -o BatchMode=yes -o ConnectTimeout=8 git@github.com 2>&1 || true)"
  if printf '%s' "$github_output" | grep -q 'successfully authenticated'; then
    ok "GitHub SSH 已认证"
  else
    dev_issue "GitHub SSH 未认证"
    printf '%s\n' "$github_output" | head -2 | sed 's/^/       /' >&2
  fi

  if ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEFAULT_RELEASE_HOST" true >/dev/null 2>&1; then
    ok "Direct 发布服务器 '${DEFAULT_RELEASE_HOST}' 可连接"
  else
    release_issue "Direct 发布服务器 '${DEFAULT_RELEASE_HOST}' 不可连接"
  fi
}

print_summary() {
  log "审计结论"

  if [ "$DEV_ISSUES" -eq 0 ]; then
    ok "开发环境：READY"
  else
    printf '  [NO-GO] 开发环境仍有 %s 个缺口\n' "$DEV_ISSUES" >&2
  fi

  if [ "$RELEASE_ISSUES" -eq 0 ]; then
    ok "打包 / 分发环境：READY"
  else
    printf '  [NO-GO] 打包 / 分发环境仍有 %s 个缺口\n' "$RELEASE_ISSUES" >&2
  fi

  printf '\n脚本没有执行 build、archive、notarization submit、tag、上传或发布。\n'
}

run_audit() {
  DEV_ISSUES=0
  RELEASE_ISSUES=0
  audit_host_and_xcode
  audit_tools
  audit_local_files
  audit_signing
  audit_notary
  audit_sparkle
  audit_universal_links
  audit_ssh
  print_summary

  [ "$DEV_ISSUES" -eq 0 ] && [ "$RELEASE_ISSUES" -eq 0 ]
}

prepare_xcode() {
  log "准备 Xcode"

  if [ ! -d "/Applications/Xcode.app/Contents/Developer" ]; then
    warn "未找到 /Applications/Xcode.app。请先从 App Store 或 Apple Developer 下载完整 Xcode，再重跑脚本。"
    return
  fi

  if [[ "$(xcode-select -p 2>/dev/null || true)" != */Xcode.app/Contents/Developer ]]; then
    if ask_yes_no "将 xcode-select 切换到 /Applications/Xcode.app 吗？" "Y"; then
      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    fi
  fi

  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    if ask_yes_no "运行 Xcode 首次启动组件安装并接受当前 Xcode license 吗？" "N"; then
      sudo xcodebuild -runFirstLaunch
    fi
  fi
}

prepare_homebrew_and_tools() {
  log "准备 Homebrew 与项目工具"

  activate_homebrew_path

  if ! command_exists brew; then
    warn "Homebrew 未安装。即将使用 brew.sh 官方安装脚本，运行前会显示安装内容。"
    if ask_yes_no "安装 Homebrew 吗？" "Y"; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
  fi

  activate_homebrew_path

  if ! command_exists brew; then
    warn "Homebrew 仍不可用，跳过工具安装"
    return
  fi

  local packages=""
  command_exists xcodegen || packages="${packages} xcodegen"
  command_exists create-dmg || packages="${packages} create-dmg"
  command_exists jq || packages="${packages} jq"

  if [ -n "$packages" ]; then
    if ask_yes_no "使用 Homebrew 安装${packages} 吗？" "Y"; then
      # shellcheck disable=SC2086
      brew install $packages
    fi
  else
    ok "XcodeGen、create-dmg、jq 已安装"
  fi
}

prepare_local_config() {
  log "准备本地 Secrets.xcconfig"

  if [ ! -f "$SECRETS_FILE" ]; then
    if ask_yes_no "从模板创建 Configs/Secrets.xcconfig 吗？" "Y"; then
      cp "$SECRETS_TEMPLATE" "$SECRETS_FILE"
    else
      return
    fi
  fi

  chmod 600 "$SECRETS_FILE"
  ok "Secrets.xcconfig 权限已收紧为 600"

  local current_team team_id
  current_team="$(xcconfig_value DEVELOPMENT_TEAM 2>/dev/null || true)"
  if [ -z "$current_team" ]; then
    read -r -p "Apple Developer Team ID [${DEFAULT_TEAM_ID}]: " team_id
    team_id="${team_id:-$DEFAULT_TEAM_ID}"
    set_xcconfig_value DEVELOPMENT_TEAM "$team_id"
    set_xcconfig_value CODE_SIGN_IDENTITY "Apple Development"
    ok "已写入 DEVELOPMENT_TEAM 和 Debug CODE_SIGN_IDENTITY"
  else
    ok "DEVELOPMENT_TEAM 已存在，不覆盖"
  fi

  if [ -f "$SPARKLE_EXPORT_DEFAULT" ]; then
    chmod 600 "$SPARKLE_EXPORT_DEFAULT"
    warn "已把 sparkle-private-key 权限收紧为 600；导入后请移入加密存储，不要长期留在仓库目录"
  fi

  warn "脚本不会询问或打印 OAuth/API Secret。请按 SOP 通过加密通道迁移现有 Secrets.xcconfig，或人工补齐模板。"
}

prepare_project_dependencies() {
  log "生成工程并解析 Swift Package"

  if ! command_exists xcodegen || ! command_exists xcodebuild; then
    warn "缺少 xcodegen 或 xcodebuild，跳过依赖准备"
    return
  fi

  if ask_yes_no "运行 xcodegen generate 吗？" "Y"; then
    (cd "$PROJECT_ROOT" && xcodegen generate)
  fi

  if [ -d "$PROJECT_ROOT/Starcat.xcodeproj" ] \
    && ask_yes_no "解析 StarcatDirect 的 Swift Package（会联网下载依赖）吗？" "Y"; then
    (cd "$PROJECT_ROOT" && xcodebuild \
      -resolvePackageDependencies \
      -disableAutomaticPackageResolution \
      -onlyUsePackageVersionsFromResolvedFile \
      -project Starcat.xcodeproj \
      -scheme StarcatDirect)
  fi
}

prepare_untracked_assets() {
  log "准备 Git 不管理的构建资产"

  if [ ! -x "$CODEBASE_BINARY" ]; then
    warn "缺少可执行的 CodebaseMemory 内置二进制"
    if ask_yes_no "运行 scripts/fetch-codebase-binary.sh 下载并校验它吗？" "Y"; then
      (cd "$PROJECT_ROOT" && ./scripts/fetch-codebase-binary.sh)
    fi
  else
    ok "CodebaseMemory 二进制已存在"
  fi

  if [ ! -d "$STARCAT_PRO_DIR/.git" ]; then
    warn "Direct Release 需要独立仓库 supports/starcat-pro"
    if ask_yes_no "只克隆 supports/starcat-pro 吗？" "Y"; then
      mkdir -p "$PROJECT_ROOT/supports"
      git clone https://github.com/starcat-app/starcat-pro.git "$STARCAT_PRO_DIR"
    fi
  else
    ok "supports/starcat-pro 已存在"
  fi
}

prepare_signing_guidance() {
  log "签名证书人工步骤"

  local team_id
  team_id="$(xcconfig_value DEVELOPMENT_TEAM 2>/dev/null || true)"
  team_id="${team_id:-$DEFAULT_TEAM_ID}"

  if has_any_identity "Apple Development" \
    && has_identity "Apple Distribution" "$team_id" \
    && has_identity "Developer ID Application" "$team_id"; then
    ok "三类 Starcat 所需签名 identity 均可用"
    return
  fi

  cat <<EOF
  需要在新 Mac 的 login Keychain 中准备带私钥的：
    - Apple Development（显示名括号可能是个人证书标识）
    - Apple Distribution (${team_id})
    - Developer ID Application (${team_id})

  推荐路径：原 Mac 的 Xcode > Settings > Accounts > Manage Certificates，
  导出受密码保护的 .p12，在新 Mac 导入；也可以在 Xcode 中按权限新建证书。
  仅登录 Xcode 账号不等于这些私钥已经存在，脚本不会自动创建或吊销证书。
EOF

  if is_ssh_session; then
    warn "当前是 SSH 会话，跳过打开 Xcode；请在这台 Mac 的 GUI 中完成证书导入或创建"
    return
  fi

  if ask_yes_no "打开 Xcode 的账号设置吗？" "Y"; then
    open -a Xcode
  fi
}

prepare_notary_profile() {
  log "准备 notarytool Keychain profile"

  if xcrun notarytool history --keychain-profile "$DEFAULT_NOTARY_PROFILE" >/dev/null 2>&1; then
    ok "${DEFAULT_NOTARY_PROFILE} 已有效"
    return
  fi

  warn "${DEFAULT_NOTARY_PROFILE} 尚不可用；请在 GUI 登录后的本机 Terminal 中配置，SSH 会话可能遇到 Keychain locked"
  if is_ssh_session; then
    warn "当前是 SSH 会话，跳过 notary 凭据输入；不要通过聊天或远程命令传递 App-specific password"
    return
  fi

  if ! ask_yes_no "现在创建 / 更新 ${DEFAULT_NOTARY_PROFILE} 吗？" "N"; then
    return
  fi

  local apple_id team_id
  read -r -p "Apple ID 邮箱: " apple_id
  team_id="$(xcconfig_value DEVELOPMENT_TEAM 2>/dev/null || true)"
  team_id="${team_id:-$DEFAULT_TEAM_ID}"

  # 不传 --password，让 notarytool 自己进行安全输入；密码不会出现在 shell history、
  # ps 或脚本日志中。
  xcrun notarytool store-credentials "$DEFAULT_NOTARY_PROFILE" \
    --apple-id "$apple_id" \
    --team-id "$team_id"
}

prepare_sparkle_key() {
  log "准备 Sparkle EdDSA 私钥"

  local sparkle_tool
  sparkle_tool="$(find_sparkle_tool)"
  if [ -z "$sparkle_tool" ]; then
    warn "未找到 generate_keys；先完成 Swift Package 解析后再重跑脚本"
    return
  fi

  if "$sparkle_tool" -p >/dev/null 2>&1; then
    ok "Keychain 中已有 Sparkle 私钥；最终审计会验证它是否匹配项目公钥"
    return
  fi

  warn "Keychain 中没有可读取的 Sparkle 私钥。Starcat 已有线上用户，禁止在这台 Mac 重新生成一组新 key。"

  if is_ssh_session; then
    warn "当前是 SSH 会话，跳过 Sparkle 私钥导入；请在这台 Mac 的 GUI Terminal 中重跑脚本"
    return
  fi

  local import_path
  import_path="$SPARKLE_EXPORT_DEFAULT"
  if [ ! -f "$import_path" ]; then
    read -r -p "原 Mac 导出的 Sparkle 私钥文件路径（留空跳过）: " import_path
  fi

  if [ -z "$import_path" ] || [ ! -f "$import_path" ]; then
    warn "未导入 Sparkle 私钥。请在原 Mac 执行 generate_keys -x <加密存储路径> 后安全传输。"
    return
  fi

  chmod 600 "$import_path"
  if ask_yes_no "从该文件导入现有 Sparkle 私钥吗？" "Y"; then
    "$sparkle_tool" -f "$import_path"
    warn "导入完成。请把私钥导出文件移回加密存储，并确认仓库目录中不再保留副本。"
  fi
}

main() {
  case "${1:-}" in
    "") ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac

  cd "$PROJECT_ROOT"

  if [ "$CHECK_ONLY" -eq 1 ]; then
    run_audit
    exit $?
  fi

  cat <<'EOF'
Starcat 新 Mac 环境准备

本脚本会逐项征求确认；不会执行 build、archive、notarization submit、tag、上传或发布。
Apple 账号登录、证书导入、App-specific password 等敏感步骤仍由你本人确认。
EOF

  prepare_xcode
  prepare_homebrew_and_tools
  prepare_local_config
  prepare_project_dependencies
  prepare_untracked_assets
  prepare_signing_guidance
  prepare_notary_profile
  prepare_sparkle_key

  log "最终只读审计"
  run_audit
}

main "$@"
