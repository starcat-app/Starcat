# Starcat Screenshot Set - 2026-06-23

本目录保存 Starcat 本次上架和 landing page 截图产物。

## App Store clean screenshots

所有文件均为真实 App 窗口截图，PNG，2880 x 1800，符合 Mac App Store 16:10 截图尺寸要求。

| 文件 | 建议用途 | 截图重点 |
| --- | --- | --- |
| `app-store/01-star-library-detail.png` | App Store 第 1 张 | 主窗口、仓库列表、README 渲染、标签、笔记、状态 |
| `app-store/02-trending-discovery.png` | App Store 第 2 张 | Trending 发现、语言筛选、仓库详情 |
| `app-store/03-weekly-activity.png` | App Store 第 3 张 | Activity / 周刊、更新追踪、README 直读 |
| `app-store/04-smart-collections.png` | App Store 第 4 张 | 智能集合总览、内置集合与自定义集合 |
| `app-store/05-ai-assistant-entry.png` | App Store 第 5 张 | 仓库详情中的 AI 助手入口、摘要与对话面板 |

## Landing page composites

这些图是基于真实截图生成的宣传组合图，尺寸 3200 x 1800。适合官网 hero、feature section、社媒预览裁切，不建议直接作为 App Store clean 截图上传。

| 文件 | 建议用途 | 主题 |
| --- | --- | --- |
| `landing/hero-library.png` | Landing hero | Your Stars, finally searchable. |
| `landing/feature-discovery.png` | Feature section | Discover what matters this week. |
| `landing/feature-ai.png` | Feature section | Ask AI about any repository. |

## Raw screenshots

`raw/` 保存了采集过程中的全部原图，包括中间态、入口态、失败态和 smoke test。正式使用时优先从 `app-store/` 与 `landing/` 选择。

## Notes

- `app-store/05-ai-assistant-entry.png` 使用 AI 入口态。当前本地 AI 生成摘要在访问 AI 时超时，因此没有采用错误弹窗或超时状态作为正式图。
- `manifest/render-landing.mjs` 仅用于本目录内生成 landing 组合图，不属于 App 代码。
