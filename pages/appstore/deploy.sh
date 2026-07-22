#!/bin/bash
# ============================================================================
# Starcat App Store 落地页 + dong4j.app Worker — 部署脚本
#
# 用法:
#   ./deploy.sh                    部署 Pages (production) + Worker
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
#   - 已全局安装 wrangler (`npm i -g wrangler`)
#   - 项目已在 Cloudflare Dashboard 创建 (或首次部署时自动创建)
#   - 域名 dong4j.app 已在 Cloudflare DNS 配置
#   - Cloudflare API Token 已配置 (环境变量或 wrangler login)
#
# Pages 项目初始创建 (仅需执行一次):
#   wrangler pages project create starcat-appstore --production-branch=main
#
# ============================================================================

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
WORKER_DIR="$SCRIPT_DIR/worker"

# --- 默认配置 ---------------------------------------------------------------
CF_PAGES_PROJECT="${CF_PAGES_PROJECT:-starcat-appstore}"
CF_PAGES_BRANCH="${CF_PAGES_BRANCH:-main}"
DRY_RUN=false

# --- 帮助 -------------------------------------------------------------------
show_help() {
    echo "================================================================================"
    echo "Starcat App Store — Cloudflare Pages + Worker 部署脚本"
    echo "================================================================================"
    echo ""
    echo "用法:"
    echo "  ./deploy.sh                      生产环境部署 (Pages → Worker)"
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
    echo "  Pages 项目: $CF_PAGES_PROJECT"
    echo "  Pages 分支: $CF_PAGES_BRANCH"
    echo "  Pages 源目录: $SCRIPT_DIR"
    echo "  Worker 目录:  $WORKER_DIR"
    echo "  线上地址:"
    echo "    https://dong4j.app/            (Worker 导航首页)"
    echo "    https://dong4j.app/starcat     (Pages 落地页)"
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
echo "Starcat App Store → Cloudflare"
echo "================================"
echo "Pages 项目: $CF_PAGES_PROJECT"
echo "Pages 分支: $CF_PAGES_BRANCH"
echo "Pages 源目录: $SCRIPT_DIR"
echo "Worker 目录:  $WORKER_DIR"
echo "================================"

# 检查源目录是否存在 index.html (确保部署的是正确目录)
if [ ! -f "$SCRIPT_DIR/index.html" ]; then
    echo "❌ 错误: 在 $SCRIPT_DIR 未找到 index.html"
    echo "   请确保从 pages/appstore/ 目录运行此脚本"
    exit 1
fi

if [ ! -f "$WORKER_DIR/worker.js" ] || [ ! -f "$WORKER_DIR/wrangler.toml" ]; then
    echo "❌ 错误: Worker 目录不完整: $WORKER_DIR"
    echo "   需要 worker.js 与 wrangler.toml"
    exit 1
fi

# 优先使用全局 wrangler；其次项目本地安装。不再回退到 npx。
WRANGLER=""
if command -v wrangler &> /dev/null; then
    WRANGLER="wrangler"
elif [ -f "$PROJECT_ROOT/node_modules/.bin/wrangler" ]; then
    WRANGLER="$PROJECT_ROOT/node_modules/.bin/wrangler"
else
    echo "❌ 未找到 wrangler。请先全局安装:"
    echo "   npm i -g wrangler"
    exit 1
fi
echo "使用 wrangler: $($WRANGLER --version 2>/dev/null || echo "$WRANGLER")"

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
        echo "    wrangler login"
        echo ""
        exit 1
    fi
    echo "✓ Cloudflare 认证成功"
fi

# --- 合规检查 ---------------------------------------------------------------
echo ""
echo "合规检查 (不应出现外部支付/直接分发关键词)..."

VIOLATIONS=$(rg -in "Creem|License|DMG|Sparkle|appcast|license.?key|starcat\\.ink|downloads|Waffo|Paddle|Stripe" "$SCRIPT_DIR" --include '*.html' -l 2>/dev/null || true)

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

# --- dry-run ----------------------------------------------------------------
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "[DRY RUN] 将按顺序执行:"
    echo ""
    echo "  1) Cloudflare Pages"
    echo "  cd $SCRIPT_DIR"
    echo "  $WRANGLER pages deploy . \\"
    echo "    --project-name=$CF_PAGES_PROJECT \\"
    echo "    --branch=$CF_PAGES_BRANCH \\"
    echo "    --commit-dirty=true"
    echo ""
    echo "  2) Cloudflare Worker (最后)"
    echo "  cd $WORKER_DIR"
    echo "  $WRANGLER deploy"
    echo ""
    echo "部署目录 HTML:"
    ls -1 "$SCRIPT_DIR"/*.html | while read -r f; do
        echo "  $(basename "$f")"
    done
    echo ""
    echo "线上地址:"
    echo "  https://dong4j.app/"
    echo "  https://dong4j.app/starcat"
    echo "预览地址: https://$CF_PAGES_BRANCH.$CF_PAGES_PROJECT.pages.dev"
    exit 0
fi

# --- 1) Pages 部署 ----------------------------------------------------------
echo "================================"
echo "1/2 部署 Cloudflare Pages..."
echo "================================"

cd "$SCRIPT_DIR"

$WRANGLER pages deploy . \
    --project-name="$CF_PAGES_PROJECT" \
    --branch="$CF_PAGES_BRANCH" \
    --commit-dirty=true

DEPLOY_EXIT=$?

if [ $DEPLOY_EXIT -ne 0 ]; then
    echo ""
    echo "❌ Pages 部署失败"
    echo ""
    echo "常见问题排查:"
    echo "  1. 项目 $CF_PAGES_PROJECT 是否存在？"
    echo "     创建项目: wrangler pages project create $CF_PAGES_PROJECT --production-branch=main"
    echo "  2. API Token 权限是否足够？需要 Pages:Edit 权限"
    echo "  3. 网络是否可访问 Cloudflare API？"
    exit $DEPLOY_EXIT
fi

echo ""
echo "✓ Pages 部署完成"

# --- 2) Worker 部署（最后）--------------------------------------------------
echo ""
echo "================================"
echo "2/2 部署 Cloudflare Worker..."
echo "================================"

cd "$WORKER_DIR"

$WRANGLER deploy

WORKER_EXIT=$?

if [ $WORKER_EXIT -ne 0 ]; then
    echo ""
    echo "❌ Worker 部署失败"
    echo "   Pages 已更新，但 dong4j.app/ 导航首页可能仍是旧版"
    echo "   可单独重试: cd $WORKER_DIR && wrangler deploy"
    exit $WORKER_EXIT
fi

echo ""
echo "================================"
echo "✓ 全部部署完成"
echo "================================"
echo "线上地址:"
echo "  https://dong4j.app/            (导航首页)"
echo "  https://dong4j.app/starcat     (App Store 落地页)"
echo "预览地址: https://$CF_PAGES_BRANCH.$CF_PAGES_PROJECT.pages.dev"
echo ""
echo "验证:"
echo "  open https://dong4j.app/"
echo "  curl -I https://dong4j.app/starcat"
echo "  open https://dong4j.app/starcat"
echo "  open https://dong4j.app/starcat/support"
echo "  open https://dong4j.app/starcat/privacy"
echo "  open https://dong4j.app/starcat/eula"
echo "================================"
