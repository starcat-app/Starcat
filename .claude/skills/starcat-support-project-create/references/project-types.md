# Starcat 支撑项目类型

## 类型选择

| 类型 | 参考项目 | 额外要求 |
|---|---|---|
| Go API | `starcat-sharing-api`、`starcat-discovery-api` | Go CI、Docker、Fly、`.env.example`、健康检查；按存储接入 backup/restore/wipe |
| CLI | `starcat-cli` | 多平台 CI/Release、checksums、attestations、安装脚本、`THIRD_PARTY_NOTICES.md` |
| Launcher | `starcat-alfred-workflow` | 宿主清单、图标、平台包、Release workflow、宿主安装验证 |
| Browser Extension | `extensions/starcat-chrome-plugin` | `PRIVACY.md`、权限说明、商店发布文档、浏览器构建/测试 |
| Homebrew | `homebrew-starcat*` | Formula/Cask、`brew style`、strict audit、版本化 URL 与真实 SHA256 |
| Agent Skill | `starcat-skill` | `SKILL.md`、Agent 元数据、skill validator、README 双语 |
| Docs | `starcat-docs` | 文档构建/链接检查、编辑与发布说明 |
| Site | `starcat-site` | 站点构建、部署边界、公开法律和安全页面 |
| Other | 最接近的公开项目 | 明确 CI、发布物、安全边界后再选择模板 |

## Go API 额外登记

新增 Go API 时不能只创建仓库，还要同步：

- `supports/AGENTS.md` 和 `supports/CLAUDE.md` 的项目、端口、存储与 Fly app；
- `supports/start-all.sh` 和 `supports/Makefile`；
- Fly status/health/secrets 脚本；
- 有状态服务的 backup/restore/wipe；
- `supports/docs/fly-io-环境变量.md` 和相关总体设计；
- Starcat 客户端真实调用契约。

端口、持久化卷和生产 always-on 策略必须由用户确认，不能从最后一个数字自动猜测。

## 分发项目额外登记

CLI、Launcher、Extension 或 Homebrew 项目必须明确：

- 版本来源；
- stable 与 prerelease 规则；
- tag 是否签名；
- Release 资产清单；
- checksums 与 provenance；
- 安装入口和回滚/patch 规则；
- 是否需要联动另一个分发仓库。

## Private 项目

Private 项目仍可使用治理文件，但：

- README 不得宣传为可自部署公共 API；
- clone 和权限说明要标记私有；
- `sync-starcat-readme-promo.py` 使用符合真实边界的 `kind` 和摘要；
- 不把私有仓库加入公开生态链接，除非用户明确要求。
