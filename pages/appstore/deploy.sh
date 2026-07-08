#!/bin/bash
# ============================================================================
# Starcat App Store 落地页 — Cloudflare Pages 部署脚本
#
# 用法:
#   ./deploy.sh                    部署到 Cloudflare Pages (production)
#   ./deploy.sh -b preview         部署到 preview 分支 (预览环境)
#   ./deploy.sh -p <project>       指定 Cloudflare Pages 项目名
#   ./deploy.sh --dry-run          仅打印将要执行的命令，不上传
#   ./deploy.sh -h                 显示帮助
#
# 环境变量:
#   CF_PAGES_PROJECT               Cloudflare Pages 项目名 (默认: starcat-appstore)
#   CF_PAGES_BRANCH                部署分支 (默认: main)
#   CLOUDFLARE_API_TOKEN           Cloudflare API Token (wrangler 自动读取)
#
# 前置条件:
#   - 项目已在 Cloudflare Dashboard 创建 (或首次部署时自动创建)
#   - 域名 dong4j.app 已在 Cloudflare DNS 配置，指向该 Pages 项目
#   - Cloudflare API Token 已配置 (环境变量或 wrangler login)
#   - 如需自定义域名和路径映射，在 Cloudflare Dashboard 中配置:
#     dong4j.app/starcat/* → 该 Pages 项目
#
# Pages 项目初始创建 (仅需执行一次):
#   npx wrangler pages project create starcat-appstore --production-branch=main
#
# ============================================================================

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# --- 默认配置 ---------------------------------------------------------------
CF_PAGES_PROJECT="${CF_PAGES_PROJECT:-starcat-appstore}"
CF_PAGES_BRANCH="${CF_PAGES_BRANCH:-main}"
DRY_RUN=false

# --- 帮助 -------------------------------------------------------------------
show_help() {
    echo "================================================================================"
    echo "Starcat App Store 落地页 — Cloudflare Pages 部署脚本"
    echo "================================================================================"
    echo ""
    echo "用法:"
    echo "  ./deploy.sh                      生产环境部署"
    echo "  ./deploy.sh -b preview           部署到 preview 分支 (预览 URL)"
    echo "  ./deploy.sh -p <项目名>          指定 Cloudflare Pages 项目名"
    echo "  ./deploy.sh --dry-run            仅检查，不执行部署"
    echo "  ./deploy.sh -h                   显示此帮助"
    echo ""
    echo "环境变量:"
    echo "  CF_PAGES_PROJECT                 项目名 (默认: starcat-appstore)"
    echo "  CF_PAGES_BRANCH                  分支 (默认: main)"
    echo "  CLOUDFLARE_API_TOKEN             Cloudflare API Token"
    echo ""
    echo "部署目标:"
    echo "  项目:     $CF_PAGES_PROJECT"
    echo "  分支:     $CF_PAGES_BRANCH"
    echo "  源目录:   $SCRIPT_DIR"
    echo "  线上地址: https://dong4j.app/starcat"
    echo "  预览地址: https://$CF_PAGES_BRANCH.$CF_PAGES_PROJECT.pages.dev"
    echo "================================================================================"
}

# --- 参数解析 ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--branch)
            CF_PAGES_BRANCH="$2"
            shift 2
            ;;
        -p|--project)
            CF_PAGES_PROJECT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# --- 前置检查 ---------------------------------------------------------------
echo "================================"
echo "Starcat App Store → Cloudflare Pages"
echo "================================"
echo "项目:   $CF_PAGES_PROJECT"
echo "分支:   $CF_PAGES_BRANCH"
echo "源目录: $SCRIPT_DIR"
echo "================================"

# 检查源目录是否存在 index.html (确保部署的是正确目录)
if [ ! -f "$SCRIPT_DIR/index.html" ]; then
    echo "❌ 错误: 在 $SCRIPT_DIR 未找到 index.html"
    echo "   请确保从 pages/appstore/ 目录运行此脚本"
    exit 1
fi

# 检查 wrangler 是否可用，优先使用项目本地安装
WRANGLER=""
if [ -f "$PROJECT_ROOT/node_modules/.bin/wrangler" ]; then
    WRANGLER="$PROJECT_ROOT/node_modules/.bin/wrangler"
elif command -v wrangler &> /dev/null; then
    WRANGLER="wrangler"
else
    # 通过 npx 临时使用，不全局安装
    WRANGLER="npx wrangler"
    echo "⚠ wrangler 未安装，将通过 npx 临时下载使用"
fi

# 检查 Cloudflare 认证状态 (跳过 dry-run)
if [ "$DRY_RUN" = false ]; then
    echo "检查 Cloudflare 认证..."
    if ! $WRANGLER whoami &> /dev/null; then
        echo ""
        echo "❌ 未登录 Cloudflare。请先执行以下任一操作:"
        echo ""
        echo "  方式 1 (推荐): 设置 API Token"
        echo "    export CLOUDFLARE_API_TOKEN=\"your-api-token\""
        echo ""
        echo "  方式 2: 交互式登录"
        echo "    npx wrangler login"
        echo ""
        exit 1
    fi
    echo "✓ Cloudflare 认证成功"
fi

# --- 合规检查 ---------------------------------------------------------------
echo ""
echo "合规检查 (不应出现外部支付/直接分发关键词)..."

VIOLATIONS=$(rg -in "Creem|Lifetime|DMG|Sparkle|appcast|license.?key|starcat\\.ink|downloads|Waffo|Paddle|Stripe" "$SCRIPT_DIR" --include '*.html' -l 2>/dev/null || true)

if [ -n "$VIOLATIONS" ]; then
    echo "⚠ 以下文件包含需要检查的关键词:"
    echo "$VIOLATIONS" | while read -r f; do
        echo "  $(basename "$f")"
    done
    echo ""
    echo "  请人工确认这些关键词仅用于否定声明（如 'does NOT use external license keys'）"
    echo "  或为 Lucide 图标名（如 'sparkles'）"
    echo ""
fi

# --- 部署 -------------------------------------------------------------------
echo "================================"
echo "开始部署到 Cloudflare Pages..."
echo "================================"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "[DRY RUN] 将执行以下命令:"
    echo ""
    echo "  cd $SCRIPT_DIR"
    echo "  $WRANGLER pages deploy . \\"
    echo "    --project-name=$CF_PAGES_PROJECT \\"
    echo "    --branch=$CF_PAGES_BRANCH \\"
    echo "    --commit-dirty=true"
    echo ""
    echo "部署目录内容:"
    ls -1 "$SCRIPT_DIR"/*.html | while read -r f; do
        echo "  $(basename "$f")"
    done
    echo ""
    echo "线上地址: https://dong4j.app/starcat"
    echo "预览地址: https://$CF_PAGES_BRANCH.$CF_PAGES_PROJECT.pages.dev"
    exit 0
fi

# 实际部署
cd "$SCRIPT_DIR"

$WRANGLER pages deploy . \
    --project-name="$CF_PAGES_PROJECT" \
    --branch="$CF_PAGES_BRANCH" \
    --commit-dirty=true

DEPLOY_EXIT=$?

if [ $DEPLOY_EXIT -ne 0 ]; then
    echo ""
    echo "❌ 部署失败"
    echo ""
    echo "常见问题排查:"
    echo "  1. 项目 $CF_PAGES_PROJECT 是否存在？"
    echo "     创建项目: npx wrangler pages project create $CF_PAGES_PROJECT --production-branch=main"
    echo "  2. API Token 权限是否足够？需要 Pages:Edit 权限"
    echo "  3. 网络是否可访问 Cloudflare API？"
    exit $DEPLOY_EXIT
fi

echo ""
echo "================================"
echo "✓ 部署完成"
echo "================================"
echo "线上地址: https://dong4j.app/starcat"
echo "预览地址: https://$CF_PAGES_BRANCH.$CF_PAGES_PROJECT.pages.dev"
echo ""
echo "验证:"
echo "  curl -I https://dong4j.app/starcat"
echo "  open https://dong4j.app/starcat"
echo "  open https://dong4j.app/starcat/support"
echo "  open https://dong4j.app/starcat/privacy"
echo "  open https://dong4j.app/starcat/eula"
echo "================================"
