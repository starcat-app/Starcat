# Starcat 集成 CodeGraphContext 方案

> 目标：Starcat 直接调用开发者 macOS 中已经安装的 Git 和 CodeGraphContext（CGC），完成仓库 clone、本地代码图谱分析，并在默认浏览器中展示 CGC 生成的可视化结果。

---

## 1. 需求边界

Starcat 的目标用户是 macOS 开发者。本方案默认用户已经具备：

- 可用的 Git 命令；
- 已安装并配置完成的 CodeGraphContext；
- CGC 所需的 Python、图数据库等运行环境。

Starcat 不负责安装、升级或修复这些外部工具，只负责调用它们。

首版链路固定为：

```text
用户点击「代码图谱」
  ↓
Starcat 使用 macOS `/usr/bin/git` clone 仓库
  ↓
Starcat 使用用户配置的 CGC 索引仓库
  ↓
Starcat 调用 CGC 的 --viz 分析命令
  ↓
CGC 在默认浏览器中展示结果
```

### 1.1 首版只做

- 固定使用 macOS 的 `/usr/bin/git`；
- 在设置页配置 CGC 可执行文件路径；
- clone 当前仓库；
- 执行 CGC 索引；
- 执行 CGC 可视化分析；
- 展示当前步骤、命令输出和失败原因；
- 支持失败后重试。

### 1.2 首版明确不做

- 不自动安装 Git、CGC、Python 或数据库；
- 不区分 App Store 版和官网版；
- 不管理分支、Tag、commit SHA；
- 不检查远端代码是否更新；
- 不执行 `git pull`、`git fetch` 或增量同步；
- 不支持私有仓库；
- 不接入 MCP；
- 不启动 Web Server；
- 不使用 WKWebView；
- 不把 CGC 结果接入 AI 摘要或 AI 对话；
- 不设计通用本地分析工具框架；
- 不实现复杂的任务恢复、队列或后台常驻。

---

## 2. 用户流程

### 2.1 首次配置

设置页新增 `CodeGraphContext` 区域，只配置一个路径：

```text
CodeGraphContext

CGC Path
[/Users/me/.local/bin/codegraphcontext] [选择]

[测试配置]
```

CGC Path 默认留空，由用户选择已经安装好的 CGC 可执行文件。

Git 不提供设置项，Starcat 固定使用：

```text
/usr/bin/git
```

“测试配置”只执行：

```bash
/usr/bin/git --version
<cgc-path> --version
```

两个命令都返回 `exitCode == 0`，配置状态即为可用。若 `/usr/bin/git` 不可用，直接提示用户当前 macOS Git 环境不可用，不增加 Git 路径配置。

Starcat 不扫描 Homebrew、pipx、uv、pyenv 等安装目录。用户直接选择最终可执行文件，避免增加环境探测逻辑。

### 2.2 分析仓库

Repo 详情页增加一个入口：

```text
[代码图谱]
```

点击后：

1. 检查 `/usr/bin/git` 和 CGC 路径是否可执行；
2. 检查本地目标目录是否已经存在；
3. 不存在则执行 `git clone`；
4. clone 完成后执行 `codegraphcontext index .`；
5. 索引完成后执行固定的 CGC 可视化分析命令；
6. CGC 使用默认浏览器打开可视化结果。

### 2.3 本地仓库已存在

如果目标目录已经存在，Starcat 直接复用现有代码并开始 CGC 分析：

```text
本地目录存在
  ↓
跳过 git clone
  ↓
执行 CGC index
```

首版不判断仓库是否完整、不检查远端更新、不切换分支。

如果目录存在但 CGC 分析失败，用户可以手动删除该目录后重试。

---

## 3. 本地目录

Starcat 统一把仓库 clone 到自己的 Application Support 目录：

```text
~/Library/Containers/com.starcat.app/Data/Library/Application Support/Starcat/
└── repos/
    └── github.com/
        └── owner/
            └── repo/
```

目录规则：

```text
repos/github.com/<owner>/<repo>
```

例如：

```text
GitHub Repo: CodeGraphContext/CodeGraphContext

本地目录:
.../Starcat/repos/github.com/CodeGraphContext/CodeGraphContext
```

Starcat 只管理自己创建的 `repos` 目录，不修改用户已有的本地开发仓库。

---

## 4. 命令链路

### 4.1 Clone

首版只 clone GitHub 默认分支，不指定分支：

```bash
/usr/bin/git clone --depth=1 <clone-url> <repo-path>
```

示例：

```bash
/usr/bin/git clone --depth=1 \
  https://github.com/CodeGraphContext/CodeGraphContext.git \
  "/path/to/Starcat/repos/github.com/CodeGraphContext/CodeGraphContext"
```

约束：

- 使用 `Repo.cloneUrl`；
- 参数通过 `Process.arguments` 传递，不拼接 shell 字符串；
- 不使用 `sh -c`、`zsh -c`；
- `exitCode != 0` 即 clone 失败，不继续执行 CGC。

### 4.2 CGC 索引

以本地仓库目录作为工作目录：

```bash
<cgc-path> index .
```

对应流程：

```text
Process.currentDirectoryURL = repoPath
Process.executableURL = cgcPath
Process.arguments = ["index", "."]
```

`exitCode == 0` 表示索引完成，然后继续执行可视化分析。

### 4.3 CGC 可视化分析

CGC 官方 CLI 支持通过全局参数 `--visual` / `--viz` 把分析结果展示为交互式图谱。

首版使用一个固定的“代码复杂度概览”命令：

```bash
<cgc-path> analyze complexity --threshold 0 --limit 200 --viz
```

该命令的作用：

- 从当前仓库图谱中选择函数节点；
- 最多展示 200 个结果，避免大型仓库一次渲染过多节点；
- 由 CGC 生成可视化结果；
- 由 CGC 打开 macOS 默认浏览器。

Starcat 不处理 CGC 生成的 HTML，也不负责浏览器页面生命周期。

> 实现前必须使用目标 CGC 版本执行一次上述完整命令，确认该版本的参数顺序和自动打开浏览器行为。若官方 CLI 发生变化，只调整这一条固定命令，不扩展成可配置命令模板。

---

## 5. UI 设计

### 5.1 Repo 详情入口

入口文案：

```text
代码图谱
```

按钮状态：

| 状态 | UI |
|---|---|
| 未配置 Git 或 CGC | `去设置` |
| 尚未开始 | `代码图谱` |
| clone 中 | `正在拉取代码...` |
| CGC 索引中 | `正在分析代码...` |
| 生成可视化 | `正在打开图谱...` |
| 失败 | 显示失败步骤和错误信息，提供 `重试` |
| 完成 | `重新打开代码图谱` |

### 5.2 进度面板

首版只显示三个步骤：

```text
代码图谱

✓ 拉取仓库
✓ 分析代码
● 打开图谱

[查看日志]
```

不展示百分比。Git 和 CGC 没有稳定的结构化进度协议，使用步骤状态即可。

### 5.3 日志

日志面板展示 Git 和 CGC 的 stdout、stderr：

```text
$ /usr/bin/git clone --depth=1 ...
Cloning into 'CodeGraphContext'...

$ codegraphcontext index .
Indexing repository...
```

日志只用于当前分析过程。首版不设计独立日志数据库。

---

## 6. 最小内部结构

首版只需要三个对象：

```text
CodeGraphContextSettings
└── cgcExecutablePath

CodeGraphContextRunner
├── testConfiguration()
├── cloneRepository()
├── indexRepository()
└── openVisualization()

CodeGraphContextViewModel
├── 当前步骤
├── 当前日志
├── 当前错误
└── startAnalysis()
```

不新增通用 `RepoAnalysisService`、Provider 抽象、MCP Manager、Web Manager 或持久化任务表。

### 6.1 状态定义

```swift
enum CodeGraphContextState {
    case idle
    case cloning
    case indexing
    case openingVisualization
    case succeeded
    case failed(step: CodeGraphContextStep, message: String)
}
```

状态只服务当前 UI，不要求 App 重启后恢复。

---

## 7. Process 实现约束

Git 和 CGC 都通过 Foundation `Process` 执行。

必须遵循：

1. Git 的 `executableURL` 固定为 `/usr/bin/git`；
2. CGC 的 `executableURL` 使用设置页保存的绝对路径；
3. 参数通过 `process.arguments` 传入；
4. CGC 的 `currentDirectoryURL` 设置为本地仓库目录；
5. stdout 和 stderr 在进程运行期间持续读取，避免 Pipe 缓冲区写满；
6. App 退出或用户取消时终止当前子进程；
7. `exitCode != 0` 时停止后续步骤；
8. UI 状态更新回到 `MainActor`；
9. 不修改 `PATH`，不推测用户 shell 环境。

Starcat 选择的是最终可执行文件，因此不需要启动 login shell，也不需要读取 `.zshrc`。

---

## 8. 失败处理

首版只区分失败发生在哪一步。

### Git 配置失败

```text
Git 命令不可用。
请确认当前 macOS 开发环境中的 `/usr/bin/git` 可以正常执行。
```

### CGC 配置失败

```text
CodeGraphContext 命令不可用。
请确认 CGC 已安装并完成初始化，然后重新选择可执行文件。
```

### Clone 失败

```text
仓库拉取失败。
<stderr>
```

### 索引失败

```text
CodeGraphContext 分析失败。
<stderr>
```

### 可视化失败

```text
代码图谱生成失败。
<stderr>
```

所有失败状态均提供：

```text
[重试] [查看日志]
```

---

## 9. 验收标准

### 设置

- [ ] 可以选择并保存 CGC 可执行文件路径；
- [ ] “测试配置”能够分别显示 `/usr/bin/git` 和 CGC 是否可用。

### 分析

- [ ] 点击“代码图谱”后，Starcat 能 clone 一个公开 GitHub 仓库；
- [ ] 本地目录已存在时跳过 clone；
- [ ] clone 完成后能执行 `codegraphcontext index .`；
- [ ] 索引完成后能执行固定的 `--viz` 分析命令；
- [ ] CGC 生成的图谱能在 macOS 默认浏览器中打开；
- [ ] 任一步失败时停止后续步骤并显示 stderr；
- [ ] 用户可以查看当前运行日志并重试。

### 明确不验收

- [ ] 不验收分支选择；
- [ ] 不验收远端更新；
- [ ] 不验收私有仓库；
- [ ] 不验收 MCP；
- [ ] 不验收 WebView；
- [ ] 不验收 AI 上下文集成；
- [ ] 不验收 App 重启后的任务恢复。

---

## 10. 最终方案

Starcat 首版 CGC 集成只实现以下链路：

```text
设置 CGC 路径
  ↓
/usr/bin/git clone --depth=1
  ↓
codegraphcontext index .
  ↓
codegraphcontext analyze complexity --threshold 0 --limit 200 --viz
  ↓
默认浏览器展示图谱
```

这条链路已经覆盖当前需求。其它能力只有在这条链路落地并确认有实际使用价值后，才单独讨论是否增加。

---

## 参考资料

- [CodeGraphContext GitHub](https://github.com/CodeGraphContext/CodeGraphContext)
- [CodeGraphContext CLI Reference](https://github.com/CodeGraphContext/CodeGraphContext/blob/main/docs/CLI_COMPLETE_REFERENCE.md)
