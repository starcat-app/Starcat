//
//  DailyRadarSharingTests.swift
//  StarcatTests
//
//  离线验证日报公开白名单、multipart、幂等缓存、任务隔离及实际 Canvas PNG。
//  每个网络用例使用独立 host，避免并行 Suite 共享 URLProtocol 回调。
//

import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import Testing
@testable import Starcat

struct DailyRadarSharingTests {
    /// 仓库分享复用稳定身份；换服务隔离，重启恢复，并发点击只发布一次。
    @Test func repoSharesPersistAndRespectIdentity() async throws {
        let fixture = SharingFixture()
        defer { fixture.clean() }
        let api = fixture.api()
        let request = ShareRepoRequest(
            repo: ShareRepoDTO(
                fullName: "owner/project", description: nil, language: nil, starsCount: 1,
                forksCount: 0, subscribersCount: 0, topics: [], homepage: nil,
                url: "https://github.com/owner/project"
            ),
            aiSummary: ShareAISummaryDTO(
                oneLiner: "Summary", summary: "Summary", platforms: [], suitableFor: [],
                strengths: [], risks: [], suggestedTags: []
            )
        )
        async let first = api.shareRepo(request: request)
        async let second = api.shareRepo(request: request)
        let results = try await [first, second]
        #expect(results[0] == results[1])
        #expect(fixture.state.requests.count == 1)
        let restarted = fixture.api()
        #expect(await restarted.cachedRepoShare(fullName: "OWNER/PROJECT") == results[0])
        #expect(try await restarted.shareRepo(request: request) == results[0])
        #expect(fixture.state.requests.count == 1)
        await restarted.updateBaseURL(URL(string: "https://different.invalid")!)
        #expect(await restarted.cachedRepoShare(fullName: "owner/project") == nil)
        await restarted.updateBaseURL(fixture.baseURL)
        #expect(await restarted.cachedRepoShare(fullName: "owner/project") == results[0])
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.directory.appendingPathComponent("repos"), includingPropertiesForKeys: nil
        )
        let expired = ShareCreateResponse(
            shareUrl: results[0].shareUrl, shareId: "expired",
            expiresAt: "2020-01-01T00:00:00Z", createdAt: "2019-01-01T00:00:00Z"
        )
        try JSONEncoder().encode(expired).write(to: #require(files.first))
        #expect(await fixture.api().cachedRepoShare(fullName: "owner/project") == nil)
    }

    @Test func repoShareExpirationValidation() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func response(_ expiration: String?, url: String = "https://share.example/s/repo") -> ShareCreateResponse {
            ShareCreateResponse(shareUrl: url, shareId: "repo", expiresAt: expiration, createdAt: "")
        }
        #expect(response(nil).isReusable(at: now))
        #expect(response("2099-01-01T00:00:00.123Z").isReusable(at: now))
        #expect(!response("2020-01-01T00:00:00Z").isReusable(at: now))
        #expect(!response("invalid").isReusable(at: now))
        #expect(!response(nil, url: "file:///tmp/share").isReusable(at: now))
    }

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
        let restarted = fixture.api()
        let restored = await restarted.cachedDailyRadarShare(
            reportID: request.report.id, language: request.report.language, revision: request.report.revision
        )
        #expect(response == repeated)
        #expect(response == restored)
        #expect(try await restarted.shareDailyRadar(request: request, heroPNG: Data([2])) == response)
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
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: fixture.recordsDirectory, includingPropertiesForKeys: nil)
        #expect(cacheFiles.count == 1)
        let cached = String(decoding: try Data(contentsOf: #require(cacheFiles.first)), as: UTF8.self)
        #expect(!cached.contains("Report body"))
        #expect(!cached.contains("test-secret"))
    }

    /// 封面和正文排版变化复用已发布快照；报告、revision、语言与服务地址仍各自隔离。
    @Test func stableReportIdentityReusesPublishedCoverAndIsolatesVersions() async throws {
        let fixture = SharingFixture()
        defer { fixture.clean() }
        let api = fixture.api()
        let first = try DailyRadarShareRequest(detail: makeReport())
        _ = try await api.shareDailyRadar(request: first, heroPNG: Data([1]))
        _ = try await api.shareDailyRadar(request: DailyRadarShareRequest(detail: makeReport(revision: "r2")), heroPNG: Data([1]))
        _ = try await api.shareDailyRadar(request: DailyRadarShareRequest(detail: makeReport(language: "zh-Hans")), heroPNG: Data([1]))
        _ = try await api.shareDailyRadar(request: first, heroPNG: Data([2]))
        _ = try await api.shareDailyRadar(
            request: DailyRadarShareRequest(detail: makeReport(markdown: "Updated rendering of the same revision")),
            heroPNG: Data([3])
        )
        let weekly = try makeReport(category: "ai-weekly-events")
        #expect(await api.cachedDailyRadarShare(
            reportID: weekly.id, language: weekly.contentLanguage, revision: weekly.revision
        ) == nil)
        _ = try await api.shareDailyRadar(request: DailyRadarShareRequest(detail: weekly), heroPNG: Data([1]))
        #expect(await fixture.api().cachedDailyRadarShare(
            reportID: weekly.id, language: weekly.contentLanguage, revision: weekly.revision
        ) != nil)
        #expect(fixture.state.requests.count == 4)
        await api.updateBaseURL(fixture.baseURL.appendingPathComponent("other"))
        #expect(await api.cachedDailyRadarShare(
            reportID: first.report.id, language: first.report.language, revision: first.report.revision
        ) == nil)
        _ = try await api.shareDailyRadar(request: first, heroPNG: Data([1]))
        #expect(fixture.state.requests.count == 5)
        await api.updateBaseURL(fixture.baseURL)
        #expect(await api.cachedDailyRadarShare(
            reportID: first.report.id, language: first.report.language, revision: first.report.revision
        ) != nil)
        #expect(fixture.state.requests.count == 5)
    }

    /// 复现旧版磁盘格式：迁移不发 HTTP，删掉旧缓存后新 client 仍能按报告恢复。
    @Test func legacyCacheMigratesWithoutPublishingAgain() async throws {
        let fixture = SharingFixture()
        defer { fixture.clean() }
        let request = try DailyRadarShareRequest(detail: makeReport())
        let png = Data([1])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(request)
        let legacyIdentity = [
            fixture.baseURL.absoluteString,
            SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined(),
            SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        ].joined(separator: "|")
        let legacyKey = SHA256.hash(data: Data(legacyIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacyFile = fixture.legacyDirectory.appendingPathComponent(legacyKey + ".json")
        try FileManager.default.createDirectory(at: fixture.legacyDirectory, withIntermediateDirectories: true)
        try encoder.encode(makeResponse()).write(to: legacyFile)
        let api = fixture.api()
        #expect(await api.hasLegacyDailyRadarShares())
        #expect(await api.cachedDailyRadarShare(request: request, heroPNG: png) == makeResponse())
        #expect(!FileManager.default.fileExists(atPath: legacyFile.path))
        #expect(!(await api.hasLegacyDailyRadarShares()))
        #expect(await fixture.api().cachedDailyRadarShare(
            reportID: request.report.id, language: request.report.language, revision: request.report.revision
        ) == makeResponse())
        #expect(fixture.state.requests.isEmpty)
    }

    /// 损坏或不安全的本地记录不得使分享入口变成已生成，查询也不能隐式上传。
    @Test func invalidRecordsAreIgnoredWithoutNetworkRequests() async throws {
        let fixture = SharingFixture()
        defer { fixture.clean() }
        let report = try makeReport()
        let request = try DailyRadarShareRequest(detail: report)
        let api = fixture.api()
        #expect(await api.cachedDailyRadarShare(
            reportID: report.id, language: report.contentLanguage, revision: report.revision
        ) == nil)
        #expect(fixture.state.requests.isEmpty)
        _ = try await api.shareDailyRadar(request: request, heroPNG: Data([1]))
        let files = try FileManager.default.contentsOfDirectory(at: fixture.recordsDirectory, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        try JSONEncoder().encode(makeResponse(url: "file:///tmp/share")).write(to: file)
        #expect(await fixture.api().cachedDailyRadarShare(
            reportID: report.id, language: report.contentLanguage, revision: report.revision
        ) == nil)
        try Data("broken record".utf8).write(to: file)
        #expect(await fixture.api().cachedDailyRadarShare(
            reportID: report.id, language: report.contentLanguage, revision: report.revision
        ) == nil)
        #expect(fixture.state.requests.count == 1)
    }

    @Test func concurrentRequestsShareOneUpload() async throws {
        let fixture = SharingFixture()
        defer { fixture.clean() }
        let api = fixture.api()
        let request = try DailyRadarShareRequest(detail: makeReport())
        async let first = api.shareDailyRadar(request: request, heroPNG: Data([1]))
        async let second = api.shareDailyRadar(request: request, heroPNG: Data([2]))
        let responses = try await (first, second)
        #expect(responses.0 == responses.1)
        #expect(fixture.state.requests.count == 1)
    }

    /// 第二个客户端使用独立的记录目录和凭据，只发 GET 即可恢复首发的链接、封面与时间。
    @MainActor @Test func anotherClientFindsPublishedShareWithoutRenderingOrUploading() async throws {
        let fixture = SharingFixture()
        defer { fixture.clean() }
        let report = try makeReport(revision: "r1+fix&preview")
        let first = try await fixture.api().shareDailyRadar(
            request: DailyRadarShareRequest(detail: report), heroPNG: Data([1])
        )
        let secondDirectory = fixture.directory.appendingPathComponent("second-records")
        let second = fixture.api(apiKey: "second-token", recordsDirectory: secondDirectory)
        let lookup: @MainActor (DailyRadarReport) async throws -> DailyRadarShareResponse? = {
            try await second.lookupDailyRadarShare(reportID: $0.id, language: $0.contentLanguage, revision: $0.revision)
        }
        let cached: @MainActor (DailyRadarReport) async -> DailyRadarShareResponse? = {
            await second.cachedDailyRadarShare(reportID: $0.id, language: $0.contentLanguage, revision: $0.revision)
        }
        #expect(await cached(report) == nil)
        let operations = DailyRadarShareOperations(
            renderCover: { _ in
                Issue.record("Published report triggered local rendering")
                throw DailyRadarShareError.coverFailed
            },
            createShare: { _, _ in
                Issue.record("Published report triggered an upload")
                throw DailyRadarShareError.unavailable
            },
            cachedShare: cached, lookupShare: lookup
        )
        let store = DailyRadarShareTaskStore()
        let identity = DailyRadarShareTaskStore.identity(report: report, serviceIdentity: "")
        await store.restore(report: report, operations: operations)
        #expect(store.jobs[identity] == nil)
        #expect(fixture.state.requests.map(\.httpMethod) == ["POST"])
        store.start(report: report, operations: operations)
        try await waitForTask(store, identity: identity)
        let cachedResponse = await cached(report)
        let restored = try #require(cachedResponse)
        #expect(store.jobs[identity]?.state == .success(restored))
        #expect(store.jobs[identity]?.coverImage == nil)
        #expect(restored.alreadyExists)
        #expect(restored.shareID == first.shareID)
        #expect(restored.shareURL == first.shareURL)
        #expect(restored.heroPNGURL == first.heroPNGURL)
        #expect(restored.heroWebPURL == first.heroWebPURL)
        #expect(restored.createdAt == first.createdAt)
        #expect(fixture.state.requests.map(\.httpMethod) == ["POST", "GET"])
        let sent = try #require(fixture.state.requests.last)
        #expect(sent.url?.path == "/api/v1/daily-radar/shares")
        #expect(sent.url?.absoluteString.contains("revision=r1%2Bfix%26preview") == true)
        let query = try #require(sent.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        #expect(query == [
            URLQueryItem(name: "report_id", value: report.id),
            URLQueryItem(name: "language", value: report.contentLanguage),
            URLQueryItem(name: "revision", value: report.revision),
        ])
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer second-token")
        #expect(sent.value(forHTTPHeaderField: "X-SC-Svc") == "sharing")
        #expect(fixture.state.bodies.last?.isEmpty == true)
        #expect(await fixture.api(recordsDirectory: secondDirectory).cachedDailyRadarShare(
            reportID: report.id, language: report.contentLanguage, revision: report.revision
        ) == restored)
    }

    /// 只有明确的未发布才进入创建流程，旧服务路由错误及服务异常不触发上传。
    @MainActor @Test(arguments: [(404, "DAILY_RADAR_SHARE_NOT_FOUND", true), (404, "NOT_FOUND", false),
                                 (405, "METHOD_NOT_ALLOWED", false), (503, "SERVICE_UNAVAILABLE", false)])
    func onlyExplicitLookupMissAllowsUpload(status: Int, code: String, shouldUpload: Bool) async throws {
        let fixture = SharingFixture(lookupStatus: status, errorCode: code)
        defer { fixture.clean() }
        let api = fixture.api()
        let report = try makeReport()
        let image = try smallImage()
        var renders = 0
        let operations = DailyRadarShareOperations(
            renderCover: { _ in
                renders += 1
                return (image, Data([1]))
            },
            createShare: { try await api.shareDailyRadar(request: $0, heroPNG: $1) },
            lookupShare: {
                try await api.lookupDailyRadarShare(reportID: $0.id, language: $0.contentLanguage, revision: $0.revision)
            }
        )
        let store = DailyRadarShareTaskStore()
        let identity = DailyRadarShareTaskStore.identity(report: report, serviceIdentity: "")
        store.start(report: report, operations: operations)
        try await waitForTask(store, identity: identity)
        #expect(fixture.state.requests.map(\.httpMethod) == (shouldUpload ? ["GET", "POST"] : ["GET"]))
        #expect(renders == (shouldUpload ? 1 : 0))
        #expect(store.jobs[identity]?.state == (shouldUpload ? .success(makeResponse()) : .failure(.unavailable)))
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
        #expect(!FileManager.default.fileExists(atPath: fixture.recordsDirectory.path))
    }

    @Test func unsafeResponseURLsAreRejected() throws {
        let response = makeResponse(url: "javascript:alert(1)")
        #expect(throws: DailyRadarShareError.unavailable) { try response.validated() }
    }

    /// 不使用真实网络：任务挂在工作区，重试继续使用第一次点击的不可变快照。
    @MainActor @Test func taskDeduplicationAndRetryKeepTheOriginalSnapshot() async throws {
        let store = DailyRadarShareTaskStore()
        let report = try makeReport()
        let identity = DailyRadarShareTaskStore.identity(report: report, serviceIdentity: "")
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
        try await waitForTask(store, identity: identity)
        #expect(uploads == 1)
        #expect(store.jobs[identity]?.state == .failure(.unavailable))
        #expect(!store.isShared(identity: identity))
        store.retry(identity: identity, operations: operations)
        try await waitForTask(store, identity: identity)
        #expect(uploads == 2)
        #expect(identities == ["r1", "r1"])
        #expect(store.jobs[identity]?.coverImage != nil)
        #expect(store.isShared(identity: identity))
        store.retry(identity: identity, operations: operations)
        await Task.yield()
        #expect(uploads == 2)
    }

    @MainActor @Test func switchingReportsKeepsIndependentResults() async throws {
        let store = DailyRadarShareTaskStore()
        let first = try makeReport()
        let second = try makeReport(revision: "r2")
        let firstIdentity = DailyRadarShareTaskStore.identity(report: first, serviceIdentity: "")
        let secondIdentity = DailyRadarShareTaskStore.identity(report: second, serviceIdentity: "")
        let image = try smallImage()
        let operations = DailyRadarShareOperations(
            renderCover: { _ in (image, Data([1])) },
            createShare: { request, _ in makeResponse(url: "https://share.example/d/\(request.report.revision)") }
        )
        store.start(report: first, operations: operations)
        store.start(report: second, operations: operations)
        try await waitForTask(store, identity: firstIdentity)
        try await waitForTask(store, identity: secondIdentity)
        #expect(store.jobs[firstIdentity]?.state == .success(makeResponse(url: "https://share.example/d/r1")))
        #expect(store.jobs[secondIdentity]?.state == .success(makeResponse(url: "https://share.example/d/r2")))
    }

    /// 重启后的查询与直接点击都优先恢复链接，封面失败也不能阻止访问已发布结果。
    @MainActor @Test func restoredLinksSkipRenderingAndUploadingAndRespectServiceIdentity() async throws {
        let report = try makeReport(category: "ai-weekly-events")
        let firstIdentity = DailyRadarShareTaskStore.identity(report: report, serviceIdentity: "first")
        let otherIdentity = DailyRadarShareTaskStore.identity(report: report, serviceIdentity: "other")
        var renders = 0
        var uploads = 0
        let cached = makeResponse()
        let operations = DailyRadarShareOperations(
            renderCover: { _ in
                renders += 1
                throw DailyRadarShareError.coverFailed
            },
            createShare: { _, _ in
                uploads += 1
                return cached
            },
            serviceIdentity: "first",
            cachedShare: { _ in cached }
        )
        let store = DailyRadarShareTaskStore()
        await store.restore(report: report, operations: operations)
        #expect(store.isShared(identity: firstIdentity))
        #expect(!store.isShared(identity: otherIdentity))
        #expect(store.jobs[firstIdentity]?.state == .success(cached))
        store.start(report: report, operations: operations)
        #expect(!store.isRunning(identity: firstIdentity))
        let restarted = DailyRadarShareTaskStore()
        restarted.start(report: report, operations: operations)
        try await waitForTask(restarted, identity: firstIdentity)
        #expect(restarted.isShared(identity: firstIdentity))
        let other = DailyRadarShareOperations(
            renderCover: operations.renderCover, createShare: operations.createShare,
            serviceIdentity: "other", cachedShare: { _ in nil }
        )
        await store.restore(report: report, operations: other)
        #expect(!store.isShared(identity: otherIdentity))
        #expect(!store.isRunning(identity: otherIdentity))
        #expect(store.jobs[otherIdentity] == nil)
        store.start(report: report, operations: other)
        try await waitForTask(store, identity: otherIdentity)
        #expect(store.jobs[otherIdentity]?.state == .failure(.coverFailed))
        #expect(store.isShared(identity: firstIdentity))
        #expect(renders == 1)
        #expect(uploads == 0)
    }

    /// 实际离屏 Canvas 必须稳定生成符合发布规格的 1600×840 PNG。
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
    private func makeReport(
        revision: String = "r1", language: String = "en", markdown: String? = nil, category: String = "ai-cli"
    ) throws -> DailyRadarReport {
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
            "id": "agents-radar:2026-11-13:\(category)", "revision": revision, "edition_date": "2026-11-13",
            "category": category, "period": category == "ai-weekly-events" ? "weekly" : "daily", "title": "Report", "summary": "Summary",
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
    let lookupStatus: Int
    let errorCode: String
    var requests: [URLRequest] { lock.withLock { captured } }
    var bodies: [Data] { lock.withLock { capturedBodies } }

    init(status: Int, lookupStatus: Int?, errorCode: String) {
        self.status = status
        self.lookupStatus = lookupStatus ?? status
        self.errorCode = errorCode
    }

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
    var recordsDirectory: URL { directory.appendingPathComponent("records") }
    var legacyDirectory: URL { directory.appendingPathComponent("legacy") }

    init(status: Int = 200, lookupStatus: Int? = nil, errorCode: String = "FIXTURE") {
        state = SharingFixtureState(status: status, lookupStatus: lookupStatus, errorCode: errorCode)
        SharingTestProtocol.register(state, host: host)
    }

    func api(apiKey: String = "test-secret", recordsDirectory: URL? = nil) -> ShareAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharingTestProtocol.self]
        return ShareAPI(
            baseURL: baseURL, apiKey: apiKey, session: URLSession(configuration: configuration),
            dailyRadarCacheDirectory: legacyDirectory, dailyRadarShareDirectory: recordsDirectory ?? self.recordsDirectory,
            repoShareDirectory: directory.appendingPathComponent("repos")
        )
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
        let lookup = request.httpMethod == "GET"
        let status = lookup ? state.lookupStatus : state.status
        let payload = status == 200
            ? #"{"schema_version":1,"data":{"share_id":"fixture","share_url":"https://share.example/d/fixture","already_exists":\#(lookup),"hero_webp_url":"https://share.example/d/fixture/hero.webp","hero_png_url":"https://share.example/d/fixture/hero.png","created_at":"2026-11-13T00:00:00Z"}}"#
            : #"{"schema_version":1,"error":{"code":"\#(state.errorCode)","message":"internal-path-must-not-be-shown"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
