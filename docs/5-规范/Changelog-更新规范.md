# Starcat Changelog 更新规范

> 适用范围：所有会修改 Starcat 代码库真实文件的任务，以及正式发版流程。
> 核心原则：日常按任务维护 Markdown，正式发版时才生成 HTML；任何日常写入都必须经过 dong4j 明确授权。

---

## 1. 询问时机

完成任务后，只要实际修改了代码、文档、配置、脚本、测试、资源或其他真实文件，Agent 就必须主动询问 dong4j 是否同步更新 Changelog。

以下情况不需要询问：

- 仅讨论方案，没有修改文件。
- 仅进行只读排查、代码审查或状态检查，没有修改文件。
- 任务被阻塞或取消，最终没有产生文件改动。

询问应放在任务结果说明中，并明确本次改动是否适合写入当前待发布版本。例如：

> 本次已产生真实文件改动，是否将“优化 AI 分享创建流程”写入 `1.2.0-待发布` Changelog？

## 2. 授权边界

- 只有 dong4j 明确回复“更新日志”“记到 Changelog”“可以写”或同等意思后，才能修改 Changelog。
- 如果 dong4j 在任务开始时已经明确要求同步 Changelog，则该要求本身就是本次写入授权，无需完成后重复确认。
- “开干”“修改代码”“提交”只授权对应任务，不等同于授权修改 Changelog。
- 禁止因为任务完成、准备提交或准备发版而自行补写 Changelog。

## 3. 日常更新范围

获得授权后，日常任务只同步修改以下 4 份 Markdown：

- App Store 英文：`CHANGELOG.md`
- App Store 中文：`CHANGELOG-ZH.md`
- Direct 英文：`supports/starcat-pro/CHANGELOG.md`
- Direct 中文：`supports/starcat-pro/CHANGELOG-ZH.md`

日常更新必须遵守以下约束：

- 写入当前待发布版本，例如 `## 1.2.0-待发布`，不得提前把它标记为正式发布版本。
- 中英文内容语义保持一致；App Store 与 Direct 的公共功能保持同步，渠道专属内容只写入对应渠道。
- 只记录对用户有意义的结果，不记录实现过程、测试命令、文件数量或 Agent 工作说明。
- 不修改 `supports/starcat-site/direct/changelog.html` 或 `supports/starcat-site/direct/changelog-zh.html`。
- 不运行 `supports/starcat-site/direct/generate-changelog.py`，也不部署官网更新日志页。

## 4. 正式发版

只有 dong4j 明确要求正式发版或更新正式发布页面时，才执行以下工作：

1. 根据实际发布范围审计 4 份 Markdown，补漏、去重并复核中英文表述。
2. 将目标版本标题从“待发布”状态改为正式版本标题。
3. 运行 `python3 supports/starcat-site/direct/generate-changelog.py`，生成官网中英文更新日志页。
4. 检查 `supports/starcat-site/direct/changelog.html` 与 `supports/starcat-site/direct/changelog-zh.html` 只展示已正式发布的版本。
5. 是否部署官网仍以 dong4j 的明确指令为准，不得因生成 HTML 而自动执行部署。

## 5. 验证要求

- 使用 `rg` 检查 4 份 Markdown 的目标版本标题和条目是否同步。
- 日常任务确认两份 HTML 没有被修改；正式发版时确认两份 HTML 已由生成脚本同步更新。
- 分别在主仓库和 `supports/starcat-pro` 独立仓库执行 `git diff --check`。
- 保留工作区中与当前任务无关的改动，不得顺手整理或覆盖。
