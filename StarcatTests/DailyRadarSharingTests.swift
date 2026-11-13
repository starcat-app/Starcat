//
//  DailyRadarSharingTests.swift
//  StarcatTests
//
//  离线验证日报公开白名单、multipart、幂等缓存、任务隔离及实际 Canvas PNG。
//  每个网络用例使用独立 host，避免并行 Suite 共享 URLProtocol 回调。
//

import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Starcat

struct DailyRadarSharingTests {
    /// 结构化正文剥离 metadata/H1，私有项目与外部封面地址不进入公开 DTO。
    @Test func snapshotContainsOnlyPublicReportFields() throws {
        let report = try makeReport()
        let request = try DailyRadarShareRequest(detail: report)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(Set(json.keys) == ["report", "projects"])
        #expect(request.report.title == "Structured report")
        #expect(request.report.summary == "Structured summary")
        #expect(request.report.readingMinutes == 6)
        #expect(request.report.markdown == "## News\n\nReport body.")
        #expect(request.report.revision == "r1")
        #expect(request.projects.map(\.repo) == ["public-repo"])
        let bytes = try JSONEncoder().encode(request)
        let payload = String(decoding: bytes, as: UTF8.self)
        #expect(!payload.contains("private-repo"))
        #expect(!payload.contains("hero_url"))
        #expect(!payload.contains("external-cover"))
        #expect(!payload.contains("is_private"))
    }

    @Test func incompleteOrOversizedReportsAreRejected() throws {
        #expect(throws: DailyRadarShareError.reportUnavailable) {
            try DailyRadarShareRequest(detail: makeReport(markdown: "   "))
        }
        #expect(throws: DailyRadarShareError.tooLarge) {
            try DailyRadarShareRequest(detail: makeReport(markdown: String(repeating: "中", count: 350_000)))
        }
    }

    /// 检查真实 HTTP body 与磁盘持久缓存；新 client 实例应直接恢复公开 URL。
    @Test func multipartAndPersistentCacheDoNotPersistPersonalData() async throws {
        let fixture = SharingFixture()
        defer { fixture.clean() }
        let request = try DailyRadarShareRequest(detail: makeReport())
        let png = Data("PNG-fixture".utf8)
        let api = fixture.api()
        let response = try await api.shareDailyRadar(request: request, heroPNG: png)
        let repeated = try await api.shareDailyRadar(request: request, heroPNG: png)
        let restored = try await fixture.api().shareDailyRadar(request: request, heroPNG: png)
        #expect(response == repeated)
        #expect(response == restored)
        #expect(fixture.state.requests.count == 1)
        let sent = try #require(fixture.state.requests.first)
        #expect(sent.url?.path == "/api/v1/daily-radar/shares")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
        #expect(sent.value(forHTTPHeaderField: "X-SC-Svc") == "sharing")
        #expect(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: try #require(fixture.state.bodies.first), as: UTF8.self)
        #expect(body.contains("name=\"request\""))
        #expect(body.contains("name=\"hero\"; filename=\"hero.png\""))
        #expect(body.contains("\"revision\":\"r1\""))
        #expect(body.contains("\"category_id\":\"ai-cli\""))
        #expect(!body.contains("test-secret"))
        #expect(!body.contains("private-repo"))
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        #expect(cacheFiles.count == 1)
        let cached = String(decoding: try Data(contentsOf: #require(cacheFiles.first)), as: UTF8.self)
        #expect(!cached.contains("Report body"))
        #expect(!cached.contains("test-secret"))
    }

    @Test func revisionLanguageCoverAndServiceChangesInvalidateCache() async throws {
        let fixture = SharingFixture()
        defer { fixture.clean() }
        let api = fixture.api()
        let first = try DailyRadarShareRequest(detail: makeReport())
        _ = try await api.shareDailyRadar(request: first, heroPNG: Data([1]))
        _ = try await api.shareDailyRadar(request: DailyRadarShareRequest(detail: makeReport(revision: "r2")), heroPNG: Data([1]))
        _ = try await api.shareDailyRadar(request: DailyRadarShareRequest(detail: makeReport(language: "zh-Hans")), heroPNG: Data([1]))
        _ = try await api.shareDailyRadar(request: first, heroPNG: Data([2]))
        await api.updateBaseURL(fixture.baseURL.appendingPathComponent("other"))
        _ = try await api.shareDailyRadar(request: first, heroPNG: Data([1]))
        #expect(fixture.state.requests.count == 5)
    }

    @Test func concurrentRequestsShareOneUpload() async throws {
        let fixture = SharingFixture()
        defer { fixture.clean() }
        let api = fixture.api()
        let request = try DailyRadarShareRequest(detail: makeReport())
        async let first = api.shareDailyRadar(request: request, heroPNG: Data([1]))
        async let second = api.shareDailyRadar(request: request, heroPNG: Data([1]))
        let responses = try await (first, second)
        #expect(responses.0 == responses.1)
        #expect(fixture.state.requests.count == 1)
    }

    @Test(arguments: [(401, DailyRadarShareError.configuration), (409, .conflict), (413, .tooLarge), (429, .rateLimited), (503, .unavailable)])
    func errorsHaveStableRecoverableCopy(status: Int, expected: DailyRadarShareError) async throws {
        let fixture = SharingFixture(status: status)
        defer { fixture.clean() }
        do {
            _ = try await fixture.api().shareDailyRadar(
                request: DailyRadarShareRequest(detail: makeReport()), heroPNG: Data([1])
            )
            Issue.record("Expected server error")
        } catch {
            #expect(DailyRadarShareError.from(error) == expected)
            #expect(!expected.localizationKey.contains("internal-path"))
        }
    }

    @Test func unsafeResponseURLsAreRejected() throws {
        let response = makeResponse(url: "javascript:alert(1)")
        #expect(throws: DailyRadarShareError.unavailable) { try response.validated() }
    }

    /// 不使用真实网络：任务挂在工作区，重试继续使用第一次点击的不可变快照。
    @MainActor @Test func taskDeduplicationAndRetryKeepTheOriginalSnapshot() async throws {
        let store = DailyRadarShareTaskStore()
        let report = try makeReport()
        let image = try smallImage()
        var uploads = 0
        var identities: [String] = []
        let operations = DailyRadarShareOperations(
            renderCover: { _ in (image, Data([1])) },
            createShare: { request, _ in
                uploads += 1
                identities.append(request.report.revision)
                if uploads == 1 { throw DailyRadarShareError.unavailable }
                return makeResponse()
            }
        )
        store.start(report: report, operations: operations)
        store.start(report: report, operations: operations)
        try await waitForTask(store, identity: report.contentIdentity)
        #expect(uploads == 1)
        #expect(store.jobs[report.contentIdentity]?.state == .failure(.unavailable))
        store.retry(identity: report.contentIdentity, operations: operations)
        try await waitForTask(store, identity: report.contentIdentity)
        #expect(uploads == 2)
        #expect(identities == ["r1", "r1"])
        #expect(store.jobs[report.contentIdentity]?.coverImage != nil)
        store.retry(identity: report.contentIdentity, operations: operations)
        await Task.yield()
        #expect(uploads == 2)
    }

    @MainActor @Test func switchingReportsKeepsIndependentResults() async throws {
        let store = DailyRadarShareTaskStore()
        let first = try makeReport()
        let second = try makeReport(revision: "r2")
        let image = try smallImage()
        let operations = DailyRadarShareOperations(
            renderCover: { _ in (image, Data([1])) },
            createShare: { request, _ in makeResponse(url: "https://share.example/d/\(request.report.revision)") }
        )
        store.start(report: first, operations: operations)
        store.start(report: second, operations: operations)
        try await waitForTask(store, identity: first.contentIdentity)
        try await waitForTask(store, identity: second.contentIdentity)
        #expect(store.jobs[first.contentIdentity]?.state == .success(makeResponse(url: "https://share.example/d/r1")))
        #expect(store.jobs[second.contentIdentity]?.state == .success(makeResponse(url: "https://share.example/d/r2")))
    }

    /// 实际离屏 Canvas 必须稳定生成 1600×840 PNG，避免服务端同 revision 原图 hash 冲突。
    @MainActor @Test func realCoverHasFixedDimensionsAndDeterministicPNG() throws {
        let report = try makeReport()
        let first = try DailyRadarShareCover.render(report: report)
        let second = try DailyRadarShareCover.render(report: report)
        #expect(first.image.width == 1600)
        #expect(first.image.height == 840)
        #expect(first.png.count <= 3_145_728)
        #expect(first.png == second.png)
        let source = try #require(CGImageSourceCreateWithData(first.png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        // 通过测试框架导出真实 PNG，兼容 App Store 沙箱，不读取或操作用户屏幕。
        Attachment.record([UInt8](first.png), named: "daily-radar-hero.png")
        print("DailyRadar sharing test hero: \(first.png.count) bytes")
    }

    @MainActor private func waitForTask(_ store: DailyRadarShareTaskStore, identity: String) async throws {
        for _ in 0..<2_000 {
            if !store.isRunning(identity: identity) { return }
            await Task.yield()
        }
        throw DailyRadarShareError.unavailable
    }

    private func smallImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private func makeResponse(url: String = "https://share.example/d/fixture") -> DailyRadarShareResponse {
        DailyRadarShareResponse(
            shareID: "fixture", shareURL: URL(string: url)!, alreadyExists: false,
            heroWebPURL: URL(string: "https://share.example/d/fixture/hero.webp")!,
            heroPNGURL: URL(string: "https://share.example/d/fixture/hero.png")!, createdAt: "2026-11-13T00:00:00Z"
        )
    }

    /// 通过实际 JSON 解码创建报告，覆盖线上 DTO 的字段映射及 private 防线。
    private func makeReport(revision: String = "r1", language: String = "en", markdown: String? = nil) throws -> DailyRadarReport {
        let body = markdown ?? """
        ---
        {"article_format":1,"title":"Structured report","summary":"Structured summary","edition_date":"2026-11-13","reading_minutes":6}
        ---

        # Structured report

        ## News

        Report body.
        """
        let project: (String, Bool) -> [String: Any] = { name, isPrivate in
            [
                "repo": ["gh_repo_id": isPrivate ? 2 : 1, "full_name": "owner/\(name)", "owner": "owner", "repo": name, "is_private": isPrivate],
                "evidence_url": "https://github.com/owner/\(name)",
            ]
        }
        let payload: [String: Any] = [
            "id": "agents-radar:2026-11-13:ai-cli", "revision": revision, "edition_date": "2026-11-13",
            "category": "ai-cli", "period": "daily", "title": "Report", "summary": "Summary",
            "reading_minutes": 3, "cover": ["kind": "category", "fallback": "orbit", "alt": "Cover", "hero_url": "https://external-cover.example/image.png"],
            "related_project_count": 2, "content_language": language, "available_languages": ["en", "zh-Hans"],
            "markdown": body, "related_projects": [project("public-repo", false), project("private-repo", true)],
        ]
        return try JSONDecoder().decode(DailyRadarReport.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

/// 锁只保护 URLProtocol 线程间传递的 fixture 数据，不参与 App 生产实现。
private final class SharingFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private var capturedBodies: [Data] = []
    let status: Int
    var requests: [URLRequest] { lock.withLock { captured } }
    var bodies: [Data] { lock.withLock { capturedBodies } }

    init(status: Int) { self.status = status }

    func capture(_ request: URLRequest) {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        lock.withLock {
            captured.append(request)
            capturedBodies.append(body)
        }
    }
}

/// 独立缓存目录与 host 保证并行运行时不命中其它测试的缓存或 Stub。
private struct SharingFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let host = "\(UUID().uuidString).daily-radar-sharing.invalid"
    let state: SharingFixtureState
    var baseURL: URL { URL(string: "https://\(host)")! }

    init(status: Int = 200) {
        state = SharingFixtureState(status: status)
        SharingTestProtocol.register(state, host: host)
    }

    func api() -> ShareAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharingTestProtocol.self]
        return ShareAPI(baseURL: baseURL, apiKey: "test-secret", session: URLSession(configuration: configuration), dailyRadarCacheDirectory: directory)
    }

    func clean() {
        SharingTestProtocol.unregister(host: host)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 只拦截本 Suite 的 .invalid 域名，禁止因 fixture 丢失而发送真实 HTTP。
private final class SharingTestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: SharingFixtureState] = [:]
    static func register(_ state: SharingFixtureState, host: String) { lock.withLock { handlers[host] = state } }
    static func unregister(host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".daily-radar-sharing.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let state = Self.lock.withLock({ Self.handlers[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        state.capture(request)
        let payload = state.status == 200
            ? #"{"schema_version":1,"data":{"share_id":"fixture","share_url":"https://share.example/d/fixture","already_exists":false,"hero_webp_url":"https://share.example/d/fixture/hero.webp","hero_png_url":"https://share.example/d/fixture/hero.png","created_at":"2026-11-13T00:00:00Z"}}"#
            : #"{"schema_version":1,"error":{"code":"FIXTURE","message":"internal-path-must-not-be-shown"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: state.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
