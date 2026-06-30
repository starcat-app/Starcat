#!/bin/bash
# ============================================================================
# Starcat 落地页部署脚本
#
# 用法:
#   ./deploy.sh          上传 pages/ 目录下所有静态资源到 aliyun:/var/www/starcat/
#   ./deploy.sh -n       上传 nginx 配置并重载 nginx
#
# 前置条件:
#   - ~/.ssh/config 中已配置 aliyun 别名
#   - 远程服务器已创建 /var/www/starcat 目录
#   - 远程服务器已创建 /etc/nginx/encrypt/starcat/ 目录（证书）
# ============================================================================

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REMOTE_HOST="aliyun"
REMOTE_WEB_DIR="/var/www/starcat"
REMOTE_NGINX_DIR="/etc/nginx/conf.d"
NGINX_CONF="$SCRIPT_DIR/starcat.ink.conf"

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
        "$NGINX_CONF" \
        "$REMOTE_HOST:$REMOTE_NGINX_DIR/"

    echo "检查 nginx 配置语法并重载..."
    ssh "$REMOTE_HOST" "nginx -t && systemctl reload nginx"

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
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_WEB_DIR"

# rsync 同步 pages/ 目录下的静态文件
# --delete: 删除远程多余文件，保持完全一致
echo "正在同步文件..."
rsync -avz --delete --progress \
    --exclude '.DS_Store' \
    --exclude '*.log' \
    --exclude 'node_modules' \
    --exclude '_local-admin/' \
    --exclude 'deploy.sh' \
    --exclude 'starcat.ink.conf' \
    "$SCRIPT_DIR/" \
    "$REMOTE_HOST:$REMOTE_WEB_DIR/"

echo "设置文件权限..."
ssh "$REMOTE_HOST" "chmod 644 $REMOTE_WEB_DIR/*.html $REMOTE_WEB_DIR/*.png $REMOTE_WEB_DIR/*.webp $REMOTE_WEB_DIR/*.jpg 2>/dev/null; true"

echo "✓ 静态资源部署完成"
echo "访问地址: https://starcat.ink"
echo "================================"
