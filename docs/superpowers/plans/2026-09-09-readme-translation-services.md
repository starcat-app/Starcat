# README 翻译服务 Implementation Plan

> **For agentic workers:** Implement task-by-task. Spec: `docs/superpowers/specs/2026-09-09-readme-translation-services-design.md`

**Goal:** MVP A — 系统翻译 + 详情菜单聚合可用引擎（含 AI），切换写回设置。

**Architecture:** 抽段/缓存/回填复用；`ReadmeTranslationEngine` 分发到 System（Translation framework + SwiftUI session bridge）或现有 AI 路径；缓存按引擎隔离。

**Tech Stack:** SwiftUI, Translation framework, 现有 ReadmeTranslationService / DiskReadmeTranslationCache

## Global Constraints

- macOS 15+；门控一期不做；不改 `功能实现总览.md`；外接 MT 不做；AI 配置不搬设置页。

---

### Task 1: Engine + Settings + Availability

- [ ] 新增 `ReadmeTranslationEngine`（system/ai）
- [ ] `AppSettings.readmeTranslationEngine` 持久化
- [ ] `ReadmeTranslationEngineAvailability` + 单测（AI 可用性 mock）

### Task 2: Cache isolation by engine

- [ ] 磁盘路径或文件名纳入 engine（system vs ai）
- [ ] 单测：同语言同 mode 不同 engine 互不覆盖

### Task 3: System translation backend

- [ ] `SystemTranslationSessionBroker` + App 根挂 `.translationTask`
- [ ] `SystemReadmeTranslationBackend`：按批 `translations(from:)` / 逐段
- [ ] Service `translate` 按 engine 分支；AI 路径保持

### Task 4: Settings + Footer menu

- [ ] 设置侧栏「翻译服务」页：默认引擎 + 说明
- [ ] `ReadmeTranslationFooterButton` 菜单增加可用引擎 Picker（写回 settings）
- [ ] i18n 键（按规范插入 Catalog）

### Task 5: Verify

- [ ] `make test` 相关 suites
- [ ] 手动：菜单只显示可用项；切引擎写回；系统/AI 缓存隔离
