# Git 提交规范

本文规定 Starcat 的 Git commit message 格式。目标是让提交历史可读、可检索，并能被脚本稳定转换为面向用户的更新日志。

## 1. 强制格式

除自动生成的 merge commit 外，所有提交必须使用以下格式：

```text
<type>(<scope>): <中文摘要>
```

示例：

```text
feat(rag): 支持知识库会话置顶
improve(rag): 优化引用弹层首帧加载体验
fix(rag): 修复切换仓库后旧提示残留
perf(rag): 降低大知识库向量扫描耗时
docs(release): 补充双渠道发布检查清单
test(rag): 覆盖显式仓库范围回归
build(appstore): 校验内嵌可执行文件签名
```

格式中的冒号必须使用半角 `:`，冒号后保留一个空格。

## 2. type 与更新日志映射

| type | 用途 | 更新日志分类 |
|---|---|---|
| `feat` | 新增用户可感知的能力 | New / 新增 |
| `improve` | 改进已有能力或交互体验 | Improved / 优化 |
| `perf` | 可感知的性能改进 | Improved / 优化 |
| `fix` | 修复用户可感知的问题 | Fixed / 修复 |
| `refactor` | 不改变外部行为的重构 | 默认排除 |
| `docs` | 文档修改 | 默认排除 |
| `test` | 测试新增或调整 | 默认排除 |
| `build` | 构建、签名或依赖调整 | 默认排除 |
| `ci` | CI/CD 调整 | 默认排除 |
| `chore` | 日常维护任务 | 默认排除 |
| `style` | 不影响行为的格式调整 | 默认排除 |
| `revert` | 回滚已有提交 | 人工确认 |

`feat`、`improve`、`perf`、`fix` 是更新日志脚本的默认输入。类型必须与实际语义一致，禁止用 `feat` 描述问题修复，也禁止为了进入更新日志而伪造类型。

## 3. scope 规则

`scope` 必填，用来标识本次变更所属的功能或发布模块：

- 使用小写英文和 kebab-case，例如 `rag`、`ai-usage`、`smart-collections`。
- 优先使用稳定的产品域，而不是文件名、类名或临时任务编号。
- 发布渠道使用 `release-appstore`、`release-direct`；构建目标使用 `appstore`、`direct`。
- 跨模块变更可使用最主要的用户入口；只有确实无法归属时才使用 `app`。
- 一个提交涉及多个互不相关的 scope，说明提交应继续拆分。

常用 scope：

```text
rag
ai
ai-usage
home
explore
weekly
auth
subscription
browser-companion
mcp
release
release-appstore
release-direct
```

## 4. 摘要规则

- 使用中文描述结果，技术名词、路径和配置 key 保留原文。
- 写清楚动作和对象，例如“修复切换仓库后旧提示残留”，不要只写“修复问题”。
- 建议不超过 50 个字符，硬上限为 72 个字符。
- 结尾不加句号、感叹号或其他标点。
- 不写任务过程、测试通过情况、文件数量或 Agent 身份。
- 一个提交只表达一个主题，避免使用“以及其他优化”“若干修复”等模糊表述。

## 5. 正文与 Footer

简单提交可以只有标题。复杂提交应在标题后空一行，再补充正文，解释“为什么修改、用户影响、关键约束”，不要逐行复述代码。

```text
fix(rag): 修复账户切换后旧检索任务写入新会话

- 账户切换时取消旧任务，并在持久化前再次校验 accountID
- 避免旧回调污染新账户数据库
```

更新日志脚本支持以下可选 Footer：

```text
Release-Note: skip
```

用于排除虽然属于 `feat`、`improve`、`perf` 或 `fix`，但完全不应出现在用户更新日志中的内部变更。不得用它隐藏真实的用户可感知变化。

需要为更新日志提供比标题更合适的用户文案时，可以使用：

```text
Release-Note: 支持在多个仓库之间进行带引用的知识库问答
```

脚本应优先使用非空的 `Release-Note` 文案；没有 Footer 时再使用提交标题。`Release-Note` 仍需经过版本发布时的人工归并和中英文审阅。

## 6. Breaking Change

存在不兼容变更时，在 type/scope 后添加 `!`，并在 Footer 说明迁移影响：

```text
feat(rag)!: 调整知识库索引格式

BREAKING CHANGE: 旧索引需要执行一次重建
```

已发布数据库 schema 的变更仍必须遵守项目 migration 规则，不能用 Breaking Change 声明替代数据库迁移。

## 7. 拆分原则

- 功能实现、测试和文档可以放在同一提交，前提是它们共同服务同一个用户结果。
- 两个可独立回滚的功能必须拆成两个提交。
- 机械格式化、依赖升级和业务行为修改必须拆开。
- 修复 bug 时，提交标题描述修复后的用户结果，不写排查过程。
- merge commit 沿用 Git 自动生成格式，不手工伪造普通提交格式。

## 8. 禁止示例

```text
功能：新增 RAG
修复：修复问题
feat(starcat): 修复 RAG 问题
优化代码
feat(rag): 新增会话置顶并修复登录且更新文档
chore: update
```

问题分别是：使用了非标准 type、缺少 scope、type 与语义不符、描述不具体、混合多个主题，以及无法供脚本可靠分类。

## 9. 提交前自检

```text
[ ] 格式是 <type>(<scope>): <中文摘要>
[ ] type 与实际变化一致
[ ] scope 是稳定的产品域或发布模块
[ ] 摘要具体、单一且不超过 72 个字符
[ ] 用户可感知变化使用 feat / improve / perf / fix
[ ] 内部变更使用正确的排除类型或 Release-Note: skip
[ ] Breaking Change 已说明迁移影响
```
