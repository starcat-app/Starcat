# komi-store 调研与 Starcat 借鉴清单

> 调研对象：[kurikomi-labs/komi-store](https://github.com/kurikomi-labs/komi-store)
> 调研时间：2026-06-28
> 目的：从 GitHub Releases 应用商店产品中提炼 Starcat 可借鉴的功能、信息架构与后续候选任务。

---

## 1. 结论摘要

`komi-store` 的定位不是 GitHub Star 管理，而是一个基于 GitHub Releases 的跨平台开源应用商店。它的核心价值是从 GitHub 仓库中筛出“真的发布可安装产物”的项目，并围绕发现、详情、下载、安装、更新和公告建立完整闭环。

对 Starcat 最有价值的不是安装器、APK 检查或 KMP 架构，而是这些产品机制：

- **Release 产物识别**：通过 asset 文件名、平台、架构、stable/pre-release 等信息判断项目是否“可落地使用”。
- **发现源分层**：`Trending` / `Hot Release` / `Most Popular` 加平台、语言、更新时间、最近发布排序。
- **搜索体验补强**：搜索历史、GitHub URL 粘贴识别、剪贴板链接检测、隐藏已看、隐藏不感兴趣仓库。
- **详情页 Release 体验**：stable / pre-release / all 分类、手动刷新 cooldown、跳过版本 changelog 合并。
- **后端索引 + GitHub fallback**：后端 curated index 负责高质量排序和聚合，GitHub passthrough 只做保底。
- **跨版本沟通**：`What's new` 一次性弹窗 + 历史页，Announcements feed 支持分类、已读、确认和静音。

Starcat 可以把这些能力转化为“更懂 GitHub 项目价值”的管理与发现功能，而不是照搬应用商店。

---

## 2. 项目概览

### 2.1 产品定位

`komi-store` 是一个跨平台 GitHub Releases 应用商店，支持 Android、Windows、macOS、Linux。README 中明确强调：

- 只展示带有可安装 release assets 的仓库。
- 首页有 `Trending`、`Hot Release`、`Most Popular`。
- 详情页展示 README、Release notes、安装包、版本、平台标签、翻译等。
- Android 侧提供安装、更新、APK 检查、静默安装等完整 app-management 闭环。
- Desktop 侧主要是下载 installer 到 Downloads 并用系统默认 handler 打开。

### 2.2 代码结构

代码是 Kotlin Multiplatform + Compose Multiplatform，结构大致如下：

```text
composeApp/      # 入口、导航、DI、desktop/android main
core/domain/     # 领域模型、仓库接口、工具、系统抽象
core/data/       # Ktor、Room、本地缓存、Repository 实现、网络策略
core/presentation/
feature/
  apps
  auth
  details
  dev-profile
  favourites
  home
  profile
  recently-viewed
  search
  starred
  tweaks
```

这个分层对 Starcat 不需要直接照搬。Starcat 已经有 SwiftUI + Repository + Service + ViewModel 的本地结构，借鉴时应保留现有边界，只吸收领域能力。

---

## 3. 可借鉴功能

### 3.1 Release 产物识别

`komi-store` 会根据 Release assets 判断仓库是否有可安装产物。例如：

- Android：`.apk`
- Windows：`.exe`、`.msi`
- macOS：`.dmg`、`.pkg`
- Linux：`.AppImage`、`.deb`、`.rpm`、`.pkg.tar.zst`

代码中还进一步处理：

- `AssetPlatform`：从 asset 文件名推断平台。
- `AssetArchitectureMatcher`：识别 `arm64`、`x86_64`、`universal` 等架构。
- `AssetSelector`：按扩展名优先级、stable/debug/nightly/beta、架构匹配、文件大小排序选择主资产。
- `AssetVariant`：从用户选择过的 asset 中提取 variant、tokens、glob，用于后续版本继续选中同一类产物。

**Starcat 可借鉴：**

Starcat 不需要下载和安装，但可以把 Release assets 识别变成项目画像的一部分：

- 新增“有可安装产物”的项目标记。
- 在 Smart Collections 中新增系统集合：
  - 有 macOS App
  - 有 CLI binary
  - 有 Docker / server artifact
  - 有 Demo / Release 产物
- 在 Repo Health 或详情页补充“分发成熟度”维度：
  - 是否有 Release
  - 是否有非源码 asset
  - 最近 stable release 时间
  - 是否只有 prerelease
  - asset 命名是否能识别平台

优先级：**P1**。这是对 Starcat “整理、理解、评估 GitHub 项目”最贴近的借鉴点。

### 3.2 从 starred 中筛出高价值项目

`StarredRepositoryImpl` 会同步用户 starred repos，并对每个 repo 检查最近 stable release 是否含有效 assets。检查过程使用并发控制，避免对 GitHub 打太多请求。

**Starcat 可借鉴：**

Starcat 已经拥有用户 stars 数据，可以增加一个后台轻量扫描：

- 对用户 stars 中近期活跃或高星项目检查 Release assets。
- 给 repo 打上派生字段，例如 `has_installable_asset`、`release_platforms`、`latest_stable_release_at`。
- 作为 Smart Collections、搜索过滤、Repo Health、AI 上下文的一部分。

关键约束：

- 不要启动期扫全量 stars。
- 只对打开详情、进入 Smart Collection、后台空闲或用户手动触发时做分页扫描。
- 需要 GitHub API rate-limit 退避和缓存 TTL。

优先级：**P1**。

### 3.3 Discovery 首页分层

`komi-store` 首页用 `Trending`、`Hot Release`、`Most Popular` 三个 chart tab，并支持平台筛选。后端提供 curated feed，客户端本地维护每个 tab 的分页缓存。

**Starcat 可借鉴：**

Starcat 当前已有 Activity、Trending、Weekly、Discovery 方向。可以强化“为什么推荐这个仓库”的分层：

| komi-store | Starcat 可映射 |
|---|---|
| Trending | 热门增长项目 |
| Hot Release | 最近发布活跃项目 |
| Most Popular | 高星稳定项目 |
| Platform filter | 语言 / 技术栈 / 应用形态过滤 |
| Hide seen | 隐藏已看 / 已处理项目 |

建议不要新增过多顶级入口，而是在现有 Activity / Discovery / Smart Collections 中承接。

优先级：**P1 / P2**，取决于 AI Discovery 后端成熟度。

### 3.4 搜索历史、URL 粘贴识别与剪贴板检测

`SearchViewModel` 有几个值得借鉴的小体验：

- 搜索历史本地保存。
- 输入内容如果完全是 GitHub URL，则不走普通关键词搜索，而是直接解析 owner/repo。
- 可选自动读取剪贴板，识别 GitHub 链接并显示快速导航。
- 搜索结果支持隐藏已看项目和隐藏不感兴趣仓库。

**Starcat 可借鉴：**

Starcat Search Center 可以补这些能力：

- `owner/repo`、`https://github.com/owner/repo`、`git@github.com:owner/repo.git` 输入直达仓库详情。
- 最近搜索词在 Search Center 中展示。
- 剪贴板 GitHub URL 检测需要做成显式开关，避免隐私体感不好。
- 增加“不再推荐 / 隐藏该仓库”本地状态，并在 Discovery、Trending、Weekly 中统一过滤。

优先级：**P1**。实现成本低，用户体感明确。

### 3.5 后端 curated index + GitHub fallback

`SearchRepositoryImpl` 的搜索策略是：

1. 本地缓存命中则直接返回。
2. 优先走后端 curated index。
3. 后端不可用时 fallback 到 GitHub Search API。
4. 后端 429 不 fallback，因为 rate-limit 是同一堵墙，需要显示退避。
5. 登录用户的 token 会被转发给 backend passthrough 路由，让后端使用用户的 GitHub quota。
6. 搜索私有仓库时只在用户登录后走 direct GitHub，并 prepend 到结果前面。

**Starcat 可借鉴：**

Starcat 的 Weekly / Trending / AI Discovery 后端可以明确采用类似边界：

- 后端负责排序、聚合、预计算字段和公共缓存。
- 客户端负责本地用户数据、私有仓库、兜底直连 GitHub。
- 用户授权后，后端 passthrough 路由可选择接收用户 token，减少匿名 60/hr 配额风险。
- `401`、`403`、`404`、`429`、`5xx` 要区分语义，不要全部当“后端失败”。

优先级：**P2**。这会影响后端接口设计，适合和 AI Discovery / GitHub 搜索后端一起规划。

### 3.6 Release 详情体验

`DetailsViewModel` 中 Release 体验比较完整：

- stable / pre-release / all 分类。
- 用户可以切换是否包含 betas。
- 如果当前安装版本落后多个版本，会把跳过版本的 release notes 合并成“what changed since ...”。
- 手动刷新走后端 refresh 接口，返回 cooldown / budget exhausted / archived / not found 等语义。
- 刷新时保留用户当前选择的 release；找不到时回退到 stable。

**Starcat 可借鉴：**

Starcat 已有 Release 订阅和 Activity Release 详情，可以补：

- Release 详情页 stable / prerelease 分组。
- 关注某 repo 时可选择是否关注 prerelease。
- “自上次查看以来的变更”合并摘要。
- 手动刷新按钮加 per-repo cooldown，避免用户连续打 GitHub。
- Release 订阅通知中区分 stable 和 prerelease。

优先级：**P1**。和 Starcat 已有 Release 订阅能力贴合。

### 3.7 Announcements 与 What's New

`komi-store` 有两类跨版本沟通：

- `What's new sheet`：当前版本第一次打开时弹一次，并保留历史页。
- `Announcements feed`：服务端公告流，支持 privacy notice、survey、security advisory、news；本地保存 dismissed、acknowledged、muted category。

**Starcat 可借鉴：**

Starcat 可以增加一个轻量“消息中心”：

- 新版本 What's New。
- 服务公告：后端维护、API 调整、AI 服务状态、隐私政策变更。
- 安全公告：GitHub OAuth scope、MCP local service、安全评分策略变化。
- 本地保存已读、已确认、已静音状态。

优先级：**P2**。上架前不是 P0，但对后续用户沟通很有价值。

### 3.8 网络与镜像策略

`komi-store` 为 GitHub release assets 和 raw files 设计了镜像系统：

- mirror catalog 可由后端更新。
- 下载时 mirror first，失败 fallback direct。
- 慢下载检测连续触发后建议用户启用镜像。
- 自定义 `gh-proxy` 风格 mirror template。

**Starcat 可借鉴：**

Starcat 不做大文件下载，但 GitHub README、Release notes、raw assets、wiki API 也可能受网络影响。可借鉴为：

- GitHub 请求失败诊断中区分 DNS、TLS、timeout、rate-limit、backend unavailable。
- 对 README/raw 内容可选代理或镜像配置。
- 在设置页提供 GitHub API / backend / README raw 连接测试。
- 对长期慢请求给出“配置代理 / 使用后端聚合 / 稍后重试”的明确建议。

优先级：**P2**。Starcat 已有服务健康检查和诊断日志，可作为增强项。

### 3.9 GitHub 登录兜底

`komi-store` 登录链路有多层：

- Web OAuth + PKCE + handoff。
- Device Flow 经 backend，基础设施失败时 fallback direct GitHub。
- Personal Access Token sign-in 作为最后兜底。

**Starcat 可借鉴：**

Starcat 已有 GitHub OAuth 与 Token 管理。可借鉴点是产品兜底层级：

- 登录失败时明确告诉用户是 GitHub、网络、backend 还是本机 keychain 问题。
- 保留 PAT 登录作为高级兜底入口，但要在 UI 文案中强调安全边界。
- 后续 Web Application Flow OAuth 接入后，可以保留 Device Flow 作为 fallback，而不是直接删除。

优先级：**P2**。需要和现有 OAuth 计划一起看。

---

## 4. 不建议照搬的部分

### 4.1 安装器与 APK 管理

`komi-store` 的 Android 安装、Shizuku、Dhizuku、APK inspect、签名校验、自动更新等是应用商店核心能力。Starcat 的核心是 GitHub Star 管理和项目理解，不应把产品方向拉向安装器。

结论：**不做**。

### 4.2 KMP / Compose Multiplatform 架构

Starcat 是 macOS SwiftUI 原生应用，Apple 原生体验是项目关键差异化。不应因为 `komi-store` 是 KMP 就引入跨平台架构。

结论：**不借鉴技术栈**。

### 4.3 兼容迁移代码

`komi-store` 已有长期发布历史，所以有大量 migration、legacy preference 迁移和跨版本兼容代码。Starcat 当前未上线、无线上用户、无线上数据，按项目铁律不应写兼容旧字段、老版本或数据迁移逻辑。

结论：**只借鉴功能思想，不借鉴兼容策略**。

---

## 5. 建议优先级

| 优先级 | 候选功能 | 理由 |
---|---|---|
| P1 | Release asset 画像与 Smart Collections | 最贴合 Starcat 的“评估项目价值”定位 |
| P1 | GitHub URL 粘贴直达 + 搜索历史 | 成本低，能明显提升搜索中心效率 |
| P1 | Release stable/pre-release 订阅策略 | 和现有 Release 订阅、Activity 详情直接相关 |
| P1 | 隐藏已看 / 不感兴趣仓库 | 提升 Discovery、Weekly、Trending 的长期使用体验 |
| P2 | 后端 curated index + token passthrough 策略 | 需要后端配合，适合与 AI Discovery 一起规划 |
| P2 | What's New / Announcements 消息中心 | 有助于上线后用户沟通，但不是核心阻塞项 |
| P2 | GitHub 网络诊断与代理/镜像建议 | 可接入现有服务健康检查和诊断日志 |
| 暂不做 | 安装、APK、静默更新 | 偏离 Starcat 产品定位 |

---

## 6. 可转成 Starcat 任务的初稿

### 6.1 Release 产物画像

- 为 repo 增加派生画像：是否有 stable release、是否有非源码 asset、可识别平台列表、最近 stable release 时间。
- 先做缓存和 UI 展示，不急着改主数据 schema；若后续证明价值稳定，再纳入持久表。
- 在详情页、Smart Collections、Repo Health 中复用。

### 6.2 Search Center URL 快速识别

- 输入 `owner/repo` 或 GitHub URL 时直接解析。
- 如果 repo 已在本地库中，打开本地详情。
- 如果不在本地库中，走 GitHub remote detail 或搜索结果。
- 最近搜索词保存本地，支持清除。

### 6.3 Release 频道与变更摘要

- Release 订阅设置中加入 stable only / include prerelease。
- Activity Release 详情按 stable / prerelease 分类。
- 当用户上次查看版本落后多个版本时，聚合中间 release notes。

### 6.4 隐藏与已看状态

- 增加本地 `seenRepos` / `hiddenRepos` 概念。
- Discovery、Weekly、Trending 列表可选择隐藏已看。
- 隐藏仓库需要有管理页，避免误操作无法恢复。

### 6.5 公告中心

- 本地先做 `What's New`，数据放 app bundle。
- 后续再做 backend announcements feed。
- 公告状态只存本地：已读、已确认、已静音分类。

