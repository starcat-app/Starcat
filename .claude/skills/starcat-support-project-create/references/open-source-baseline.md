# Starcat 支撑项目开源基线

## 必备文件

| 文件 | 要求 |
|---|---|
| `README.md` | 完整英文项目说明，包含中文入口和 Starcat 营销区块 |
| `README-ZH.md` | 完整中文项目说明，包含英文入口和 Starcat 营销区块 |
| `LICENSE` | 默认 MIT；版权年份和持有人必须真实 |
| `CODE_OF_CONDUCT.md` | 贡献者行为准则和私下举报入口 |
| `CONTRIBUTING.md` | 开发、测试、PR、生成文件和安全要求 |
| `SECURITY.md` | GitHub Security Advisory 私密披露方式和安全边界 |
| `SUPPORT.md` | 仓库 Issue 与 Starcat 产品支持的分流 |
| `CHANGELOG.md` | 至少包含 `Unreleased`；可发布项目必须维护版本记录 |
| `.gitignore` | 覆盖本技术栈构建产物、`.env`、本地数据库和 IDE 文件 |
| `.github/PULL_REQUEST_TEMPLATE.md` | 测试、文档、安全与 Changelog 检查 |
| `.github/ISSUE_TEMPLATE/bug_report.yml` | 复现、环境、版本和脱敏提醒 |
| `.github/ISSUE_TEMPLATE/feature_request.yml` | 问题、方案和替代方案 |
| `.github/ISSUE_TEMPLATE/config.yml` | Security Advisory 和产品支持入口 |

## 按条件增加

| 条件 | 文件 |
|---|---|
| 使用受 Dependabot 支持的包管理器 | `.github/dependabot.yml` |
| 有可执行测试或构建 | `.github/workflows/ci.yml` 或项目约定名称 |
| 发布二进制/Workflow/扩展包 | `.github/workflows/release.yml`、`RELEASING.md` |
| Homebrew tap | Audit workflow，Formula/Cask style 与 strict audit |
| 分发二进制或 vendored 内容 | `THIRD_PARTY_NOTICES.md` |
| 浏览器扩展或处理用户数据 | `PRIVACY.md` 和商店发布说明 |
| Go API / 容器服务 | `Dockerfile`、`.dockerignore`、`.env.example`、部署与健康检查 |
| Fly.io 服务 | `fly.toml`、secrets 文档、状态/健康与持久化运维入口 |

## README 结构

项目自身内容至少覆盖：

1. 项目是什么，以及与 Starcat 的关系；
2. 安装或本地开发；
3. 配置与安全边界；
4. 测试和构建；
5. 贡献、安全、支持和 License 链接。

Starcat 产品推广区块不要写进模板的固定正文。项目登记到
`supports/scripts/sync-starcat-readme-promo.py` 后，由该脚本在一级标题后生成
统一内容。

## 定制要求

- 所有 `{{...}}` 占位符必须替换。
- `CONTRIBUTING.md` 的命令必须能在真实项目运行。
- `SECURITY.md` 要描述项目真实凭据、网络、更新或数据边界，不能保留泛化假话。
- `SUPPORT.md` 的仓库链接必须指向新项目，产品支持统一指向 `starcat-pro`。
- `config.yml` 的 Security Advisory URL 必须指向新仓库。
- LICENSE 不得因“统一模板”覆盖第三方许可证要求。
