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

### 3.1 与 App 内「更新说明」窗口的关系

- Help → 更新说明（What's New）**只读取主仓库** bundle 内的 `CHANGELOG.md` / `CHANGELOG-ZH.md`（构建脚本拷贝进 App）。
- `supports/starcat-pro/` 下两份供 Direct 渠道与官网生成脚本使用，**不进** App 内窗口；公共功能条目仍须与 App Store 两份语义一致。
- 因此主仓库两份 Markdown 的结构与条目写法，优先照顾 App 内扫读；官网 HTML 由同一 Markdown 生成，不另维护第二套文案。

## 4. 结构与条目写法（App 更新说明友好）

> 自本规范更新起，**新写入**的待发布条目必须遵守本节。
> 已发布历史版本（如 `1.1.0`、`1.0.0`）不必回溯改写；当前 `*-待发布` 若仍是旧句式，须在 dong4j 授权改 Changelog 时按本节整理。

### 4.1 版本与分区结构

保持 Keep a Changelog 风格，层级固定：

```markdown
## 1.2.0-待发布

可选：一两句版本引导（放在第一个 ### 之前）。

### 新增

- 短标题：用户能懂的说明。

### 优化

- …

### 修复

- …
```

英文分区标题与中文固定对应（勿自造变体，App 靠标题映射图标）：

| 中文 | 英文 | 用途 |
|------|------|------|
| `### 新增` | `### New` | 新能力 |
| `### 优化` | `### Improvements` | 体验 / 性能改进 |
| `### 修复` | `### Fixes` | 缺陷修复 |
| `### 亮点` | `### Highlights` | 仅大版本开篇摘要等少数场景 |

不要使用 `### 其他改进`、`### Changed`、`### Bug Fixes` 等未在上表的标题。

### 4.2 条目模板（强制）

每条一行：

```markdown
- 短标题：一句说明，不写实现细节、文件名或测试过程。
- Short title: One-sentence user-facing detail.
```

分隔符约定（强制）：

| 语言 | 分隔符 | 说明 |
|------|--------|------|
| 中文 | `：`（全角冒号） | 标题与说明之间无额外空格，如 `短标题：说明` |
| 英文 | `: `（半角冒号 + 空格） | 必须带尾随空格；不要写成 `title:detail` |

App 解析器仍兼容历史 ` — ` / ` – `，**新写入与整理待发布条目时一律用冒号**，不要再写 em dash。

约束：

1. **短标题在前**：中文约 4–16 字；英文为简短名词短语（一般 ≤ 6 个词）。
2. **用上表冒号分开短标题与说明**，不要依赖第一个逗号来拆标题——逗号拆分不稳定，App 窗口扫读会变差。
3. **说明大约一两行**：一条只写一件用户可感知的事；细节过多就拆成两条或删掉非用户信息。
4. **禁止在 bullet 再写分类动词**：不要以「新增 / 优化 / 修复 / 支持」或 `Added` / `Improved` / `Fixed` / `Changed` 开头——`###` 分区已经表达类别。
   - ❌ `- 新增 Manage 仓库置顶，支持 Pin…`
   - ✅ `- Manage 仓库置顶：支持 Pin / Unpin，按最近置顶优先，卡片显示置顶标识。`
5. **中英文语义对齐**，但语序可按语言习惯调整；两侧都要用「短标题 + 冒号 + 说明」结构。

### 4.3 示例

中文：

```markdown
### 新增

- Manage 仓库置顶：支持 Pin / Unpin，按最近置顶优先排列，卡片左上角显示置顶标识。
- 仓库分享链接：点击后在 Starcat 中打开并定位到对应仓库。

### 优化

- 添加标签弹出层：彩色图标行与选中态更清晰，背景与主窗口一致。

### 修复

- 知识库入口：修复偶发无响应、最小化无法恢复，以及索引未就绪时误进空库引导的问题。
```

英文：

```markdown
### New

- Repository pinning in Manage: Pin / Unpin, most-recently-pinned ordering, and a card-corner indicator.
- Repository share links: Open Starcat and locate the shared repository.

### Improvements

- Add-tag popover: Clearer colored-icon rows and selection, with a solid window-matched background.

### Fixes

- Knowledge Base entry: Fixes occasional no-response, minimized-window restore, and opening empty-library setup before index status finishes loading.
```

### 4.4 写入前自检

授权改 Changelog 时，写完每条后快速核对：

- [ ] 落在正确的 `###` 分区，标题词表未跑偏
- [ ] 无句首「新增/优化/修复/Added/…」
- [ ] 中文用 `：`、英文用 `: ` 分开短标题与说明（不用 em dash）
- [ ] 主仓库中英文 +（若公共功能）starcat-pro 中英文语义一致
- [ ] 打开 App Help → 更新说明，确认最新版卡片扫读正常（有授权改文案时）

## 5. 正式发版

只有 dong4j 明确要求正式发版或更新正式发布页面时，才执行以下工作：

1. 根据实际发布范围审计 4 份 Markdown，补漏、去重并复核中英文表述。
2. 将目标版本标题从“待发布”状态改为正式版本标题。
3. 运行 `python3 supports/starcat-site/direct/generate-changelog.py`，生成官网中英文更新日志页。
4. 检查 `supports/starcat-site/direct/changelog.html` 与 `supports/starcat-site/direct/changelog-zh.html` 只展示已正式发布的版本。
5. 是否部署官网仍以 dong4j 的明确指令为准，不得因生成 HTML 而自动执行部署。

## 6. 验证要求

- 使用 `rg` 检查 4 份 Markdown 的目标版本标题和条目是否同步。
- 日常任务确认两份 HTML 没有被修改；正式发版时确认两份 HTML 已由生成脚本同步更新。
- 分别在主仓库和 `supports/starcat-pro` 独立仓库执行 `git diff --check`。
- 保留工作区中与当前任务无关的改动，不得顺手整理或覆盖。
- 新条目符合第 4 节结构与模板（短标题 + 中文 `：` / 英文 `: `，无句首分类动词）。
