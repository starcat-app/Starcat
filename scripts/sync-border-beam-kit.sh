#!/usr/bin/env bash
# 从 Jakubantalik/Libraries 同步 BorderBeamKit 到 ThirdParty/BorderBeamKit。
#
# 为什么需要脚本：上游 Package.swift 不在仓库根，SPM 无法直接 URL 依赖；
# Starcat 用本地 path 包验证效果，升级时只同步固定子目录，避免拉整个 monorepo。
#
# 用法：
#   scripts/sync-border-beam-kit.sh              # 同步 main 最新
#   scripts/sync-border-beam-kit.sh <commit>     # 同步指定 commit
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/ThirdParty/BorderBeamKit"
REPO_URL="https://github.com/Jakubantalik/Libraries.git"
# main 分支路径；旧 tag 1.4.0 曾在 ports/ios/BorderBeamKit。
PACKAGE_SUBPATH="packages/border-beam/ports/ios/BorderBeamKit"
REF="${1:-main}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/border-beam-kit.XXXXXX")"
cleanup() {
  /bin/rm -rf "${TMP}"
}
trap cleanup EXIT

echo "→ cloning ${REPO_URL} @ ${REF}"
git clone --filter=blob:none --sparse "${REPO_URL}" "${TMP}/repo"
cd "${TMP}/repo"
git checkout "${REF}"
git sparse-checkout set "${PACKAGE_SUBPATH}"
COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"

if [[ ! -f "${PACKAGE_SUBPATH}/Package.swift" ]]; then
  echo "error: ${PACKAGE_SUBPATH}/Package.swift not found at ${REF}" >&2
  exit 1
fi

echo "→ syncing into ${DEST}"
mkdir -p "${DEST}"
rsync -a --delete \
  --exclude '.git' \
  --exclude 'VENDOR.md' \
  --exclude 'LICENSE' \
  "${PACKAGE_SUBPATH}/" "${DEST}/"

# LICENSE 在 npm 包根，不在 iOS port 目录内；单独拉取保证致谢合规。
curl -fsSL "https://raw.githubusercontent.com/Jakubantalik/Libraries/${COMMIT}/packages/border-beam/LICENSE" \
  -o "${DEST}/LICENSE" \
  || curl -fsSL "https://raw.githubusercontent.com/Jakubantalik/Libraries/${COMMIT}/LICENSE" \
  -o "${DEST}/LICENSE"

cat > "${DEST}/VENDOR.md" <<EOF
Upstream: https://github.com/Jakubantalik/Libraries
Path: ${PACKAGE_SUBPATH}
Commit: ${COMMIT}
Synced: $(date -u +%Y-%m-%d)
License: MIT (see LICENSE)
Sync: scripts/sync-border-beam-kit.sh
EOF

echo "✓ BorderBeamKit synced @ ${SHORT} (${COMMIT})"
