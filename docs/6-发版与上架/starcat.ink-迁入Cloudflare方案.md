# starcat.ink 迁入 Cloudflare 方案

> 状态: 调研中 | 2026-07-09
>
> **当前阶段**: 方案调研，未做决策。文档记录完整的迁移技术方案和中国大陆访问策略。
> **待决策**: §6 中的 A / B1 / B2 / B3 四种方案尚未选择。建议先收集国内用户占比数据后再定。

## 1. 现状：aliyun 完整链路

当前 `starcat.ink` 域名在腾讯云购买，DNS 指向 aliyun ECS，nginx 服务所有流量。

### 1.1 服务器上的文件

```
aliyun:/var/www/starcat/
├── index.html / index-zh.html          # 落地页
├── privacy.html / privacy-zh.html      # 隐私政策
├── eula.html / eula-zh.html            # 用户协议
├── changelog.html / changelog-zh.html  # 更新日志
├── appcast.xml                         # Sparkle 应用更新描述
├── starcat-logo.png                    # Logo
├── sc-*.webp × 12                      # 截图
└── downloads/                          # DMG 下载目录
    ├── Starcat-1.1.0-arm64.dmg         (~82 MB)
    ├── Starcat-1.1.0-arm64.dmg.sha256
    ├── Starcat-1.2.0-arm64.dmg
    └── ...
```

### 1.2 release-direct.sh 完整发布流程

```
Step 1. deploy_nginx
        ── rsync pages/direct/starcat.ink.conf → aliyun:/etc/nginx/conf.d/
        ── ssh aliyun "nginx -t && systemctl reload nginx"

Step 2. deploy_site
        ── python3 generate-changelog.py        (本地生成 changelog HTML)
        ── rsync pages/direct/* → aliyun:/var/www/starcat/  (全部静态文件)

Step 3. package_direct
        ── 本地 Xcode 构建 StarcatDirect.app
        ── create-dmg → Starcat-{version}-arm64.dmg
        ── shasum -a 256 → .dmg.sha256
        ── Sparkle generate_appcast → appcast-current.xml (仅当前版本)

Step 4. upload_direct_artifacts
        ── rsync DMG + SHA256 → aliyun:/var/www/starcat/downloads/

Step 5. merge_appcast
        ── python3 merge-appcast.py             (当前版本 appcast 合并入全量)
        ── rsync appcast.xml → aliyun:/var/www/starcat/

Step 6. verify_remote_urls
        ── curl https://starcat.ink/appcast.xml
        ── curl https://starcat.ink/downloads/Starcat-{version}-arm64.dmg
        ── curl https://starcat.ink/changelog.html
```

### 1.3 涉及的脚本和文件

| 文件 | 职责 | 改造成本 |
|------|------|---------|
| `scripts/release-direct.sh` | 发布编排主脚本 | 重构（去 nginx、改上传目标） |
| `pages/direct/deploy.sh` | 静态页 rsync 部署 | 重写为 wrangler pages deploy |
| `pages/direct/starcat.ink.conf` | nginx 配置 | **废弃** |
| `scripts/package-direct.sh` | 本地打包 DMG + appcast | 基本不变 |
| `scripts/merge-appcast.py` | appcast 增量合并 | 不变（纯本地操作） |
| `pages/direct/generate-changelog.py` | changelog 生成 | 不变（纯本地操作） |

---

## 2. 目标架构

```
starcat.ink (DNS @ Cloudflare)
│
├── /*.html, /*.webp, /*.png, /appcast.xml
│   ── Cloudflare Pages (starcat-direct)
│       部署: wrangler pages deploy pages/direct/
│
├── /downloads/*
│   ── Cloudflare R2 (bucket: starcat-downloads)
│       自定义域名绑定: starcat.ink/downloads/*
│       上传: wrangler r2 object put 或 aws s3 cp
│
└── SSL / CDN / DDoS
    ── Cloudflare 免费自带
```

### 2.1 为什么用 R2 而不是 Pages 放 DMG

Cloudflare Pages 单文件限制 25MB，DMG ~82MB 超过限制。R2 免费额度：
- 10 GB 存储
- 1000 万次 Class A 操作
- 1000 万次 Class B 操作
- 无出口流量费

### 2.2 域名规划

| 路径 | 服务 | 说明 |
|------|------|------|
| `starcat.ink/*` (HTML/CSS/图片/appcast) | Cloudflare Pages | `starcat-direct` 项目 |
| `starcat.ink/downloads/*` | Cloudflare R2 | DMG + SHA256 下载 |
| `dong4j.app/starcat/*` | Cloudflare Pages | `starcat-appstore` 项目（已部署） |

---

## 3. 改造步骤

### 3.1 域名迁入 (腾讯云 → Cloudflare)

1. Cloudflare Dashboard → Add site → `starcat.ink`
2. Cloudflare 自动扫描并导入现有 DNS 记录
3. 腾讯云改 NS 为 `carrera.ns.cloudflare.com` / `darl.ns.cloudflare.com`
4. 等待 DNS 传播（通常 2-24h，期间零停机）

### 3.2 创建 Cloudflare Pages 项目

```bash
# 创建 Pages 项目
npx wrangler pages project create starcat-direct --production-branch=main

# 绑定自定义域名
# Cloudflare Dashboard → starcat-direct → Custom domains → starcat.ink
```

### 3.3 创建 R2 Bucket

R2 是 Cloudflare 的对象存储（兼容 S3 API），用于托管超过 Pages 25MB 限制的 DMG 文件。

#### 3.3.1 创建 Bucket

```bash
# 确认 wrangler 版本 ≥ 4.x
npx wrangler --version

# 创建 bucket（名称全局唯一，建议加前缀防冲突）
npx wrangler r2 bucket create starcat-downloads

# 验证创建成功
npx wrangler r2 bucket list
npx wrangler r2 bucket info starcat-downloads
```

#### 3.3.2 配置公开访问

R2 bucket 默认私有。DMG 需要公开下载，必须绑定自定义域名才能对外暴露 HTTP 访问（R2 不支持直接通过 `*.r2.dev` 裸域名公开）：

**Dashboard 步骤：**

1. Cloudflare Dashboard → **R2** → 点击 `starcat-downloads` bucket
2. 进入 **Settings** 标签页
3. 找到 **Custom Domains** → 点击 **Connect Domain**
4. 选择域名 `starcat.ink`，路径填写 `downloads`
5. 生效后 `https://starcat.ink/downloads/Starcat-1.2.0-arm64.dmg` 即指向 R2 中的 `Starcat-1.2.0-arm64.dmg` 对象

> ⚠️ **绑定顺序约束**: 必须先完成 3.2（Pages 绑定 `starcat.ink` 根域名），才能在这里把 R2 挂到 `starcat.ink/downloads` 子路径。Cloudflare 要求父域名已存在且归属于当前 zone。

#### 3.3.3 验证 R2 公开访问

```bash
# 上传一个测试文件
echo "test" | npx wrangler r2 object put starcat-downloads/test.txt --pipe

# 确认 curl 可访问
curl -I https://starcat.ink/downloads/test.txt
# 预期: HTTP/2 200

# 清理
npx wrangler r2 object delete starcat-downloads/test.txt
```

#### 3.3.4 R2 上传命令参考

```bash
# 上传单个文件
npx wrangler r2 object put starcat-downloads/Starcat-1.2.0-arm64.dmg \
  --file ./dist/direct/downloads/Starcat-1.2.0-arm64.dmg

# 上传 SHA256
npx wrangler r2 object put starcat-downloads/Starcat-1.2.0-arm64.dmg.sha256 \
  --file ./dist/direct/downloads/Starcat-1.2.0-arm64.dmg.sha256

# 查看 bucket 中的文件列表
npx wrangler r2 object list starcat-downloads

# 删除旧版本（需要时）
npx wrangler r2 object delete starcat-downloads/Starcat-1.0.0-arm64.dmg
```

### 3.4 迁移历史 DMG 文件

```bash
# 从 aliyun 拉 DMG
rsync -avz aliyun:/var/www/starcat/downloads/ ./dist/direct/downloads/

# 批量上传到 R2
for f in ./dist/direct/downloads/*.dmg ./dist/direct/downloads/*.sha256; do
  npx wrangler r2 object put "starcat-downloads/$(basename "$f")" --file "$f"
done
```

### 3.5 重写 pages/direct/deploy.sh

```bash
#!/bin/bash
# pages/direct/deploy.sh — Cloudflare Pages 部署
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT="${CF_PAGES_PROJECT:-starcat-direct}"
BRANCH="${CF_PAGES_BRANCH:-main}"

cd "$SCRIPT_DIR"
npx wrangler pages deploy . \
  --project-name="$PROJECT" \
  --branch="$BRANCH" \
  --commit-dirty=true

echo "✓ https://starcat.ink"
```

### 3.6 重写 release-direct.sh

核心改动：

1. **删除** `deploy_nginx` — Cloudflare 自动 HTTPS/边缘缓存，不需要 nginx
2. **流程重排序** — 因为 Cloudflare Pages 是整体部署（非 rsync 增量），appcast 合并必须在 Pages 部署之前完成
3. **DMG 上传** `rsync → R2` — 使用 `wrangler r2 object put`
4. **去掉 ssh/rsync 依赖** — 完全无服务器运维

#### 3.6.1 新旧流程对比

```
旧流程 (aliyun rsync):              新流程 (Cloudflare Pages + R2):
─────────────────────               ─────────────────────────────
1. deploy_nginx   → rsync conf      1. package_direct  → 本地打包 DMG + 生成 appcast-current.xml
2. deploy_site    → rsync HTML      2. merge_appcast   → 合并 appcast (本地文件)
3. package_direct → 本地打包         3. upload_direct_artifacts → R2
4. upload_direct  → rsync DMG       4. deploy_site     → wrangler pages deploy (含 appcast.xml)
5. merge_appcast  → rsync appcast   5. verify_remote   → curl 校验
6. verify_remote  → curl 校验
```

#### 3.6.2 新版 release-direct.sh 完整代码

```bash
#!/usr/bin/env bash
#
# release-direct.sh — Starcat Direct 渠道一键发布 (Cloudflare 版)。
#
# 用法:
#   ./scripts/release-direct.sh <version>
#
# 流程:
#   1. 确认 main 分支 + 干净工作区
#   2. 创建 / 推送 git tag
#   3. 本地打包 DMG + 生成 appcast-current.xml  (package-direct.sh)
#   4. 合并 appcast → pages/direct/appcast.xml    (merge-appcast.py)
#   5. 上传 DMG + SHA256 → Cloudflare R2
#   6. 部署静态页 + appcast → Cloudflare Pages
#   7. curl 校验线上 URL
#
# 环境变量:
#   CLOUDFLARE_API_TOKEN                必需。Pages + R2 操作都需要。
#   STARCAT_NOTARIZE=1                  正式公开发布必须开启。
#   STARCAT_NOTARY_PROFILE              公证 Keychain profile 名。
#   STARCAT_R2_BUCKET                   R2 bucket 名。默认: starcat-downloads
#   STARCAT_PAGES_PROJECT               Pages 项目名。默认: starcat-direct
#   STARCAT_DOWNLOAD_BASE_URL           DMG 下载前缀。默认: https://starcat.ink/downloads/
#   其他跳过开关: STARCAT_RELEASE_SKIP_*  见 show_help()
# ============================================================================

set -euo pipefail

show_help() {
  cat <<'EOF'
Starcat Direct 一键发布 (Cloudflare 版)

用法:
  ./scripts/release-direct.sh <version>

默认流程:
  1. 确认 main 分支 + 干净工作区
  2. 创建 / 推送 git tag
  3. package-direct  → 本地打包 DMG + appcast-current.xml
  4. merge-appcast   → 合并 appcast (本地 pages/direct/appcast.xml)
  5. upload R2       → 上传 DMG + SHA256 到 Cloudflare R2
  6. deploy Pages    → wrangler pages deploy (含 appcast + 所有 HTML)
  7. curl 校验       → 确认线上 appcast / DMG / changelog 可访问

跳过开关:
  STARCAT_RELEASE_SKIP_TAG=1        跳过 tag 创建推送
  STARCAT_RELEASE_SKIP_SITE=1       跳过 Pages 部署
  STARCAT_RELEASE_SKIP_BRANCH_CHECK=1  跳过 main 分支检查
  STARCAT_RELEASE_SKIP_DIRTY_CHECK=1   跳过工作区干净检查
  STARCAT_RELEASE_DRY_RUN=1         演练模式
EOF
}

# ── 参数解析 ──────────────────────────────────────────────────────────────

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then show_help; exit 0; fi
VERSION="${1:-}"
[ -z "$VERSION" ] && { show_help >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "版本号必须是 X.Y.Z" >&2; exit 1; }

# ── 路径与默认值 ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAGES_DIR="${PROJECT_ROOT}/pages/direct"
DOWNLOADS_DIR="${PROJECT_ROOT}/dist/direct/downloads"

DMG_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
APPCAST_PATH="${PAGES_DIR}/appcast.xml"
CURRENT_APPCAST_PATH="${DOWNLOADS_DIR}/appcast-current.xml"

DRY_RUN="${STARCAT_RELEASE_DRY_RUN:-0}"
TAG_NAME="v${VERSION}"

R2_BUCKET="${STARCAT_R2_BUCKET:-starcat-downloads}"
PAGES_PROJECT="${STARCAT_PAGES_PROJECT:-starcat-direct}"
DOWNLOAD_BASE_URL="${STARCAT_DOWNLOAD_BASE_URL:-https://starcat.ink/downloads/}"
RELEASE_BRANCH="${STARCAT_RELEASE_BRANCH:-main}"
RELEASE_REMOTE="${STARCAT_RELEASE_REMOTE:-origin}"

# ── 工具函数 ──────────────────────────────────────────────────────────────

log()   { printf '[release-direct] %s\n' "$1"; }
fail()  { printf '[release-direct] ERROR: %s\n' "$1" >&2; exit 1; }
run_or_print() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[release-direct] DRY RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
require_command() { command -v "$1" >/dev/null 2>&1 || fail "$1 不在 PATH"; }

# ── Step 1: 分支与工作区检查 ───────────────────────────────────────────────

require_clean_worktree() {
  if [ "${STARCAT_RELEASE_SKIP_DIRTY_CHECK:-0}" = "1" ]; then log "跳过工作区检查"; return; fi
  [ -z "$(git status --porcelain)" ] || { git status --short >&2; fail "工作区不干净"; }
}

require_branch() {
  if [ "${STARCAT_RELEASE_SKIP_BRANCH_CHECK:-0}" = "1" ]; then log "跳过分支检查"; return; fi
  local b; b="$(git branch --show-current)"
  [ "$b" = "$RELEASE_BRANCH" ] || fail "当前分支 ${b}，需在 ${RELEASE_BRANCH}"
}

# ── Step 2: Tag ───────────────────────────────────────────────────────────

create_and_push_tag() {
  if [ "${STARCAT_RELEASE_SKIP_TAG:-0}" = "1" ]; then log "跳过 tag: ${TAG_NAME}"; return; fi
  if [ "${STARCAT_RELEASE_SKIP_FETCH:-0}" != "1" ]; then
    run_or_print git fetch "$RELEASE_REMOTE" --tags
  fi
  git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null \
    && fail "tag 已存在: ${TAG_NAME}，设 STARCAT_RELEASE_SKIP_TAG=1 跳过"
  log "创建 tag: ${TAG_NAME}"
  run_or_print git tag -a "$TAG_NAME" -m "Starcat ${VERSION}"
  log "推送 tag: ${RELEASE_REMOTE} ${TAG_NAME}"
  run_or_print git push "$RELEASE_REMOTE" "$TAG_NAME"
}

# ── Step 3: 打包 DMG ──────────────────────────────────────────────────────

package_direct() {
  log "本地打包并生成 appcast: ${VERSION}"
  run_or_print env \
    STARCAT_GENERATE_APPCAST=1 \
    STARCAT_DOWNLOAD_BASE_URL="$DOWNLOAD_BASE_URL" \
    "${SCRIPT_DIR}/package-direct.sh" "$VERSION"
}

verify_local_artifacts() {
  [ "$DRY_RUN" = "1" ] && return
  [ -f "$DMG_PATH" ]  || fail "未找到 DMG: $DMG_PATH"
  [ -f "$SHA_PATH" ]  || fail "未找到 SHA256: $SHA_PATH"
  [ -f "$CURRENT_APPCAST_PATH" ] || fail "未找到 appcast: $CURRENT_APPCAST_PATH"
  grep -q "Starcat-${VERSION}-arm64.dmg" "$CURRENT_APPCAST_PATH" \
    || fail "appcast 未指向 Starcat-${VERSION}-arm64.dmg"
}

# ── Step 4: 合并 appcast ──────────────────────────────────────────────────

merge_appcast() {
  [ "$DRY_RUN" = "1" ] && return
  log "增量合并 appcast → ${APPCAST_PATH}"
  python3 "${SCRIPT_DIR}/merge-appcast.py" \
    --base "$APPCAST_PATH" \
    --incoming "$CURRENT_APPCAST_PATH" \
    --output "$APPCAST_PATH"

  grep -q "Starcat-${VERSION}-arm64.dmg" "$APPCAST_PATH" \
    || fail "合并后 appcast 未指向 Starcat-${VERSION}-arm64.dmg"
  log "appcast 合并完成（本地文件，将随 Pages 一起部署）"
}

# ── Step 5: 上传 DMG 到 R2 ────────────────────────────────────────────────

upload_direct_artifacts() {
  log "上传 DMG 到 R2: ${R2_BUCKET}"
  local dmg_obj="Starcat-${VERSION}-arm64.dmg"
  local sha_obj="Starcat-${VERSION}-arm64.dmg.sha256"

  run_or_print npx wrangler r2 object put "${R2_BUCKET}/${dmg_obj}" \
    --file "$DMG_PATH"

  run_or_print npx wrangler r2 object put "${R2_BUCKET}/${sha_obj}" \
    --file "$SHA_PATH"

  log "DMG 上传完成: ${DOWNLOAD_BASE_URL%/}/${dmg_obj}"
}

# ── Step 6: 部署 Pages ────────────────────────────────────────────────────

deploy_site() {
  if [ "${STARCAT_RELEASE_SKIP_SITE:-0}" = "1" ]; then
    log "跳过 Pages 部署"
    return
  fi

  log "生成 changelog"
  run_or_print python3 "${PAGES_DIR}/generate-changelog.py"

  log "部署 Cloudflare Pages: ${PAGES_PROJECT}"
  cd "$PAGES_DIR"
  run_or_print npx wrangler pages deploy . \
    --project-name="$PAGES_PROJECT" \
    --branch=main \
    --commit-dirty=true

  log "Pages 部署完成: https://starcat.ink"
}

# ── Step 7: 线上校验 ──────────────────────────────────────────────────────

verify_remote_urls() {
  if [ "$DRY_RUN" = "1" ]; then log "DRY RUN 完成"; return; fi

  local appcast_url="https://starcat.ink/appcast.xml"
  local dmg_url="${DOWNLOAD_BASE_URL%/}/Starcat-${VERSION}-arm64.dmg"
  local changelog_url="https://starcat.ink/changelog.html"

  log "校验 appcast: $appcast_url"
  curl -fsSI "$appcast_url" >/dev/null || fail "appcast 不可访问"

  log "校验 DMG: $dmg_url"
  curl -fsSI "$dmg_url" >/dev/null || fail "DMG 不可访问"

  if [ "${STARCAT_RELEASE_SKIP_SITE:-0}" != "1" ]; then
    log "校验 changelog: $changelog_url"
    curl -fsSI "$changelog_url" >/dev/null || fail "changelog 不可访问"
  fi

  log "完成 ✓"
  log "  tag:      ${TAG_NAME}"
  log "  appcast:  $appcast_url"
  log "  dmg:      $dmg_url"
  log "  changelog:$changelog_url"
  log "  site:     https://starcat.ink"
}

# ── 主流程 ────────────────────────────────────────────────────────────────

main() {
  require_command git
  require_command python3
  require_command curl

  cd "$PROJECT_ROOT"

  require_branch
  require_clean_worktree

  if [ "${STARCAT_NOTARIZE:-0}" != "1" ] \
    && [ "${STARCAT_RELEASE_ALLOW_UNNOTARIZED:-0}" != "1" ] \
    && [ "$DRY_RUN" != "1" ]; then
    fail "正式发布需 STARCAT_NOTARIZE=1；临时验证设 STARCAT_RELEASE_ALLOW_UNNOTARIZED=1"
  fi

  create_and_push_tag
  package_direct
  verify_local_artifacts
  merge_appcast
  upload_direct_artifacts
  deploy_site
  verify_remote_urls
}

main
```

#### 3.6.3 关键变化说明

| 变化 | 原因 |
|------|------|
| `deploy_nginx` 删除 | Cloudflare 自动 HTTPS，不需要自己管 nginx |
| 流程重排序（打包→合并→R2上传→Pages部署→校验） | Pages 是整体部署；appcast.xml 必须先合并进 `pages/direct/`，再一次性部署 |
| `upload_direct_artifacts` 用 `wrangler r2 object put` | 不再 rsync 到 aliyun |
| `deploy_site` 用 `wrangler pages deploy` | 不再 rsync |
| 去掉 `ssh` / `rsync` 依赖 | 不再需要 SSH 到 aliyun |
| `STARCAT_RELEASE_HOST` / `_SSH_KEY` / `_WEB_DIR` 删除 | 无服务器 |
| 新增 `STARCAT_R2_BUCKET` / `STARCAT_PAGES_PROJECT` | R2 bucket 和 Pages 项目名可配 |

---

## 4. 风险点

### 4.1 历史 appcast 兼容性

当前 `appcast.xml` 中 DMG 的 enclosure URL 是 `https://starcat.ink/downloads/Starcat-x.x.x-arm64.dmg`。迁移后 URL 不变，旧版 Starcat 的 Sparkle 更新检查不受影响。

### 4.2 下载统计

aliyun 上可能有 nginx 日志做下载统计。R2 不做服务端日志；如需统计，可选：
- Cloudflare Web Analytics（免费，基础统计）
- 在 DMG 下载链接上加 Cloudflare Zaraz 埋点

### 4.3 R2 自定义域名子路径

R2 绑定 `starcat.ink/downloads` 子路径时，Cloudflare Dashboard 需要 Pages 先绑定 `starcat.ink` 根域名。配置顺序：
1. Pages 绑定 `starcat.ink`
2. R2 绑定 `starcat.ink/downloads`

### 4.4 DNS 切换窗口

腾讯云 NS → Cloudflare 期间，Cloudflare 会自动导入现有 DNS 记录，理论上零停机。建议在非发布窗口期操作。

---

## 5. 改动清单 (完整)

### 需要修改的文件

| 文件 | 改动 | 工作量 |
|------|------|--------|
| `scripts/release-direct.sh` | 去 nginx/ssh/rsync，重排流程，R2 上传 | 中 |
| `pages/direct/deploy.sh` | rsync → wrangler pages deploy | 小 |
| `pages/direct/starcat.ink.conf` | **删除** | — |

### 不动的文件

| 文件 | 原因 |
|------|------|
| `scripts/package-direct.sh` | 纯本地构建，不改 |
| `scripts/merge-appcast.py` | 纯本地合并，不改 |
| `pages/direct/generate-changelog.py` | 纯本地生成，不改 |
| `pages/direct/*.html` | 纯静态内容，不改 |
| `pages/direct/appcast.xml` | Sparkle 格式，URL 不变，不改 |

### 新增文件

| 文件 | 用途 |
|------|------|
| `docs/6-发版与上架/starcat.ink-迁入Cloudflare方案.md` | 本文档 |

---

## 6. 中国大陆访问策略（待决策）

> 本节为调研记录，尚未决定最终方案。

### 6.1 问题

Cloudflare 免费版在国内存在以下风险：

| 问题 | 表现 | 影响 |
|------|------|------|
| DNS 污染 | 部分运营商解析到错误 IP | 直接打不开 |
| SNI 阻断 | HTTPS 握手阶段被 reset | TLS 错误 |
| TCP 限速 | 能打开但速度极慢 | 几十 KB/s |
| 边缘节点缺失 | 回源走国际链路 | 高延迟 |

而当前 aliyun 大陆 ECS 国内访问稳定，是国内用户的主要入口。

### 6.2 硬约束

Cloudflare Pages 的自定义域名要求域名 DNS 在 Cloudflare 管理。这意味着：
- 如果把 `starcat.ink` 迁到 Cloudflare DNS，就不能再用腾讯云做地域分流
- 如果保留腾讯云 DNS，Pages 就无法绑定 `starcat.ink`

因此方案选择实质是：`starcat.ink` 的 DNS 放在哪、流量如何路由。

### 6.3 方案对比

#### 方案 A：全迁 Cloudflare（低复杂度，国内靠运气）

```
starcat.ink DNS → Cloudflare
  └── 全球统一: 橙云代理 → Pages + R2
```

- ✅ 零成本，最简单
- ✅ 海外体验最佳（CDN 加速）
- ⚠️ 国内可用性看人品，不稳定
- ⚠️ 如果国内用户占比大，风险较高

#### 方案 B1：Cloudflare Load Balancing（中等复杂度，效果好）

```
starcat.ink DNS → Cloudflare
  ├── 中国大陆 Origin Pool → aliyun IP（灰云直连）
  └── 海外 Origin Pool      → Cloudflare Pages
```

- ✅ 国内体验和现在一样好
- ✅ 海外走 CDN
- ❌ $5/月起（Cloudflare Load Balancing）
- ❌ 需要同时维护 aliyun + Cloudflare 两套基础设施

#### 方案 B2：分域名（中等复杂度，零成本）

```
starcat.ink  (腾讯云 DNS → aliyun)
  ── 国内用户主力入口，现状不变

starcat.app  (Cloudflare DNS → Pages + R2)
  ── 海外用户入口，新注册域名约 $12/年
```

- ✅ 国内零变化，零风险
- ✅ 海外走 Pages CDN
- ✅ 免费用
- ⚠️ 两个域名，品牌分裂感
- ⚠️ 需要额外注册维护一个域名

#### 方案 B3：先迁后补（低复杂度，渐进式，推荐调研首选）

```
阶段 1: starcat.ink → 全迁 Cloudflare
  ── aliyun 服务器先保留不销毁
  ── 观察 1-2 个月国内用户反馈

阶段 2a（无问题）: 阿里云退机
阶段 2b（有问题）: 两种回退手段——
  A) Cloudflare DNS A 记录改灰云 → 瞬间回退 aliyun
  B) 升级到方案 B1（Load Balancing）
```

- ✅ 启动成本最低
- ✅ aliyun 作为回退兜底
- ✅ 有数据后再决策，不盲目
- ⚠️ 观察期内可能需要回滚

### 6.4 决策因素

需要确认以下问题后再做选择：

| 因素 | 问题 | 重要性 |
|------|------|--------|
| 国内用户占比 | Starcat 用户中大陆开发者多吗？ | 高 |
| Sparkle 更新 | 国内用户下载 DMG 更新会不会断？ | 高 |
| Creem 支付 | 支付页在国内能开吗？（已经走 fly.dev） | 中 |
| 维护意愿 | 愿意同时维护 aliyun + Cloudflare 吗？ | 中 |

---

## 7. 暂不迁移

- `starcat-license-api.fly.dev`（Creem 结账 API）— 独立服务，不走 starcat.ink
- `starcat-backend` (starcat-backend.fly.dev) — 独立服务，不走 starcat.ink
