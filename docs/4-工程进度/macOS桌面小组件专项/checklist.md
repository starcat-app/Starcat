# macOS 桌面小组件专项 Checklist

> 状态：实施中
>
> 基线：`dev@aa135b7e899b209c6e074d0b4821dc302d40b8cc`
>
> 分支：`codex/macos-widget`
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
- [ ] 确认未修改 `docs/功能实现总览.md`
  - 证据：最终 `git diff dev...HEAD -- docs/功能实现总览.md` 无输出

---

## 1. 阶段 0：双渠道工程与签名门禁

- [ ] `project.yml` 新增 `StarcatWidgets` target
- [ ] `project.yml` 新增 `StarcatDirectWidgets` target
- [ ] Store 主应用只嵌入 Store Widget Extension
- [ ] Direct 主应用只嵌入 Direct Widget Extension
- [ ] 两个 Extension 复用同一份业务源码
- [ ] Store Host / Extension 配置同一 Store App Group
- [ ] Direct Host / Extension 配置同一 Direct App Group
- [ ] 两个 Widget Info.plist 均声明 `com.apple.widgetkit-extension`
- [ ] `xcodegen generate` 成功
- [ ] `Starcat` Debug 构建成功
- [ ] `StarcatDirect` Debug 构建成功
- [ ] Store `.app` 只包含 Store `.appex`
- [ ] Direct `.app` 只包含 Direct `.appex`
- [ ] `codesign` 验证 Store Host / Extension App Group 一致
- [ ] `codesign` 验证 Direct Host / Extension App Group 一致

---

## 2. 共享快照契约

- [ ] 新增 `WidgetSnapshot` v1 顶层模型
- [ ] 新增 `WidgetAccountState`
- [ ] 新增最小化 `WidgetRepository`
- [ ] 新增最小化 `WidgetRelease`
- [ ] 模型遵循 `Codable`、`Equatable`、`Sendable`
- [ ] 快照不包含 Token、Keychain key、Local API Key
- [ ] 快照不包含笔记、RAG chunk、对话
- [ ] 快照默认排除 Private repository
- [ ] description、tags、列表条数都有上限
- [ ] 更高 schema version 可恢复降级

---

## 3. 快照存储与用户隔离

- [ ] 渠道配置从 Info.plist 读取，不猜测容器
- [ ] App Group 容器缺失时返回明确错误
- [ ] 快照使用临时文件 + 原子替换
- [ ] 损坏快照不会使 Extension 崩溃
- [ ] 文件不存在显示 preparing
- [ ] 登出先写 signedOut 空快照
- [ ] 用户切换先写 preparing 空快照
- [ ] 新用户数据库就绪后才发布 ready 快照
- [ ] 发布后调用 `WidgetCenter.reloadAllTimelines()`
- [ ] 测试环境不会触发真实系统容器或刷新副作用

---

## 4. 业务投影与刷新

- [ ] Focus 候选按指定 / 置顶 / using 优先
- [ ] Focus 按 repo ID 去重并限制 6 条
- [ ] 今日重逢过滤 archived、Private、近 30 天、置顶和 using
- [ ] 今日重逢同一账号同一天选择稳定
- [ ] 今日重逢空候选可恢复
- [ ] Release Watch 只取已订阅且未读 Release
- [ ] Release Watch 排除 Private repository
- [ ] Release Watch 未读总数与列表过滤口径一致
- [ ] 快照刷新覆盖启动恢复、Stars 同步、置顶、状态、标签、Release
- [ ] 高频刷新信号被合并，避免重复全量构建

---

## 5. 头像缓存

- [ ] Widget Extension 不发起网络请求
- [ ] 主应用只接受 GitHub HTTPS owner avatar
- [ ] 下载设置超时和 2 MB 响应上限
- [ ] 图片解码校验通过后才写入缓存
- [ ] 头像缓存使用临时文件 + 原子替换
- [ ] 快照只保存头像相对路径
- [ ] 缓存失败使用内置 fallback
- [ ] 退出登录清理共享头像
- [ ] 清理未引用头像并限制缓存总量

---

## 6. Starcat Focus

- [ ] 提供 Small / Medium / Large
- [ ] Small 展示一个仓库
- [ ] Medium 最多展示三个仓库
- [ ] Large 最多展示六个仓库
- [ ] 支持自动选择与指定仓库配置
- [ ] 每行展示 owner avatar、仓库名与来源状态
- [ ] 空态可点击打开 Starcat
- [ ] 每个仓库可点击打开对应详情

---

## 7. 今日重逢

- [ ] 提供 Small / Medium
- [ ] Small 展示头像、名称、语言
- [ ] Medium 增加描述、Star 数和标签
- [ ] 当天 Timeline 刷新不更换候选
- [ ] 次日 00:05 后请求新 Timeline
- [ ] 空态可点击打开 Starcat
- [ ] 仓库可点击打开对应详情

---

## 8. Release Watch

- [ ] 提供 Medium / Large
- [ ] Medium 最多展示三条
- [ ] Large 最多展示六条
- [ ] 展示未读总数、tag、仓库、时间和 prerelease
- [ ] 无未读 Release 时显示明确空态
- [ ] Release 行可点击打开仓库 Release 区域
- [ ] Release ID 不存在时降级到仓库 Release 区域

---

## 9. Deep Link、安全与 UI 规范

- [ ] 仓库点击复用 `RepositoryDeepLink`
- [ ] 新增 Release Deep Link 编码与解析
- [ ] 拒绝非 Starcat / 非受信任 Universal Link
- [ ] 拒绝无效 repo ID / release ID
- [ ] 冷启动导航保留 pending request
- [ ] 所有 Widget 使用 `containerBackground(for: .widget)`
- [ ] 文本和图标只使用 `.primary` / `.secondary`
- [ ] 固定文案进入 `Localizable.xcstrings`
- [ ] 所有交互元素有 VoiceOver label
- [ ] 深色、浅色模式信息可读

---

## 10. 自动化测试

- [ ] snapshot v1 encode / decode
- [ ] 更高 schema、损坏和缺失文件降级
- [ ] 原子写入及临时文件清理
- [ ] signedOut / preparing 不携带业务数据
- [ ] Private repository 过滤
- [ ] Focus 优先级、去重和上限
- [ ] 今日重逢过滤、稳定性和空候选
- [ ] Release 订阅、未读、隐私过滤和排序
- [ ] Deep Link 正常与非法输入
- [ ] Store / Direct 渠道配置
- [ ] Widget 相关定向测试通过
- [ ] Starcat 全量测试通过

---

## 11. 构建、签名与真机验收

- [ ] `git diff --check` 通过
- [ ] `xcodegen generate` 后工程无未预期漂移
- [ ] Store Debug build 通过
- [ ] Direct Debug build 通过
- [ ] Store Host / Extension 签名与 App Group 检查通过
- [ ] Direct Host / Extension 签名与 App Group 检查通过
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

- [ ] 第一轮审查报告先落档并提交
- [ ] 第一轮发现的问题全部修复并提交
- [ ] 第二轮审查报告先落档并提交
- [ ] 第二轮发现的问题全部修复并提交
- [ ] 第三轮审查报告先落档并提交
- [ ] 第三轮没有未关闭 P0/P1
- [ ] 如第三轮仍有问题，继续审查直至关闭
- [ ] 文档、代码、测试、工程进度和 checklist 一致
- [ ] 所有 checklist 项均有真实证据
- [ ] 新增并提交最终结果报告
- [ ] 最终分支无未提交改动
- [ ] 全程未 push

---

## 13. 提交记录

| Commit | 类型 | 内容 | 验证 |
|--------|------|------|------|
| `afd99a2` | 文档 | 迁入两篇初步方案 | `git diff --check` |
| `b0cfaa4` | 文档 | 新增详细落地方案 | `git diff --check` |

后续每次提交后立即追加本表；审查时以 `git log --reverse dev..HEAD` 反向核对。
