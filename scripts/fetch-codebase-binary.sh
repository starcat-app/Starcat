#!/usr/bin/env bash
# fetch-codebase-binary.sh
# ========================
# 从 GitHub releases 下载 codebase-memory-mcp darwin-arm64 二进制，
# SHA-256 强校验，解压 → 重命名 → chmod → 写入 Starcat/Resources/Codebase/。
#
# 用法:
#   ./scripts/fetch-codebase-binary.sh                    # 拉当前受控版本
#   ./scripts/fetch-codebase-binary.sh v0.9.0             # 拉指定版本
#
# 要求:
#   - curl / python3 / shasum / tar / 标准 macOS 环境即可
#   - 不需要 Homebrew / Xcode / npm
#
# 上游更新流程（dong4j）:
#   - 默认版本必须与 Bundle 内二进制保持一致；升级时先完成隔离兼容性验证，
#     再同步更新默认版本与 SHA-256，避免“latest”在不同时间下载到不同产物
#   - 跑完复核 CODEBASE-INTEGRATION.md（自动写入）
#   - git add Starcat/Resources/Codebase/ && git commit
set -euo pipefail

# ── 参数 ──────────────────────────────────────────────
VERSION="${1:-v0.8.1}"
PINNED_ARCHIVE_SHA256="131f7de0a9691974a656502443f86c7c29cb89e62ddc43c9553134a5075b52fb"
PINNED_BINARY_SHA256="caf388141eeca0236a3f548c62c3e54a7c36933c730864c0e260abaeea69179b"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$PROJECT_ROOT/Starcat/Resources/Codebase"
WORK_DIR="$(mktemp -d /tmp/codebase-fetch.XXXXXX)"
REPO="DeusData/codebase-memory-mcp"
ASSET="codebase-memory-mcp-ui-darwin-arm64.tar.gz"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> fetch-codebase-binary.sh"
echo "    target dir: $TARGET_DIR"

DOWNLOAD_BASE="https://github.com/$REPO/releases/download/$VERSION"

# ── 2. 下载 tarball + checksums ──
cd "$WORK_DIR"
echo "==> downloading $ASSET ($VERSION)..."
curl -fsSL -o "$ASSET" "$DOWNLOAD_BASE/$ASSET"
echo "==> downloading checksums.txt..."
curl -fsSL -o checksums.txt "$DOWNLOAD_BASE/checksums.txt"

# ── 3. SHA-256 强校验（失败立即退出） ──
echo "==> verifying SHA-256..."
EXPECTED=$(grep "$ASSET" checksums.txt | awk '{print $1}')
if [ -z "$EXPECTED" ]; then
    echo "ERROR: $ASSET not found in checksums.txt"
    exit 1
fi
if [ "$VERSION" = "v0.8.1" ]; then
    # 归档与解压后文件分别校验，不能把二进制哈希拿来检查 tarball。
    if [ "$EXPECTED" != "$PINNED_ARCHIVE_SHA256" ]; then
        echo "ERROR: release checksum differs from the pinned archive checksum"
        exit 1
    fi
fi
ACTUAL=$(shasum -a 256 "$ASSET" | awk '{print $1}')
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "ERROR: SHA-256 mismatch!"
    echo "  expected: $EXPECTED"
    echo "  actual:   $ACTUAL"
    exit 1
fi
echo "    SHA-256 ok: $ACTUAL"

# ── 4. 解压 + 重命名 + 权限 ──
echo "==> extracting..."
tar -xzf "$ASSET"
# UI variant 解压后名字可能是 codebase-memory-mcp-ui 或 codebase-memory-mcp
if [ -f "codebase-memory-mcp-ui" ]; then
    BIN_NAME="codebase-memory-mcp-ui"
elif [ -f "codebase-memory-mcp" ]; then
    BIN_NAME="codebase-memory-mcp"
else
    echo "ERROR: codebase-memory-mcp binary not found after extraction"
    ls -la "$WORK_DIR"
    exit 1
fi
mv "$BIN_NAME" codebase.bin
chmod 0755 codebase.bin
echo "    binary size: $(stat -f%z codebase.bin) bytes"
BINARY_SHA=$(shasum -a 256 codebase.bin | awk '{print $1}')
if [ "$VERSION" = "v0.8.1" ] && [ "$BINARY_SHA" != "$PINNED_BINARY_SHA256" ]; then
    echo "ERROR: extracted binary differs from the pinned binary checksum"
    exit 1
fi
BINARY_VERSION="$(./codebase.bin --version)"
if [ "$BINARY_VERSION" != "codebase-memory-mcp ${VERSION#v}" ]; then
    echo "ERROR: extracted binary version does not match $VERSION: $BINARY_VERSION"
    exit 1
fi

# ── 5. 拷贝到 Bundle 资源目录 ──
echo "==> installing to $TARGET_DIR..."
mkdir -p "$TARGET_DIR"
cp codebase.bin "$TARGET_DIR/codebase.bin"
chmod 0755 "$TARGET_DIR/codebase.bin"

# ── 6. 写入 CODEBASE-INTEGRATION.md（自动生成，每次覆盖） ──
FINAL_SHA=$(shasum -a 256 "$TARGET_DIR/codebase.bin" | awk '{print $1}')
cat > "$TARGET_DIR/CODEBASE-INTEGRATION.md" << EOF
# CodebaseMemory Integration

- 上游: https://github.com/DeusData/codebase-memory-mcp
- 许可: MIT License © DeusData
- 版本: $VERSION
- 归档: \`$ASSET\`
- 归档 SHA-256: \`$ACTUAL\`
- 二进制 SHA-256: \`$FINAL_SHA\`
- 重新生成: \`./scripts/fetch-codebase-binary.sh $VERSION\`
- 上次更新: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo ""
echo "✅ Done."
echo "   版本:   $VERSION"
echo "   路径:   $TARGET_DIR/codebase.bin"
echo "   大小:   $(stat -f%z "$TARGET_DIR/codebase.bin") bytes"
echo "   SHA-256: $FINAL_SHA"
echo ""
echo "   下一步: make build-appstore"
