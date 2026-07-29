# Starcat 支撑项目中央登记地图

## 独立 Git 边界

新项目目录位于 `supports/<project>` 或 `supports/extensions/<project>`，自身包含
`.git/`。Starcat 主仓库通过根 `.gitignore` 的 `supports/*` /
`supports/extensions/starcat-*` 忽略这些工作树。

验证：

```bash
git check-ignore -v supports/<project>
git -C supports/<project> status --short --branch
git status --short
```

不要使用 `git add -f` 把新项目加入 Starcat 主仓库。

## `supports/clone-all.sh`

同步三个位置：

1. 文件头的项目分类说明；
2. `--help` 输出中的项目名和说明；
3. `PROJECTS` 数组：

```text
"<dir>|https://github.com/starcat-app/<repo>.git|<中文说明>"
```

`TOTAL` 由数组长度计算，不要手写。修改后运行：

```bash
bash -n supports/clone-all.sh
supports/clone-all.sh --help
```

不要为验证真实执行全量 clone/pull。

## README 营销登记

真实脚本：

```text
supports/scripts/sync-starcat-readme-promo.py
```

向 `PROJECTS` 增加 `Project(...)`，包含：

- 相对 `path`；
- 英文 `title`；
- `kind`；
- `zh_title`；
- `zh_summary`；
- `en_summary`。

脚本没有 dry-run，会重写清单中多个独立仓库的 README。运行前记录每个目标仓库的
`git status`；运行后逐仓库检查 diff，不吸收既有 dirty files。验证新项目两份
README 都有且只有一对 `starcat-promo` marker。

## 主仓库文档

每个 GitHub 独立项目同步：

- `supports/README.md`：总数、分类表、GitHub URL、用途和独立仓库数量；
- `supports/SYNC.md`：独立仓库数量、清单、clone 流程和决策记录；
- `supports/AGENTS.md`：只有类型、架构、运行或跨项目规则变化时更新；
- `supports/CLAUDE.md`：只有硬性协作/技术栈/部署规则变化时更新。

高层目录结构发生变化时再同步根 `AGENTS.md` / `CLAUDE.md`。不要为普通新项目修改
`docs/功能实现总览.md`。

## 类型专属登记

| 类型 | 额外中央文件 |
|---|---|
| Go API | `supports/start-all.sh`、`supports/Makefile`、Fly scripts/docs、API 总览 |
| Browser Extension | `supports/extensions/AGENTS.md`、`supports/extensions/CLAUDE.md`、发布文档 |
| Homebrew | 对应上游 Release skill、安装文档和 Audit Action |
| CLI/Launcher | 相关集成设计、发布 Skill、安装入口 |
| Docs/Site | `supports/README.md` 与官网/文档单一来源说明 |

## GitHub 组织仓库

创建 `starcat-app/<repo>` 前再次确认：

- repository name；
- Public / Private；
- description、topics、homepage；
- default branch；
- 是否启用 Issues、Discussions、Security Advisories；
- 需要的 Actions secrets 和最小 token 权限。

创建和推送后从 GitHub 远端验证默认分支、visibility、Actions 和 community health，
不能只看本地 remote。
