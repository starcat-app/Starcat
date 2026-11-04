# Starcat Skills

本目录是 Starcat 项目沉淀的 Agent Skills **单一事实源**：所有 skill 只在这里维护，
通过软链安装到各 agent 工具的用户级全局 skills 目录，不在工具目录里留副本。

## 安装与卸载

```bash
./install-skills.sh                       # 安装到默认目标：claude、codex、agents
./install-skills.sh --all                 # 追加 cursor、gemini、opencode
./install-skills.sh --target claude,codex # 只安装到指定目标
./install-skills.sh --list                # 预览可安装的 skill 与目标

./uninstall-skills.sh                     # 删除所有目标里指向本目录的软链
./uninstall-skills.sh --list              # 预览将被删除的软链
```

- 安装方式是 **绝对路径软链**（`ln -sfn`），本目录 git pull / 编辑后各工具立即生效。
- 卸载只删指向本目录的软链，不碰工具目录里任何真目录、真文件和其它来源的软链。
- 两个脚本自动发现「根目录含 `SKILL.md`」的子目录，新增 skill 放进本目录即可被发现。
- `apple-skills/`、`macos-app-skills/` 两个参考库在 `.claude/skills/`，不随本脚本安装。

## Skill 一览

### 发版与发布

| Skill                       | 作用                                                                                                                                             |
|-----------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| `starcat-release`           | 主 App 双渠道发版：App Store archive、Direct DMG、Sparkle appcast、notarization、官网与 changelog 部署的入口选择与执行                           |
| `starcat-release-readiness` | 发版准备与审计：dev 整改、main 发布、迁移收口、测试/构建/签名/公证、全工作区版本文档同步与人工验收门禁；默认只读                                 |
| `starcat-backend-release`   | `supports/starcat-*-api` 独立后端仓库（sharing / trending / weekly / wiki / recommend / discovery）的 tag、PR、GitHub Actions 与 Fly.io 发布链路 |
| `starcat-cli-release`       | `supports/starcat-cli` 与 Homebrew Formula 联动发版：Go 发布门禁、版本 tag、多平台产物与 attestations 验证                                       |

### supports 支撑项目

| Skill                            | 作用                                                                                                                        |
|----------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| `starcat-support-project-create` | 在 `supports/` 下创建独立支撑项目（API、CLI、扩展、tap、文档、网站），补齐开源治理文件、双语 README、营销区块并完成中央登记 |
| `starcat-supports-ops`           | 自建 Go API 后端运维：本地服务启停、Fly.io secrets / 状态 / 健康检查、`/data` 卷备份恢复、生产 API key 写入                 |
| `starcat-public-site-and-promo`  | starcat.ink 官网部署（nginx 配置上传、静态资源同步）、官网 changelog 生成、supports 各项目 README 推广区块同步              |

### 内容与本地化

| Skill                        | 作用                                                                                                                                               |
|------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| `starcat-update-changelog`   | 读取主仓库全部 git commit，为 `supports/starcat-site` 的 appstore/ 与 direct/ 四份 Changelog 生成中英文分类 release notes                                                                  |
| `starcat-changelog-cdn-sync` | 以 `CHANGELOG-ZH.md` 为唯一编辑源，截图转 WebP 经 PicList 上传 CDN，并把图片与条目改动同步到四份更新日志                                           |
| `starcat-localization-sync`  | 本地化生产与同步：`Localizable.xcstrings` 与 `supports/starcat-localization` 的 xcloc 双向同步、AI 初稿、翻译审批、18 语言审计；仅在明确要求时使用 |
| `starcat-weekly-import`      | 从新闻 / 清单等批量文本联网甄别真实 GitHub 仓库，核验 `owner/repo` 并经用户确认后，通过 weekly-api 批量写入受控人工来源（默认 `ai_intelligence`）  |

### 通用工作流

| Skill                    | 作用                                                                                                                                                             |
|--------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `github-issue-lifecycle` | 以 GitHub Issue 驱动代码变更的完整生命周期（建 Issue → 开发 → 审查 → 验收 → 关闭），并把已配置仓库的 Issue 自动同步到 GitHub Project 看板；远端操作仅用 `gh` CLI |

## 新增 skill 约定

- 遵守根 `AGENTS.md`：skill 一律用 **中文**编写（`SKILL.md`、`references/`、示例与步骤），技术字面量保持原文。
- 目录结构：`SKILL.md`（必需，放根目录）+ 按需的 `references/`、`scripts/`、`agents/`、`assets/`。
- 新 skill 放进本目录后运行 `./install-skills.sh` 即完成分发。
