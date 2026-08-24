//
//  GitHubStatusMonitor.swift
//  Starcat
//
//  GitHub 官方 Statuspage 状态读取与后台轮询。
//
//  这里与 `ServiceAvailabilityMonitor` 保持分离：后者主动探测 Starcat 自建服务的
//  `/healthz`，本文件只读取 GitHub 官方发布的状态声明。Statuspage 请求失败不能证明
//  GitHub 故障，因此失败时保留最后一次成功快照，并让 UI 显示“状态暂不可用”。
//

import Foundation

private let githubStatusDefaultInterval: Duration = .seconds(10 * 60)

/// GitHub Statuspage component 的公开状态。
///
/// `unknown` 是前向兼容兜底：Statuspage 新增枚举值时不应让整个 summary 解码失败。
enum GitHubComponentStatus: String, Decodable, Equatable, Sendable {
    case operational
    case degradedPerformance = "degraded_performance"
    case partialOutage = "partial_outage"
    case majorOutage = "major_outage"
    case underMaintenance = "under_maintenance"
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// 只有真实降级或中断才升级 Starcat toolbar；计划维护单独展示，不按故障处理。
    var requiresAttention: Bool {
        switch self {
        case .degradedPerformance, .partialOutage, .majorOutage:
            true
        case .operational, .underMaintenance, .unknown:
            false
        }
    }
}

/// GitHub Statuspage 的全局 indicator，仅用于保留官方摘要语义。
enum GitHubOverallStatus: String, Decodable, Equatable, Sendable {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

/// 最近一次成功读取的 GitHub 官方状态快照。
struct GitHubStatusSnapshot: Equatable, Sendable {
    let overallStatus: GitHubOverallStatus
    let apiRequestsStatus: GitHubComponentStatus
    let relevantIncidentCount: Int
    let otherIncidentCount: Int
    let fetchedAt: Date

    var hasRelevantIssue: Bool { apiRequestsStatus.requiresAttention }
}

/// GitHub Statuspage 请求错误。
enum GitHubStatusClientError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}

/// 读取 GitHub 公开 Status API 的轻量客户端。
///
/// summary endpoint 已同时返回全局状态、components 与未解决 incidents，因此单次请求
/// 就能完成状态面板所需判断，不需要 Starcat 后端代理，也不携带 GitHub OAuth token。
struct GitHubStatusClient: Sendable {
    static let statusPageURL = URL(string: "https://www.githubstatus.com/")!
    static let summaryURL = URL(string: "https://www.githubstatus.com/api/v2/summary.json")!

    private static let timeout: TimeInterval = 8
    private static let relevantComponentName = "API Requests"

    private let session: URLSession
    private let endpointURL: URL

    init(session: URLSession? = nil, endpointURL: URL = Self.summaryURL) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.endpointURL = endpointURL
    }

    /// 拉取并压缩为 Starcat 关心的快照。
    ///
    /// Starcat 的核心 GitHub 网络能力统一落在 `API Requests` component；其他组件事件
    /// 只计入 `otherIncidentCount`，避免 Copilot / Actions 故障污染主 toolbar。
    func fetchSnapshot(fetchedAt: Date = .now) async throws -> GitHubStatusSnapshot {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0 (github-status)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubStatusClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubStatusClientError.httpStatus(http.statusCode)
        }

        let summary = try JSONDecoder().decode(SummaryResponse.self, from: data)
        let apiComponent = summary.components.first { $0.name == Self.relevantComponentName }
        let apiComponentID = apiComponent?.id
        let relevantIncidentCount = summary.incidents.reduce(into: 0) { count, incident in
            guard let apiComponentID else { return }
            if incident.components.contains(where: { $0.id == apiComponentID }) {
                count += 1
            }
        }

        return GitHubStatusSnapshot(
            overallStatus: summary.status.indicator,
            apiRequestsStatus: apiComponent?.status ?? .unknown,
            relevantIncidentCount: relevantIncidentCount,
            otherIncidentCount: max(0, summary.incidents.count - relevantIncidentCount),
            fetchedAt: fetchedAt
        )
    }
}

private extension GitHubStatusClient {
    struct SummaryResponse: Decodable {
        let status: OverallStatusResponse
        let components: [ComponentResponse]
        let incidents: [IncidentResponse]
    }

    struct OverallStatusResponse: Decodable {
        let indicator: GitHubOverallStatus
    }

    struct ComponentResponse: Decodable {
        let id: String
        let name: String
        let status: GitHubComponentStatus
    }

    struct IncidentResponse: Decodable {
        let components: [IncidentComponentResponse]

        private enum CodingKeys: String, CodingKey {
            case components
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            components = try container.decodeIfPresent([IncidentComponentResponse].self, forKey: .components) ?? []
        }
    }

    struct IncidentComponentResponse: Decodable {
        let id: String
    }
}

/// toolbar 与状态 popover 共用的 GitHub 官方状态容器。
///
/// 约束：
/// - 首次启动立即请求，之后默认每 10 分钟轮询；popover 打开可触发即时刷新。
/// - 后台轮询与即时刷新共用 in-flight task，避免重复请求。
/// - 刷新失败保留成功快照；`lastRefreshFailed` 只表达状态源不可达，不升级为 GitHub 故障。
@MainActor
@Observable
final class GitHubStatusMonitor {
    private let client: GitHubStatusClient
    private let interval: Duration
    private var periodicTask: Task<Void, Never>?
    private var activeRefreshTask: Task<Void, Never>?

    private(set) var snapshot: GitHubStatusSnapshot?
    private(set) var isChecking = false
    private(set) var lastRefreshFailed = false

    init(
        client: GitHubStatusClient = GitHubStatusClient(),
        interval: Duration = githubStatusDefaultInterval
    ) {
        self.client = client
        self.interval = interval
    }

    var hasRelevantIssue: Bool { snapshot?.hasRelevantIssue == true }

    /// 首次立即读取，之后按固定间隔刷新 GitHub 官方状态。
    func startPeriodicChecks() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                do {
                    try await Task.sleep(for: self?.interval ?? githubStatusDefaultInterval)
                } catch {
                    break
                }
            }
        }
    }

    /// 停止轮询并取消当前请求，主要供生命周期收口与单元测试使用。
    func stopPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = nil
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        isChecking = false
    }

    /// 立即刷新；相同时间只允许一个 Statuspage 请求在途。
    func refreshNow() async {
        if let activeRefreshTask {
            await activeRefreshTask.value
            return
        }

        isChecking = true
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await client.fetchSnapshot()
                guard !Task.isCancelled else {
                    finishRefresh()
                    return
                }
                self.snapshot = snapshot
                lastRefreshFailed = false
            } catch is CancellationError {
                // 主动停止不属于状态源故障，不覆盖最后一次成功结果或失败标记。
            } catch {
                lastRefreshFailed = true
            }
            finishRefresh()
        }
        activeRefreshTask = task
        await task.value
    }

    private func finishRefresh() {
        isChecking = false
        activeRefreshTask = nil
    }
}
