//
//  ReadmeTranslationViewModelTests.swift
//  StarcatTests
//
//  切仓 / 取消后，过期的缓存命中和 onBatch 不能写进当前详情页。
//  用可挂起的假 Service 卡住 await，再切换 identity，复现串帖。
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

    // MARK: - 辅助

    private func makeHarness() -> (ReadmeTranslationViewModel, HangingReadmeTranslationServiceStub) {
        let fake = HangingReadmeTranslationServiceStub()
        return (ReadmeTranslationViewModel(service: fake), fake)
    }

    private func makePage(
        owner: String,
        repo: String,
        translatedText: String
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
            translatedText: translatedText
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

private struct TranslationTestPage {
    let owner: String
    let repo: String
    let sourceHtml: String
    let segment: ReadmeSourceSegment
    let translatedText: String

    var identity: String { "readme:\(owner)/\(repo)" }
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
        mode: ReadmeTranslationMode
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
