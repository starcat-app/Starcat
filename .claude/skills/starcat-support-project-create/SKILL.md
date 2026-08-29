---
name: starcat-support-project-create
description: 创建并登记 Starcat supports 独立支撑项目的完整流程。用于用户要在 supports/ 下新增 API、CLI、Launcher、浏览器扩展、Homebrew tap、文档、网站或其他独立仓库，并要求补齐开源治理文件、中英文 README、Starcat 营销区块、GitHub 模板/Actions、clone-all.sh、sync-starcat-readme-promo.py 和 supports 跨项目文档的场景。
---

# Starcat 支撑项目创建

使用这个 skill 在 `supports/` 下创建独立项目，并完成开源治理、双语 README、Starcat
生态营销和主仓库中央登记。它不负责凭空决定业务架构；项目类型差异见
`references/project-types.md`。

## 硬性规则

- 始终使用中文说明；代码、命令、路径、YAML key 和错误日志保持原文。
- 先说明项目名、类型、可见性、技术栈、外部副作用和验收标准，获得 dong4j 明确
  确认后再创建目录、GitHub 仓库、remote、分支或推送。
- `supports/<project>` 是独立 Git 仓库，不能加入 Starcat 主仓库；分别管理新项目
  与 Starcat 主仓库的提交。
- 默认公开项目使用 MIT License。私有项目、非 MIT 项目或包含第三方素材时先确认
  许可证，不套用公开自部署文案。
- 不覆盖已有文件。脚手架发现冲突必须停止，让用户决定合并方式。
- 不把 secrets、`.env`、私有 URL、token 或客户数据写入 README、模板或 Git。
- 创建 GitHub 组织仓库、设置 visibility、推送分支和配置 secrets 都是外部副作用，
  必须在当前对话中得到明确授权。
- 保留其它独立仓库的 dirty files；营销同步脚本会遍历多个仓库，运行前后都要检查
  实际 diff。

## 开工输入

至少明确：

- 仓库名与本地目录；
- 项目类型：API、CLI、Launcher、Browser Extension、Homebrew、Docs、Site 或 Other；
- Public / Private；
- 英文标题、中文标题；
- 英文一句话摘要、中文一句话摘要；
- 技术栈、CI 命令、是否发布二进制/容器/商店包；
- 是否需要 GitHub Release、Dependabot、隐私声明或 Fly.io 运维。

信息会实质改变仓库内容时不要猜测。公开项目默认值可以是
`starcat-app/<project>`、`main` 默认分支、MIT License，但仍需在方案中写明。

## 标准工作流

1. 读取：
   - `references/open-source-baseline.md`
   - `references/project-types.md`
   - `references/registration-map.md`
2. 检查 Starcat 主仓库和目标目录状态，确认目标没有被主仓库跟踪：

```bash
git status --short
git check-ignore -v supports/<project>
test ! -e supports/<project>
```

3. 使用脚手架先 dry-run：

```bash
python3 .claude/skills/starcat-support-project-create/scripts/scaffold.py \
  --target supports/<project> \
  --name <project> \
  --title-en "<English title>" \
  --title-zh "<中文标题>" \
  --summary-en "<English summary>" \
  --summary-zh "<中文摘要>" \
  --dry-run
```

4. 确认输出后去掉 `--dry-run`，生成通用开源基线。
5. 按项目类型补充代码、项目级 `.gitignore`、CI、Release/Audit、Dependabot、
   `THIRD_PARTY_NOTICES.md` 或 `PRIVACY.md`；不要复制错误技术栈的 workflow。
6. 初始化独立 Git 仓库。只有得到外部操作授权后，才创建
   `starcat-app/<project>`、配置 remote、推送 `main`/`dev`。
7. 按 `references/registration-map.md` 同步中央登记。
8. 在 `supports/scripts/sync-starcat-readme-promo.py` 注册项目后运行营销同步，
   确认 `README.md` 和 `README-ZH.md` 都包含完整 marker 区块。
9. 分别验证新项目和 Starcat 主仓库；分别报告两个 Git 边界的 diff、测试和待提交
   内容。

## README 与营销规则

- `README.md` 必须是完整英文说明，`README-ZH.md` 必须是完整中文说明；禁止只复制
  同一种语言。
- 两份 README 都要有项目用途、安装/开发、贡献、安全、支持和 License 入口。
- Starcat 营销内容的单一来源是：

```text
supports/scripts/sync-starcat-readme-promo.py
```

- 项目必须登记 `Project(path, title, kind, zh_title, zh_summary, en_summary)`，再由脚本
  插入或替换：

```html
<!-- starcat-promo:start -->
...
<!-- starcat-promo:end -->
```

- 图片继续引用 `starcat-app/starcat-pro` 的公开 `banner.webp` 和 `main.webp`，不要在
  新项目复制营销图片。
- 真实脚本名是 `sync-starcat-readme-promo.py`，不是
  `sync-starcat-readme-prpmo.sh`。

## 中央登记

每个新的 GitHub 独立项目至少同步：

- `supports/clone-all.sh`
- `supports/scripts/sync-starcat-readme-promo.py`
- `supports/README.md`
- `supports/SYNC.md`
- 必要时同步 `supports/AGENTS.md`

API、扩展或新分发类型还要同步对应运维入口和类型文档。完整映射见
`references/registration-map.md`。

本次创建项目时不要修改 `docs/功能实现总览.md`。若确实需要登记产品进度，先给出
拟写内容，等待 dong4j 明确说可以同步总览。

## 验证标准

通用验证：

```bash
git diff --check
bash -n supports/clone-all.sh
python3 -m py_compile supports/scripts/sync-starcat-readme-promo.py
```

新项目还必须：

- 脚手架模板占位符全部消失；
- 中英文 README 都有 `starcat-promo` 起止 marker；
- README 中项目摘要语义一致，但不是机械同语种复制；
- `LICENSE`、治理文件、Issue/PR 模板存在；
- CI 与实际技术栈一致并通过；
- `git check-ignore` 证明父仓库不会吸收独立项目文件；
- `clone-all.sh` URL、项目说明和 supports 文档数量一致；
- 公开仓库 URL、Security Advisory、support 链接不含旧 owner 或私有地址。

不要把“本地目录已生成”“GitHub 仓库已创建”或“README 已有标题”单独报告为完整
创建成功。
