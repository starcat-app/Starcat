---
name: starcat-public-site-and-promo
description: Starcat 官网部署与推广内容同步流程。用于用户要部署 starcat-site 静态官网、上传 nginx 配置、生成官网 changelog 页面、同步 supports 各项目 README 的 starcat-promo 区块、检查 starcat.ink 页面发布、或询问 supports/starcat-site/direct/deploy.sh、supports/starcat-site/direct/generate-changelog.py、supports/scripts/sync-starcat-readme-promo.py 如何使用的场景。
---

# Starcat 官网与推广同步

使用这个 skill 处理 `supports/starcat-site/` 官网部署、nginx 配置发布、官网 changelog 生成，以及 supports 各项目 README 推广区块同步。

## 硬性规则

- 先说明会改本地文件还是远程服务器，等确认后再执行。
- `supports/starcat-site/direct/deploy.sh` 会通过 `ssh`/`rsync` 修改 `aliyun2` 服务器，属于生产副作用。
- `supports/starcat-site/direct/deploy.sh` 会依次上传 nginx 配置、reload nginx 并同步静态资源，必须确认完整副作用。
- `sync-starcat-readme-promo.py` 会批量改 supports 多个 README，执行前先说明影响范围。
- 不要复制公开图片到各项目；推广区块统一引用 `starcat-pro` 的远程图片。

## 入口选择

| 任务 | 使用入口 |
|---|---|
| 部署 Direct 官网与 nginx | `cd supports/starcat-site/direct && ./deploy.sh` |
| 部署 Direct 测试站与 nginx | `cd supports/starcat-site/direct-test && ./deploy.sh` |
| 生成官网 changelog 页面 | `python3 supports/starcat-site/direct/generate-changelog.py` |
| 同步 README 推广区块 | `supports/scripts/sync-starcat-readme-promo.py` |
| Direct 发布时全链路官网/appcast | 使用 `starcat-release` skill 的 `release-direct.sh` |

## 标准工作流

1. 读取 `references/site-promo-map.md`。
2. 只读检查：
   - `git status --short`
   - `ls supports/starcat-site`
   - `test -f supports/starcat-site/direct/starcat.ink.conf`
   - 需要远程操作时先确认 `~/.ssh/config` 有 `aliyun2`。
3. 对本地生成类任务先执行并检查 diff。
4. 对远程部署类任务先说明命令、远程目录和可验证 URL。
5. 等确认后执行。
6. 验证：
   - 官网：`https://starcat.ink`
   - changelog：`https://starcat.ink/changelog.html`
   - nginx：`ssh aliyun2 "nginx -t"` 或脚本内校验结果。

## 参考

详细命令、排除规则、README marker 和失败恢复见 `references/site-promo-map.md`。
