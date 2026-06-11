#!/usr/bin/env bash

rm "$HOME/Library/Containers/com.starcat.app/Data/Library/Application Support/com.starcat.app/starcat.sqlite"* && \
rm "$HOME/Library/Application Support/com.starcat.app/starcat.sqlite"* 2>/dev/null; \
echo "✅ 已删除（重启 Starcat 后会按 v1-initial 重新一次性建库）"