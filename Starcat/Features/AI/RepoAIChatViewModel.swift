//
//  RepoAIChatViewModel.swift
//  Starcat
//
//  详情页 AI 助手窗口（HOM-150）里的"对话"段状态模型。
//
//  模块职责：
//  - 维护一组按时间顺序排列的 `ChatMessage`（用户 / 助手两类）；
//  - 把"用户发送 → 流式接收助手回答"的过程映射成可观察的 SwiftUI 状态；
//  - 与"AI 摘要"完全解耦：本 VM **不**承载摘要 / 标签推荐，那块仍由
//    `RepoAIInsightViewModel` 独立负责，避免重新生成摘要时把对话清空。
//
//  关键约束：
//  - 流式响应通过 `RepoAIInsightService.chatStream` 拉取增量；本 VM 在助手消息上
//    原地累积 partial content，让 UI 一帧一帧重绘出"打字机效果"。
//  - 发送中若收到第二次 send 请求要被拦截（`isSending` 守门），避免并发 stream
//    把回答串成两段错乱的内容。
//  - 历史只存在内存（@State 维度），关闭窗口即丢失；HOM-150 验收里这是有意为之，
//    避免第一版引入新表 / 迁移 / CloudKit 同步带来的复杂度。
//

import Foundation
import Observation

/// 详情页 AI 助手窗口里的一条聊天消息。
///
/// 同时承载"已完成"和"流式累积中"两种状态：
/// - 用户发送：构造一次后 `content` 不再变化；
/// - 助手回答：先以空 content 插入 messages 末尾，随后按 stream chunk 不断改写。
///
/// **HOM-70（2026-06-15）补 Codable**：磁盘持久化用，schema 见
/// `DiskChatHistoryStore` 顶部注释。`isStreaming` 不参与持久化（默认 false 即可），
/// 因为落盘的消息一定是"已完成"状态。
struct ChatMessage: Identifiable, Equatable, Sendable, Codable {
    enum Role: String, Sendable, Equatable, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    /// 正文。助手消息在流式过程中会被不断改写。
    var content: String
    let timestamp: Date
    /// 流式生成是否还在进行。完成后置 false，UI 据此显示"光标 / 打字中"指示。
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }

    // 自定义 Codable：跳过 `isStreaming`（落盘的消息恒为 false），其余字段照常。
    // 老 JSON（理论上不存在，HOM-70 首版上线）若缺这个字段也能正常 decode。
    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(Role.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.isStreaming = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

/// AI 对话会话（HOM-70 / 2026-06-15）。
///
/// 一个 `(owner, repo)` 下可以有多个 session：用户点「+ 新增对话」即新建，或在
/// 上下文溢出（`context_length_exceeded`）时手动新建并把上一 session 的尾部对话
/// 摘要作为"开场白"带进来。
///
/// 设计约束：
/// - `title`：取首条 user message 的首行（max 30 字符）；为空时显示本地化"新对话"。
/// - `carriedOverSummary`：仅当此 session 由「上下文溢出 → 新建」诞生时非 nil，
///   首次渲染时 UI 显示一条"承接上一对话"banner / 系统消息（消费一次后保留在
///   session 里供历史回看）。
/// - `messages` 顺序：第一条最早，末尾最新；空数组合法（刚创建未发言）。
struct ChatSession: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    /// 上一 session 在溢出时摘要带过来的开场白。nil = 全新空白 session。
    var carriedOverSummary: String?

    init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        messages: [ChatMessage] = [],
        carriedOverSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.messages = messages
        self.carriedOverSummary = carriedOverSummary
    }
}

/// 会话索引项（`index.json` 用，"轻量列表"专用）。
///
/// 为什么不直接复用 `ChatSession`：list 视图（session popover）只需要 title + 时间 +
/// 消息数 + 体积，不需要全部 messages；磁盘读 index 一次就能渲染列表，远快于扫
/// 所有 `<session-id>.json`。当 session 被新增 / 修改 / 删除时由
/// `DiskChatHistoryStore` 同步更新对应 index 条目。
struct ChatSessionSummary: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messageCount: Int
    var bytes: Int64
}

@MainActor
@Observable
final class RepoAIChatViewModel {

    // MARK: - 可观察状态

    /// 当前已经加载进 UI 的对话窗口。顺序：第一条最早，最后一条最新。
    ///
    /// 注意：这里不再等于完整历史。磁盘层按 20 条一个 chunk 存储，首次进入聊天只
    /// 加载最后 2 条，用户点击「加载更早消息」才向前追加 20 条。发送请求 / 复制完整
    /// 对话这类确实需要全量历史的路径，会按需从 `DiskChatHistoryStore` 读取完整 session。
    private(set) var messages: [ChatMessage] = []

    /// 当前正在生成的 assistant 消息；nil 表示没有进行中的流式回答。
    private(set) var streamingMessage: ChatMessage?

    /// `messages.first` 在完整 session messages 数组中的下标。0 表示已经加载到最早消息。
    private(set) var messageStartIndex: Int = 0

    /// 当前 session 的完整消息数（不含 `streamingMessage`）。
    private(set) var totalMessageCount: Int = 0

    /// 点击「加载更早消息」时的防重入状态。
    private(set) var isLoadingEarlierMessages: Bool = false

    var hasEarlierMessages: Bool {
        messageStartIndex > 0
    }

    /// 当前 session id（nil = 尚未初始化）。所有 send / load / 切换路径都围绕此 id。
    private(set) var currentSessionId: UUID?

    /// 当前 session 的"承接上一对话摘要"（仅由溢出新建路径写入；UI 以 banner 形式展示）。
    private(set) var currentCarriedOverSummary: String?

    /// 当前 repo 下的全部 session 概要（按 updatedAt 倒序）。供 popover 列表渲染。
    /// 由 `refreshSessions(repo:)` / saveSession 后自动刷新。
    private(set) var sessions: [ChatSessionSummary] = []

    /// 是否正在发送（含等待首个 token + 流式中）。
    private(set) var isSending: Bool = false

    /// 最近一次错误（非 nil 时 UI 渲染错误条）。
    private(set) var errorMessage: String?

    /// 上下文窗口溢出标志（HOM-70）。
    ///
    /// 由 `sendMessage` 中检测 chatStream 错误的 errorDescription 是否含
    /// `context_length_exceeded` / `maximum context length` / `token limit` 等关键字
    /// 后设置；UI 据此显示一行"上下文已满，新建对话"banner + CTA 按钮。
    /// 调用 `startNewSessionAfterOverflow(repo:)` 后自动清零。
    private(set) var isContextOverflow: Bool = false

    /// 当前 repo 的已索引外部 Wiki 镜像链接（2026-06-15 v4.y）。
    ///
    /// 由 `bootstrap` 阶段从 `WikiContextService` 同步读盘填充（cache hit fresh /
    /// stale 都走这里取值）；session 寿命内复用 —— 不在每条 sendMessage 重新读盘，
    /// 让 dong4j 拍板的"探测一次复用整个对话"语义落地。
    ///
    /// **注意**：bootstrap 期同时会触发 `refreshInBackground`，刷新结果写回磁盘
    /// `DiskWikiCache` 但**不**回填本字段。下次详情页重开 AI 窗口（bootstrap 重跑）
    /// 才用上最新值。这是有意为之 —— 避免 stream 期间字段变更引起 SwiftUI 闪动。
    private(set) var wikiLinks: [WikiLink] = []

    /// 当前 repo 的本地 CodeFlow 调用图 `file://` URL（2026-06-15 v4.y）。
    /// nil = 没生成过 / 被删了 / 输出目录授权失败。同 `wikiLinks` 的复用策略。
    private(set) var codeFlowPageURL: URL?

    // MARK: - 依赖

    private let service: RepoAIInsightService
    private let historyStore: DiskChatHistoryStore
    private let wikiContextService: WikiContextService?
    private let codeFlowStorage: CodeFlowStorage
    /// 面板切换 task 与“在摘要页直接发送”可能同时触发 bootstrap。共享同一个 Task，
    /// 防止重复读盘后较晚返回的旧结果覆盖用户刚发送的新消息。
    private var bootstrapTask: Task<Void, Never>?
    private var hasBootstrapped: Bool = false

    /// 当前正在执行的发送 / 流式 Task 句柄（2026-06-15 13:12 dong4j 反馈"AI 输出时
    /// 发送按钮要变成终止按钮"，需要把 Task 句柄交给 UI 层 cancel）。
    ///
    /// 为什么把 Task 句柄收在 vm：
    /// - async 函数自身无法获取所在 Task —— 必须在 Task 创建时存好句柄；
    /// - 视图层只持有 chatVM 引用，不直接知道 Task；让 vm 自己持有句柄符合"状态归
    ///   集到 ViewModel"的模式；
    /// - `sendMessage(_:repo:)` 内部把核心 stream 逻辑包到 Task 里，外层 await 仍然
    ///   等到完成（即便被 cancel 也从 Task.value 正常返回），保持 API 行为兼容。
    private var sendTask: Task<Void, Never>?

    private static let initialVisibleMessageCount = 2
    private static let earlierMessagePageSize = DiskChatHistoryStore.messagesPerChunk

    /// 主 init（生产路径 / 测试都走这一个，2026-06-15 v4.y 收敛）。
    ///
    /// - `wikiContextService`：**必填**，没有默认。原因：项目未上线，让编译器逼着
    ///   所有 callsite 显式传依赖，避免新增对话 VM 实例化路径漏注入。传 nil 等价于
    ///   "本会话不消费 wiki 资源"（测试 fast path / 不关心 wiki 注入的单测用）。
    /// - `historyStore` / `codeFlowStorage`：进程级单例默认即可，测试要隔离 disk
    ///   时再注入 `rootOverride` 版本。
    init(
        service: RepoAIInsightService,
        wikiContextService: WikiContextService?,
        historyStore: DiskChatHistoryStore = .shared,
        codeFlowStorage: CodeFlowStorage = .shared
    ) {
        self.service = service
        self.wikiContextService = wikiContextService
        self.historyStore = historyStore
        self.codeFlowStorage = codeFlowStorage
    }

    // MARK: - Session 生命周期

    /// 进入对话时调用：加载该 repo 的所有 session，自动选中最近的一个；都没有就新建一个空 session。
    ///
    /// 只在聊天面板首次显示或用户首次发送时调用。重复调用会复用同一加载任务，
    /// 避免 SwiftUI `.task` 与发送动作并发 bootstrap。
    func bootstrap(repo: Repo) async {
        if hasBootstrapped { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performBootstrap(repo: repo)
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
        hasBootstrapped = true
    }

    private func performBootstrap(repo: Repo) async {
        await refreshSessions(repo: repo)
        if let latest = sessions.first,
           let page = (try? await historyStore.loadSessionTailAsync(
               owner: repo.owner,
               repo: repo.name,
               sessionId: latest.id,
               tailCount: Self.initialVisibleMessageCount
           )) ?? nil {
            applySessionPage(page)
        } else {
            startEmptySession()
        }
        prefetchStarcatResources(repo: repo)
    }

    /// 进入对话时一次性把"Starcat 衍生资源"（Wiki / CodeFlow）从磁盘读出，存进
    /// 内存供本 session 所有 sendMessage 复用（2026-06-15 v4.y dong4j 拍板形态 C/E1）。
    ///
    /// 行为细节：
    /// - Wiki：`cachedLinks(owner:repo:)` 同步读盘 —— miss 直接拿空数组，hit 直接拿
    ///   `[WikiLink]`（不管 fresh / stale 一并使用）；
    /// - Wiki 后台刷新：cache miss 或 stale 时调 `refreshInBackground` 触发一次网络
    ///   往返写盘；**写盘结果不回填本 session 的 `wikiLinks`**，下次详情页重开 AI
    ///   窗口（bootstrap 重跑）才用上新值 —— 避免 stream 期间字段变更引起 UI 闪动；
    /// - CodeFlow：同步调 `CodeFlowStorage.existingProject(...)?.pageURL`，throw 时
    ///   直接吞错（最常见的是输出目录授权失败，用户没设置过 CodeFlow 即正常状态）。
    private func prefetchStarcatResources(repo: Repo) {
        if let wikiContextService {
            self.wikiLinks = wikiContextService.cachedLinks(owner: repo.owner, repo: repo.name)
            // 决策：cache miss 一定触发后台刷新；cache hit 时按 snapshot.freshness 判
            // —— stale 才刷新，fresh 完全跳过（省 API + 网络）。
            let snapshot = wikiContextService.cachedSnapshot(owner: repo.owner, repo: repo.name)
            let shouldRefresh: Bool
            if let snapshot {
                shouldRefresh = snapshot.freshness() == .stale
            } else {
                shouldRefresh = true
            }
            if shouldRefresh {
                wikiContextService.refreshInBackground(owner: repo.owner, repo: repo.name)
            }
        } else {
            self.wikiLinks = []
        }

        // `existingProject` 是 throwing 方法且返回值本身是可选，所以 `try?` 平铺出来
        // 是 `CodeFlowStoredProject??`。`?? nil` 把双层 optional 收成单层，再 `?.pageURL`。
        // 这种"throws + Optional"组合的解包模式在本 VM 的 historyStore 路径里已大量出现。
        let stored = (try? codeFlowStorage.existingProject(
            owner: repo.owner,
            name: repo.name
        )) ?? nil
        self.codeFlowPageURL = stored?.pageURL
    }

    /// 主动切换到另一个已有 session。
    func switchSession(to sessionId: UUID, repo: Repo) async {
        guard !isSending else { return }
        guard sessionId != currentSessionId else { return }
        guard let page = (try? await historyStore.loadSessionTailAsync(
            owner: repo.owner,
            repo: repo.name,
            sessionId: sessionId,
            tailCount: Self.initialVisibleMessageCount
        )) ?? nil
        else { return }
        applySessionPage(page)
    }

    /// 主动新建一个空 session（用户点「+ 新增对话」入口）。
    ///
    /// 行为：内存切到新空 session（**不立即落盘**，避免列表里冒出"未发过言的空对话"），
    /// 第一次 sendMessage 后才会真正写入 disk + 出现在列表里。
    func startNewSession() {
        guard !isSending else { return }
        startEmptySession()
    }

    /// 检测到上下文溢出后用户点「新建并承接」入口：把上一 session 末尾 6 条
    /// 对话转成摘要文案，写入新 session 的 `carriedOverSummary`。
    func startNewSessionAfterOverflow(repo: Repo) async {
        guard !isSending else { return }
        let fullMessages = await loadFullMessagesForCurrentSession(repo: repo) ?? messages
        let summary = makeCarryOverSummary(from: fullMessages)
        let new = ChatSession(carriedOverSummary: summary)
        applySession(new)
        // 立即落盘让该 carry-over session 出现在列表里（避免用户切走又切回来后空白）。
        try? historyStore.saveSession(owner: repo.owner, repo: repo.name, session: makeSnapshot(messages: []))
        await refreshSessions(repo: repo)
    }

    /// 删当前 repo 的全部对话（AI 窗口右上角"清除当前 repo 对话"入口）。
    func deleteAllForCurrentRepo(repo: Repo) async {
        guard !isSending else { return }
        try? historyStore.deleteAllForRepo(owner: repo.owner, repo: repo.name)
        startEmptySession()
        await refreshSessions(repo: repo)
    }

    /// 删某个 session（用户在列表里单条删除入口）。
    /// 若删的是当前 session，自动跳到下一个最新的，没有就新建空 session。
    func deleteSession(sessionId: UUID, repo: Repo) async {
        guard !isSending else { return }
        try? historyStore.deleteSession(owner: repo.owner, repo: repo.name, sessionId: sessionId)
        if currentSessionId == sessionId {
            await refreshSessions(repo: repo)
            if let next = sessions.first,
               let page = (try? await historyStore.loadSessionTailAsync(
                   owner: repo.owner,
                   repo: repo.name,
                   sessionId: next.id,
                   tailCount: Self.initialVisibleMessageCount
               )) ?? nil {
                applySessionPage(page)
            } else {
                startEmptySession()
            }
        } else {
            await refreshSessions(repo: repo)
        }
    }

    /// 刷新列表 (popover 打开 / saveSession 之后)。
    func refreshSessions(repo: Repo) async {
        sessions = (try? await historyStore.listSessionsAsync(owner: repo.owner, repo: repo.name)) ?? []
    }

    /// 向前加载更早的消息。每次最多读取一个 chunk（20 条），并 prepend 到当前渲染窗口。
    func loadEarlierMessages(repo: Repo) async {
        guard !isSending, !isLoadingEarlierMessages, hasEarlierMessages else { return }
        guard let currentSessionId else { return }

        isLoadingEarlierMessages = true
        defer { isLoadingEarlierMessages = false }

        let end = messageStartIndex
        let start = max(0, end - Self.earlierMessagePageSize)
        let earlier = (try? await historyStore.loadMessagesAsync(
            owner: repo.owner,
            repo: repo.name,
            sessionId: currentSessionId,
            start: start,
            end: end
        )) ?? []
        guard !earlier.isEmpty else {
            messageStartIndex = 0
            return
        }

        messages.insert(contentsOf: earlier, at: 0)
        messageStartIndex = start
    }

    // MARK: - 动作

    /// 发送输入组件提交的文本；流式累积助手回答；按 turn 落盘。
    ///
    /// 流程（HOM-70 修订版）：
    /// 1. 守门：去空白 + 拦截并发 + 确保 currentSessionId 已就绪；
    /// 2. 用户消息追加到 `messages` 末尾，**立即落盘**（保证就算 stream 挂了，user 消息也不丢）；
    /// 3. 助手 placeholder 占位 + `isStreaming = true`；
    /// 4. service.chatStream 增量回调原地改写助手 content（与 HOM-150 同款）；
    /// 5. **完成**（成功 / 失败 / 取消）后翻 `isStreaming = false`，**再次落盘**整段 session；
    /// 6. 失败时若错误关键字命中 context-overflow → 设 `isContextOverflow = true`，UI 给 banner。
    ///
    /// 2026-06-15 13:12 dong4j 反馈"AI 输出时发送按钮要变成终止按钮"：
    /// - 在外层包一层内部 Task 并把句柄存到 `sendTask`,`cancelStreaming()` 调
    ///   `sendTask?.cancel()` 中断流式（cancellation 顺着 `await` 链传到
    ///   `client.chatStream` 内的 URLSession,网络停止接收下一片 chunk）；
    /// - catch 块新增 `Task.isCancelled` 分支：把已累积的 partial 当作正常完成的
    ///   助手消息保存（ChatGPT / Claude 行为：取消不是错误,生成到一半的内容不丢）。
    /// - 外层 `await sendMessage(...)` 行为不变：内部 Task 完成 / 被 cancel 后,
    ///   `await task.value` 都会正常返回,sendTask 清 nil,isSending 已经在内部 defer
    ///   翻 false。
    func sendMessage(_ text: String, repo: Repo) async {
        let task = Task<Void, Never> { [weak self] in
            await self?.performSendMessage(text: text, repo: repo)
        }
        sendTask = task
        await task.value
        sendTask = nil
    }

    /// 用户在 AI 输出时点"停止"按钮：cancel 当前 sendTask。
    ///
    /// cancel 后 `performSendMessage` 内的 `for try await` 会抛 CancellationError
    /// → catch 块走 `Task.isCancelled` 分支，把已累积的 partial 作为正常完成的
    /// 助手消息保存（不报错、不丢内容）。
    func cancelStreaming() {
        sendTask?.cancel()
    }

    /// 实际执行 stream 流程（被 `sendMessage` 内部 Task 包裹,允许从外面 cancel）。
    private func performSendMessage(text: String, repo: Repo) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        if currentSessionId == nil { startEmptySession() }

        let userMessage = ChatMessage(role: .user, content: trimmed)
        let assistantPlaceholder = ChatMessage(role: .assistant, content: "", isStreaming: true)

        // 用完整磁盘历史（不含本轮新加的两条）拼 prompt history。UI 里的 `messages`
        // 可能只加载了尾部 2 条，不能用它直接发给模型，否则长对话会丢上下文。
        let persistedMessages = await loadFullMessagesForCurrentSession(repo: repo) ?? messages
        let history = persistedMessages.map { message in
            AIChatMessage(
                role: message.role == .user ? .user : .assistant,
                content: message.content
            )
        }

        messages.append(userMessage)
        totalMessageCount += 1
        // 首条消息触发：用文案生成 title（30 字符截断）。后续轮次保留首条 title。
        if persistedMessages.allSatisfy({ $0.role != .user }) {
            currentSessionTitle = Self.makeTitle(from: trimmed)
        }
        // 落盘 user message（即便 stream 挂了也不丢）。
        var sessionMessagesForPersist = persistedMessages + [userMessage]
        persistCurrentSession(repo: repo, messages: sessionMessagesForPersist)

        streamingMessage = assistantPlaceholder

        isSending = true
        errorMessage = nil
        isContextOverflow = false

        defer { isSending = false }

        // HOM-70 v2：把 carriedOverSummary 显式透传给 service —— 如果本 session 是
        // 「上下文溢出 → 新建并承接」诞生的，每条用户消息都让 AI 看到上一对话的承接段
        // （写在 system prompt 里，不耗对话轮次，但 session 寿命内一直在 prompt 头部）。
        // 普通 session `currentCarriedOverSummary == nil`，service 渲染出空 section
        // header，LLM 自然忽略,token 浪费 < 10 可接受。
        //
        // 2026-06-15 11:15 流式节流（dong4j 反馈"AI 流式输出 200+ 字开始卡，500+ 字主线
        // 程死锁 + CPU 100%"）：根因 = `AIChatBubble` 用 `swift-markdown-ui` 渲染整段
        // markdown，每个 token 触发：①流式消息状态改写 → ② AIChatBubble.body 重算
        // → ③ MarkdownHeadingDemoter.demoteToH3(O(n)) →
        // ④ swift-markdown-ui 重新 parse + AST → SwiftUI view tree。LLM 流式典型 50-200
        // token/s, 长回答 + 含代码块 syntax highlighting 时主线程渲染管线被压满，帧预算
        // 爆 → SwiftUI 报 `OnScrollGeometryChange Modifier tried to update multiple times
        // per frame` + AttributeGraph cycle，最终主线程 livelock CPU 100%（强退）。
        //
        // 节流策略：用时间窗口而非 chunk 数量（partial 是累积串不是 chunk 数）。窗口
        // 80 ms ≈ 12.5 Hz，仍有连续打字感，同时给滚动 phase / sentinel 回调留出主线程
        // 预算。历史 messages 在 stream 期间完全不改，只有独立 streamingMessage 重绘；
        // chatStream 返回后再把 final 一次 append 为正式消息，保证最终内容完整。
        //
        // 实现要点：`lastCommitAt` / `pendingPartial` 是 sendMessage 函数局部 `var`，
        // closure 是 `@MainActor (String) -> Void` 故 captured var 访问在 main actor
        // 隔离下安全，无 Sendable / race 问题。`pendingPartial` 仅作为"是否有未提交
        // 的 partial 在等"的语义标记，节流窗口未到不写 UI，等下个 partial 到来
        // 时窗口到了就 commit 最新的（中间被跳过的不需要补，因为是累积串）。
        var lastCommitAt: TimeInterval = 0
        var pendingPartial: String?
        // Markdown parse 比纯文本昂贵。80 ms 约 12.5 Hz，仍有连续打字感，同时给
        // 滚动 phase / sentinel 可见性回调保留主线程预算。
        let throttleInterval: TimeInterval = 0.08
        do {
            let final = try await service.chatStream(
                for: repo,
                history: history,
                userMessage: trimmed,
                carriedOverSummary: currentCarriedOverSummary,
                wikiLinks: wikiLinks,
                codeFlowPageURL: codeFlowPageURL
            ) { [weak self] partial in
                guard let self else { return }
                pendingPartial = partial
                let now = Date.timeIntervalSinceReferenceDate
                guard now - lastCommitAt >= throttleInterval else { return }
                lastCommitAt = now
                if var streaming = self.streamingMessage,
                   let toCommit = pendingPartial {
                    // 只改独立流式消息，历史 messages 数组在整个 stream 期间保持稳定。
                    streaming.content = toCommit
                    self.streamingMessage = streaming
                    pendingPartial = nil
                }
            }

            if var completed = streamingMessage {
                completed.content = final
                completed.isStreaming = false
                messages.append(completed)
                totalMessageCount += 1
                sessionMessagesForPersist.append(completed)
            }
            streamingMessage = nil
            persistCurrentSession(repo: repo, messages: sessionMessagesForPersist)
            await refreshSessions(repo: repo)
        } catch {
            // 用户主动取消（点了"停止"按钮）→ 当作正常完成处理，把累积内容作为
            // 助手消息保存（ChatGPT / Claude 同款行为：取消不是错误，生成到一半
            // 的内容不丢）。
            //
            // 判定根据 `Task.isCancelled`，而不是 `error is CancellationError`：
            // 底层 URLSession 在 cancel 时抛的是 `URLError(.cancelled)` 不是
            // CancellationError；只要 vm 的 sendTask 被 cancel,Task.isCancelled
            // 就是 true,统一靠这个判。
            if Task.isCancelled {
                if var stopped = streamingMessage {
                    // 节流尾巴 flush：取消瞬间可能有未 commit 的最新 partial。
                    if let unflushed = pendingPartial,
                       unflushed.count > stopped.content.count {
                        stopped.content = unflushed
                    }
                    stopped.isStreaming = false
                    // 内容为空（用户在首个 token 之前就取消）→ 不留空助手消息，
                    // 避免出现一条"空气泡"。否则正常 append 到 messages。
                    let trimmedStopped = stopped.content
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedStopped.isEmpty {
                        messages.append(stopped)
                        totalMessageCount += 1
                        sessionMessagesForPersist.append(stopped)
                    }
                }
                streamingMessage = nil
                // errorMessage 不写、isContextOverflow 不动 —— 取消不是错误。
                persistCurrentSession(repo: repo, messages: sessionMessagesForPersist)
                await refreshSessions(repo: repo)
                return
            }

            let description = error.localizedDescription
            errorMessage = description
            if Self.looksLikeContextOverflow(description) {
                isContextOverflow = true
            }
            if var failed = streamingMessage {
                // 节流尾巴 flush：失败时可能有未 commit 的最后一片 partial（节流窗口内
                // stream 抛错），用 pendingPartial 兜底拿到节流期间收到的最新累积串。
                // partial 是单调累加的，所以"长度更大"就是"内容更新"，简单可靠的兜底判定。
                if let unflushed = pendingPartial,
                   unflushed.count > failed.content.count {
                    failed.content = unflushed
                }
                // 不留空占位（避免 UI 上看到一条"灰色光标但无文字"的助手消息）。
                // 失败占位文案走 i18n：英文 / 中文用户都能看懂自己语言的失败提示。
                let prefix = failed.content
                failed.content = prefix.isEmpty
                    ? String(
                        format: String(localized: "ai.assistant.chat.failureFormat"),
                        description
                    )
                    : prefix
                failed.isStreaming = false
                messages.append(failed)
                totalMessageCount += 1
                sessionMessagesForPersist.append(failed)
            }
            streamingMessage = nil
            // 失败 turn 也落盘（保留用户消息 + 失败占位，便于回看 / 复制问题反馈）。
            persistCurrentSession(repo: repo, messages: sessionMessagesForPersist)
            await refreshSessions(repo: repo)
        }
    }

    /// 显式清空错误条。
    func dismissError() {
        errorMessage = nil
    }

    /// 显式清空 context-overflow 标志（UI 上 "关闭 banner" 入口；不影响 errorMessage）。
    func dismissContextOverflow() {
        isContextOverflow = false
    }

    /// 显式清空对话历史（仅内存层，不删盘）。
    ///
    /// 当前主用户路径是「清除当前 repo 对话」/「+ 新增对话」，本方法保留供 reset 类场景使用。
    func resetConversation() {
        guard !isSending else { return }
        messages.removeAll()
        streamingMessage = nil
        messageStartIndex = 0
        totalMessageCount = 0
        errorMessage = nil
        isContextOverflow = false
    }

    // MARK: - Session 持久化辅助

    /// 当前 session 的可变 title（首条 user 消息发出后即写入）。
    private var currentSessionTitle: String = ""
    private var currentSessionCreatedAt: Date = Date()

    private func startEmptySession() {
        let id = UUID()
        let now = Date()
        currentSessionId = id
        currentSessionTitle = ""
        currentSessionCreatedAt = now
        currentCarriedOverSummary = nil
        messages.removeAll()
        streamingMessage = nil
        messageStartIndex = 0
        totalMessageCount = 0
        errorMessage = nil
        isContextOverflow = false
    }

    private func applySession(_ session: ChatSession) {
        currentSessionId = session.id
        currentSessionTitle = session.title
        currentSessionCreatedAt = session.createdAt
        currentCarriedOverSummary = session.carriedOverSummary
        messages = session.messages
        streamingMessage = nil
        messageStartIndex = 0
        totalMessageCount = session.messages.count
        errorMessage = nil
        isContextOverflow = false
    }

    private func applySessionPage(_ page: ChatSessionPage) {
        currentSessionId = page.session.id
        currentSessionTitle = page.session.title
        currentSessionCreatedAt = page.session.createdAt
        currentCarriedOverSummary = page.session.carriedOverSummary
        messages = page.session.messages
        streamingMessage = nil
        messageStartIndex = page.messageStartIndex
        totalMessageCount = page.totalMessageCount
        errorMessage = nil
        isContextOverflow = false
    }

    private func makeSnapshot(messages snapshotMessages: [ChatMessage]) -> ChatSession {
        ChatSession(
            id: currentSessionId ?? UUID(),
            title: currentSessionTitle,
            createdAt: currentSessionCreatedAt,
            updatedAt: Date(),
            messages: snapshotMessages,
            carriedOverSummary: currentCarriedOverSummary
        )
    }

    private func persistCurrentSession(repo: Repo, messages snapshotMessages: [ChatMessage]) {
        guard currentSessionId != nil else { return }
        do {
            try historyStore.saveSession(owner: repo.owner, repo: repo.name, session: makeSnapshot(messages: snapshotMessages))
        } catch {
            AppLog.ai.warning("Chat history persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFullMessagesForCurrentSession(repo: Repo) async -> [ChatMessage]? {
        guard let currentSessionId else { return nil }
        guard let session = (try? await historyStore.loadSessionAsync(
            owner: repo.owner,
            repo: repo.name,
            sessionId: currentSessionId
        )) ?? nil else {
            return nil
        }
        return session.messages
    }

    /// 从对话末尾 6 条消息生成"承接上一对话"摘要文案。
    ///
    /// 简化策略：不调 LLM 二次摘要（dong4j 拍板"用户自己处理上下文"），直接把末尾 6 条
    /// 按 role 拼成 markdown 列表交给下一 session 的 system 上下文。
    /// 单条截断到 ~280 字符防止本身又溢出。
    private func makeCarryOverSummary(from messages: [ChatMessage]) -> String {
        let recent = Array(messages.suffix(6))
        var lines: [String] = []
        for msg in recent {
            let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let snippet = trimmed.count > 280 ? String(trimmed.prefix(280)) + "…" : trimmed
            let prefix = msg.role == .user ? "Q" : "A"
            lines.append("- \(prefix): \(snippet)")
        }
        return lines.joined(separator: "\n")
    }

    /// 把 user 消息首行截成 ~30 字符的 session title。
    private static func makeTitle(from userMessage: String) -> String {
        let firstLine = userMessage
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstLine.count > 30 {
            return String(firstLine.prefix(30)) + "…"
        }
        return firstLine
    }

    /// 错误描述里命中下列任一关键字 → 视为 context-window 溢出。
    ///
    /// 关键字覆盖 OpenAI / Anthropic / DashScope / 国产 LLM 常见返回文案；保守命中策略：
    /// 命中即给 banner（误报 = 用户看到 banner 但其实其它原因失败，自己关掉即可）；
    /// 没命中也无害，errorMessage 仍然显示。
    static func looksLikeContextOverflow(_ description: String) -> Bool {
        let lower = description.lowercased()
        let keywords = [
            "context_length_exceeded",
            "maximum context length",
            "context window",
            "context length exceeded",
            "token limit",
            "tokens exceed",
            "exceeds the maximum",
            "上下文长度",
            "上下文窗口",
            "tokens超过",
            "超出最大上下文"
        ]
        return keywords.contains { lower.contains($0) }
    }

    /// 把当前对话历史拼成可粘贴到外部 Markdown 渲染器（Obsidian / Notion / 飞书
    /// 文档 / Bear / GitHub 等）的友好文档。
    ///
    /// 演进历史：
    /// - HOM-150 dong4j 2026-06-04 15:13：初版用 `####`（H4）做角色标头。
    /// - HOM-150 dong4j 2026-06-04 15:48 反馈：改 H2、加 GitHub 用户名 + HH:mm 时间
    ///   戳到角色标头、末尾追加「由 {model} 生成」署名。
    ///
    /// 文档结构（新版）：
    /// ```
    /// # Starcat AI Chat · {owner/name}
    ///
    /// - **仓库**: [owner/name](https://github.com/owner/name)
    /// - **导出时间**: 2026-06-04 15:48:21
    /// - **消息数**: N
    ///
    /// ---
    ///
    /// ## 👤 dong4j (15:30)
    ///
    /// {user 消息原文}
    ///
    /// ## 🤖 AI (15:30)
    ///
    /// {assistant 消息原 Markdown}
    ///
    /// ---
    ///
    /// ## 👤 dong4j (15:35)
    /// ...
    ///
    /// ---
    ///
    /// > 由 qwen3.5-omni-flash-2026-03-15 生成
    /// ```
    ///
    /// 参数：
    /// - `userLogin`：当前登录的 GitHub username（如 `dong4j`）；nil 时回退为
    ///   "你"，保留旧行为，单测 / 未登录场景仍能跑通。
    ///
    /// 设计取舍：
    /// - H2 标头（dong4j 明确要求）：注意助手回答内部如果用了 `##` 会和角色标头
    ///   同级，但 dong4j 的需求是"标头层级要够分量"，权衡后服从用户决定。
    /// - 标头时间戳用 `HH:mm` 24h 格式（en_US_POSIX 强制英文 locale，避免不同
    ///   系统语言下输出"15:30"vs"下午 3:30"）。
    /// - 末尾署名走 blockquote `>`：渲染器普遍支持，且与正文形成弱视觉分隔，
    ///   与 AI 摘要 footer "由 X 生成 · date" 的视觉权重对齐。
    /// - 助手内容原样输出，不二次转义/包裹：助手返回的 Markdown 本身就是合法
    ///   Markdown（包含 fenced code、链接、列表等），任何包裹都会破坏渲染。
    /// - 流式中的消息也包含进去（按当前累积的 content 写），用户中途想"分段保
    ///   存"也能用。
    /// - 模型名取 `service.resolvedChatModelName`：与 `chatStream` 内部模型解析
    ///   逻辑完全一致，保证用户看到的"由 X 生成"就是真实跑回答的模型。
    func markdownExport(repo: Repo, userLogin: String? = nil) -> String {
        let exportMessages: [ChatMessage] = {
            guard let currentSessionId,
                  let session = try? historyStore.loadSession(
                      owner: repo.owner,
                      repo: repo.name,
                      sessionId: currentSessionId
                  ) else {
                return messages
            }
            return session.messages
        }()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let exportedAt = formatter.string(from: Date())

        // 角色标头里的 HH:mm 短时间戳。用独立 formatter，与导出时间格式解耦，
        // 便于将来需要"角色用 12h 显示、导出时间保留 24h"等独立调整。
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"

        // GitHub 用户名兜底：未登录或 login 为空时退化成 "You" / "你"
        // （走本地化 key `ai.assistant.chat.export.userFallback`，跟 UI 语言一致）。
        // 避免导出出现 `## 👤  (15:30)` 这种空名词的尴尬格式。
        let userDisplayName: String = {
            if let login = userLogin?.trimmingCharacters(in: .whitespacesAndNewlines),
               !login.isEmpty {
                return login
            }
            return String(localized: "ai.assistant.chat.export.userFallback")
        }()

        // 全套导出模板都走本地化（HOM-150 dong4j 2026-06-04 16:05 反馈：
        // "有很多都没有做国际化配置"）。英文用户复制粘贴出去的 Markdown 应该
        // 是英文版"Starcat AI Chat · ... / Repo: / Exported: / Messages:"，
        // 而不是夹杂中英文的混合体。模板里 `%@` 由 `String(format:)` 注入。
        let docTitle = String(
            format: String(localized: "ai.assistant.chat.export.docTitleFormat"),
            repo.fullName
        )
        let repoLabel = String(localized: "ai.assistant.chat.export.repoLabel")
        let exportedAtLabel = String(localized: "ai.assistant.chat.export.exportedAtLabel")
        let messageCountLabel = String(localized: "ai.assistant.chat.export.messageCountLabel")
        let emptyContentPlaceholder = String(localized: "ai.assistant.chat.export.emptyContent")

        var lines: [String] = []
        lines.append("# \(docTitle)")
        lines.append("")
        lines.append("- **\(repoLabel)**: [\(repo.fullName)](\(repo.htmlUrl))")
        lines.append("- **\(exportedAtLabel)**: \(exportedAt)")
        lines.append("- **\(messageCountLabel)**: \(exportMessages.count)")
        lines.append("")
        lines.append("---")
        lines.append("")

        for (index, message) in exportMessages.enumerated() {
            // 在每个 user 消息前（除第一条）插 `---`，划分新一轮 turn 起点。
            // 这样视觉上"问 + 答"成对，turn 之间有明显边界。
            if index > 0, message.role == .user {
                lines.append("---")
                lines.append("")
            }

            let timeStr = timeFormatter.string(from: message.timestamp)
            switch message.role {
            case .user:
                lines.append("## 👤 \(userDisplayName) (\(timeStr))")
            case .assistant:
                lines.append("## 🤖 AI (\(timeStr))")
            }
            lines.append("")

            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // 流式还没开始 / 错误占位：给一个 placeholder 比留空白行友好。
                lines.append(emptyContentPlaceholder)
            } else if message.role == .assistant {
                // dong4j 2026-06-04 16:05 反馈：助手 Markdown 里若有 H1/H2 会与
                // 角色标头 `## 🤖 AI` 撞同级，需要按需降级到 H3 起步。
                // user 消息纯文本，没有 markdown 标题，不需要降级（也避免万一用户
                // 输入 `# 帮我看下` 被错改）。
                lines.append(MarkdownHeadingDemoter.demoteToH3(trimmed))
            } else {
                lines.append(trimmed)
            }
            lines.append("")
        }

        // 末尾署名（dong4j 2026-06-04 15:48）：与 AI 摘要 footer 对齐。仅在有
        // 真实消息时输出（空对话不署名，避免出现"由 X 生成"却没有任何内容
        // 这种诡异情况——虽然 UI 流程上空对话也不会触发复制按钮，但 API 层
        // 多一道保险）。
        if !exportMessages.isEmpty {
            let generatedBy = String(
                format: String(localized: "ai.assistant.chat.export.generatedByFormat"),
                service.resolvedChatModelName
            )
            lines.append("---")
            lines.append("")
            lines.append("> \(generatedBy)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
