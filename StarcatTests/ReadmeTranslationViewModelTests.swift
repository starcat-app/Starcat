//
//  ReadmeTranslationViewModelTests.swift
//  StarcatTests
//
//  切仓 / 取消后，过期的缓存命中和 onBatch 不能写进当前详情页。
//  共享 VM 还要按 identity 过滤可见 renderState，覆盖探索 / 活动未走
//  HomeView.selectedRepoID prepare 的路径。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("ReadmeTranslationViewModel 切仓守门")
struct ReadmeTranslationViewModelTests {

    @Test("缓存命中返回后若已切仓，不得把 A 的译文写进 B")
    func staleCacheDoesNotPaintSwitchedRepo() async {
        let (vm, fake) = makeHarness()
        let alpha = makePage(
            owner: "alpha",
            repo: "one",
            translatedText: "ALPHA-TRANSLATION"
        )
        fake.store(alpha)

        vm.prepare(page: alpha)
        await settle()

        fake.park(owner: alpha.owner)
        vm.toggle(page: alpha)
        await waitUntil { fake.hasParkedCache(owner: alpha.owner) }

        let bravo = makePage(owner: "bravo", repo: "two", translatedText: "BRAVO-TRANSLATION")
        vm.prepare(page: bravo)
        fake.releaseParked(owner: alpha.owner)
        await settle()

        #expect(vm.displayMode == .showingOriginal)
        #expect(!vm.renderState.isVisible)
        #expect(vm.renderState.translations.isEmpty)
        fake.finishHangingWork()
    }

    @Test("切到 B 并开译后，A 的迟到缓存不得覆盖 B 或掐掉 B 的任务")
    func staleCacheDoesNotAbortNewTranslation() async {
        let (vm, fake) = makeHarness()
        let alpha = makePage(
            owner: "alpha",
            repo: "one",
            translatedText: "ALPHA-TRANSLATION"
        )
        let bravo = makePage(
            owner: "bravo",
            repo: "two",
            translatedText: "BRAVO-TRANSLATION"
        )
        fake.store(alpha)

        vm.prepare(page: alpha)
        await settle()

        fake.park(owner: alpha.owner)
        vm.toggle(page: alpha)
        await waitUntil { fake.hasParkedCache(owner: alpha.owner) }

        fake.hangTranslate = true
        vm.prepare(page: bravo)
        vm.toggle(page: bravo)
        await waitUntil { fake.hasHangingTranslate }

        #expect(vm.isTranslating)
        #expect(!vm.renderState.isVisible)

        fake.releaseParked(owner: alpha.owner)
        await settle()

        #expect(vm.isTranslating)
        #expect(!vm.renderState.isVisible)
        #expect(vm.renderState.translations.isEmpty)

        vm.cancelTranslation()
        fake.finishHangingWork()
    }

    @Test("取消后迟到的缓存不得再上屏")
    func cancelledTaskDoesNotApplyCache() async {
        let (vm, fake) = makeHarness()
        let alpha = makePage(
            owner: "alpha",
            repo: "one",
            translatedText: "ALPHA-TRANSLATION"
        )
        fake.store(alpha)

        vm.prepare(page: alpha)
        await settle()

        fake.park(owner: alpha.owner)
        vm.toggle(page: alpha)
        await waitUntil { fake.hasParkedCache(owner: alpha.owner) }

        vm.cancelTranslation()
        fake.releaseParked(owner: alpha.owner)
        await settle()

        #expect(vm.displayMode == .showingOriginal)
        #expect(!vm.renderState.isVisible)
        #expect(vm.renderState.translations.isEmpty)
        fake.finishHangingWork()
    }

    @Test("未切 identity 时，B 详情也不得把 A 的译文当成可见状态")
    func visibleRenderStateIsScopedToIdentity() async {
        let (vm, fake) = makeHarness()
        let alpha = makePage(
            owner: "alpha",
            repo: "one",
            translatedText: "ALPHA-TRANSLATION"
        )
        let bravo = makePage(
            owner: "bravo",
            repo: "two",
            translatedText: "BRAVO-TRANSLATION"
        )
        fake.store(alpha)

        vm.prepare(page: alpha)
        await settle()
        vm.toggle(page: alpha)
        await settle()

        #expect(vm.visibleRenderState(matching: alpha.identity).isVisible)
        #expect(vm.isShowingTranslation(matching: alpha.identity))
        #expect(!vm.visibleRenderState(matching: bravo.identity).isVisible)
        #expect(!vm.isShowingTranslation(matching: bravo.identity))
        #expect(!vm.isActivelyTranslating(matching: bravo.identity))
        fake.finishHangingWork()
    }

    @Test("切仓后迟到的 onBatch 不得写入当前页")
    func staleBatchDoesNotPaintSwitchedRepo() async {
        let (vm, fake) = makeHarness()
        let alpha = makePage(
            owner: "alpha",
            repo: "one",
            translatedText: "ALPHA-TRANSLATION"
        )
        let bravo = makePage(
            owner: "bravo",
            repo: "two",
            translatedText: "BRAVO-TRANSLATION"
        )

        fake.hangTranslate = true
        vm.prepare(page: alpha)
        vm.toggle(page: alpha)
        await waitUntil { fake.hasHangingTranslate }

        vm.prepare(page: bravo)
        fake.fireLatestBatch(
            id: alpha.segment.id,
            translatedText: "STREAM-A"
        )
        await settle()

        #expect(vm.displayMode == .showingOriginal)
        #expect(!vm.renderState.isVisible)
        #expect(vm.renderState.translations.isEmpty)

        vm.cancelTranslation()
        fake.finishHangingWork()
    }

    @Test("README 与同仓不同路径的 Skill 分别命中缓存，译文可切回原文")
    func skillTranslationCachesAreIsolated() async throws {
        let (vm, fake) = makeHarness()
        let readme = try await makeControl(viewModel: vm)
        var first = readme
        first.documentPath = "skills/review/SKILL.md"
        var second = readme
        second.documentPath = "other/review/SKILL.md"

        #expect(readme.identity == ReadmeTranslationViewModel.readmeIdentity(for: readme.repo))
        #expect(readme.cacheOwner == readme.repo.owner && readme.cacheRepo == readme.repo.name)
        #expect(first.cacheOwner != readme.cacheOwner)
        #expect(first.identity != second.identity && first.cacheRepo != second.cacheRepo)
        #expect(!first.cacheRepo.contains("/"))

        let pages = [
            makePage(control: readme, translatedText: "README"),
            makePage(control: first, translatedText: "FIRST-SKILL"),
            makePage(control: second, translatedText: "SECOND-SKILL")
        ]
        pages.forEach { fake.store($0) }
        for page in pages {
            vm.prepare(page: page)
            await settle()
            vm.toggle(page: page)
            await settle()
            #expect(vm.renderState.translations.map(\.translatedText) == [page.translatedText])
            #expect(vm.isShowingTranslation(matching: page.identity))
            #expect(vm.errorMessage == nil)
            vm.toggle(page: page)
            #expect(!vm.renderState.isVisible)
            #expect(vm.displayMode == .showingOriginal)
        }
        fake.finishHangingWork()
    }

    @Test("Skill 正文更新复用原缓存位置，并标记旧译文过期")
    func updatedSkillMarksTranslationStale() async throws {
        let (vm, fake) = makeHarness()
        var control = try await makeControl(viewModel: vm)
        control.documentPath = "skills/review/SKILL.md"
        let page = makePage(control: control, translatedText: "CACHED-SKILL")
        fake.store(page)
        vm.prepare(page: page)
        await settle()
        #expect(!vm.cacheIsStale)

        vm.prepare(
            identity: control.identity, cacheOwner: control.cacheOwner, cacheRepo: control.cacheRepo,
            sourceHtml: "<p>Updated skill instructions with a different source fingerprint.</p>",
            targetLanguage: .simplifiedChinese, mode: .segmented
        )
        await settle()
        #expect(vm.cacheIsStale)
        #expect(!vm.renderState.isVisible)
        fake.finishHangingWork()
    }

    @Test("切换同仓 Skill 或关闭阅读窗口后，旧翻译批次不得上屏", arguments: [false, true])
    func staleSkillBatchDoesNotPaintCurrentDocument(closingWindow: Bool) async throws {
        let (vm, fake) = makeHarness()
        var first = try await makeControl(viewModel: vm)
        first.documentPath = "skills/review/SKILL.md"
        var second = first
        second.documentPath = "skills/implement/SKILL.md"
        let page = makePage(control: first, translatedText: "OLD-SKILL")
        fake.hangTranslate = true
        vm.prepare(page: page)
        vm.toggle(page: page)
        await waitUntil { fake.hasHangingTranslate }

        if closingWindow {
            vm.prepare(repo: nil, sourceHtml: nil, targetLanguage: .simplifiedChinese, mode: .segmented)
        } else {
            vm.prepare(page: makePage(control: second, translatedText: "NEW-SKILL"))
        }
        fake.fireLatestBatch(id: page.segment.id, translatedText: "LATE-SKILL")
        await settle()

        #expect(!vm.isTranslating)
        #expect(!vm.visibleRenderState(matching: second.identity).isVisible)
        #expect(vm.renderState.translations.isEmpty)
        fake.finishHangingWork()
    }

    // MARK: - 辅助

    /// 使用真实仓库模型与隔离偏好验证控件的缓存路由，测试不访问用户翻译目录或模型服务。
    private func makeControl(viewModel: ReadmeTranslationViewModel) async throws -> ReadmeTranslationControl {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1)
        let repo = try #require(try await GRDBRepoRepository(database: database).findById(1))
        let defaults = try #require(UserDefaults(suiteName: "skill-translation-\(UUID().uuidString)"))
        return ReadmeTranslationControl(
            repo: repo, translationVM: viewModel, settings: AppSettings(defaults: defaults)
        )
    }

    private func makePage(control: ReadmeTranslationControl, translatedText: String) -> TranslationTestPage {
        makePage(
            owner: control.cacheOwner, repo: control.cacheRepo,
            translatedText: translatedText, identity: control.identity
        )
    }

    private func makeHarness() -> (ReadmeTranslationViewModel, HangingReadmeTranslationServiceStub) {
        let fake = HangingReadmeTranslationServiceStub()
        return (ReadmeTranslationViewModel(service: fake), fake)
    }

    private func makePage(
        owner: String,
        repo: String,
        translatedText: String,
        identity: String? = nil
    ) -> TranslationTestPage {
        let segment = ReadmeSourceSegment(
            id: "p-0",
            text: "Hello world this is a repository description."
        )
        return TranslationTestPage(
            owner: owner,
            repo: repo,
            sourceHtml: "<p>Hello world this is a repository description.</p>",
            segment: segment,
            translatedText: translatedText,
            documentIdentity: identity
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for step in 0..<50 {
            if condition() { return }
            if step < 10 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("条件在超时前未满足")
    }

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - 同语种轻提示

@MainActor
@Suite("ReadmeTranslationViewModel 同语种轻提示")
struct ReadmeTranslationNoticeTests {

    @Test("整篇已是目标语言时点击翻译：置轻提示、不转圈、不打翻译接口")
    func sameLanguageToggleSetsNoticeInsteadOfSilentNoop() async {
        let (vm, fake) = makeHarness()
        let text = "This whole README is already written in English so no translation is needed here."
        let segment = ReadmeSourceSegment(id: "p-0", text: text)
        let identity = "readme:alpha/same"

        vm.prepare(
            identity: identity,
            cacheOwner: "alpha",
            cacheRepo: "same",
            sourceHtml: "<p>\(text)</p>",
            targetLanguage: .english,
            mode: .segmented
        )
        await settle()
        vm.toggleTranslation(
            identity: identity,
            cacheOwner: "alpha",
            cacheRepo: "same",
            sourceHtml: "<p>\(text)</p>",
            sourceSegments: [segment],
            targetLanguage: .english,
            mode: .segmented
        )
        await settle()

        #expect(vm.showsAlreadyInTargetNotice)
        #expect(!vm.isTranslating)
        #expect(!vm.renderState.isVisible)
        #expect(vm.errorMessage == nil)
        fake.finishHangingWork()
    }

    @Test("服务层同语种短路：捕获 alreadyInTargetLanguage 置轻提示而非报错")
    func serviceAlreadyInTargetLanguageSetsNotice() async {
        let (vm, fake) = makeHarness()
        // 段落本身识别为英语，VM 层不会提前跳过；短路发生在服务层文档级投票。
        let text = "Hello world this is a repository description for the service level short circuit."
        let segment = ReadmeSourceSegment(id: "p-0", text: text)
        let identity = "readme:alpha/svc"
        fake.throwAlreadyInTarget = true

        vm.prepare(
            identity: identity,
            cacheOwner: "alpha",
            cacheRepo: "svc",
            sourceHtml: "<p>\(text)</p>",
            targetLanguage: .simplifiedChinese,
            mode: .segmented
        )
        await settle()
        vm.toggleTranslation(
            identity: identity,
            cacheOwner: "alpha",
            cacheRepo: "svc",
            sourceHtml: "<p>\(text)</p>",
            sourceSegments: [segment],
            targetLanguage: .simplifiedChinese,
            mode: .segmented
        )
        await waitUntil { vm.showsAlreadyInTargetNotice }

        #expect(!vm.isTranslating)
        #expect(vm.errorMessage == nil)

        // 切仓 prepare 必须复位提示，不能把旧提示带进新详情页。
        vm.prepare(
            identity: "readme:bravo/next",
            cacheOwner: "bravo",
            cacheRepo: "next",
            sourceHtml: "<p>next</p>",
            targetLanguage: .simplifiedChinese,
            mode: .segmented
        )
        #expect(!vm.showsAlreadyInTargetNotice)
        fake.finishHangingWork()
    }

    // MARK: 辅助

    private func makeHarness() -> (ReadmeTranslationViewModel, HangingReadmeTranslationServiceStub) {
        let fake = HangingReadmeTranslationServiceStub()
        return (ReadmeTranslationViewModel(service: fake), fake)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for step in 0..<50 {
            if condition() { return }
            if step < 10 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("条件在超时前未满足")
    }

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private struct TranslationTestPage {
    let owner: String
    let repo: String
    let sourceHtml: String
    let segment: ReadmeSourceSegment
    let translatedText: String
    var documentIdentity: String? = nil

    var identity: String { documentIdentity ?? "readme:\(owner)/\(repo)" }
}

@MainActor
private extension ReadmeTranslationViewModel {
    func prepare(page: TranslationTestPage) {
        prepare(
            identity: page.identity,
            cacheOwner: page.owner,
            cacheRepo: page.repo,
            sourceHtml: page.sourceHtml,
            targetLanguage: .simplifiedChinese,
            mode: .segmented
        )
    }

    func toggle(page: TranslationTestPage) {
        toggleTranslation(
            identity: page.identity,
            cacheOwner: page.owner,
            cacheRepo: page.repo,
            sourceHtml: page.sourceHtml,
            sourceSegments: [page.segment],
            targetLanguage: .simplifiedChinese,
            mode: .segmented
        )
    }
}

/// 按 owner 挂起 `cachedTranslation`，并可卡住 `translate` / 补发 onBatch。
@MainActor
private final class HangingReadmeTranslationServiceStub: ReadmeTranslationServiceProtocol {
    private var records: [String: ReadmeTranslation] = [:]
    private var parkedOwners: Set<String> = []
    var hangTranslate = false
    /// 置 true 时 translate 抛 alreadyInTargetLanguage，覆盖服务层同语种短路路径。
    var throwAlreadyInTarget = false

    func park(owner: String) {
        parkedOwners.insert(owner)
    }

    private var cacheWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var translateWaiters: [CheckedContinuation<ReadmeTranslation, Error>] = []
    private var latestBatchHandler: ReadmeTranslationBatchProgressHandler?

    func store(_ page: TranslationTestPage) {
        records[Self.key(page.owner, page.repo)] = ReadmeTranslation(
            repoId: nil,
            targetLanguage: ReadmeTranslationLanguage.simplifiedChinese.rawValue,
            model: "test-model",
            sourceHash: ReadmeTranslationService.hash(page.sourceHtml),
            segments: [
                ReadmeTranslatedSegment(
                    sourceHash: page.segment.sourceHash,
                    translatedText: page.translatedText
                )
            ],
            isComplete: true,
            size: page.translatedText.utf8.count,
            createdAt: "2026-08-24T00:00:00Z"
        )
    }

    func hasParkedCache(owner: String) -> Bool {
        !(cacheWaiters[owner] ?? []).isEmpty
    }

    var hasHangingTranslate: Bool { !translateWaiters.isEmpty }

    func releaseParked(owner: String) {
        let waiters = cacheWaiters[owner] ?? []
        cacheWaiters[owner] = []
        parkedOwners.remove(owner)
        waiters.forEach { $0.resume() }
    }

    func fireLatestBatch(id: String, translatedText: String) {
        latestBatchHandler?(
            [ReadmeRenderedTranslation(id: id, translatedText: translatedText)],
            1,
            1
        )
    }

    func finishHangingWork() {
        let cache = cacheWaiters
        cacheWaiters = [:]
        parkedOwners = []
        cache.values.flatMap { $0 }.forEach { $0.resume() }

        let translates = translateWaiters
        translateWaiters = []
        translates.forEach { $0.resume(throwing: CancellationError()) }
        latestBatchHandler = nil
    }

    func cachedTranslation(
        owner: String,
        repo: String,
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode,
        engine: ReadmeTranslationEngine
    ) async throws -> ReadmeTranslation? {
        if parkedOwners.contains(owner) {
            await withCheckedContinuation { continuation in
                cacheWaiters[owner, default: []].append(continuation)
            }
        }
        return records[Self.key(owner, repo)]
    }

    func isCacheFresh(cached: ReadmeTranslation, sourceHtml: String) -> Bool {
        cached.isComplete && cached.sourceHash == ReadmeTranslationService.hash(sourceHtml)
    }

    func renderedTranslations(
        from cached: ReadmeTranslation,
        matching sourceSegments: [ReadmeSourceSegment]
    ) -> [ReadmeRenderedTranslation] {
        let translatedByHash = Dictionary(
            cached.segments.map { ($0.sourceHash, $0.translatedText) },
            uniquingKeysWith: { first, _ in first }
        )
        return sourceSegments.compactMap { source in
            guard let text = translatedByHash[source.sourceHash] else { return nil }
            return ReadmeRenderedTranslation(id: source.id, translatedText: text)
        }
    }

    func translate(
        request: ReadmeTranslationRequest,
        cached: ReadmeTranslation?,
        onBatch: ReadmeTranslationBatchProgressHandler?
    ) async throws -> ReadmeTranslation {
        latestBatchHandler = onBatch
        if throwAlreadyInTarget {
            throw ReadmeTranslationError.alreadyInTargetLanguage
        }
        if hangTranslate {
            return try await withCheckedThrowingContinuation { continuation in
                translateWaiters.append(continuation)
            }
        }
        throw ReadmeTranslationError.emptySource
    }

    private static func key(_ owner: String, _ repo: String) -> String {
        "\(owner)/\(repo)"
    }
}
