# 关注关系图谱 MVP 实施记录

> 状态：MVP 已实现，待真实账号与人工界面验收；未关闭专项\
> 日期：2026-11-05\
> 分支：`codex/follow-graph-mvp`\
> 基线：`dev` 的 `016ec9304fe54c2e3d44dfa5344960005ceabb26`\
> Worktree：`../Starcat-follow-graph-mvp`\
> 需求：[需求规格说明书](../2-产品/需求讨论/正式方案/关注关系图谱需求规格说明书.md)\
> 设计：[技术方案](../3-设计/详细设计/71-关注关系图谱技术方案.md)

## 硬上限解除与真实配额提示（2026-11-10）

- dong4j 确认不设人为节点 / 边 / 请求数上限，接受最终由 GitHub API 配额与本机性能限制；保留 5,000 节点自动探索软停。
- `9cbab46e`：删除 Store 的 10,000 节点 / 30,000 边与 300 请求闸门、GraphQL 剩余配额 200 的预判停止；只有真实 429 才进入冷却并记录恢复时间。手动展开不再有全局容量约束，只受该源已取得关系数与性能限制。
- 配额提示改为真实原因加本地恢复时间：新增 `followGraph.toast.quotaReset`（17 语言、`%@` 本地时间），状态条保留 `followGraph.status.quota`；`followGraph.status.limit` 改写为自动探索软停的正常说明，不再按错误展示。解析失败保留原始时间字符串，不伪造数值。
- 缓存只保留防损坏边界：快照 512MB（原 20MB）、sidecar 16MB（原 1MB）、单源预算与源数 1,000,000（原 10,000）；快照读取不再按 10,000 节点 / 30,000 边拒绝。
- 原生 **76 项 / 8 suites** 通过，覆盖低 GraphQL 配额不再提前停止、真实 429 冷却与恢复时间、超一万节点合并落盘、301 次分页不被预算拒绝、手动展开超过 10,000 节点且默认采样停在 5,000、预算 sidecar 新边界，以及模型级 403 提示含本地年份。
- `make build-appstore`、`make build-direct` 通过；`followGraph.toast.quotaReset` 与 `followGraph.status.limit` 的 17 语言编译资源与 Catalog 一致。日志：`/tmp/starcat-followers-nolimit-tests.log`、`/tmp/starcat-followers-nolimit-appstore.log`、`/tmp/starcat-followers-nolimit-direct.log`。
- 未做 GUI 自动化或真实账号配额验收；未改总览与 Changelog，未推送，专项保持待人工验收。

## 三批性能优化（2026-11-09，待人工视觉验收）

- 在 `codex/followers-graph` / `../Starcat-followers-graph` 实施，保留两方向现有功能、逐个入场和视觉效果。
- `89c77172`：流光独立绘制。1,000 节点稳定图连续 30 动画帧的替身回归中，基础绘制与命中回调配置、图数据更新均为 0 次，流光持续绘制；同时覆盖 Retina、缩放、后台暂停和关闭释放。
- `293c8ee9`：头像渐入完成后释放临时占位表面；按视口回收头像，512 张软预算保护屏内、本人、选中、在途及渐入资源。700 张全部屏内时允许超预算，部分移出后可收敛；返回视口优先探测原生缓存。
- `a694852e`：增量维护可见关系，缓存原生方向计数与 BFS 父节点。覆盖交叉边、自环、两方向、删除和减少动态效果；原生测试比较缓存路径与原图算法，校验动态人数。
- JS **38 项**、原生 **70 项 / 8 suites**通过。日志：`/tmp/starcat-followers-perf-index-js.log`、`/tmp/starcat-followers-perf-index-tests.log`。

| 节点 / 边 | 入场数据整理累计耗时：优化前 → 后 | 边检查次数：优化前 → 后 | graphData 调用次数（前后相同） |
|---|---:|---:|---:|
| 1,000 / 2,986 | 28.92 → 9.95ms | 421,026 → 7,959 | 141 |
| 5,000 / 14,986 | 164.14 → 36.28ms | 3,506,724 → 39,959 | 234 |
| 10,000 / 29,986 | 488.16 → 74.04ms | 10,315,184 → 79,959 | 344 |

- 对比基线 `36f7b4b6`，同规模和 34ms 虚拟帧，5 轮去前 2 轮取中位数；真实渐进队列配合 Canvas / ForceGraph 替身。计时源码不插桩，边检查次数另跑一轮统计，避免计数回调污染耗时。前后出现数量、帧步数和数据提交数量一致。脚本及结果：`/tmp/starcat-followers-perf-compare.cjs`、`/tmp/starcat-followers-perf-before.jsonl`、`/tmp/starcat-followers-perf-after.jsonl`。
- 耗时不含 Canvas 与 D3，不代表实际 FPS 或进程 CPU 百分比。单张头像 Canvas 像素预算 16KiB，512 张为 8MiB；原始 Image、流光背板、WebKit 和图结构另占内存，未测实际 RSS，不能宣称进程内存减半。
- D3 参数及布局步数不变，大图物理计算仍是剩余成本。未执行 GUI 自动化，未改总览或 Changelog，未关闭专项，未推送或合回 dev。
- `make build-appstore`、`make build-direct` 及渠道产物校验通过；两渠道 HTML / JS / 许可证与源码逐字节一致，已有 2 条刷新提示 × 17 语言的编译资源与 Catalog 一致。日志：`/tmp/starcat-followers-perf-appstore.log`、`/tmp/starcat-followers-perf-direct.log`；核验脚本：`/tmp/starcat-followers-verify-refresh-artifacts.py`。
- `make run-direct` 已通过 LaunchServices 稳定启动本 worktree 的 Direct Debug，PID `64632`，进程路径及单实例核实通过，启动后再次核验离线资源一致。日志：`/tmp/starcat-followers-perf-launch.log`。实际视觉体验仍待人工查看。

## 五秒提示、同步 dev 与性能预研（2026-11-09）

- `0be61184` 将图谱共用 Toast 时长统一为 5 秒，覆盖刷新结果与加载更多的普通、受限 / 失败提示；按 dong4j 要求直接提交，不测试、编译或重启，本节不能视为新产物验证。
- `2b9531ae` 将本地 `dev@d6b7b5f2` 合入 `codex/followers-graph`，保留 dev 的今日 Star 展示和本分支的两方向图谱入口。仅该侧栏文件发生内容冲突并已按两者语义解决；已确认 dev 为当前分支祖先。主工作区的未提交改动未带入，未推送或合回 dev。
- 性能阶段仅分析和测量，未修改性能实现。临时脚本 `/tmp/starcat-followers-perf-audit.cjs` 直接读取当前源码，结果 `/tmp/starcat-followers-perf-audit.jsonl`；不执行测试、应用构建、GUI、网络或真实缓存写入。
- 合成图包含根节点大 hub 和交叉路径。真实渐进逻辑配合 Canvas / ForceGraph 组件替身测量数据提交次数；真实 D3 使用当前 charge、link、按度数计算的碰撞半径和两次碰撞迭代，独立测量初始 8 tick 的每步耗时。渲染侧 5 轮去前 2 轮、D3 4 轮去前 1 轮，取中位数。D3 起始位置为确定性螺旋，不代表运行中全部布局形态。

| 节点 / 边 | 入场期间 graphData 调用 | 渲染侧逻辑累计 CPU，不含 Canvas / D3 | 独立 D3 单步 CPU | 两张头像 Canvas 的 RGBA 像素估算 |
|---|---:|---:|---:|---:|
| 1,000 / 2,986 | 141 | 28.70ms | 8.55ms | 31.25MiB |
| 5,000 / 14,986 | 234 | 167.61ms | 50.29ms | 156.25MiB |
| 10,000 / 29,986 | 344 | 475.05ms | 106.64ms | 312.50MiB |

- 内存列为所有节点均已创建两张 64×64、RGBA 四字节 Canvas 时的像素预算，未测实际进程占用；不含原始 Image 解码、Canvas / WebKit 对象和图结构开销。远景圆点不会全部创建头像，不能把该列当成实际常驻值。以上 Node / V8 CPU 测量不等于 WebKit FPS、CPU 百分比或真实账号验收。
- 建议待确认后分批实施：① 稳定布局时将路径流光单独绘制，避免每次动画都重绘全图与命中层，模拟或交互时同步更新；② 完成渐入后释放占位表面，并对头像表面做可见优先的有界缓存；③ 为当前展示版本缓存有向邻接计数与稳定 BFS 路径，避免计数更新反复扫描边或重建路径；大图入场的全量扫描与物理重热另行拆分，保留逐个入场、实时计数和可操作性。

## 刷新稳定性与结果提示（2026-11-09，待人工验收）

- 继续在 `codex/followers-graph` / `../Starcat-followers-graph` 分批实施：`ed1e6125` 修复无变化刷新布局抖动；`c09aaef1` 增加刷新结果 Toast。本轮不修改主工作区，不合并或推送。
- 原生分页元数据变化不再增加图版本；Canvas 对节点 ID 和边集合进行顺序无关比较，仅拓扑变化更新力导向数据。重复批次与资料更新保持节点对象、位置、镜头及正在执行的入场队列。
- 成功结束分别报告展示图的用户和关系净新增 / 移除，无变化明确提示；不把隐藏缓存和重复分页计为新增。失败、限额、停止或过期会话不显示成功，刷新预算和安全删除规则保持不变。
- 先复现重复 payload 引起布局更新的两项失败，再完成修复；JS **33 项**通过。最终原生 **70 项 / 8 suites**通过，包含两方向无变化刷新及用户变化、仅关系变化、失败和取消的参数化回归。
- 新增 2 条提示覆盖全部 17 语言，4 个数量占位符一致，原 Catalog 条目未改；保留 AI `needs_review`，译文仍待人工审核。未修改总览、Changelog、数据库或用户缓存，未执行 GUI 自动化。
- 测试日志：`/tmp/starcat-followers-refresh-stability-js.log`、`/tmp/starcat-followers-refresh-feedback-tests.log`。Canvas 替身回归验证布局调用和坐标保持，不代替真实 WebKit 视觉验收。
- `make build-appstore`、`make build-direct` 与产物校验通过；两渠道图谱 HTML / JS / 许可证与源码逐字节一致，2 条新增提示 × 17 语言的编译 strings 与 Catalog 一致。日志：`/tmp/starcat-followers-refresh-appstore.log`、`/tmp/starcat-followers-refresh-direct.log`；核验脚本：`/tmp/starcat-followers-verify-refresh-artifacts.py`。
- `make run-direct` 已通过 LaunchServices 稳定重启当前 worktree 的 Direct Debug，PID 68722、单实例，进程路径已核实。启动日志：`/tmp/starcat-followers-refresh-launch.log`；实际刷新观感与真实账号结果由 dong4j 人工验看。

## 加载范围恢复与初始化（2026-11-09，待人工验收）

- 继续在 `codex/followers-graph` / `../Starcat-followers-graph` 分批实施。`6b3ee9bd` 保存和恢复加载范围；`7499cdb6` 加入独立初始化确认入口。本轮不合并、推送或修改主工作区。
- 展开预算使用账户目录下独立的 `following-range.json` / `followers-range.json`，完整关系与分页游标仍在原快照内。关闭立即重开等待已排队预算写入；新模型也可恢复，不把完整缓存全部绘出。预算文件损坏或版本无效时忽略，恢复出厂后的迟到保存不重建目录。
- 重开先恢复范围再挂载新 WebView，初始化也重建画布；两者均从本人按层级逐个入场。搜索、选中和视角重置，结束不自动适配；现有有效范围不补采。新节点仍增量入场，关系与头像缓存不清理。
- 顶部新增竖线分隔的初始化图标，原生二次确认；确认后停止采集、写入默认预算，缺少默认层级时才补采。确认弹窗期间暂停工具栏自动隐藏。新增 3 条文案覆盖 17 语言，保留 AI `needs_review`，Catalog 仅新增原位条目。
- 最终相关原生 **68 项 / 8 suites**、Canvas 桥接 **31 项**回归通过，覆盖两方向重开 / 新模型恢复、默认范围初始化、立即重开保存顺序、部分缓存按需补采、缓存损坏与恢复出厂迟到保存。重播从本人开始，结束不自动 fit；桥接替身测试不等于 WebKit 视觉验收。
- `make build-appstore`、`make build-direct` 与产物校验通过；两渠道图谱 HTML / JS / 许可证逐字节匹配仓库资源，3 条新增文案 × 17 语言的编译 strings 与 Catalog 全部一致。原 Catalog 条目保持原字节，零删除。未使用 GUI 自动化，待人工验看，未关闭专项或写总览 / Changelog。
- 日志：`/tmp/starcat-followers-initialize-final-tests.log`、`/tmp/starcat-followers-range-js.log`、`/tmp/starcat-followers-range-appstore.log`、`/tmp/starcat-followers-range-direct.log`；资源核验脚本为 `/tmp/starcat-followers-verify-range-artifacts.py`。
- `make run-direct` 已通过 LaunchServices 稳定启动当前 Followers worktree 的 Direct Debug（PID 92435，单实例），进程路径已核实；启动日志 `/tmp/starcat-followers-range-launch.log`。视觉效果与真实账号交互由 dong4j 人工验看。

## 默认三层与加载反馈（2026-11-09，待人工验收）

- 继续在 `codex/followers-graph` / `../Starcat-followers-graph` 实施。三批代码提交：`8c632f13` 默认三层与分支预算；`bdb0ac80` 画布真实入场人数；`be063f71` 加载更多、手动容量分配与底部 Toast。本轮未修改主工作区，未合并或推送。
- Followers 默认本人、直接关注者、关注者的关注者三层；第三层稳定均分最多 1,000 条样本名额，每人最多 20 条。55 个分支的合成接口回归得到 1,056 个唯一节点，未采集第四层；旧首层缓存补齐后重开不再请求。该数量为测试样本，不代表真实账号本次结果。
- 卡片人数跟随 Canvas 已入场关系增长，按方向统计；选择版本、图版本与画布会话共同拒绝旧回调。已完成分页不重读第一页，人数已满但分页未完整时只收起按钮，不改写完整标记；隐藏缓存仍可展开。手动名额在默认投影后单独分配，避免大图中被其他分支抢占。
- 正常新增由节点与数字表达；只补关系、重复用户、完成、容量 / 配额与失败复用底部 Toast。普通提示 2 秒，受限 / 失败 4 秒；窄窗口避开资料卡，关闭与重开清理提示。新增 4 条文案覆盖本分支全部 17 语言，与 AppLocale、locales.json 及双渠道编译 strings 核对一致，保留 AI `needs_review`。
- 最终相关原生回归 **65 项 / 8 suites**、JS **30 项**通过；覆盖旧缓存补齐、分支预算、真实计数、A → B → A 迟到回调、默认及更深节点手动容量、重复分页、网络失败与低配额反馈。原有配额测试改用未完成分页验证继续请求阻断，完整缓存读取另有测试。
- `make build-appstore`、`make build-direct` 与产物校验通过；两渠道 HTML / JS / 许可证逐字节匹配仓库资源，4 条 Toast 文案的 17 语言编译资源与 Catalog 完全一致。未执行 GUI 自动化，动画、窄窗口视觉及真实账号加载仍由人工验看；未关闭专项，未改总览或 Changelog。
- 日志：`/tmp/starcat-followers-loading-feedback-tests.log`、`/tmp/starcat-followers-dynamic-count-js.log`、`/tmp/starcat-followers-three-layers-appstore.log`、`/tmp/starcat-followers-three-layers-direct.log`。

## Followers 扩展（2026-11-08，待验收）

- 分支：`codex/followers-graph`，基于 `dev@11d3a8bd`。
- Worktree：`../Starcat-followers-graph`；主工作区保留给并行功能，本轮不合并或推送。
- 「关注者」新增真实 followers 图谱；「正在关注」保留既有 following 图谱。
- Followers 默认完整本人首层、资料卡手动展开；真实边和流水始终指向被关注者。
- 按方向隔离分页与缓存，旧 following 快照继续可读；回关不改变 follower 身份。
- 原生相关回归：41 项、5 组通过，包含图模型、Store / Cache、API / ViewModel 生命周期、关注状态及恢复出厂；JS 25 项通过。
- 新增状态文案覆盖 AppLocale 当前 17 种语言，原有 Catalog 条目未改变；AI 翻译仍为 `needs_review`。
- 新 worktree 复用主工作区被忽略的本地签名配置与 Package.resolved。首次自动解析到更新的 MLX 分支出现无关枚举编译错误；恢复主工作区依赖锁定版本后测试通过，未修改 Local AI 模块或依赖声明。
- 2026-11-09：`make build-appstore`、`make build-direct` 均通过；两渠道 HTML / JS / 许可证逐字节匹配源码，新增文案 17 语言编译资源全部匹配 Catalog。
- 本地提交：`7a0f0308` 文档决议、`9cf2aed4` 模型 / 缓存 / 回归、`cdf89791` 入口 / UI / Canvas。未合并、推送或启动应用，真实账号 GUI 与视觉效果仍待人工验收。
- 验证日志：`/tmp/starcat-followers-tests.log`、`/tmp/starcat-followers-js-tests.log`、`/tmp/starcat-followers-appstore.log`、`/tmp/starcat-followers-direct.log`。

以下保留原 MVP 历史记录，入口以本轮双方向契约为准。

## 已实现范围

- 左侧现有「关注者」统计入口打开全窗口遮盖层，覆盖原侧栏与工具栏，关闭后恢复原页面。
- 离线打包 2D Canvas 图谱脚本，展示圆形头像及首字母占位；支持缩放、平移、节点拖动与定位，根节点固定原点并加入碰撞间距。
- 顶部悬浮查找、刷新、停止、继续、重置视角与定位自己；选中用户在右下角固定资料卡显示资料、贡献草坪、文本路径与操作。
- GraphQL following cursor 分页，使用现有 GitHubAPIClient 的认证与错误处理；Token 不进入 WebView。
- 默认优先加载一级关注，再每位一级用户首批 20 条，以四个并发请求为一批；允许手动单页展开。
- 纯原生图模型按 GitHub 数值 ID 去重，保留有向边与环路，BFS 选择一条稳定最短路径。
- 单轮最多 300 请求；自动探索在 5,000 节点停止；10,000 节点、30,000 边为硬上限；GraphQL 剩余配额低于 200 时暂停。
- 刷新仅覆盖已探索源；只有一个用户的完整分页刷新成功才删除其旧出边；中止或失败保留旧关系。
- 按账户 JSON 原子缓存、离线恢复、关闭取消、账户切换隔离与迟到响应保护。
- 设置页展示当前账户缓存占用、节点数、关系数与保存时间，不提供图谱缓存清理入口；已有恢复出厂操作会清理目标账户图谱缓存。
- 两渠道免费，无 Pro 门控；新增 25 个文案 key 覆盖全部 17 种支持语言，AI 翻译保留 `needs_review` 状态。

## 文件入口

| 范围 | 位置 |
|---|---|
| 数据模型、接口、调度、缓存、UI 与渲染桥 | `Starcat/Features/FollowGraph/` |
| 主窗口与入口 | `Starcat/Features/Home/HomeView.swift`、`SidebarView.swift`、`SidebarHeaderView.swift` |
| 设置统计 | `Starcat/Features/Settings/SettingsView.swift` |
| 恢复出厂 | `Starcat/Core/Reset/AppDataResetService.swift` |
| 离线产物 | `Starcat/Resources/FollowGraph/` |
| 渲染源码、锁定版本与重建脚本 | `resources/follow-graph/` |
| 开源致谢 | `Starcat/Features/About/AboutView.swift` |
| 图模型、缓存、调度与接口测试 | `StarcatTests/FollowGraphTests.swift` |
| 恢复出厂账户边界回归 | `StarcatTests/AppDataResetServiceTests.swift` |

直接依赖锁定为 `force-graph 1.52.0`、`d3-force-3d 3.0.6`，后者仅用于二维力计算。
30 个实际打包依赖均登记 About，并随 App 保留许可证及原始作者声明；`bezier-js 6.1.4` 的 npm 包和上游固定提交均未提供独立 LICENSE 文件，`notices/` 保留其源文件作者声明、README 的 MIT 声明与 MIT 条款，不编造版权年份。
离线脚本约 208 KB，已移除 Three.js / WebGL / 透视相机，运行时不依赖 CDN；头像请求只允许 GitHub avatars 域名。

## 2D 修订验证（2026-11-05）

- `npm test`：3 项渲染桥接回归通过，覆盖二维视口恢复、迟到序号、增量位置保留、路径方向、头像点击范围、下载并发、暂停与清理；组件 API 使用替身，不代替真实 WebKit 界面验收。
- `make test TEST_ARGS="-only-testing:StarcatTests/FollowGraphEngineTests -only-testing:StarcatTests/FollowGraphStoreTests -only-testing:StarcatTests/FollowGraphAPITests"`：3 个 suite、16 项测试通过（0.110 秒），包括新增二维视口合法值、缩放范围、旧三维数组与非有限值拒绝测试。日志：`/tmp/starcat-follow-graph-2d-tests.log`。
- `make build-appstore`、`make build-direct` 均通过；两渠道 HTML / JS / 许可证产物与当前源码逐字节一致。日志：`/tmp/starcat-follow-graph-2d-appstore.log`、`/tmp/starcat-follow-graph-2d-direct.log`。
- `make run-direct` 重试后已稳定启动当前 worktree 的 Direct Debug（PID 35330）。首次启动时同 bundle ID 的主工作区进程正在运行，未建立本 worktree 目标进程；重试通过单实例与目标路径校验。启动日志：`/tmp/starcat-follow-graph-2d-launch-retry.log`。实际 2D 外观、操作手感与大图性能等待 dong4j 人工验收。

## 节点浮层修订验证（2026-11-05）

- 用户确认后完成：选中节点全部已加载入边 / 出边加粗并显示方向，蓝色保留最短路径语义；邻接头像保持清晰，其余关系弱化。
- 用户信息改为头像旁原生浮层，坐标更新尾随合并、去重并验证身份 / 数值；卡片根据实际尺寸翻转和避让边缘。点击空白或浮层关闭按钮取消选中；Esc 依次清除查找、取消选中、关闭图谱。
- 删除底部用户条与状态卡，加载状态及用户 / 关系数量移至顶部，快照说明与时间通过悬浮提示查看。本轮复用已有文案，无新增国际化 key。
- `npm test`：5 项通过，新增全部邻接边（含对象端点、反向边）、相邻头像透明度、取消选中、卡片坐标跟随、帧合并、静止去重和关闭释放回归。Canvas API 仍使用替身，不等同于真实 WebKit 视觉验收。
- 图谱 3 个 suite 共 17 项原生测试通过（0.095 秒），新增非法坐标拒绝和卡片右 / 下边缘与顶部避让。日志：`/tmp/starcat-follow-graph-card-tests.log`。
- `make build-appstore` 与 `make build-direct` 通过，两渠道 3 份离线资源逐字节匹配源码；`git diff --check` 通过。日志：`/tmp/starcat-follow-graph-card-appstore.log`、`/tmp/starcat-follow-graph-card-direct.log`。
- `make run-direct` 已稳定启动本 worktree 产物（PID 66327），进程路径已复核。日志：`/tmp/starcat-follow-graph-card-launch.log`。卡片外观、长译文布局、真实平移缩放手感仍待 dong4j 人工验收；未使用 GUI 自动化。

## 数量暴涨与点击修复（2026-11-06）

- 根因证据：原刷新循环追到每个源的最后一页；当前真实缓存包含 `nikivdev` 的 6,000 条出边，整图为 9,976 用户 / 10,924 关系，本人一级关注为 64。
- 新增独立展示快照，默认取本人全部已加载一级关系和每个一级源 20 个稳定样本，保留可见节点之间全部已知关系；磁盘快照不因读取而裁剪。用真实 Swift 模型只读处理当前缓存，默认得到 722 用户 / 1,135 关系，读取前后磁盘字节一致。
- 刷新逐源限制累计条数和每页大小；样本未到末页不删除旧关系。手动展开优先利用缓存，网络仅补不足的单页。
- 移除卡片外层全屏透明 GeometryReader，改用根尺寸观察与实际卡片 offset；点击回调立即更新关联高亮，并在选中消息之后发送卡片坐标。缩远命中半径至少为 6 屏幕像素。
- `npm test` 6 项通过。新增回归从渲染器点击回调进入，无需等待原生选中回传，即能更新关联线和发送卡片坐标；仍是 Canvas API 替身测试，不是实际桌面点击验收。
- 图谱 3 个 suite、19 项原生测试通过（0.255 秒）。新增高出度缓存展示、显式展开稳定性和有界刷新测试。日志：`/tmp/starcat-follow-graph-bounded-tests.log`。
- App Store / Direct 双渠道构建通过，3 份离线资源均与源码一致，`git diff --check` 通过。日志：`/tmp/starcat-follow-graph-bounded-appstore.log`、`/tmp/starcat-follow-graph-bounded-direct.log`。
- 实际 WebKit / SwiftUI 鼠标命中及浮层外观仍待人工复验；本轮未使用桌面控制，也未宣称 GUI 验收通过。
- `make run-direct` 已稳定启动修复版（PID 59499），进程路径确认属于本 worktree。日志：`/tmp/starcat-follow-graph-bounded-launch.log`。

## 完整路径流水（2026-11-06）

- 已实现点击后立即从本人算起的完整有向路径高亮、跨每一跳的流水光带，并强化原生选中状态同步。其他入边 / 出边保留次级加重。
- 渲染回归 7 项通过，原生图谱 3 个 suite、19 项通过；日志：`/tmp/starcat-follow-graph-flow-tests.log`。渲染测试使用 Canvas API 替身，未代替桌面视觉验收。
- 与逐个弹出加载动画分别提交。MVP 基础提交单独保留，便于审阅后续交互差异。

## 逐个弹出的加载动画（2026-11-06）

- 已实现先本人、再按层级逐个放出头像；新头像从父节点附近播种，使用 360 ms 淡入 / 缩放 / 轻回弹，缓存与增量批次共享队列，旧节点不重播。
- 顶部节点 / 关系数量由实际可见图上报；只接受当前 revision 和合法范围。搜索定位可立即显示完整目标路径，已有可见节点持续可交互。
- 队列逐渐加速，数据批次不逐节点重置视口；Reduce Motion 直接显示，后台暂停时间轴，关闭取消帧任务并清队列。
- 渲染回归 10 项通过，包含完整路径流水、实际可见计数、父节点附近出现、增量对象复用、暂停 / 删除 / 释放和一万节点调度加速；一万节点测试是虚拟时间调度验证，不能用作真实帧率结论。
- 原生图谱 3 个 suite、19 项通过（0.257 秒），日志：`/tmp/starcat-follow-graph-reveal-tests.log`。真实桌面观感仍待人工验收。
- 最终 App Store / Direct 构建及产物校验通过，两渠道 3 份离线资源均逐字节匹配源码；日志：`/tmp/starcat-follow-graph-animated-appstore.log`、`/tmp/starcat-follow-graph-animated-direct.log`。

## 右下角紧凑资料卡（2026-11-06）

- 复用 OwnerCardView 的紧凑布局和 OwnerFollowService：图谱身份先显示，按需补全简介、社交链接、关注统计与贡献草坪，组织不支持时隐藏草坪。详情页原布局保持。
- 卡片固定右下角，支持内部滚动；开关轻移淡入淡出，切换用户淡换内容，Reduce Motion 只用透明度。按节点身份隔离加载并检查任务取消。
- 移除每帧 anchor 上报与原节点旁定位算法，保留选中、完整路径流水和逐个加载动画。渲染回归 10 项通过。
- `make build-direct` 构建与产物校验通过；日志 `/tmp/starcat-follow-graph-compact-direct.log`。原生回归和双渠道最终构建在关注同步提交时一并执行。
- GUI 外观、长译文和真实点击体验留待人工验收，未使用屏幕控制。关注写操作在下一独立提交中接入。

## 关注操作与关系同步（2026-11-06）

- 复用 OwnerFollowService 接入关注 / 取消关注，本人隐藏按钮；请求失败保留状态并在卡片内提示，查询重试与写入重试分别处理，避免误取消关注。关闭或切换卡片不重复提交请求，旧查询不能回滚写入成功结果。
- GitHub 成功后在 Store 中同步本人出边、可达分量与账户 JSON 缓存，更新路径和流水。取消直接关注后，仍可达的选中用户和完整间接路径不会被展示样本截断。
- 关注修订号保护操作前已开始的跨页刷新；之后新刷新仍使用远端结果。同账户重开和迟到发布使用快照新旧校验；成功回调检查账户及 Store 身份。
- 5 个 suite、34 项原生测试通过（0.295 秒），含 Owner 卡片社交链接回归；新增关注失败 / 重试、查询重试意图、重复点击、迟到查询、取消查询、缓存、账户拒绝、并发分页和重开保护。日志 `/tmp/starcat-follow-graph-follow-tests.log`。
- 本轮复用已有文案，12 个相关 key 均具备 17 种语言，未修改 Catalog；真实文案布局、明暗主题、过渡效果与 GitHub 关注写操作仍待人工验收，自动测试不代替 GUI 或真实账号操作。
- 最终 `make build-appstore` / `make build-direct` 构建及产物校验通过；两渠道 3 份离线渲染资源与源码逐字节一致，12 个复用 key × 17 种语言与编译后的字符串一致。日志 `/tmp/starcat-follow-graph-profile-appstore.log`、`/tmp/starcat-follow-graph-profile-direct.log`；`git diff --check` 通过。

## 原 3D MVP 自动验证（历史记录）

- `xcodegen generate` 已执行。
- App Store / Direct 的 `make build-*` 构建与产物校验已通过；只构建，没有停止或启动用户应用。
- 最终独立验证：图谱与恢复出厂共 4 个 suite、16 项测试通过（0.359 秒），涵盖去重、环路、稳定路径、一万节点算法、缓存隔离、分页、刷新、配额、容量、迟到响应与恢复出厂账户删除边界。日志：`/tmp/starcat-follow-graph-delivery-tests.log`。
- 两渠道最终构建日志：`/tmp/starcat-follow-graph-appstore-delivery.log`、`/tmp/starcat-follow-graph-direct-delivery.log`。
- 两渠道编译产物已检查：25 个新 key 在 17 种语言的 `.strings` 中均存在，离线渲染文件与最终源码产物逐字节一致；既有 Catalog 条目保持不变，diff 仅新增。
- 离线脚本重建成功；许可证与 About 登记一致。
- 全量回归在 `External Agent Runtime Host` 的「DeepSeek MCP 冷启动失败时重建 carrier 且不重复模型 turn」测试中触发 `NSFileHandleOperationException`；栈位于本轮未修改的 `ExternalAgentLineReader`。测试 runner 自动重启并继续执行，但全量命令最终仍返回 exit 65 / `TEST FAILED`，不能宣称全量测试通过。原始日志：`/tmp/starcat-follow-graph-all-tests.log`。

## 本机查看

在本 worktree 执行：

```bash
make run-direct
```

或以沙盒渠道验证：

```bash
make run-appstore
```

进入当前登录账户后，点击左侧「关注者」统计数字。首次会读取真实 following 关系；
后续重开优先读缓存，主动「继续加载」或「刷新」才继续网络请求。
本 worktree 的 `Configs/Secrets.xcconfig` 使用指向主工作区本机文件的忽略链接，不纳入 Git。

## 尚待验收与后续产品化

- 当前登录账户约 500 一级关注规模的真实请求与视觉验收尚未执行，不把算法测试当成真实网络性能结果。
- 5,000 / 10,000 节点 Canvas 帧率、头像内存、平移缩放延迟与窗口反复开关的资源释放仍需实测；已支持缩远普通节点降为圆点与稳定后暂停持续重绘。
- 重新打开重置视口、选中、查找及展示展开预算；关系缓存仍复用，不恢复旧布局。
- 当前查找采用输入后实时过滤与原生按钮键盘导航，不含专用上下方向键结果高亮状态机。
- 错误先通过全局状态与选中列表完整性呈现，逐用户详细失败状态和复杂重试队列仍可继续完善。
- 缓存按账户限制单份快照最多 20 MB，未实现跨账户总量淘汰。
- 明暗主题、窄窗口、长译文、Reduce Motion、键盘焦点与屏幕阅读器待人工验证；翻译尚未人工审核。

启动仅通过 `make run-direct`，没有执行 GUI 控制、推送、合并或发布；没有修改功能实现总览与 Changelog。2026-11-06 按 dong4j 授权，先提交 MVP 基础，再将路径流水与逐个弹出分别提交。


## 画布五项优化（2026-11-06）

- 分批提交重开初始化 / 空白取消、头像过渡 / 连接数尺寸、性能优化。关系线命中原先吞掉背景回调，已接入统一取消；重开不再沿用旧视口及手动展开投影。
- 头像渐入 280ms，节点尺寸由已加载连接数决定；命中、碰撞和流水端点统一，Reduce Motion 直接替换。
- `make test` 指定图谱及 OwnerCardSocialLinks 的 5 个 suite：35 项通过（0.285 秒），日志 `/tmp/starcat-graph-canvas-tests.log`。JS 13 项通过，涵盖头像过渡、尺寸、线命中、稳定路径、环路与关系删除后路径重算。
- 合成 CPU 基准（队列初始化中位数，ms）：1,000 节点 / 2,986 边从 5.60 降至 0.77；5,000 / 14,986 从 28.62 降至 3.15；10,000 / 29,986 从 56.27 降至 5.45。同机同数据，预热 2 次后 7 次采样；主要优化为复用数字排序器，另复用 BFS 父节点树避免每次点击重新排序整图。
- 此基准不代表实际 Canvas FPS 或 GUI 验收；缩放重开、头像渐入、密集区域点击以及明暗主题仍需人工查看。未改用户缓存、数据库或全局图谱加载预算。
- 双渠道 `make build-appstore` / `make build-direct` 构建及产物校验通过，三份离线资源逐字节一致。日志 `/tmp/starcat-graph-canvas-appstore.log`、`/tmp/starcat-graph-canvas-direct.log`；未新增文案或修改 Catalog。

## 首帧与加载完成跳变修复（2026-11-06）

- 首帧修复提交 `9fc901a6`：先 open 再挂载 WebView，避免初次创建后立即重建；透明 WebKit / HTML 底色与统一主题背景避免空白页面露出。带主题的本人节点真实绘制后，JS 发送单次 presented，原生淡入 120ms；Reduce Motion 直接显示。重开与重载均重置可见状态，保留错误入口。
- 镜头修复：初始中心为本人、缩放固定 0.8；移除布局停止和完成后的自动 fit。逐步加载、头像到达和数据批次不移动镜头，只有主动重置适配全图；定位继续响应用户指令。为避免组件在 1 倍缩放时自动 re-zoom，数据更新前保存当前镜头，在布局更新后、绘制前按需恢复，不产生每帧无意义的原生 viewport 消息。
- 原生相关 5 个 suite、35 项测试通过（0.281 秒），覆盖重开及重载时清空首帧可见状态；日志 `/tmp/starcat-graph-opening-tests.log`。JS 16 项通过，新增主题 / 真实绘制帧门控、加载完成不适配、后续批次 / 头像 / ResizeObserver 不适配、模拟库自动缩放后恢复，以及主动重置 / 定位仍有效。
- 测试使用 Canvas 库替身，未执行桌面控制、截图或真实 WebKit 视觉验收；闪烁与镜头连续性的最终观感需人工确认。未改数据加载预算、账户缓存、数据库、全语言文案、功能实现总览或 Changelog。
- `make build-appstore` / `make build-direct` 构建及产物校验通过；两渠道的 JS、HTML、许可证三份资源与源码逐字节一致。日志 `/tmp/starcat-graph-opening-appstore.log`、`/tmp/starcat-graph-opening-direct.log`；`git diff --check` 通过。

## 头像持久缓存接入（2026-11-06）

- 原实现每次创建 nonPersistent WebView，页面 Map 与 Image 请求随关闭丢失；关系 JSON 只有头像地址，不包含图片。现通过受控 scheme 读取原生 `ImageCache.default`，保留重开初始化画布行为，头像独立复用。
- 64px 地址复用 `GitHubAvatarURL`，原生相同 URL / 尺寸缓存可互通；本地探测并发 8、下载并发 4，预取本人及后续 16 个待展示节点。缓存命中直接显示，真正下载后渐入；本人首帧只等待本地探测，未命中不等待网络。不同尺寸、已过期或未落盘的历史图片仍需要下载。
- 新增缓存及 handler 回归，使用临时目录和可控下载器，验证首次 miss 零网络、首次下载、重建实例后断网命中、原生缓存键互通、过期及损坏重下、失败不落盘，以及 stop / 拆除后的迟到结果不交付、不落盘。
- `make test` 指定 8 个相关 suite 通过：Swift Testing 40 项 / 7 suite，XCTest 10 项；日志 `/tmp/starcat-follow-graph-avatar-tests.log`。首次测试夹具使用 `.expired` 写入模拟过期，但 Kingfisher 对此直接 no-op，已改为新 key 的短 TTL 到期，并确认回归通过。
- JS 19 项通过，覆盖缓存命中不渐入、下载渐入、独立并发和限量预取、旧请求清理，以及既有首帧、路径、视角、大小与渐进展示。离线 bundle 重建成功，30 个运行时依赖许可证保持一致。
- 以上是离线缓存及 delegate / Canvas 替身测试，不代表真实屏幕观感或 FPS 验收；未控制桌面、修改用户缓存或触发真实关注请求。无新增文案、数据库、功能实现总览或 Changelog 修改。
- 双渠道 `make build-appstore` / `make build-direct` 及产物校验通过，包内 HTML、JS、许可证均与源码逐字节一致。日志 `/tmp/starcat-follow-graph-avatar-appstore.log`、`/tmp/starcat-follow-graph-avatar-direct.log`。

## 卡片头像同步与下载并发（2026-11-06）

- 原节点仅查 64px 完整 URL，卡片使用 224px，且二者没有完成通知；同用缓存目录仍可能重复下载。现节点探测同用户、同版本的常用较大尺寸，命中后补齐节点 key；卡片成功先复用实际 URL 的内存 / 磁盘图片，再发送轻量 avatarReady 事件刷新对应节点。
- 卡片通知校验原画布 revision 与当前选中 ID，重复成功去重；JS 取消旧节点图片请求并重新探测，旧关系批次不能覆盖本会话卡片的新头像地址。整图、镜头与布局不重建。
- 图谱头像下载上限改为 8，本地探测独立保持 8。选中节点排到队首，保持总上限，不抢占其它节点的在途请求；失败后再次点击才重试，不在每帧自动重试。重试 attempt 不进入原生缓存键。
- 并发评估：小头像沿用现有超时、取消、限量预取，8 个请求可控；关系 API 并发保持 4。离线队列回归验证同时不超过 8 张、选中项优先和本地读取不受慢下载阻塞，不把并发翻倍当成真实下载耗时减半。
- JS 23 项通过，包括旧回调拒绝、卡片通知不移动镜头、刷新后旧数据不覆盖头像，以及既有首帧、路径、渐入、大小和销毁回归。原生相关 8 个 suite 通过：42 项 Swift Testing / 7 suite 与 10 项 XCTest；日志 `/tmp/starcat-follow-graph-avatar-sync-tests.log`。
- 未控制桌面、读取屏幕或宣称真实 CDN 性能已验收；无新增文案、数据库、功能实现总览或 Changelog 修改。
- 双渠道构建、产物校验及包内 HTML / JS / 许可证逐字节核验通过；日志 `/tmp/starcat-follow-graph-avatar-sync-appstore.log`、`/tmp/starcat-follow-graph-avatar-sync-direct.log`。最终原生回归包含切走再选回后可重新通知，保持 42 + 10 项全部通过。


## Followers 图谱视觉优化（2026-11-09）

- 在 `codex/followers-graph` worktree 实施，未修改主工作区：`680f1858` 弱化邻接线与固定尺寸开口方向标记；`5d263e60` 青绿流光、渐隐拖尾、到达轮廓及切换淡出；`494e76d5` 资料卡底部压缩为两行；`9dc5da6a` 刷新 / 停止共用按钮，支持悬停和键盘焦点。
- JS 27 项通过，新增缩放后的方向标记尺寸、密集节点箭头抑制、渐隐拖尾和取消后停止调度回归；既有 Followers / Following 方向、头像缓存、渐进展示与镜头保护保持通过。日志 `/tmp/starcat-followers-ui-js.log`。
- 原生相关 41 项 / 5 suites 通过，日志 `/tmp/starcat-followers-ui-tests.log`。`make build-appstore`、`make build-direct` 及产物校验通过，两渠道图谱 HTML / JS / 许可证与源码逐字节一致；日志 `/tmp/starcat-followers-ui-appstore.log`、`/tmp/starcat-followers-ui-direct.log`。
- 沿用现有本地化 key，无新增文案或依赖。未修改总览、Changelog、数据采集预算或用户缓存。未执行 GUI 自动化；以上回归不代替箭头密度、流光观感、长路径布局与鼠标 / 键盘交互的人工验收。


## 箭头回到目标节点（2026-11-09）

- 根据 dong4j 人工反馈，将开口箭头由线段内部移到真实 target 头像外沿，尖端间距保持屏幕 3pt、长度保持 6pt；保留密集节点方向标记控制、弱化连线和青绿流光。
- JS 28 项通过，新增两种探索方向下斜向边的目标半径 / 间距 / 箭头朝向校验，并校验缩放后的屏幕尺寸；日志 `/tmp/starcat-followers-arrow-rim-tests.log`。
- 双渠道构建及产物校验通过，两渠道 HTML / JS / 许可证与源码逐字节一致；日志 `/tmp/starcat-followers-arrow-rim-appstore.log`、`/tmp/starcat-followers-arrow-rim-direct.log`。本次仅修改 Canvas 与相关规格，无 Swift 或本地化改动；未重复原生单测，未执行 GUI 自动化，观感仍待人工验收。


## 单行加载数量与工具栏收敛（2026-11-09）

- 卡片状态改为单行“已加载 X / Y 人”，X 仅计当前展示投影中该用户对应方向的直接关系，Y 优先取分页总数、否则取已取得的资料卡对应人数；未知总数只显示 X，真实 0 保留。完整性仍依据分页游标；过长数量截断，悬停保留完整数量和状态。
- 删除独立继续按钮及无用 resume 方法，顶部只剩刷新 / 停止、重置视角、本人定位。首次分页前停止或失败可从刷新恢复；两种图谱的本人首层均完整刷新，二层继续限制在展示预算。
- 原生相关 46 项 / 5 suites 全部通过，包含两方向计数、投影预算、未知 / 零总数、数量相等不代表完整，以及空分页状态 / 首层中断后的刷新恢复；日志 `/tmp/starcat-followers-count-tests.log`。
- 两条新增数量文案补齐 AppLocale 与 locales.json 一致的全部 17 语言，参数及占位符通过，原 Catalog 条目未改、仅新增 216 行，AI needs_review 保留。数字显式注入环境 locale。
- `make build-appstore`、`make build-direct` 及产物校验通过。两渠道图谱资源逐字节匹配，两条文案的 17 语言编译 strings 均与 Catalog 一致；日志 `/tmp/starcat-followers-count-appstore.log`、`/tmp/starcat-followers-count-direct.log`。
- 未执行 GUI 自动化，未新增依赖或修改数据库、功能总览与 Changelog；长语言 / 大字号下的真实视觉观感与译文仍待人工验收。
