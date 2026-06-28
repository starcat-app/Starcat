# Phase 2: AI 与 Release 详细设计及实施计划

> 本文档根据 dong4j 在 2026-06-01 的指示，详细定义第二阶段（AI 对接与核心差异化功能）的技术方案。

---

## 一、 核心目标 (Objective)
将 Starcat 从一个单纯的“书签管理器”升级为“智能知识库”。引入 BYOK 模式的 AI 基础设施、自动化摘要与标签推荐、Release 订阅追踪，以及基于 SQLite 向量扩展的语义搜索。

---

## 二、 关键模块设计

### 2.1 凭证安全与基础设施 (D-16 收口)
*   **本地加密管理器 (`CryptoManager`)**:
    *   引入 `CryptoKit`。
    *   使用设备 Hardware UUID 结合固定盐值派生 `SymmetricKey`。
    *   使用 AES-GCM 对本地 `credentials.json` 进行全量加密/解密。
    *   彻底弃用明文存储，同时绕过系统 Keychain 的 ad-hoc 签名弹窗限制。
*   **AI 设置界面 (`AISettingsView`)**:
    *   在设置中提供 Provider 切换（DeepSeek / OpenAI / Gemini / Ollama）。
    *   提供端点（Base URL）与 API Key 配置。
*   **AI 服务层协议 (`AIServiceProtocol`)**:
    *   抽象统一接口：`summarize`, `recommendTags`, `generateEmbedding`。
    *   各 Provider 实现独立 Service，由 `AIServiceFactory` 动态分发。

### 2.2 智能化分析 (摘要与标签)
*   **数据模型 (Migration V2)**:
    *   `repo_ai_analysis` 表：存储 `one_liner`, `summary`, `pros`, `cons` 及 `cached_at`。
    *   `Repo` 模型扩展相应可选属性。
*   **标签推荐确认流**:
    *   AI 推荐标签进入“建议态”（UI 上以虚线或星星标记）。
    *   用户点击后，调用 `RepoTagRepository` 正式入库。

### 2.3 Release 订阅追踪 (核心差异化)
*   **后台轮询**:
    *   使用 `NSBackgroundActivityScheduler` 定期调度。
    *   利用 ETag 进行条件请求，节省 GitHub API 配额。
*   **时间线 UI**:
    *   Sidebar 新增 "Releases" 视图。
    *   聚合卡片展示版本、更新摘要及直达下载链接。

### 2.4 语义搜索 (SQLite 向量化)
*   **SQLite 扩展**:
    *   集成 `sqlite-vec` 提供向量存储与计算。
*   **混合检索**:
    *   实现 FTS5 BM25 + 向量余弦相似度 RRF 融合排序。

---

## 三、 实施计划

### Week 5: 基础设施与分析落地
1.  **CryptoManager** 落地，解决 D-16 债。
2.  **AISettingsView** 与 Provider 基础模型建立。
3.  **Migration V2** 数据库升级。
4.  实现单仓 **AI 摘要** 与 **标签推荐** 逻辑。

### Week 6: 差异化与语义检索
1.  **Release 监测系统** (Poller + Notification) 落地。
2.  **Release Timeline** 视图实现。
3.  集成 **sqlite-vec**。
4.  落地 **Embedding 生成** 队列与 **语义搜索** 界面。

---

*创建日期：2026-06-01*
