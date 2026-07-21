#!/bin/bash
# ============================================================================
# Starcat Direct 生产落地页部署脚本
#
# 用法:
#   ./deploy.sh          上传生产 nginx 配置并重载，然后同步 pages/direct/ 静态资源
#   DEPLOY_SSH_KEY=~/.ssh/server ./deploy.sh
#                       使用指定私钥连接远程服务器，避免本机 ssh alias 绑定到错误 key
#
# 前置条件:
#   - ~/.ssh/config 中已配置 aliyun2 别名
#   - 远程服务器已创建 /var/www/starcat 目录
#   - 远程服务器已创建 /etc/nginx/encrypt/starcat/ 目录（证书）
# ============================================================================

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REMOTE_HOST="aliyun2"
REMOTE_WEB_DIR="/var/www/starcat"
REMOTE_NGINX_DIR="/etc/nginx/conf.d"
NGINX_CONF="$SCRIPT_DIR/starcat.ink.conf"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-}"

SSH_CMD=(ssh)
RSYNC_SSH="ssh"
if [ -n "$DEPLOY_SSH_KEY" ]; then
    SSH_CMD=(ssh -i "$DEPLOY_SSH_KEY")
    RSYNC_SSH="ssh -i $DEPLOY_SSH_KEY"
fi

echo "================================"
echo "部署 Starcat Direct 生产落地页"
echo "本地目录: $SCRIPT_DIR"
echo "远程服务器: $REMOTE_HOST"
echo "远程目录:   $REMOTE_WEB_DIR"
echo "访问地址:   https://starcat.ink"
echo "================================"

if [ "${1:-}" = "-n" ]; then
    echo "错误: deploy.sh 不再支持 -n；直接执行 ./deploy.sh 会同时部署 nginx 和静态资源。"
    exit 1
fi
if [ "${1:-}" != "" ]; then
    echo "错误: 未知参数 $1"
    exit 1
fi

if [ ! -f "$NGINX_CONF" ]; then
    echo "错误: 找不到 Nginx 配置文件: $NGINX_CONF"
    exit 1
fi

echo "上传生产 Nginx 配置..."
rsync -avz --progress \
    -e "$RSYNC_SSH" \
    "$NGINX_CONF" \
    "$REMOTE_HOST:$REMOTE_NGINX_DIR/"

echo "检查 nginx 配置语法并重载..."
"${SSH_CMD[@]}" "$REMOTE_HOST" "nginx -t && systemctl reload nginx"

if [ $? -ne 0 ]; then
    echo "错误: Nginx 重载失败"
    exit 1
fi

echo "✓ 生产 Nginx 配置已部署并重载完成"

# 确保远程目录存在
"${SSH_CMD[@]}" "$REMOTE_HOST" "mkdir -p $REMOTE_WEB_DIR"

# rsync 同步 pages/direct/ 目录下由官网部署维护的静态文件。
# downloads/ 与 appcast.xml 由 release-direct.sh 单独维护，必须排除，避免官网部署
# 的 --delete 删除已发布 DMG，或用仓库里的旧 feed 覆盖线上 Sparkle 更新信息。
# 部署脚本、生成器与 Python cache 只服务于本地发布流程，不能进入公开 Web 目录。
echo "正在同步文件..."
rsync -avz --delete --progress \
    -e "$RSYNC_SSH" \
    --exclude '.DS_Store' \
    --exclude '*.log' \
    --exclude 'node_modules' \
    --exclude 'deploy.sh' \
    --exclude '*.py' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude 'starcat.ink.conf' \
    --exclude 'downloads/' \
    --exclude 'appcast.xml' \
    "$SCRIPT_DIR/" \
    "$REMOTE_HOST:$REMOTE_WEB_DIR/"

echo "设置文件权限..."
"${SSH_CMD[@]}" "$REMOTE_HOST" "find '$REMOTE_WEB_DIR' -type d -exec chmod 755 {} + && find '$REMOTE_WEB_DIR' -type f \( -name '*.html' -o -name '*.json' -o -name '*.png' -o -name '*.webp' -o -name '*.jpg' -o -name 'apple-app-site-association' \) -exec chmod 644 {} +"

echo "✓ 生产 nginx 与静态资源部署完成"
echo "访问地址: https://starcat.ink"
echo "================================"
