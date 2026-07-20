#!/bin/bash
# ============================================================================
# Starcat Direct 测试落地页部署脚本
#
# 用法:
#   ./deploy.sh          上传测试 nginx 配置并重载，然后同步 pages/direct-test/ 静态资源
#   DEPLOY_SSH_KEY=~/.ssh/server ./deploy.sh
#                       使用指定私钥连接远程服务器，避免本机 ssh alias 绑定到错误 key
#
# 前置条件:
#   - ~/.ssh/config 中已配置 aliyun2 别名
#   - 远程服务器已创建 /var/www/starcat-test 目录
#   - 远程服务器已创建 /etc/nginx/encrypt/starcat/ 目录（证书）
# ============================================================================

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REMOTE_HOST="aliyun2"
REMOTE_WEB_DIR="/var/www/starcat-test"
REMOTE_NGINX_DIR="/etc/nginx/conf.d"
NGINX_CONF="$SCRIPT_DIR/starcat-test.ink.conf"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-}"

SSH_CMD=(ssh)
RSYNC_SSH="ssh"
if [ -n "$DEPLOY_SSH_KEY" ]; then
    SSH_CMD=(ssh -i "$DEPLOY_SSH_KEY")
    RSYNC_SSH="ssh -i $DEPLOY_SSH_KEY"
fi

echo "================================"
echo "部署 Starcat Direct 测试落地页"
echo "本地目录: $SCRIPT_DIR"
echo "远程服务器: $REMOTE_HOST"
echo "远程目录:   $REMOTE_WEB_DIR"
echo "访问地址:   https://test.starcat.ink"
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

echo "上传测试 Nginx 配置..."
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

echo "✓ 测试 Nginx 配置已部署并重载完成"

# 确保远程目录存在
"${SSH_CMD[@]}" "$REMOTE_HOST" "mkdir -p $REMOTE_WEB_DIR"

# rsync 同步 pages/direct-test/ 目录下的静态文件。
# --delete: 删除远程多余文件，保持完全一致。
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
    --exclude 'starcat-test.ink.conf' \
    "$SCRIPT_DIR/" \
    "$REMOTE_HOST:$REMOTE_WEB_DIR/"

echo "设置文件权限..."
"${SSH_CMD[@]}" "$REMOTE_HOST" "find '$REMOTE_WEB_DIR' -maxdepth 1 -type f \( -name '*.html' -o -name '*.png' -o -name '*.webp' -o -name '*.jpg' \) -exec chmod 644 {} +"

echo "✓ 测试 nginx 与静态资源部署完成"
echo "访问地址: https://test.starcat.ink"
echo "================================"
