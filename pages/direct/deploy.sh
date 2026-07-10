#!/bin/bash
# ============================================================================
# Starcat 落地页部署脚本
#
# 用法:
#   ./deploy.sh          上传 pages/direct/ 目录下所有静态资源到 aliyun:/var/www/starcat/
#   ./deploy.sh -n       上传 nginx 配置并重载 nginx
#   DEPLOY_SSH_KEY=~/.ssh/server ./deploy.sh
#                       使用指定私钥连接远程服务器，避免本机 ssh alias 绑定到错误 key
#
# 前置条件:
#   - ~/.ssh/config 中已配置 aliyun 别名
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

# ============================================================
# -n: 上传 Nginx 配置并重载
# ============================================================
if [ "${1:-}" = "-n" ]; then
    echo "================================"
    echo "部署 Nginx 配置: starcat.ink.conf"
    echo "远程服务器: $REMOTE_HOST"
    echo "远程目录:   $REMOTE_NGINX_DIR"
    echo "================================"

    if [ ! -f "$NGINX_CONF" ]; then
        echo "错误: 找不到 Nginx 配置文件: $NGINX_CONF"
        exit 1
    fi

    echo "上传配置文件..."
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

    echo "✓ Nginx 配置已部署并重载完成"
    echo "================================"
    exit 0
fi

# ============================================================
# 默认: 上传静态资源
# ============================================================
echo "================================"
echo "部署 Starcat 落地页静态资源"
echo "本地目录: $SCRIPT_DIR"
echo "远程服务器: $REMOTE_HOST"
echo "远程目录:   $REMOTE_WEB_DIR"
echo "================================"

# 确保远程目录存在
"${SSH_CMD[@]}" "$REMOTE_HOST" "mkdir -p $REMOTE_WEB_DIR"

# rsync 同步 pages/direct/ 目录下的静态文件
# --delete: 删除远程多余文件，保持完全一致
echo "正在同步文件..."
rsync -avz --delete --progress \
    -e "$RSYNC_SSH" \
    --exclude '.DS_Store' \
    --exclude '*.log' \
    --exclude 'node_modules' \
    --exclude 'starcat.ink.conf' \
    "$SCRIPT_DIR/" \
    "$REMOTE_HOST:$REMOTE_WEB_DIR/"

echo "设置文件权限..."
"${SSH_CMD[@]}" "$REMOTE_HOST" "find '$REMOTE_WEB_DIR' -maxdepth 1 -type f \( -name '*.html' -o -name '*.png' -o -name '*.webp' -o -name '*.jpg' \) -exec chmod 644 {} +"

echo "✓ 静态资源部署完成"
echo "访问地址: https://starcat.ink"
echo "================================"
