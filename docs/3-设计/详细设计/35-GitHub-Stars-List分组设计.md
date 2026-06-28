# GitHub Stars List 仓库分组设计

> 状态：2026-06-26 方案确认，进入实现。  
> 范围：Manage 侧边栏的「仓库分组」、GitHub Stars List 同步、本地缓存、repo 卡片右键分组操作。  
> 非范围：Smart Collections 规则系统、CloudKit 同步、旧 token / 旧 schema 兼容。

## 1. 背景与目标

GitHub Stars 页面支持把已 star 的仓库加入 List。这个能力和 Starcat 现有 Tags / Smart Collections 的语义不同：

- Tags 是 Starcat 私有整理数据，只存在本地 / CloudKit。
- Smart Collections 是 Starcat 规则视图，本质是动态查询结果。
- GitHub Stars List 是 GitHub 账号下的远端分组，需要与 GitHub 双向同步。

本次新增「仓库分组」的目标是：

1. 在 Manage →「全部仓库」下面新增「仓库分组」分区，同步 GitHub Stars List。
2. 支持创建、编辑、删除分组，并把改动同步到 GitHub。
3. 支持对 repo 执行添加到分组、移出分组、移动到另一个分组，并把改动同步到 GitHub。
4. 支持一个本地虚拟分组「未分组」，展示所有没有加入任何 GitHub List 的 starred repo。
5. 分组颜色只存在本地。GitHub 没有颜色字段；未选择颜色时按 `list.id` 做稳定 hash 得到颜色。

## 2. GitHub API 结论

GitHub Stars List 相关能力走 GraphQL API。当前已用 Starcat 登录 token 验证以下 mutation 可用：

- `createUserList`：创建 list，字段包含 name / description / isPrivate。
- `updateUserList`：编辑 list。
- `deleteUserList`：删除 list。注意 payload 只支持 `clientMutationId` 和 `user`，不能查询 `list` 字段。
- `updateUserListsForItem`：为某个 starrable item 设置完整 list 集合。它是“替换式写入”，不是增量 add/remove。

GitHub 网页上的 `https://github.com/stars/{login}/list-check?...` 是 Web 私有接口；用 OAuth Bearer 调用返回 404，本功能不依赖它。

## 3. 数据模型

### 3.1 `github_star_lists`

保存 GitHub List 元数据和 Starcat 本地颜色。

```sql
CREATE TABLE github_star_lists (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  is_private INTEGER NOT NULL DEFAULT 0,
  color_hex TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0,
  created_at TEXT,
  updated_at TEXT,
  synced_at TEXT NOT NULL
);
```

关键约束：

- `id` 使用 GitHub GraphQL node id，不能自造本地 id。
- `color_hex` 是本地字段。创建或首次同步时，如果用户没有选择颜色，用 `list.id` 稳定 hash 到项目现有标签色板。
- `position` 使用远端列表顺序写入，侧边栏按 `position ASC, name ASC` 排序。
- 不为“未分组”建真实记录；它是查询视图。

### 3.2 `repo_github_star_lists`

保存 repo 与 GitHub List 的多对多关系。

```sql
CREATE TABLE repo_github_star_lists (
  repo_id INTEGER NOT NULL,
  list_id TEXT NOT NULL,
  PRIMARY KEY (repo_id, list_id),
  FOREIGN KEY (repo_id) REFERENCES repos(id) ON DELETE CASCADE,
  FOREIGN KEY (list_id) REFERENCES github_star_lists(id) ON DELETE CASCADE
);
```

关键约束：

- 不在 `repos` 表加单个 `group_id`。GitHub List 是多对多，一个 repo 可以在多个 List 中。
- `未分组` 查询条件是 starred repo 且不存在任何 `repo_github_star_lists` 记录。

## 4. 同步策略

### 4.1 触发时机

仓库分组同步与 starred repo 同步相互独立，但 UI 上需要一致：

1. App 启动 / 登录恢复后，正常刷新 sidebar 时拉取本地缓存。
2. stars 同步完成后触发一次 GitHub List 同步，确保新增 star 的 list membership 被补齐。
3. 用户手动创建 / 编辑 / 删除 list 或修改 repo membership 后，先调用 GitHub mutation 成功，再写本地缓存并刷新 sidebar。

### 4.2 拉取内容

同步服务从 GitHub GraphQL 拉取当前用户的 Lists，并展开每个 List 下的 items：

- list metadata：`id / name / description / isPrivate / createdAt / updatedAt`
- list items：`id / owner / name`

本地写入采用“远端快照覆盖”：

1. upsert `github_star_lists`。
2. 删除本次远端不存在的 list。
3. 以远端 list items 重建 `repo_github_star_lists`。

对 item 到本地 repo 的映射优先用 `owner/name` 对应 `repos.full_name`，只处理 Starcat 已缓存且仍为 starred 的 repo。远端出现但本地还没有的 repo 不单独创建，因为 starred repo 同步才是 repo 缓存的唯一来源。

### 4.3 本地写入顺序

所有用户主动操作都遵循同一事务顺序：

1. 调 GitHub GraphQL mutation。
2. mutation 成功后，根据 GitHub 返回的 list / item lists 写本地表。
3. 刷新 `HomeViewModel` 的 sidebar 分组、计数和当前列表。

如果 GitHub mutation 失败，本地不做乐观写入，避免 UI 显示与 GitHub 不一致。

## 5. UI 设计

### 5.1 Sidebar

Manage 分区顺序：

1. 全部仓库
2. 仓库分组
   - 未分组（虚拟分组，首位）
   - GitHub List 1
   - GitHub List 2
3. 现有其它 Manage items

「仓库分组」header 右侧提供新增按钮，设计形式与 Tags 右侧 `+` 保持一致。每个真实分组 item 右侧提供编辑按钮，设计形式与新增按钮一致；「未分组」没有编辑按钮。

计数：

- 真实分组：该 list 下本地已缓存 starred repo 数量。
- 未分组：所有 starred 且不属于任何 GitHub List 的 repo 数量。

### 5.2 创建 / 编辑分组

使用一个 `GitHubStarListEditorSheet`：

- name：必填，trim 后非空。
- description：可空。
- private：布尔字段，同 GitHub。
- color：可选。如果用户不选，创建成功后用返回的 `list.id` hash 得到默认颜色。

编辑已有分组时允许修改 name / description / private / color。颜色只写本地，不上传 GitHub。

### 5.3 删除分组

真实分组编辑入口中提供删除操作：

- 需要二次确认。
- 删除成功后 GitHub 会移除该 list，repo 的 membership 也随之消失。
- 本地删除 `github_star_lists`，依赖外键级联清理 `repo_github_star_lists`。

### 5.4 Repo 卡片右键菜单

右键菜单根据当前列表上下文决定可见动作：

- 非「仓库分组」分类：显示「添加到...」。
- 「仓库分组 / 未分组」：显示「添加到...」。
- 具体 GitHub List：显示「移出分组」和「移动到...」，不显示「添加到...」。

行为语义：

- 添加到：把当前 repo 加入选择的目标 list，保留它已有的其它 list。
- 移出分组：只从当前 list 移除，保留它已有的其它 list。
- 移动到：从当前 list 移除并加入目标 list，保留它已有的其它 list。

由于 GitHub 的 `updateUserListsForItem` 是替换式写入，执行这些动作前必须基于本地最新 membership 计算完整目标 list id 集合。

## 6. 查询与 ViewModel 接入

`RepoListScope` 新增两类 scope：

- `githubStarList(id: String)`
- `githubStarListUngrouped`

Repository 查询：

- `githubStarList(id:)`：`EXISTS repo_github_star_lists WHERE repo_id = repos.id AND list_id = ?`
- `githubStarListUngrouped`：`NOT EXISTS repo_github_star_lists WHERE repo_id = repos.id`

`SidebarItem` 新增：

- `.githubStarListUngrouped`
- `.githubStarList(id: String)`

持久化选择值需要支持这两个 case；如果本地缓存中目标 list 已不存在，则恢复到 `.allStars`。

## 7. 错误与边界

- GitHub List 为空：分组仍显示，计数为 0。
- repo 在多个 list：多个分组都显示该 repo，未分组不显示。
- GitHub mutation 成功但本地写入失败：显示错误，下一次同步会以 GitHub 为准修复。
- 本地 list 颜色：远端不会覆盖已有颜色；只有首次见到 list 时生成默认颜色。
- 产品未上线：直接修改 v1 schema，不写旧字段兼容和迁移分支。

## 8. 测试计划

优先覆盖以下单元测试：

1. `GitHubStarListRepositoryTests`
   - upsert list 并保持已有颜色。
   - replace memberships 后计数正确。
   - 未分组计数正确。
2. `RepoRepositoryTests`
   - `githubStarList(id:)` scope 查询正确。
   - `githubStarListUngrouped` scope 查询正确。
3. `HomeViewModel` 相关测试
   - sidebar 能加载分组和未分组。
   - 当前选择为已删除 list 时回落到全部仓库。
4. API 层测试
   - GraphQL mutation payload 使用已验证字段，尤其 `deleteUserList` 不查询 `list`。

阶段验证：

- 每新增 Swift 文件后跑 `xcodegen generate`。
- 至少跑定向 tests；最终跑 macOS arm64 build。

