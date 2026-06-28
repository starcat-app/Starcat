#!/usr/bin/env bash
# fetch-codebase-binary.sh
# ========================
# 从 GitHub releases 下载 codebase-memory-mcp darwin-arm64 二进制，
# SHA-256 强校验，解压 → 重命名 → chmod → 写入 Starcat/Resources/Codebase/。
#
# 用法:
#   ./scripts/fetch-codebase-binary.sh                    # 拉 latest
#   ./scripts/fetch-codebase-binary.sh v0.9.0             # 拉指定版本
#
# 要求:
#   - curl / python3 / shasum / tar / 标准 macOS 环境即可
#   - 不需要 Homebrew / Xcode / npm
#
# 上游更新流程（dong4j）:
#   - 本脚本不硬编码版本号，不传参数默认拉 latest
#   - 跑完复核 STARCAT-INTEGRATION.md（自动写入）
#   - git add Starcat/Resources/Codebase/ && git commit
set -euo pipefail

# ── 参数 ──────────────────────────────────────────────
VERSION="${1:-latest}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$PROJECT_ROOT/Starcat/Resources/Codebase"
WORK_DIR="$(mktemp -d /tmp/codebase-fetch.XXXXXX)"
REPO="DeusData/codebase-memory-mcp"
ASSET="codebase-memory-mcp-darwin-arm64.tar.gz"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> fetch-codebase-binary.sh"
echo "    target dir: $TARGET_DIR"

# ── 1. 解析版本号（latest → 调 GitHub API 拿 tag_name） ──
if [ "$VERSION" = "latest" ]; then
    echo "==> resolving latest release tag..."
    API_URL="https://api.github.com/repos/$REPO/releases/latest"
    VERSION=$(curl -fsSL "$API_URL" | python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'])")
    echo "    resolved: $VERSION"
fi

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
if [ ! -f "codebase-memory-mcp" ]; then
    echo "ERROR: codebase-memory-mcp binary not found after extraction"
    ls -la "$WORK_DIR"
    exit 1
fi
mv codebase-memory-mcp codebase
chmod 0755 codebase
echo "    binary size: $(stat -f%z codebase) bytes"

# ── 5. 拷贝到 Bundle 资源目录 ──
echo "==> installing to $TARGET_DIR..."
mkdir -p "$TARGET_DIR"
cp codebase "$TARGET_DIR/codebase"
chmod 0755 "$TARGET_DIR/codebase"

# ── 6. 写入 / 更新 UPSTREAM-README.md（如果不存在） ──
if [ ! -f "$TARGET_DIR/UPSTREAM-README.md" ]; then
    echo "    writing UPSTREAM-README.md (first time)..."
    cat > "$TARGET_DIR/UPSTREAM-README.md" << 'UPEOF'
# CodebaseMemory 上游 Provenance

本目录的 `codebase` 二进制由 Starcat 从
[DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)
打包进 App。

---

## 许可

MIT License © DeusData

---

## 重命名说明

上游二进制名 `codebase-memory-mcp` → Starcat 内统一改名为 `codebase`：
- 短名，避免和"项目代码库(codebase)"语义混淆
- 与 `starcat` / `starcat-mcp-stdio` 等其他 Starcat 自有二进制风格一致 — 不加文件扩展名

---

## 完整性验证

每次重新生成时用 `scripts/fetch-codebase-binary.sh` 自动执行：
1. 从 GitHub releases 下载 tarball + checksums.txt
2. sha256sum -c --strict 校验
3. 解压 → 重命名 → chmod

---

## 已知约束

- 不调用 update 子命令 — 版本升级跟随 Starcat App Store 更新
- 不下载任何外部二进制到运行时环境
- CBM_CACHE_DIR 重定向到 sandbox container 内
UPEOF
fi

# ── 7. 写入 STARCAT-INTEGRATION.md（自动生成，每次覆盖） ──
FINAL_SHA=$(shasum -a 256 "$TARGET_DIR/codebase" | awk '{print $1}')
cat > "$TARGET_DIR/STARCAT-INTEGRATION.md" << EOF
# CodebaseMemory Integration

- 上游: https://github.com/DeusData/codebase-memory-mcp
- 版本: $VERSION
- 二进制 SHA-256: \`$FINAL_SHA\`
- 重新生成: \`./scripts/fetch-codebase-binary.sh\`
- 上次更新: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo ""
echo "✅ Done."
echo "   版本:   $VERSION"
echo "   路径:   $TARGET_DIR/codebase"
echo "   大小:   $(stat -f%z "$TARGET_DIR/codebase") bytes"
echo "   SHA-256: $FINAL_SHA"
echo ""
echo "   下一步: xcodegen generate && xcodebuild -scheme Starcat build"
