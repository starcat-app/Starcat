# macOS 桌面小组件专项 Checklist

> 状态：自动化与签名门禁完成，人工桌面验收中
>
> 基线：`dev@aa135b7e899b209c6e074d0b4821dc302d40b8cc`
>
> 开发分支：`codex/macos-widget`；当前状态：已合并到 `dev`
>
> 约束：每个小功能单独提交，不 push；所有勾选必须有代码、命令输出、产物检查、截图或
> 审查报告作为证据。
>
> 方案：[macOS 桌面小组件详细落地方案](../../3-设计/详细设计/56-macOS桌面小组件详细落地方案.md)

---

## 0. 开工与文档

- [x] 基于最后一个 `dev` 提交创建独立 worktree，不影响当前开发工作区
  - 证据：`codex/macos-widget@aa135b7e`，`git worktree list`
- [x] 迁入外部应用扩展与桌面小组件两篇初步方案
  - 证据：commit `afd99a2`
- [x] 新增开发者可直接执行的详细落地方案
  - 证据：commit `b0cfaa4`
- [x] 建立本专项 checklist
  - 证据：本文件对应提交
- [x] 确认未修改 `docs/功能实现总览.md`
  - 证据：最终 `git diff dev...HEAD -- docs/功能实现总览.md` 无输出

---

## 1. 阶段 0：双渠道工程与签名门禁

- [x] `project.yml` 新增 `StarcatWidgets` target
- [x] `project.yml` 新增 `StarcatDirectWidgets` target
- [x] Store 主应用只嵌入 Store Widget Extension
- [x] Direct 主应用只嵌入 Direct Widget Extension
- [x] 两个 Extension 复用同一份业务源码
- [x] Store Host / Extension 配置同一 Store App Group
- [x] Direct Host / Extension 配置同一 Direct App Group
- [x] 两个 Widget Info.plist 均声明 `com.apple.widgetkit-extension`
- [x] `xcodegen generate` 成功
- [x] `Starcat` Debug 构建成功
  - 证据：`CODE_SIGNING_ALLOWED=NO` 构建通过，签名门禁单列保留
- [x] `StarcatDirect` Debug 构建成功
  - 证据：`CODE_SIGNING_ALLOWED=NO` 构建通过，签名门禁单列保留
- [x] Store `.app` 只包含 Store `.appex`
  - 证据：仅 `StarcatWidgets.appex`，bundle id 为 `com.starcat.app.store.widgets`
- [x] Direct `.app` 只包含 Direct `.appex`
  - 证据：仅 `StarcatDirectWidgets.appex`，bundle id 为 `com.starcat.app.direct.widgets`
- [x] `codesign` 验证 Store Host / Extension App Group 一致
  - 证据：Team `8WCUMGCWMB`，两者均为 `group.com.starcat.app.store.widgets`，
    `codesign --verify --deep --strict` 通过
- [x] `codesign` 验证 Direct Host / Extension App Group 一致
  - 证据：Team `8WCUMGCWMB`，两者均为 `group.com.starcat.app.direct.widgets`，
    `codesign --verify --deep --strict` 通过

> 签名阻断已于 2026-07-30 解除：Store / Direct 全新 DerivedData 构建均使用
> `Apple Development: liwen gong (MZ4R5J393K)`，Host / Extension 的 Team、App Group
> 和 `CFBundleVersion=2291` 一致。

---

## 2. 共享快照契约

- [x] 新增 `WidgetSnapshot` v1 顶层模型
- [x] 新增 `WidgetAccountState`
- [x] 新增最小化 `WidgetRepository`
- [x] 新增最小化 `WidgetRelease`
- [x] 模型遵循 `Codable`、`Equatable`、`Sendable`
- [x] 快照不包含 Token、Keychain key、Local API Key
- [x] 快照不包含笔记、RAG chunk、对话
- [x] 快照默认排除 Private repository
- [x] description、tags、列表条数都有上限
- [x] 更高 schema version 可恢复降级

> 证据：`ffb242c1`、`02878bce`、`WidgetSnapshotStoreTests`、
> `WidgetSnapshotBuilderTests`。

---

## 3. 快照存储与用户隔离

- [x] 渠道配置从 Info.plist 读取，不猜测容器
- [x] App Group 容器缺失时返回明确错误
- [x] 快照使用临时文件 + 原子替换
- [x] 损坏快照不会使 Extension 崩溃
- [x] 文件不存在显示 preparing
- [x] 登出先写 signedOut 空快照
- [x] 用户切换先写 preparing 空快照
- [x] 新用户数据库就绪后才发布 ready 快照
- [x] 发布后调用 `WidgetCenter.reloadAllTimelines()`
- [x] 测试环境不会触发真实系统容器或刷新副作用

> 证据：`2fae33b5`、`b30bbb68`、`7a97c345`、`WidgetSnapshotStoreTests`。

---

## 4. 业务投影与刷新

- [x] Focus 候选按指定 / 置顶 / using 优先
- [x] Focus 按 repo ID 去重并限制 6 条
- [x] 今日重逢过滤 archived、Private、近 30 天、置顶和 using
- [x] 今日重逢同一账号同一天选择稳定
- [x] 今日重逢空候选可恢复
- [x] Release Watch 只取已订阅且未读 Release
- [x] Release Watch 排除 Private repository
- [x] Release Watch 未读总数与列表过滤口径一致
- [x] 快照刷新覆盖启动恢复、Stars 同步、置顶、状态、标签、Release
- [x] 高频刷新信号被合并，避免重复全量构建

> 证据：`02878bce`、`b30bbb68`、`09e739ff`、`WidgetSnapshotBuilderTests`。

---

## 5. 头像缓存

- [x] Widget Extension 不发起网络请求
- [x] 主应用只接受 GitHub HTTPS owner avatar
- [x] 下载设置超时和 2 MB 响应上限
- [x] 图片解码校验通过后才写入缓存
- [x] 头像缓存使用临时文件 + 原子替换
- [x] 快照只保存头像相对路径
- [x] 缓存失败使用内置 fallback
- [x] 退出登录清理共享头像
- [x] 清理未引用头像并限制缓存总量

> 证据：`b1bc4bc1`、`20e55708`。

---

## 6. Starcat Focus

- [x] 提供 Small / Medium / Large
- [x] Small 展示一个仓库
- [x] Medium 最多展示三个仓库
- [x] Large 最多展示六个仓库
- [x] 支持自动选择与指定仓库配置
- [x] 每行展示 owner avatar、仓库名与来源状态
- [x] 空态可点击打开 Starcat
- [x] 每个仓库可点击打开对应详情

> 证据：`1548a5dd`，Store / Direct unsigned build 均通过。

---

## 7. 今日重逢

- [x] 提供 Small / Medium
- [x] Small 展示头像、名称、语言
- [x] Medium 增加描述、Star 数和标签
- [x] 当天 Timeline 刷新不更换候选
- [x] 次日 00:05 后请求新 Timeline
- [x] 空态可点击打开 Starcat
- [x] 仓库可点击打开对应详情

> 证据：`6ae7de3d`、`WidgetSnapshotBuilderTests`。

---

## 8. Release Watch

- [x] 提供 Medium / Large
- [x] Medium 最多展示三条
- [x] Large 最多展示六条
- [x] 展示未读总数、tag、仓库、时间和 prerelease
- [x] 无未读 Release 时显示明确空态
- [x] Release 行可点击打开仓库 Release 区域
- [x] Release ID 不存在时降级到仓库 Release 区域

> 证据：`82edec6b`、`7a7be021`、`09e739ff`。

---

## 9. Deep Link、安全与 UI 规范

- [x] 仓库点击复用 `RepositoryDeepLink`
- [x] 新增 Release Deep Link 编码与解析
- [x] 拒绝非 Starcat / 非受信任 Universal Link
- [x] 拒绝无效 repo ID / release ID
- [x] 冷启动导航保留 pending request
- [x] 所有 Widget 使用 `containerBackground(for: .widget)`
- [x] 文本和图标只使用 `.primary` / `.secondary`
- [x] 固定文案进入 `Localizable.xcstrings`
- [x] 所有交互元素有 VoiceOver label
- [ ] 深色、浅色模式信息可读

> 证据：`7a7be021`、`f23c2b24`；深浅色最终项保留给已签名安装后的人工验收。

---

## 10. 自动化测试

- [x] snapshot v1 encode / decode
- [x] 更高 schema、损坏和缺失文件降级
- [x] 原子写入及临时文件清理
- [x] signedOut / preparing 不携带业务数据
- [x] Private repository 过滤
- [x] Focus 优先级、去重和上限
- [x] 今日重逢过滤、稳定性和空候选
- [x] Release 订阅、未读、隐私过滤和排序
- [x] Deep Link 正常与非法输入
- [x] Store / Direct 渠道配置
- [x] Widget 相关定向测试通过
  - 证据：29 tests，0 failures，0 skipped
- [x] Starcat 全量测试通过
  - 证据：2076 tests，2067 passed，0 failures，8 skipped，1 expected failure

---

## 11. 构建、签名与真机验收

- [x] `git diff --check` 通过
- [x] `xcodegen generate` 后工程无未预期漂移
- [x] Store Debug build 通过
- [x] Direct Debug build 通过
- [x] Store Host / Extension 签名与 App Group 检查通过
  - 证据：bundle ID 为 `com.starcat.app.store` / `com.starcat.app.store.widgets`，
    App Group 为 `group.com.starcat.app.store.widgets`
- [x] Direct Host / Extension 签名与 App Group 检查通过
  - 证据：bundle ID 为 `com.starcat.app.direct` / `com.starcat.app.direct.widgets`，
    App Group 为 `group.com.starcat.app.direct.widgets`
- [ ] Widget Gallery 出现三个组件
- [ ] 所有声明尺寸均可添加到桌面
- [ ] 真实数据、头像、空态符合方案
- [ ] 仓库点击前台 / 冷启动定位正确
- [ ] Release 点击前台 / 冷启动定位正确
- [ ] 登出后桌面不显示旧数据
- [ ] 切换账号不显示上一账号数据
- [ ] Store / Direct 同时安装时不串数据、不串宿主
- [ ] 深色、浅色、VoiceOver 人工验收通过

---

## 12. 多轮审查与收口

- [x] 第一轮审查报告先落档并提交
  - 证据：commit `7d063b5`
- [x] 第一轮发现的问题全部修复并提交
  - 证据：commits `1d22dde` 至 `d12122d`
- [x] 第二轮审查报告先落档并提交
  - 证据：commit `862fedb`
- [x] 第二轮发现的问题全部修复并提交
  - 证据：commits `cc4bd22`、`74b1d63`、`d15a900`
- [x] 第三轮审查报告先落档并提交
  - 证据：commit `4690484`
- [x] 第三轮没有未关闭 P0/P1
  - 证据：第三轮审查结论为 P0 / P1 / P2 均为 0
- [x] 如第三轮仍有问题，继续审查直至关闭
  - 证据：第三轮未发现新问题，无需追加第四轮修复
- [x] 文档、代码、测试、工程进度和 checklist 一致
  - 证据：第三轮审查报告第 3、4 节
- [x] 第四轮签名与调试增量审查报告先落档并提交
  - 证据：commit `176be40`
- [x] 第四轮签名阻断、调试入口与运行时问题完成修复
  - 证据：commits `3917714`、`61034a2`、`f5a102e`、`60246d0`
- [x] 第五轮修复后复审无新增 P0 / P1 / P2
  - 证据：commit `c0c8760`，第一轮 Clean
- [x] 第六轮最终复审无新增 P0 / P1 / P2
  - 证据：commit `e0ec026`，第二轮连续 Clean
- [ ] 所有 checklist 项均有真实证据
- [ ] 新增并提交最终结果报告
- [x] 最终分支无未提交改动
  - 证据：本次进度提交完成后 `git status --porcelain` 无输出
- [x] 全程未 push
  - 证据：仅保留本地分支 `codex/macos-widget`

---

## 13. 提交记录

| Commit | 类型 | 内容 | 验证 |
|--------|------|------|------|
| `afd99a2` | 文档 | 迁入两篇初步方案 | `git diff --check` |
| `b0cfaa4` | 文档 | 新增详细落地方案 | `git diff --check` |
| `45f21c5` | 文档 | 新增专项 checklist | `git diff --check` |
| `113b2e5` | 工程 | 新增双渠道 Widget target、App Group 和占位组件 | `xcodegen` + 双渠道 unsigned build + `.appex` 检查 |
| `7926a9f` | 文档 | 回填双渠道工程门禁进度 | `git diff --check` |
| `ffb242c` | 功能 | 添加版本化共享快照模型 | 双渠道 unsigned build |
| `2fae33b` | 功能 | 实现原子快照存储 | 双渠道 unsigned build |
| `02878bc` | 功能 | 实现小组件快照构建 | 双渠道 unsigned build |
| `b30bbb6` | 功能 | 接入小组件快照刷新协调器 | 双渠道 unsigned build |
| `b1bc4bc` | 功能 | 添加共享头像缓存 | 双渠道 unsigned build |
| `7a97c34` | 功能 | 添加小组件时间线加载基础设施 | 双渠道 unsigned build |
| `1548a5d` | 功能 | 实现 Starcat Focus 小组件 | 双渠道 unsigned build |
| `6ae7de3` | 功能 | 实现今日重逢小组件 | 双渠道 unsigned build |
| `82edec6` | 功能 | 实现 Release Watch 小组件 | 双渠道 unsigned build |
| `7a7be02` | 功能 | 完善 Release 深层链接 | 双渠道 unsigned build |
| `b2ee74f` | 测试 | 覆盖共享快照与渠道配置 | 定向测试通过 |
| `09e739f` | 修复 | 兼容 Release 时间格式 | 数据库投影测试通过 |
| `dd427cb` | 测试 | 覆盖数据库投影选择规则 | 定向测试通过 |
| `f23c2b2` | 测试 | 覆盖 Release 深层链接边界 | 定向测试通过 |
| `20e5570` | 测试 | 覆盖头像缓存安全边界 | 定向测试通过 |
| `1f2515b` | 文档 | 回填实现与测试进度 | `git diff --check` |
| `7d063b5` | 审查 | 新增第一轮审查报告 | 报告先于修复提交 |
| `1d22dde` | 修复 | 补齐 Focus 来源状态 | 双渠道 unsigned build |
| `7832d66` | 修复 | 修正空态应用路由 | 定向测试通过 |
| `7c0460b` | 修复 | 统一时间线恢复刷新策略 | 双渠道 unsigned build |
| `df9abce` | 修复 | 补齐小尺寸过期提示 | 双渠道 unsigned build |
| `b514399` | 修复 | 遵循链接焦点环规范 | 静态规范检查 |
| `d12122d` | 测试 | 强化账户隔离回归覆盖 | 定向测试通过 |
| `862fedb` | 审查 | 新增第二轮审查报告 | 报告先于修复提交 |
| `cc4bd22` | 修复 | 阻止旧账号快照越界发布 | 29 项 Widget 定向测试通过 |
| `74b1d63` | 修复 | 完善可访问性操作语义 | 双渠道 unsigned build |
| `d15a900` | 修复 | 补充快照降级诊断 | 双渠道 unsigned build |
| `76727db` | 文档 | 回填第二轮审查进度 | `git diff --check` |
| `4690484` | 审查 | 新增第三轮审查报告 | 29 项定向测试 + 2061 项全量测试 |
| `3917714` | 工程 | 固化 App Group 自动签名配置 | 双渠道签名构建 + entitlement 检查 |
| `61034a2` | 修复 | 同步宿主与扩展构建版本 | 双渠道 Host / Extension 均为 `2291` |
| `f5a102e` | 工程 | 添加三个组件调试 Scheme | `xcodebuild -list` + 三个 Scheme 构建 |
| `60246d0` | 修复 | 避免 Focus 占位列表重复身份 | Focus Scheme 构建通过 |
| `176be40` | 审查 | 新增第四轮签名与调试审查报告 | 报告先于文档修复提交 |
| `1ae18d2` | 文档 | 同步签名结果与独立调试入口 | `xcodegen` + Scheme 列表检查 |
| `c0c8760` | 审查 | 新增第五轮 Clean 复审报告 | 无新增 P0 / P1 / P2 |
| `883816a` | 文档 | 回填第五轮 Clean 审查进度 | `git diff --check` |
| `e0ec026` | 审查 | 新增第六轮最终 Clean 复审报告 | 29 项定向测试 + 2076 项全量测试 |

审查时继续以 `git log --reverse aa135b7e..HEAD -- <Widget 相关路径>` 反向核对；本表在
每轮审查后补齐新增提交。
