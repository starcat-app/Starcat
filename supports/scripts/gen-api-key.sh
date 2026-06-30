#!/usr/bin/env bash
# ============================================================================
# gen-api-key.sh — Starcat 后端 API Key 一键生成脚本
# ============================================================================
#
# 用途：
#   生成符合 Starcat R-01 鉴权规范的 API Key,格式：
#     sk-starcat-<32 字符 base32 大写>
#   总长度：43 字符
#
# 适用范围：
#   Starcat 自建后端服务（starcat-trending-api / starcat-weekly-api /
#   starcat-sharing-api / starcat-wiki-api / starcat-discovery-api /
#   starcat-recommend-api）的 `.env`
#   文件 / fly secrets 中 `API_KEYS` 变量的值。
#
# 用法：
#   bash supports/scripts/gen-api-key.sh                # 生成 1 个 key
#   bash supports/scripts/gen-api-key.sh 3              # 生成 3 个 key（用逗号连接）
#   bash supports/scripts/gen-api-key.sh 2 --env        # 生成 2 个并直接组装成 API_KEYS=... 行
#
# 设计要点（详见 supports/docs/R-01-总体设计.md §3.4.3）：
#   - 固定前缀 `sk-starcat-`：与 OpenAI / Anthropic 等业界 AI key 风格一致,方便识别
#   - 随机部分 32 字符 base32 大写（[A-Z2-7]）：
#       * 信息熵：32 × log2(32) = 160 bit,远超 UUID v4 的 122 bit
#       * 不含易混字符（0/O/1/I 都不在 base32 字母表）
#       * 不含特殊字符,可双击复制 / URL / Header 都安全
#   - 依赖 python3（macOS 12+ / 几乎所有 Linux 都内置）调用 secrets + base64.b32encode,
#     避免 macOS 没有原生 `base32` 命令的兼容问题
#
# 依赖：
#   - python3（macOS 12+ 自带 / Linux 自带）
#
# 安全提醒：
#   - 生成的 key **不要** 提交到 git
#   - 本地开发：写到各 API 项目的 `.env`（已在 .gitignore）
#   - 生产环境：用 `fly secrets set API_KEYS="..."` 设置
#
# ============================================================================

set -euo pipefail

# ─── 参数解析 ────────────────────────────────────────────────────────────────
COUNT="${1:-1}"
EMIT_ENV_LINE=false
if [[ "${2:-}" == "--env" ]]; then
    EMIT_ENV_LINE=true
fi

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
    echo "Error: count must be a positive integer" >&2
    echo "Usage: $0 [count] [--env]" >&2
    exit 1
fi

# ─── 函数：生成单个 API Key ─────────────────────────────────────────────────
# base32 部分长度：32 字符。
# 用 python3 secrets.token_bytes(20) 生成 20 字节强随机 → base64.b32encode 编码 → 32 字符。
# 选 python3 而非 macOS `base32`：macOS 不带原生 base32 命令，python3 跨平台稳定。
PY3_CMD="$(command -v python3 || true)"
if [[ -z "$PY3_CMD" ]]; then
    echo "Error: python3 not found. Install python3 first (macOS: 'brew install python', Linux: 'apt install python3')." >&2
    exit 2
fi

generate_one_key() {
    local random_part
    random_part="$("$PY3_CMD" -c "
import secrets, base64
print(base64.b32encode(secrets.token_bytes(20)).decode('ascii').rstrip('=').upper())
")"
    # 兜底校验长度
    if [[ "${#random_part}" -ne 32 ]]; then
        echo "Error: generated random part length is ${#random_part}, expected 32" >&2
        exit 2
    fi
    echo "sk-starcat-${random_part}"
}

# ─── 主流程 ──────────────────────────────────────────────────────────────────
KEYS=()
for ((i = 0; i < COUNT; i++)); do
    KEYS+=("$(generate_one_key)")
done

# IFS join 数组为逗号分隔
joined="$(IFS=','; echo "${KEYS[*]}")"

if [[ "$EMIT_ENV_LINE" == "true" ]]; then
    # 直接输出可粘到 .env 文件的整行
    echo "API_KEYS=${joined}"
else
    # 默认逐行输出（每行一个 key,便于挑选 / 复制）
    for k in "${KEYS[@]}"; do
        echo "$k"
    done
    # 多个 key 时额外给一行逗号拼接的快捷格式
    if [[ "$COUNT" -gt 1 ]]; then
        echo ""
        echo "# Joined (for API_KEYS= line):"
        echo "$joined"
    fi
fi
