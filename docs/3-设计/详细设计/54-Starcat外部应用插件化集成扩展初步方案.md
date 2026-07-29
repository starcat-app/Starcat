# Starcat 外部应用插件化集成扩展初步方案

> 状态：初步方案，待按优先级逐项立项
>
> 适用版本：v1.2 及后续版本
>
> 前置基线：
> - [Alfred 外部搜索集成详细设计](52-Alfred外部搜索集成详细设计.md)
> - [uTools 与 Raycast 外部搜索集成详细设计](53-uTools与Raycast外部搜索集成详细设计.md)
> - [StarcatCLI 与外部 MCP 桥接设计](34-StarcatCLI与外部MCP桥接设计.md)
>
> 调研时间：2026-07-30

---

## 1. 目标与结论

Alfred、uTools、Raycast 已证明 Starcat 的本地数据和 GitHub 全局搜索能力可以通过
CLI/MCP 安全地提供给外部工具。后续扩展不应继续以“每发现一个应用就复制一套搜索”
的方式推进，而应按宿主能力分成三条集成路线：

1. **Apple 系统级集成**：Spotlight、Shortcuts、Siri 等，由 Starcat 主应用直接提供。
2. **本地插件适配器**：LaunchBar、VS Code、PopClip、Obsidian、JetBrains 等，优先调用
   `starcat` CLI。
3. **MCP 客户端接入**：支持 MCP 的 AI Agent / IDE 直接配置 Starcat MCP，不再创建
   仅用于转发 MCP 的重复插件。

当前建议的实施顺序是：

1. Spotlight + Shortcuts。
2. LaunchBar。
3. VS Code。
4. PopClip。
5. Obsidian。
6. JetBrains。
7. Hammerspoon、Keyboard Maestro、BetterTouchTool 等自动化模板。

这是一份候选方向和架构边界文档，不代表所有候选都已进入开发排期。

---

## 2. 当前可复用基线

### 2.1 已实现能力

| 层 | 当前能力 | 后续集成如何复用 |
|----|----------|------------------|
| Starcat App | 本地仓库搜索、GitHub 搜索、跨来源合并与去重 | 继续作为唯一业务实现 |
| MCP | `starcat.global_search_repos` | 外部搜索的唯一协议入口 |
| CLI | `starcat search` | 本地插件的唯一进程入口 |
| Deep Link | `starcat://repo/{owner}/{name}?v=1&rid={id}` | 本地结果统一回到 Starcat |
| GitHub URL | `https://github.com/{owner}/{repo}` | 纯远端结果统一在 GitHub 打开 |
| Search Contract | `schema_version = 1`、来源、头像、`open_url`、warning、错误码 | 所有适配器共同消费 |
| Pro 门控 | MCP Service 与业务层集中判断 | 外部插件禁止重复实现订阅判断 |

### 2.2 不允许突破的边界

任何新集成都必须遵守：

- 不直接读取 Starcat SQLite。
- 不直接读取 Keychain、Local API Key 或 GitHub Token。
- 不复制 Local FTS、GitHub Search、去重或排序算法。
- 不通过 shell 拼接用户输入。
- 不接受上游返回的任意可执行 URL。
- 不把宿主专属 UI 数据结构加入 MCP Tool。
- 不因为宿主支持网络请求，就绕过 Starcat 直接调用 GitHub。
- 不为同一搜索能力新增第二套 Pro 门控。

---

## 3. 集成类型

### 3.1 Apple 系统级集成

这类能力属于 Starcat App 本身，不创建 `supports/` 独立仓库。

```text
Starcat App
    ├── Core Spotlight index
    ├── App Intents / App Entities
    ├── App Shortcuts
    └── Deep Link Router
```

适合：

- Spotlight 搜索本地仓库。
- Shortcuts 查询、打开、同步或获取统计信息。
- Siri / 系统建议调用高价值 App Intent。
- 后续 Widget 配置与交互复用 App Entity。

### 3.2 本地插件适配器

这类宿主具有插件、Action、Extension 或命令面板能力，但不应访问 Starcat 内部存储。

```text
Host Plugin
    -> argv 调用 starcat CLI
    -> 解码 Search Contract v1
    -> 映射宿主 UI
    -> 校验并打开 Starcat Deep Link / GitHub URL
```

适合：

- LaunchBar Action。
- VS Code Extension。
- PopClip Extension。
- Obsidian Community Plugin。
- JetBrains Platform Plugin。

### 3.3 MCP 客户端

当宿主已支持 MCP 时，默认只提供安装与配对文档：

```text
MCP Host
    -> starcat stdio adapter 或本地 HTTP MCP
    -> Starcat MCP Tools
```

除非宿主缺少结果 UI、Deep Link 或安全凭据配置能力，否则不创建只负责再次转发 MCP
的插件。

### 3.4 自动化模板

Hammerspoon、Keyboard Maestro、BetterTouchTool 等工具可以执行命令或打开 URL，但没有
必要维护完整插件项目。建议提供经过审计的模板和安装说明：

- 固定调用 `starcat` 可执行文件。
- 使用 argv / stdin 传参。
- 限制超时。
- 只打开允许的 Starcat / GitHub URL。
- 不在模板中保存 Token。

---

## 4. 候选应用矩阵

| 集成目标 | 宿主形态 | 首轮能力 | 调用入口 | 建议优先级 | 主要价值 |
|----------|----------|----------|----------|------------|----------|
| Spotlight | macOS 系统搜索 | 索引本地仓库、点击打开详情 | Core Spotlight + Deep Link | P0 | 无需安装第三方 Launcher |
| Shortcuts | Apple 自动化 | 搜索、打开仓库、获取统计、触发显式操作 | App Intents | P0 | 可组合系统自动化，也能复用给 Widget |
| LaunchBar | macOS Launcher | 与 Alfred 对齐的本地 + GitHub 搜索 | `starcat search` | P0 | 复用成本低，覆盖另一类 Launcher 用户 |
| VS Code | 编辑器 Extension | Quick Pick 搜索、打开仓库、复制链接 | `starcat search` | P1 | 直接进入开发者工作流 |
| PopClip | 选中文本 Extension | 搜索选中仓库名、打开 Starcat | CLI / Shortcut / URL | P1 | 低打扰的上下文入口 |
| Obsidian | 知识库插件 | 搜索仓库并插入 Markdown 引用 | `starcat search` | P1 | 连接收藏管理与个人知识库 |
| JetBrains | IDE Plugin | Search Everywhere / Action 搜索 | `starcat search` | P2 | 覆盖 IntelliJ IDEA 等 IDE |
| MCP Hosts | AI / IDE 客户端 | 使用搜索、统计、知识库问答等 MCP Tool | MCP | 文档优先 | 无需重复开发插件 |
| Hammerspoon 等 | 自动化工具 | 快捷键、菜单、选中文本脚本 | CLI / Deep Link | P2 | 用模板覆盖长尾需求 |

这里的 P0/P1/P2 是本方案内部的候选顺序，不修改
`docs/功能实现总览.md` 中的产品优先级。

---

## 5. 第一梯队设计

### 5.1 Spotlight

#### 目标

让用户在 macOS Spotlight 中输入 owner、repo、描述、语言或标签即可找到 Starcat 本地
仓库，并点击进入对应详情。

#### 数据范围

Spotlight 只索引 Starcat 已落地的本地内容：

- `owner/name`
- 仓库描述
- 主要语言
- 用户标签名称
- 是否在知识库
- Starcat 仓库 Deep Link
- owner avatar 缩略图

不索引：

- GitHub 动态远端搜索结果。
- 私有笔记正文。
- GitHub Token 或任何凭据。
- RAG chunk、对话、Prompt。

#### 更新时机

- 登录后的首次本地同步完成。
- repo metadata、标签、知识库状态变化。
- 取消 Star 或删除本地数据。
- 用户切换和退出登录。

Spotlight 索引由 Starcat 维护，不把数据库路径交给系统。索引 item 的唯一标识应基于
GitHub repository ID，避免仓库 rename 后产生重复。

### 5.2 Shortcuts

#### 首批 App Intent

| Intent | 输入 | 输出 / 行为 |
|--------|------|-------------|
| Search Starcat Repositories | query、source、limit | 仓库实体列表 |
| Open Starcat Repository | repository entity | 打开仓库详情 |
| Get Starcat Overview | 无 | Star、标签、知识库、Release 等只读统计 |
| Sync Starcat Stars | 无 | 显式打开或请求主应用执行同步 |

首轮不提供静默 Star / Unstar、删除笔记、批量修改标签等高风险写操作。

#### 与其他能力的关系

App Entity 应成为以下系统能力的共享模型：

- Shortcuts 参数。
- Spotlight Entity。
- Widget Configuration Intent。
- 后续 Siri / 系统建议。

App Intent 不应反向调用 CLI；它位于 Starcat 原生进程边界，应复用应用层只读服务。

### 5.3 LaunchBar

LaunchBar 与 Alfred 的产品目标一致，建议新建独立支持仓库：

```text
supports/starcat-launchbar-action
```

首轮只实现：

- 输入关键词后调用 `starcat search`。
- 展示 owner avatar、仓库名、描述和来源。
- 本地结果打开 Starcat。
- GitHub 结果打开浏览器。
- 映射公共错误码和修复提示。

LaunchBar Action 不持有 Starcat 凭据，也不访问 MCP endpoint。

---

## 6. 第二梯队设计

### 6.1 VS Code

建议仓库：

```text
supports/starcat-vscode-extension
```

首轮命令：

- `Starcat: Search Repositories`
- `Starcat: Open Current GitHub Repository`
- `Starcat: Copy Repository Link`

搜索结果使用 VS Code Quick Pick：

- `label`：`owner/name`
- `description`：来源与语言
- `detail`：仓库描述
- icon：远程 avatar 或本地 fallback

远程开发场景必须明确降级。若 VS Code Extension Host 在 SSH / Container 内运行而
Starcat 在本机，默认不能假定远端存在 CLI。首版只承诺本地 macOS Extension Host。

### 6.2 PopClip

PopClip 的优势不是展示复杂搜索列表，而是把“选中的文本”变成 Starcat 输入。

首轮 Action：

- `Search in Starcat`：把选中文本作为搜索词。
- `Open Repository in Starcat`：选中内容符合 `owner/repo` 时构造安全入口。

如果搜索返回多个结果，应打开 Starcat Search Center，而不是在 PopClip 中伪造复杂
列表。需要新增搜索页 Deep Link 时，应先扩展 Starcat 的统一导航协议。

### 6.3 Obsidian

建议仓库：

```text
supports/starcat-obsidian-plugin
```

首轮只做知识引用，不同步 Starcat 私有笔记：

1. 命令面板执行 `Starcat: Insert Repository Link`。
2. 调用 `starcat search`。
3. 用户选择仓库。
4. 插入 Markdown：

```markdown
[owner/repo](https://starcat.ink/r/owner/repo?v=1&rid=123)
```

第二阶段可评估插入结构化仓库卡片，但不得未经用户确认写入或覆盖 Vault 内容。

### 6.4 JetBrains

JetBrains Plugin 需要 Kotlin、Gradle、Marketplace 签名和跨 IDE 兼容测试，维护成本
明显高于 VS Code，因此排在后面。

首轮只做一个 Action / Search Everywhere Contributor，继续调用 CLI，不实现 JVM 版
Starcat SDK。

---

## 7. 统一搜索与展示契约

### 7.1 调用

```bash
starcat search "<query>" --source all --limit 30
```

所有进程型适配器必须：

- 使用 `execFile`、`Process.arguments` 或等价 argv API。
- 禁止 `/bin/zsh -c`、`shell: true` 和字符串拼命令。
- 输入 trim 后限制 1...200 字符。
- limit 限制 1...50。
- 支持取消上一轮搜索。
- 设置明确超时。

### 7.2 来源展示

每条结果必须保留来源：

- `Starcat 本地`
- `GitHub`

如果宿主只有一个 icon 槽，owner avatar 优先，来源放到 subtitle、accessory 或 detail。
不能为了放来源 badge 丢掉仓库身份图标。

### 7.3 打开行为

| 结果类型 | 允许打开 |
|----------|----------|
| Starcat 本地 | 版本化 `starcat://repo/...` |
| GitHub 远端 | 无凭据、无自定义端口的 `https://github.com/{owner}/{repo}` |

适配器必须复用公共 URL fixture，不因为某个宿主的 API 更宽松就接受其他 scheme。

### 7.4 错误

插件只消费结构化错误码，例如：

- `CLI_NOT_FOUND`
- `PAIRING_REQUIRED`
- `SERVICE_UNAVAILABLE`
- `PRO_REQUIRED`
- `CLI_VERSION_UNSUPPORTED`
- `INVALID_ARGUMENTS`
- `SEARCH_TIMEOUT`

用户提示应包含修复动作，不直接展示 Go / Node / Swift 内部错误全文。

---

## 8. 仓库和发布边界

### 8.1 需要独立仓库的项目

满足以下任一条件时使用 `supports/` 独立仓库：

- 有宿主 Marketplace / Gallery 发布流程。
- 使用独立语言、构建工具或锁文件。
- 需要单独版本、Release 和安装包。
- 需要宿主专属 CI。

候选仓库：

```text
supports/starcat-launchbar-action
supports/starcat-vscode-extension
supports/starcat-popclip-extension
supports/starcat-obsidian-plugin
supports/starcat-jetbrains-plugin
```

这些仓库必须遵循 Starcat 支撑型项目规范，包含中英文 README、开源文件、营销引用、
GitHub Actions、Release 构建和 supports 同步脚本登记。

### 8.2 留在主仓库的能力

- Core Spotlight。
- App Intents / App Entities。
- App Shortcuts。
- Deep Link 扩展。
- 设置页的集成发现入口。

### 8.3 只提供文档或模板

- MCP Host 配置。
- Hammerspoon Spoon / Lua 示例。
- Keyboard Maestro Macro。
- BetterTouchTool Preset。
- 通用 shell / AppleScript 示例。

---

## 9. 质量门禁

每个新适配器至少需要：

### 9.1 自动化

- Search Contract v1 fixtures 全部通过。
- CLI 定位、参数、超时、取消测试。
- 来源字段展示测试。
- URL allowlist 测试。
- 错误码映射测试。
- 空结果、部分 Provider 失败和非法 JSON 测试。
- 构建产物结构校验。
- README 安装命令 smoke test。

### 9.2 人工

- 真实宿主安装。
- 连续快速输入。
- 本地 / GitHub 来源辨识。
- 头像首次加载和缓存命中。
- 点击本地结果打开 Starcat。
- 点击远端结果打开 GitHub。
- CLI 未安装、未配对、Starcat 未运行、非 Pro 等提示。
- 浅色 / 深色主题。
- Apple Silicon；如宿主仍支持 Intel，再补 Intel 验收。

自动化通过不能替代真实宿主验收，未执行项必须保持未完成状态。

---

## 10. 风险与控制

| 风险 | 控制 |
|------|------|
| 支撑仓库数量快速膨胀 | 一次只立项一个宿主；先验证真实需求和维护成本 |
| 各插件字段与错误提示漂移 | Search Contract fixtures + 公共错误码 |
| 插件绕过 Starcat 调 GitHub | Code Review 明确禁止；凭据不出 Starcat |
| 宿主市场审核规则变化 | 发布前重新核对官方文档和签名要求 |
| 远程 IDE 找不到本机 CLI | 首版限定本地 macOS，远程桥接另行设计 |
| 私有仓库信息泄漏到第三方宿主 | 默认只返回现有契约允许字段；宿主不得持久化结果 |
| 为长尾工具维护完整插件不划算 | 优先提供模板和 Deep Link |

---

## 11. 实施建议

### 阶段 A：Apple 系统底座

1. 设计统一 `RepositoryAppEntity`。
2. 实现本地 Spotlight 索引。
3. 实现首批只读 App Intent。
4. 实现 App Shortcuts。
5. 为 Widget 复用 Entity 和 Intent 模型。

### 阶段 B：下一个 Launcher

1. 选择 LaunchBar。
2. 用支撑项目创建规范初始化仓库。
3. 复用 Search Contract v1。
4. 完成 Action、测试、签名和真实宿主验收。

### 阶段 C：开发者工作流

1. 先做 VS Code。
2. 收集使用反馈后再决定 JetBrains。
3. 不在首轮处理 Remote SSH / Dev Container 桥接。

### 阶段 D：知识与上下文工作流

1. PopClip 只做选中文本入口。
2. Obsidian 只做显式插入仓库引用。
3. 评估用户需求后再扩展写操作。

---

## 12. 后续立项前需要确认

- Spotlight 是否允许索引 Private repository 名称。
- Shortcuts 首批是否包含同步操作，还是严格只读。
- 下一个第三方宿主是否确定为 LaunchBar。
- VS Code 是否只支持本地 Extension Host。
- Obsidian 插入公开链接还是 `starcat://` 本地链接，或提供二选一。
- 新支撑项目是否统一归属 `starcat-app` GitHub Organization。
- 设置页是否只展示已发布集成，避免提前暴露 404 安装入口。

---

## 13. 官方参考

- [Apple Core Spotlight](https://developer.apple.com/documentation/corespotlight)
- [Apple App Intents](https://developer.apple.com/documentation/appintents)
- [Apple App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
- [LaunchBar Developer Documentation](https://developer.obdev.at/launchbar-developer-documentation/)
- [PopClip Extensions Developer Reference](https://www.popclip.app/dev/)
- [Visual Studio Code Extension API](https://code.visualstudio.com/api/)
- [IntelliJ Platform Plugin SDK](https://plugins.jetbrains.com/docs/intellij/developing-plugins.html)
- [Obsidian Build a Plugin](https://docs.obsidian.md/Plugins/Getting%20started/Build%20a%20plugin)


