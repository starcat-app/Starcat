# 官网与推广同步地图

## 官网部署

静态资源部署：

```bash
cd supports/starcat-site/direct && ./deploy.sh
```

行为：

- 确保远程 `/var/www/starcat` 存在；
- 使用 `rsync -avz --delete --progress` 同步 `supports/starcat-site/direct/`；
- 排除 `.DS_Store`、`*.log`、`node_modules`、`downloads/`、`appcast.xml`、部署脚本、生成器和 `starcat.ink.conf`；
- 设置远程 HTML/图片文件权限；
- 访问地址为 `https://starcat.ink`。
- 同一个部署脚本还会上传 `supports/starcat-site/direct/starcat.ink.conf` 到 `aliyun2:/etc/nginx/conf.d/`，并远程执行 `nginx -t && systemctl reload nginx`。

前置条件：

- `~/.ssh/config` 中配置 `aliyun2`；
- 远程已有 `/var/www/starcat`；
- 远程已有 `/etc/nginx/encrypt/starcat/` 证书目录。

## changelog 页面生成

```bash
python3 supports/starcat-site/direct/generate-changelog.py
```

输入：

- `supports/starcat-site/direct/CHANGELOG.md`
- `supports/starcat-site/direct/CHANGELOG-ZH.md`

输出：

- `supports/starcat-site/direct/changelog.html`
- `supports/starcat-site/direct/changelog-zh.html`

脚本内置页面样式，目标是避免中英文页面样式漂移。

### 已发布 Beta 的日志补发

Beta 发布授权包含官网双语更新日志。输入必须是构建时固定的快照；
工作稿可能含 `2.0.0-待发布` 等未来版本，不能直接拿来生成公开页面。
从 Starcat 主仓库运行，版本参数替换为本次已经发布的 Beta：

```bash
python3 scripts/release_changelog.py check \
  --source-root dist/direct-development/downloads/release-notes-X.Y.Z-beta.N \
  --version X.Y.Z-beta.N
python3 supports/starcat-site/direct/generate-changelog.py \
  --source-root dist/direct-development/downloads/release-notes-X.Y.Z-beta.N
rsync -avz --progress \
  supports/starcat-site/direct/changelog.html \
  supports/starcat-site/direct/changelog-zh.html \
  aliyun2:/var/www/starcat/
ssh aliyun2 "chmod 644 /var/www/starcat/changelog.html /var/www/starcat/changelog-zh.html"
```

上传前检查两页目标标题为 `X.Y.Z Beta N`、无未来版本和待发布内容；上传后分别
下载两页，与本地 HTML 逐字节比对。此次只写两份 HTML，不使用 `--delete`，
不重载 nginx，也不更改默认稳定版下载、正式 feed 或 App Store 页面。
完成后提交生成页，并按发布收尾约定同步各仓 `dev/main`。

## Direct 下载与支持页的定向修复

双语下载共用 `direct/downloads.js`，同时读取正式 `appcast.xml` 和开发
`appcast-development.xml`。默认按钮保持最新正式版，可选开发入口随 feed 更新；
GitHub URL 中的 tag 才是完整身份，不能只展示 `shortVersionString` 而漏掉
`beta.N` / `dev.N`，也不能把开发 feed 里的稳定版标为 Beta。

修改后从 Starcat 主仓库执行：

```bash
node --test supports/starcat-site/tests/direct-downloads.test.mjs
python3 -m unittest scripts/tests/test_direct_downloads.py scripts/tests/test_direct_release_resume.py
```

下载修复只同步 `index.html`、`index-zh.html`、`downloads.js`；支持页修复按
实际 diff 追加 `support/`、首页链接与 sitemap。上传使用已核实的服务器连接与
`/var/www/starcat` 目录，精确列出文件、不用 `--delete`，随后只对目标文件设
`644` 权限。不运行全站生成器或 `deploy.sh`，避免夹带并行 Changelog 工作稿。
已有可信主机连接参数可沿用；SSH alias 缺失时先核实既有配置和 known_hosts，
不得关闭 host key 校验。

部署后执行：

```bash
python3 scripts/verify-direct-downloads.py --version X.Y.Z-beta.N
curl -fsSI https://starcat.ink/downloads.js
curl -fsSI https://starcat.ink/support
curl -fsSL https://starcat.ink/support/
curl -fsSL https://starcat.ink/support/zh.html
```

正式版 `--version` 使用 `X.Y.Z`。核验器检查双语挂载点、线上共享脚本逐字节
一致、双 feed 最新版本与 GitHub tag/附件/大小一致；再跟随重定向验证两种
渠道的实际 DMG 可访问。模块须以 JavaScript MIME 返回。下载展示的自动化
验收应执行已部署脚本和真实双语 HTML/feed 的 DOM 渲染，检查默认稳定、
开发入口及历史 Beta/Dev；不得把数据核验报告为人工浏览器验收。

支持页检查 `/support` → `/support/` 的规范化、两种正文、语言切换与 CSS，
确认不是首页兜底的假成功；下载修复同时回归两种语言首页的支持链接。
定向静态修复不改 feed、双语日志或 nginx，部署前后可用摘要比对确认。

## README 推广区块同步

```bash
supports/scripts/sync-starcat-readme-promo.py
```

行为：

- 在目标 README 一级标题后插入或替换 `starcat-promo` marker 区块；
- 为缺少中文说明的项目补充 `README-ZH.md`；
- 清理 `homebrew-starcat` 旧本地图片头图与重复 Starcat 介绍。

marker：

```markdown
<!-- starcat-promo:start -->
...
<!-- starcat-promo:end -->
```

覆盖项目包括：

- `supports/starcat-docs`
- `supports/starcat-site`
- `supports/homebrew-starcat`
- `supports/homebrew-starcat-cli`
- `supports/starcat-cli`
- `supports/starcat-skill`
- Chrome/Safari 浏览器插件
- `starcat-discovery-api`
- `starcat-license-api`
- `starcat-recommend-api`
- `starcat-sharing-api`
- `starcat-trending-api`
- `starcat-weekly-api`
- `starcat-wiki-api`
- `supports/starcat-localization`

明确排除：

- `supports/.github`：组织主页使用信息密度更高的专属双语介绍，不插入通用区块。
- `supports/starcat-site`：推广图片（`assets/`）与两渠道 Changelog 的单一来源，自身也是生成目标，避免生成自引用区块。
- `supports/ai-file-wall`：仅供本地多 AI 协作，不属于 `starcat-app` 公开生态。

公开图片统一引用：

- `https://raw.githubusercontent.com/starcat-app/starcat-site/main/assets/banner.webp`
- `https://raw.githubusercontent.com/starcat-app/starcat-site/main/assets/main.webp`

## 验证

本地生成后：

```bash
git diff -- supports/scripts/sync-starcat-readme-promo.py
git -C supports/starcat-site diff
git -C supports/starcat-docs diff
```

远程部署后：

```bash
curl -fsSI https://starcat.ink
curl -fsSI https://starcat.ink/changelog.html
curl -fsSI https://starcat.ink/changelog-zh.html
```

## 失败恢复

| 问题 | 处理 |
|---|---|
| `aliyun2` SSH 不通 | 检查现有 SSH 配置；可使用当前任务已核实的可信连接参数恢复，不关闭 host key 校验；缺少可信参数再向用户确认 |
| nginx reload 失败 | 不继续静态部署；先修 `starcat.ink.conf` |
| rsync 删除了远程多余文件 | 这是 `--delete` 预期行为；执行前必须说明 |
| changelog 源文件不存在 | 检查 `supports/starcat-site/direct/CHANGELOG*.md` 是否存在 |
| README diff 过大 | 检查 marker 是否缺失或旧推广区块清理规则是否匹配过宽 |
