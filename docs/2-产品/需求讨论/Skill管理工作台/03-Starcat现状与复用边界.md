# Starcat 现状与复用边界

> 研究日期：2026-11-14。主仓 HEAD：`ed8d689c4fca523f2f125e23d037e697cd900893`，分支 `dev`。若干 Skill 代码有未提交修改，以下区分仓库现状与本次拟新增内容。

## 1. 现有仓库 Skill 功能是什么

现有路径围绕一个 GitHub 仓库展开：识别 Skill → 阅读目录与文件 → 选择目标 → 安装／导出。`RepoSkillWindowController` 创建绑定 `RepoSkillSession` 的预览／安装 sheet，固定一次打开的画布和仓库上下文，不是一个持续管理本机库的独立窗口。

已确认决策保留在 [开发前问题清单](../../../1-立项/开发前问题清单.md) 的仓库 Skill 章节：Direct 安装、App Store 授权目录导出、固定 commit、完整目录校验、不执行仓库脚本、不自动接入 Starcat Agent。新工作台不应改变这些边界。

## 2. 能力清单与复用方式

| 现有组件 | 当前职责／约束 | 新功能中的用法 |
|---|---|---|
| `Core/Skills/RepoSkill.swift` | 仓库内 Skill、目录、文件等值类型 | 远端候选输入；不直接充当本机库条目 |
| `RepoSkillScanner.swift` | 固定 commit 的 GitHub tree 扫描，有界回退、分批结果 | GitHub 导入与来源检查；本机扫描另写 |
| `SkillFrontmatter.swift` | 轻量 name／description 解析及格式约束 | 基础展示与现有远端流程继续复用；不是完整 YAML 编辑器 |
| `RepoSkillReadingCache.swift` | 仓库 Skill 阅读缓存 | 远端预览缓存；本机文件按内容指纹缓存 |
| `RepoSkillInstaller.swift` | 文件、来源、hash、权限与回执校验，暂存、替换、恢复 | 抽取可共享文件事务原语，保留旧流程契约 |
| `RepoSkillStore.swift` | 远端扫描、安装与账号变更协调 | 新来源 provider 的上游适配；不承载全局本机库 |
| `RepoSkillAgentCatalog.swift` | 当前工作区新增的工具路径及只读检测 | 工具描述与发现种子；不能直接证明启停语义 |
| `RepoFileDownloader.swift` | 仓库文件获取与校验能力 | 继续走现有网络、鉴权与下载协议 |
| `RepoSkillDetailPane` / `RepoSkillFilePreview` | 远端说明与文件预览 | 提炼纯展示组件或输入适配，保留仓库业务隔离 |
| `WorkspaceColumns` 等 | 工作台分栏、尺寸、显隐、持久化 | 优先复用，共享 chrome 与独立偏好键 |
| `DistributionGate` | UI 可用性与执行层渠道拒绝 | 增补拟议 `ChannelFeature.skillManagement` |
| `LocaleStore.AppLocale` | 17 种语言与系统选项 | 新文案全语言覆盖，不另建翻译机制 |

以上文件均位于主仓；`supports/starcat-localization` 是独立仓库。路径和证据见 [SC01–SC09](11-证据索引与核查记录.md#starcat-源码与规则)。

## 3. 现有安装器是最重要的技术资产

研究时读取的 `RepoSkillInstaller` 工作区实现已经包含：

- `.starcat-install.json` 回执记录仓库、目录、commit 与各文件 SHA256。
- 判断已安装时核对来源、内容集合、内容指纹及可执行权限。
- Skill 内部 symlink 阻断；目标根可以是真实解析后的链接目录。
- 同卷 staging／payload／backup，下载按 blob 校验，提交失败恢复旧目录。
- 卸载前再次完整验证，拒绝删除已被修改或来源不明的目录。
- 取消在提交前生效，避免用户取消导致提交中途遗留半状态。

这属于**当前工作区源码证据**，不表示本轮新增、已提交、已发布或已经过本次验证。

新工作台要增加的是受管内容库、逐目标链接所有权、外部位置诊断、批量结果和持久化操作记录。不能声称现有安装器已经支持这些能力，也不应直接复制一份再独立演进。

推荐在保留 `RepoSkillInstaller` 对外契约的前提下，抽取 `SkillFileTransaction` 与目录指纹原语；App Store 的现有导出仍走原有授权目录流程，不能被 Direct 管理器替代。

## 4. 三栏基础的真实结构

`WorkspaceColumns<Rail, RunSurface, Inspector>` 使用左侧 `NavigationSplitView`、中间 detail 以及右侧 `.inspector` 组合。它不是三个任意 View 直接组成的普通三参数分栏。

Skill 工作台建议映射为：

| 泛型角色 | 本功能内容 |
|---|---|
| Rail | 全部、受管、更新、Agent、来源等导航 |
| RunSurface | Skill 列表及搜索／排序／多选 |
| Inspector | 主要阅读详情、文件、分配与版本 |

右栏在此是主要详情区，需要比 Agent 的辅助 inspector 更宽。使用独立 `WorkspaceColumnLayout` 参数和偏好键，不更改 Agent/RAG 的默认宽度。先用真实内容验证右栏最小宽度、折叠与焦点；若共享组件存在硬限制，优先做最小的可配置扩展，不重写全部窗口架构。

`WorkspaceColumnWidthPersistence` 刻意将测量缓存与响应式布局分开，避免“测量→保存→布局”循环。新功能不得在拖动时用 `@AppStorage` 持续反向更新当前 ideal width。

## 5. 窗口与依赖生命周期

现有 Agent/RAG 通过 `StarcatApp` 的单例 `Window` Scene 和 coordinator 暴露 `openWindow`。RAG 还处理账号数据库切换，说明窗口生命周期必须和业务数据范围一致。

本功能的推荐差异：

- 拟新增 `SkillWorkspaceSceneCoordinator`，沿用注册／打开 Scene 的模式，不把新窗口塞入 `RepoSkillWindowController`。
- 拟新增 `SkillLibraryEnvironment` 作为 app／本机级依赖持有者，按需创建，生存期不随 `DatabaseManager.reopen(userId:)` 切换。
- `AppDependencies` 只向它提供当前远端访问能力；私有仓库请求在账号变化时取消并重新授权。
- 本机目录、标签、分配、来源记录在账号切换时保留；远端内容及错误消息不得混入其他账号的授权上下文。
- 本机管理入口不要求 GitHub 登录；启动依赖尚未完成时显示可重试状态，不能创建第二套数据库单例。

`AppDependencies` 已有较大装配范围，应增加一个明确的组合点，而非把所有扫描、监听和操作状态继续堆进去。

## 6. Direct 门控方案

用户要求的是 Direct 独有，不是 Pro 独有。拟增加独立能力 `skillManagement`：

| 层 | 必须处理 |
|---|---|
| UI | 仅 Direct 显示工作台菜单、快捷入口与“在管理器中查看” |
| Scene | 恢复／内部打开请求同样检查，App Store 无法进入有效工作台 |
| 服务入口 | 扫描、管理器导入、分配、编辑、更新、usage 扫描统一执行门控 |
| 初始化 | App Store 不创建管理器目录、数据库或 watcher |
| 原有功能 | 仓库 Skill 预览和 App Store 授权目录导出继续有效 |
| 测试 | Direct 放行与 App Store 拒绝分别验证，不能只断言按钮隐藏 |

以 [分发渠道能力门控规范](../../../5-规范/分发渠道能力门控规范.md) 为实现依据，不能自行发明编译宏或把渠道判断散落在各个 View。

## 7. UI、国际化和文档约束

先读 [DESIGN.md](../../../../DESIGN.md)，再执行当前 UI 专项规范。文字与普通图标只用 `.primary` / `.secondary`，状态颜色按规范使用；plain Button 禁止焦点蓝框，折叠标题整行点击。

刷新、关闭、复制、危险操作使用现有共享组件；设置内独立按钮右对齐。列表分页使用现有策略，不在 Skill 页面单独发明另一套滚动触发规则。

实际语言集合已核对 `AppLocale` 与 `supports/starcat-localization/locales.json`：

`en、zh-Hans、zh-Hant、ja、ko、de、fr、es、pt-BR、it、ru、nl、pl、uk、tr、vi、id`。

新增 key 不只补中文／英文；AI 翻译状态必须保留，不用英语复制冒充覆盖。`Localizable.xcstrings` 不能用 ApplyPatch 或 JSON 全量写回，实施时遵循本地化专项流程。

## 8. 研究期间的工作区隔离

读取时仓库已有 Skill、健康评估 sheet 和问题清单等脏改动；研究过程中其他任务又增加了 Skill inspector／chip 与本地化改动。`RepoSkillAgentCatalog.swift` 当时尚未跟踪。

因此后续 AI 必须重新检查 `git status`，读真实文件；不要把本报告提到的工作区能力当作 HEAD 中必然存在的代码，不要回退、格式化或顺手提交其他任务文件。

本轮仅新增本目录报告。进入实施阶段时，应按仓库分支规范读取 `BRANCH.md` 后确认工作区安排；本报告不授权创建、切换、合并或推送分支。
