# Starcat 接入 Repomix 集成方案

## 1. 背景

Starcat 当前已经具备 GitHub Repo 浏览、README 预览、Trending、AI 摘要等能力。现阶段 AI 摘要主要依赖：

- GitHub Repo 元信息
- README 内容
- Star / Fork / Language / Topics 等基础数据

这套方案适合做轻量摘要，但存在明显问题：

1. **README 不一定完整**  
   很多项目 README 只介绍用法，不解释代码结构、模块职责、核心实现、技术选型和内部依赖关系。

2. **AI 无法理解真实代码结构**  
   仅靠 README，很难判断项目是否真的活跃、代码是否复杂、核心模块在哪里、是否存在 CLI / Server / SDK / UI 等不同子模块。

3. **后续 AI 对话上下文不足**  
   用户如果继续问：
   - “这个项目的核心架构是什么？”
   - “入口文件在哪里？”
   - “它是如何启动的？”
   - “我想集成它，应该看哪些代码？”
   - “有没有类似插件机制？”

   仅靠 README 很难回答准确。

因此，Starcat 需要引入一个 **项目上下文生成层**，把 GitHub Repo 转换成更适合 LLM 消费的上下文。

Repomix 正好适合这个场景。它可以把本地或远程仓库打包成 AI-friendly 的单文件，支持 XML、Markdown、JSON、Plain Text 等输出格式，也支持压缩代码、token 统计、ignore 规则、远程仓库处理等能力。

参考：

- Repomix GitHub: https://github.com/yamadashy/repomix
- Repomix Docs: https://repomix.com/
- Repomix CLI Options: https://repomix.com/guide/command-line-options

---

## 2. 为什么现在必须做本地 Clone

原本 Starcat 的 AI 摘要可以只依赖远程 API，不一定需要把项目 clone 到本地。

但是现在 Starcat 后续计划接入 **CodeGraphContext**，而 CodeGraphContext 的核心能力是对本地代码进行索引，生成代码图谱、调用关系、类关系、复杂度分析等结构化信息。它本质上要求目标仓库必须存在于本地文件系统。

参考：

- CodeGraphContext GitHub: https://github.com/CodeGraphContext/CodeGraphContext
- CodeGraphContext Docs: https://codegraphcontext.github.io/

也就是说：

```text
只做 README 摘要：不一定需要 clone
接入 CodeGraphContext：必须 clone 到本地
```

既然后续为了 CodeGraphContext 必须引入本地 clone，那么 Starcat 就可以顺手复用这套本地仓库缓存机制，把 Repomix 一起集成进来。

这样可以形成一条统一链路：

```text
GitHub Repo
   ↓
Starcat 本地 clone / pull
   ↓
Repomix 生成 AI 上下文
   ↓
CodeGraphContext 生成代码图谱
   ↓
AI 摘要 / AI 对话 / 代码结构分析
```

这个设计的好处是：

1. **Clone 成本只付一次**  
   Repomix 和 CodeGraphContext 共用同一个本地仓库目录。

2. **后续扩展统一**  
   不管是 Repomix、CodeGraphContext、tree-sitter、自研分析器，还是其他 CLI 工具，都可以基于本地 repo 工作。

3. **AI 摘要质量显著提升**  
   Repomix 可以把真实代码结构和核心代码内容提供给 LLM，不再只依赖 README。

4. **AI 对话可以走多层上下文**  
   初始问题使用 Repomix，结构化追问使用 CodeGraphContext。

---

## 3. Repomix 在 Starcat 中的定位

Repomix 不应该被设计成一个独立功能入口，而应该作为 Starcat AI 能力的底层 Context Provider。

推荐定位：

```text
Repomix = Repo Context Packager
```

它主要服务于：

- AI 摘要
- AI 对话
- 项目结构理解
- 依赖和模块分析
- 后续 AI Prompt 构建

不建议把 Repomix 暴露成用户必须理解的概念。用户看到的应该是：

```text
生成项目上下文
重新生成上下文
上下文已过期
上下文 token 数
用于 AI 摘要
用于 AI 对话
```

而不是让用户直接关心：

```text
repomix-output.xml
repomix.config.json
--compress
--style json
```

---

## 4. 总体架构

建议在 Starcat 中新增一个统一的本地分析层：

```text
RepoDetailView
   ↓
AIContextViewModel
   ↓
RepoLocalWorkspaceService
   ↓
LocalRepoManager
   ↓
Context Providers
   ├─ ReadmeContextProvider
   ├─ GitHubMetadataProvider
   ├─ RepomixContextProvider
   └─ CodeGraphContextProvider
   ↓
AIContextBuilder
   ↓
AI Summary / AI Chat
```

其中 Repomix 只负责一件事：

```text
输入：本地 repo 路径
输出：AI-friendly 上下文文件 + metadata
```

---

## 5. 本地目录设计

建议 Starcat 统一维护本地工作区：

```text
~/Library/Application Support/Starcat/
  repos/
    github.com_owner_repo/
      .git/
      README.md
      src/
      package.json
      ...

  analysis/
    github.com_owner_repo/
      repomix/
        repomix-output.xml
        repomix-output.json
        metadata.json
        repomix.config.json

      codegraphcontext/
        status.json
        reports/
        viz/
```

### repoId 生成规则

建议使用稳定、可读的 ID：

```text
github.com_{owner}_{repo}
```

例如：

```text
github.com_CodeGraphContext_CodeGraphContext
```

如果未来支持 GitLab、Gitee、自定义 Git URL，可以统一扩展为：

```text
{host}_{owner}_{repo}
```

---

## 6. Clone / Pull 策略

### 6.1 首次分析

```text
用户点击 AI 摘要
   ↓
检查本地是否存在 repo
   ↓
不存在：git clone --depth=1
   ↓
存在：检查是否需要 pull
   ↓
执行 Repomix
   ↓
生成 AI 上下文
   ↓
调用 LLM 生成摘要
```

### 6.2 后续分析

如果本地 repo 已存在：

1. 获取远程默认分支最新 commit sha
2. 对比本地 HEAD
3. 如果一致，复用已有 Repomix 结果
4. 如果不一致，执行 pull 后重新生成 Repomix

### 6.3 clone 命令建议

```bash
git clone --depth=1 https://github.com/{owner}/{repo}.git /path/to/local/repo
```

浅克隆即可满足大部分 AI 摘要场景。

后续如果用户需要 commit history 分析，再单独扩展。

---

## 7. Repomix 执行策略

### 7.1 推荐默认命令

优先使用 XML 输出：

```bash
repomix /path/to/repo \
  --style xml \
  --compress \
  --output /path/to/analysis/repomix/repomix-output.xml
```

原因：

- XML 对 LLM 更稳定
- 结构边界清晰
- 适合作为 prompt 上下文
- Repomix 默认也推荐 XML 作为主要格式

### 7.2 需要程序解析时使用 JSON

如果 Starcat 需要解析文件列表、token、summary、目录结构，建议额外生成 JSON：

```bash
repomix /path/to/repo \
  --style json \
  --compress \
  --output /path/to/analysis/repomix/repomix-output.json
```

### 7.3 初期建议只生成一份 XML

MVP 阶段为了降低复杂度，可以只生成 XML：

```text
repomix-output.xml
```

metadata 由 Starcat 自己记录：

```json
{
  "repoId": "github.com_owner_repo",
  "tool": "repomix",
  "style": "xml",
  "compressed": true,
  "commitSha": "abc123",
  "outputPath": ".../repomix-output.xml",
  "createdAt": "2026-06-12T00:00:00Z"
}
```

---

## 8. Repomix 配置策略

### 8.1 默认不信任远程配置

Repomix 支持远程仓库配置，但 Starcat 默认不应该信任远程仓库中的 Repomix 配置。

原因：

- 远程配置可能刻意扩大扫描范围
- 可能包含不适合 Starcat 的输出设置
- 对 App Store 审核和用户信任不友好

因此建议：

```text
Starcat 自己生成 repomix.config.json
不要默认读取仓库自带 repomix.config.json
```

### 8.2 Starcat 默认 ignore 规则

建议默认排除：

```text
.git/**
node_modules/**
dist/**
build/**
DerivedData/**
.target/**
.gradle/**
.idea/**
.vscode/**
*.lock
*.png
*.jpg
*.jpeg
*.gif
*.webp
*.mp4
*.mov
*.zip
*.tar
*.gz
*.jar
*.war
*.class
```

注意：lock 文件是否排除可以做成配置。对某些项目，lock 文件能帮助 AI 判断依赖版本；但它们通常 token 很大。

---

## 9. AI 摘要链路设计

### 9.1 当前链路

```text
GitHub Repo Metadata
   + README HTML / Markdown
   ↓
Prompt
   ↓
LLM
   ↓
AI Summary
```

### 9.2 接入 Repomix 后

```text
GitHub Repo Metadata
   + README
   + Repomix compressed context
   ↓
AIContextBuilder
   ↓
Prompt
   ↓
LLM
   ↓
AI Summary
```

### 9.3 摘要 Prompt 推荐结构

```text
你是一个资深软件架构师，请基于以下信息分析这个 GitHub 项目：

1. GitHub 元信息
2. README
3. Repomix 生成的项目上下文

请输出：
- 项目一句话总结
- 适合什么场景
- 核心模块
- 技术栈
- 入口文件
- 架构特点
- 集成方式
- 风险点
- 是否值得 Starcat 用户关注
```

---

## 10. AI 对话链路设计

AI 对话不要每次都塞完整 Repomix 输出，否则成本高、速度慢、也容易超过上下文窗口。

推荐做成三种模式：

| 模式 | 上下文来源 | 适用场景 |
|---|---|---|
| Basic | README + Metadata | 普通问答 |
| Context | README + Repomix compressed | 项目理解、集成建议 |
| Deep | README + Repomix full / CodeGraphContext | 架构分析、调用关系、复杂问题 |

MVP 阶段先做：

```text
README + Repomix compressed
```

后续再做基于问题的动态选择。

---

## 11. 与 CodeGraphContext 的关系

Repomix 和 CodeGraphContext 不冲突，它们解决的问题不同。

| 工具 | 输入 | 输出 | 适合场景 |
|---|---|---|---|
| Repomix | 本地 repo | AI-friendly 单文件 | 摘要、问答、整体理解 |
| CodeGraphContext | 本地 repo | 代码图谱、调用关系、结构分析 | 调用链、复杂度、死代码、结构化查询 |

推荐分工：

```text
Repomix：给 LLM 一次性理解项目
CodeGraphContext：让 Starcat / AI 按需查询代码结构
```

最终组合：

```text
AI 摘要：README + Repomix
AI 对话：README + Repomix + 按需 CodeGraphContext 查询
代码结构页：CodeGraphContext
调用链/复杂度/死代码：CodeGraphContext
```

---

## 12. Starcat 内部接口设计

### 12.1 LocalRepoManager

```swift
protocol LocalRepoManager {
    func ensureRepo(owner: String, repo: String, url: URL) async throws -> LocalRepo
    func updateRepo(_ repo: LocalRepo) async throws -> LocalRepoStatus
    func getLocalPath(repoId: String) -> URL
}
```

职责：

- clone repo
- pull repo
- 获取当前 commit sha
- 管理本地 repo 路径
- 判断缓存是否过期

### 12.2 RepomixAnalyzer

```swift
protocol RepomixAnalyzer {
    func isAvailable() async -> Bool
    func generateContext(repo: LocalRepo, options: RepomixOptions) async throws -> RepomixResult
}
```

### 12.3 RepomixOptions

```swift
struct RepomixOptions {
    let style: RepomixStyle
    let compress: Bool
    let outputPath: URL
    let tokenBudget: Int?
}
```

### 12.4 RepomixResult

```swift
struct RepomixResult {
    let repoId: String
    let commitSha: String
    let outputPath: URL
    let style: String
    let compressed: Bool
    let createdAt: Date
    let tokenCount: Int?
    let fileCount: Int?
}
```

---

## 13. 数据库设计

建议新增表：

```sql
CREATE TABLE repo_local_workspaces (
  id TEXT PRIMARY KEY,
  repo_id TEXT NOT NULL,
  remote_url TEXT NOT NULL,
  local_path TEXT NOT NULL,
  default_branch TEXT,
  current_commit_sha TEXT,
  status TEXT NOT NULL,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL,
  last_error TEXT
);
```

```sql
CREATE TABLE repo_context_artifacts (
  id TEXT PRIMARY KEY,
  repo_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  artifact_type TEXT NOT NULL,
  artifact_path TEXT NOT NULL,
  commit_sha TEXT,
  status TEXT NOT NULL,
  metadata_json TEXT,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL,
  last_error TEXT
);
```

provider 示例：

```text
readme
github_metadata
repomix
codegraphcontext
```

artifact_type 示例：

```text
repomix_xml
repomix_json
codegraph_report
codegraph_viz
```

---

## 14. UI 设计

### 14.1 Repo Detail 页面

建议增加一个 AI Context 状态区域：

```text
AI Context

Repo Workspace
- 状态：未下载 / 已下载 / 更新中 / 失败
- 当前 Commit：abc123
- 本地路径：打开 Finder

Repomix Context
- 状态：未生成 / 已生成 / 已过期 / 失败
- 输出格式：XML
- 压缩：已开启
- 生成时间：2026-06-12 10:00
- 操作：生成 / 重新生成 / 删除
```

### 14.2 AI 摘要按钮

点击 AI 摘要时：

```text
如果没有本地 repo：提示需要下载源码
如果没有 Repomix context：自动生成
如果已存在且未过期：直接复用
如果已过期：提示重新生成或继续使用旧上下文
```

### 14.3 用户提示文案

```text
为了生成更准确的 AI 摘要，Starcat 需要将该仓库 clone 到本地，并使用 Repomix 生成项目上下文。源码仅保存在你的本机，不会上传到 Starcat 服务器。
```

---

## 15. 安装与依赖策略

### 15.1 App Store 版本

不建议 Starcat 自动安装 Repomix。

推荐做法：

```text
检测 repomix 是否存在
不存在则提示用户安装
提供安装命令
用户自行安装
```

检测命令：

```bash
which repomix
```

安装提示：

```bash
brew install repomix
```

或者：

```bash
npm install -g repomix
```

### 15.2 官网版本

官网版本可以考虑增强：

- 自动检测 Node.js
- 自动安装 Repomix
- 内置工具管理页
- 支持更新 Repomix
- 支持卸载 Repomix

但 App Store 版本建议保守。

---

## 16. 安全策略

### 16.1 本地源码说明

必须明确告诉用户：

```text
Starcat 会 clone GitHub 仓库到本地，用于生成 AI 上下文。
```

### 16.2 不自动执行项目代码

Repomix 只读取文件，不应该执行项目里的脚本。

Starcat 也不应执行：

```text
npm install
pnpm install
pip install
make
./gradlew
```

### 16.3 私有仓库

MVP 阶段建议先只支持公开仓库。

后续支持私有仓库时，需要明确：

- 使用 GitHub token clone
- 本地缓存路径
- 删除缓存能力
- AI 供应商是否会接收代码上下文

### 16.4 敏感信息

Repomix 有安全检查能力，但 Starcat 仍应增加自己的安全提示：

```text
生成 AI 摘要时，项目上下文可能会被发送给你配置的 AI 服务商。请不要对包含敏感信息的私有仓库启用该功能，除非你确认该 AI 服务商可信。
```

---

## 17. 错误处理

常见错误：

| 场景 | 处理 |
|---|---|
| 未安装 git | 提示安装 Xcode Command Line Tools |
| clone 失败 | 展示 Git 错误信息 |
| 仓库过大 | 提示使用压缩模式或排除目录 |
| 未安装 Repomix | 提示安装命令 |
| Repomix 执行失败 | 展示 stderr |
| 输出超过 token budget | 提示改用压缩模式 |
| 本地缓存损坏 | 提供重新 clone |

---

## 18. MVP 落地范围

第一版只做最小闭环：

```text
1. 检测 git
2. 检测 repomix
3. clone repo 到本地
4. 执行 repomix --style xml --compress
5. 保存 output.xml
6. AI 摘要使用 output.xml
7. UI 展示上下文状态
```

暂不做：

```text
- 自动安装 Repomix
- 私有仓库
- 多分支
- 增量分析
- CodeGraphContext 联动
- Repomix JSON 深度解析
- token 树 UI
```

---

## 19. 推荐实现步骤

### Step 1：本地 repo 工作区

实现：

```text
LocalRepoManager.ensureRepo()
```

能力：

- 根据 repo URL clone
- 已存在则复用
- 记录 local path 和 commit sha

### Step 2：Repomix 可用性检测

实现：

```text
RepomixAnalyzer.isAvailable()
```

内部执行：

```bash
which repomix
repomix --version
```

### Step 3：生成 Repomix 上下文

执行：

```bash
repomix {repoPath} --style xml --compress --output {outputPath}
```

### Step 4：AI 摘要接入

AI Summary Prompt 从原来的：

```text
README + GitHub Metadata
```

升级为：

```text
README + GitHub Metadata + Repomix Context
```

### Step 5：UI 状态展示

展示：

```text
本地源码：已下载
Repomix 上下文：已生成
重新生成
删除本地缓存
```

---

## 20. 推荐最终效果

用户体验应该是：

```text
用户打开一个 GitHub Repo
   ↓
点击 AI 摘要
   ↓
Starcat 提示：为了生成更准确摘要，需要下载源码到本地
   ↓
用户确认
   ↓
Starcat clone repo
   ↓
Starcat 使用 Repomix 生成上下文
   ↓
AI 输出更完整的项目摘要
```

后续接入 CodeGraphContext 后：

```text
同一个本地 repo
   ↓
Repomix 用于 AI 摘要和 AI 对话
   ↓
CodeGraphContext 用于代码图谱和结构分析
```

---

## 21. 方案结论

Repomix 非常适合作为 Starcat AI 摘要能力的第一层增强。

它的价值不是单独作为一个功能存在，而是补齐 Starcat 当前 AI 摘要上下文不足的问题。

更重要的是，Starcat 后续计划集成 CodeGraphContext，而 CodeGraphContext 本身就要求本地仓库。因此，本地 clone 这件事已经不可避免。

既然本地 clone 已经成为 Starcat AI 能力的基础设施，那么同时接入 Repomix 是一个非常自然、低成本、高收益的选择。

推荐最终定位：

```text
Local Repo Workspace：Starcat 本地代码分析基础设施
Repomix：AI 上下文生成器
CodeGraphContext：代码图谱分析器
AIContextBuilder：统一上下文编排层
```

第一阶段先完成 Repomix MVP，尽快提升 AI 摘要质量；第二阶段再接入 CodeGraphContext，提供代码结构、调用链和图谱分析能力。
