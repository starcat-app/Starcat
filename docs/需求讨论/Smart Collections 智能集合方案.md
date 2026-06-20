# Smart Collections 智能集合方案

> 日期：2026-06-20  
> 状态：v1 方案确认，准备实施  
> 范围：不新增左侧顶级分类，先在 Manage 内提供系统智能集合入口

## 目标

Smart Collections 的目标是把已有 stars 自动组织成可行动的视图，而不是再增加一个和 Manage / Trending / Activity 平级的新频道。

第一版只做内置系统集合，避免一开始就引入复杂规则编辑器。

## 入口设计

左侧仍保持三个顶层入口：

- Manage
- Trending
- Activity

Smart Collections 放在 Manage 的 `Main Navigation` 分组内，作为一行入口：

- 名称：Smart Collections
- 图标：`line.3.horizontal.decrease.circle`
- 右侧计数：系统集合数量 + 用户集合数量，第一版只有系统集合

点击该入口后，中栏展示集合总览，而不是直接展示 repo 列表。

## 第一版系统集合

第一版只提供以下系统集合：

- Needs Review：健康度较低、已归档、或关键元数据缺失的项目
- Unmaintained：长期未更新或长期无 release 的项目
- High Value：高 star 且健康度较高的项目
- No Tags：未打标签项目
- Recently Active：最近有 push / release 的项目

其中 `No Tags` 已有 Untagged 入口，Smart Collections 中保留它的意义是与其它系统集合形成统一总览。

## 数据模型

第一版不新增用户自定义集合表。

系统集合用 Swift enum 固化：

```swift
enum SmartCollectionKind: String, CaseIterable, Identifiable {
    case needsReview
    case unmaintained
    case highValue
    case noTags
    case recentlyActive
}
```

集合命中结果通过现有 repo 查询 + Repo Health 快照计算，不在 DB 中持久化结果列表。

## 查询策略

第一版查询走 `HomeViewModel` 现有 repo 列表管线：

1. Sidebar 选择 `.smartCollectionsHome` 时展示集合总览。
2. 点击具体集合后选择 `.smartCollection(kind)`。
3. `HomeViewModel` 按 kind 派发查询。
4. 查询结果仍进入普通 repo list，因此排序、多选、详情页能力复用现有实现。

## 不做范围

- 不做用户自定义 rule builder。
- 不做静态 list 保存。
- 不新增左侧顶级分类。
- 不为每个集合都在 sidebar 展开一行，避免左侧继续膨胀。

## 后续扩展

后续可以把 `SavedSearch` 升级成用户自定义智能集合：

- 条件 JSON 继续存 `saved_searches.query`
- UI 从“保存搜索”升级为“保存为智能集合”
- 支持自然语言生成筛选条件，但必须用户确认后保存
