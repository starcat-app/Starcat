# 关注关系图谱 MVP 实施记录

> 状态：MVP 已实现，待真实账号与人工界面验收；未关闭专项\
> 日期：2026-11-05\
> 分支：`codex/follow-graph-mvp`\
> 基线：`dev` 的 `016ec9304fe54c2e3d44dfa5344960005ceabb26`\
> Worktree：`../Starcat-follow-graph-mvp`\
> 需求：[需求规格说明书](../2-产品/需求讨论/正式方案/关注关系图谱需求规格说明书.md)\
> 设计：[技术方案](../3-设计/详细设计/71-关注关系图谱技术方案.md)

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
