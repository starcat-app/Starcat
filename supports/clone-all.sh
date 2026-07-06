#!/bin/bash
# =============================================================================
# clone-all.sh — Starcat 支撑项目一键拉取脚本
# =============================================================================
# 用法:
#   ./clone-all.sh          首次运行: clone 所有支撑项目(已存在则跳过)
#   ./clone-all.sh --pull   更新模式: 对已存在的项目执行 git pull
#   ./clone-all.sh --help   显示帮助
#
# 支撑项目统一放在 supports/ 目录下:
#   - 6 个 Go API 服务(starcat-*-api)
#   - starcat-pro / starcat-license-api / starcat-localization
#   - homebrew-starcat / vscode-makefile-explorer
#   - extensions/ 下 2 个浏览器插件
#
# 前置条件: git 可用; starcat-license-api 是私有仓库,需要 gh CLI 或 SSH key 已配置
# =============================================================================

set -euo pipefail

# ---- 颜色定义 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---- 切换到脚本所在目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- 参数解析 ----
PULL_MODE=false
SHOW_HELP=false

case "${1:-}" in
  --pull|-p)
    PULL_MODE=true
    ;;
  --help|-h)
    SHOW_HELP=true
    ;;
  "")
    ;;
  *)
    echo -e "${RED}未知参数: $1${NC}"
    SHOW_HELP=true
    ;;
esac

if $SHOW_HELP; then
  echo "用法: $(basename "$0") [--pull | --help]"
  echo ""
  echo "  (无参数)    首次 clone 所有支撑项目，已存在则跳过"
  echo "  --pull, -p  对已存在的项目执行 git pull 更新"
  echo "  --help, -h  显示此帮助"
  echo ""
  echo "支撑项目列表:"
  echo "  6 个 Go API 服务  (starcat-*-api)"
  echo "  starcat-pro        Pro 订阅服务"
  echo "  starcat-license-api  Direct 分发授权 API (🔒 私有)"
  echo "  starcat-localization  本地化资源"
  echo "  homebrew-starcat    Homebrew tap"
  echo "  vscode-makefile-explorer  VS Code 插件"
  echo "  starcat-chrome-plugin     Chrome 浏览器插件"
  echo "  starcat-safari-plugin     Safari 浏览器插件"
  exit 0
fi

# ---- 支撑项目清单 ----
# 格式: "目录名|GitHub URL|描述"
# extensions/ 下的项目目录名带 "extensions/" 前缀
PROJECTS=(
  "starcat-sharing-api|https://github.com/dong4j/starcat-sharing-api.git|Go API - 分享服务"
  "starcat-trending-api|https://github.com/dong4j/starcat-trending-api.git|Go API - 趋势服务"
  "starcat-weekly-api|https://github.com/dong4j/starcat-weekly-api.git|Go API - 周刊服务"
  "starcat-wiki-api|https://github.com/dong4j/starcat-wiki-api.git|Go API - Wiki 服务"
  "starcat-recommend-api|https://github.com/dong4j/starcat-recommend-api.git|Go API - 推荐服务"
  "starcat-discovery-api|https://github.com/dong4j/starcat-discovery-api.git|Go API - 发现服务"
  "starcat-pro|https://github.com/dong4j/starcat-pro.git|Pro 订阅服务"
  "starcat-license-api|https://github.com/dong4j/starcat-license-api.git|Direct 分发授权 API 🔒"
  "starcat-localization|https://github.com/dong4j/starcat-localization.git|本地化资源"
  "homebrew-starcat|https://github.com/dong4j/homebrew-starcat.git|Homebrew tap"
  "vscode-makefile-explorer|https://github.com/dong4j/vscode-makefile-explorer.git|VS Code 插件"
  "extensions/starcat-chrome-plugin|https://github.com/dong4j/starcat-chrome-plugin.git|Chrome 浏览器插件"
  "extensions/starcat-safari-plugin|https://github.com/dong4j/starcat-safari-plugin.git|Safari 浏览器插件"
)

# ---- 计数器 ----
TOTAL=${#PROJECTS[@]}
SUCCESS=0
SKIPPED=0
FAILED=0

# ---- 打印分隔线 ----
print_separator() {
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ---- 主流程 ----
echo ""
print_separator
echo -e "${BOLD}${CYAN}  Starcat 支撑项目一键拉取${NC}"
if $PULL_MODE; then
  echo -e "  模式: ${YELLOW}更新 (git pull)${NC}"
else
  echo -e "  模式: ${GREEN}首次 clone${NC}"
fi
echo -e "  共 ${TOTAL} 个项目"
print_separator
echo ""

for entry in "${PROJECTS[@]}"; do
  IFS='|' read -r dir url desc <<< "$entry"

  if $PULL_MODE; then
    # ---- 更新模式 ----
    if [[ -d "$dir/.git" ]]; then
      echo -e "${BLUE}[↻]${NC} ${BOLD}${dir}${NC} — ${desc}"
      if (cd "$dir" && git pull --ff-only); then
        echo -e "    ${GREEN}✓ 已更新${NC}"
        ((SUCCESS++))
      else
        echo -e "    ${RED}✗ pull 失败,请检查本地改动或网络${NC}"
        ((FAILED++))
      fi
    else
      echo -e "${YELLOW}[!]${NC} ${BOLD}${dir}${NC} — ${desc}"
      echo -e "    ${YELLOW}目录不存在,跳过 (先运行 ./clone-all.sh 无参数 clone)${NC}"
      ((SKIPPED++))
    fi
  else
    # ---- Clone 模式 ----
    if [[ -d "$dir/.git" ]]; then
      echo -e "${GREEN}[✓]${NC} ${BOLD}${dir}${NC} — ${desc}"
      echo -e "    ${GREEN}已存在,跳过${NC}"
      ((SKIPPED++))
    else
      echo -e "${CYAN}[↓]${NC} ${BOLD}${dir}${NC} — ${desc}"
      # extensions/ 子目录需要先创建父目录
      if [[ "$dir" == */* ]]; then
        mkdir -p "$(dirname "$dir")"
      fi
      if git clone "$url" "$dir"; then
        echo -e "    ${GREEN}✓ clone 成功${NC}"
        ((SUCCESS++))
      else
        echo -e "    ${RED}✗ clone 失败,请检查网络或仓库权限${NC}"
        echo -e "    ${YELLOW}  提示: starcat-license-api 是私有仓库,需 gh auth login 或配置 SSH key${NC}"
        ((FAILED++))
      fi
    fi
  fi
  echo ""
done

# ---- 汇总 ----
print_separator
echo -e "${BOLD}汇总:${NC}"
echo -e "  ${GREEN}成功${NC}  ${SUCCESS}"
echo -e "  ${YELLOW}跳过${NC}  ${SKIPPED}"
echo -e "  ${RED}失败${NC}  ${FAILED}"
echo -e "  ${CYAN}合计${NC}  ${TOTAL}"
print_separator

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo -e "${YELLOW}提示: 有项目拉取失败。对于私有仓库 (starcat-license-api),确保:${NC}"
  echo -e "  1. gh CLI 已安装并登录: ${CYAN}gh auth login${NC}"
  echo -e "  2. 或已配置 SSH key:   ${CYAN}ssh -T git@github.com${NC}"
fi

echo ""

exit $FAILED
