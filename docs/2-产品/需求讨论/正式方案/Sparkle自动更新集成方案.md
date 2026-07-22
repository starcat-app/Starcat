# Sparkle 自动更新集成方案（已归并）

> 状态：已归并，不再作为单一信任源。

本文原内容已归并到：

| 新文档 | 覆盖内容 |
|--------|----------|
| `docs/2-产品/需求讨论/分发渠道.md` | Direct Sparkle 自动更新需求 |
| `docs/2-产品/需求讨论/正式方案/分发渠道正式方案.md` | Sparkle 只进入 Direct build 的正式方案 |
| `docs/3-设计/详细设计/41-分发渠道详细设计.md` | Sparkle Info.plist、entitlements、appcast、打包脚本详细设计 |
| `docs/4-工程进度/分发渠道专项/checklist.md` | Sparkle 实施 checklist |

Direct appcast 静态入口为：`supports/starcat-site/direct/appcast.xml`，部署地址为 `https://starcat.ink/appcast.xml`。

