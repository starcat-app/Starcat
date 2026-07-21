# 官网与推广同步地图

## 官网部署

静态资源部署：

```bash
cd pages && ./deploy.sh
```

行为：

- 确保远程 `/var/www/starcat` 存在；
- 使用 `rsync -avz --delete --progress` 同步 `pages/`；
- 排除 `.DS_Store`、`*.log`、`node_modules`、`_local-admin/`、`downloads/`、`deploy.sh`、`starcat.ink.conf`；
- 设置远程 HTML/图片文件权限；
- 访问地址为 `https://starcat.ink`。

nginx 配置部署：

```bash
cd pages && ./deploy.sh -n
```

行为：

- 上传 `pages/starcat.ink.conf` 到 `aliyun:/etc/nginx/conf.d/`；
- 远程执行 `nginx -t && systemctl reload nginx`。

前置条件：

- `~/.ssh/config` 中配置 `aliyun`；
- 远程已有 `/var/www/starcat`；
- 远程已有 `/etc/nginx/encrypt/starcat/` 证书目录。

## changelog 页面生成

```bash
python3 pages/generate-changelog.py
```

输入：

- `supports/starcat-pro/CHANGELOG.md`
- `supports/starcat-pro/CHANGELOG-ZH.md`

输出：

- `pages/changelog.html`
- `pages/changelog-zh.html`

脚本内置页面样式，目标是避免中英文页面样式漂移。

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
- `supports/starcat-pro`：作为推广图片与公开支持内容的单一来源，避免生成自引用区块。
- `supports/ai-file-wall`：仅供本地多 AI 协作，不属于 `starcat-app` 公开生态。

公开图片统一引用：

- `https://raw.githubusercontent.com/starcat-app/starcat-pro/main/banner.webp`
- `https://raw.githubusercontent.com/starcat-app/starcat-pro/main/main.webp`

## 验证

本地生成后：

```bash
git diff -- pages supports
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
| `aliyun` SSH 不通 | 停止；让用户检查 `~/.ssh/config` |
| nginx reload 失败 | 不继续静态部署；先修 `starcat.ink.conf` |
| rsync 删除了远程多余文件 | 这是 `--delete` 预期行为；执行前必须说明 |
| changelog 源文件不存在 | 检查 `supports/starcat-pro/CHANGELOG*.md` 是否存在 |
| README diff 过大 | 检查 marker 是否缺失或旧推广区块清理规则是否匹配过宽 |
