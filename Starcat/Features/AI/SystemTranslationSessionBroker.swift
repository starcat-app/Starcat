//
//  SystemTranslationSessionBroker.swift
//  Starcat
//
//  把 Apple TranslationSession 接到非 SwiftUI 的 README 翻译 Service。
//
//  为什么需要 Broker：
//  - macOS 15 上可靠拿到可下载语言包的 Session，必须走 SwiftUI `.translationTask`；
//  - `TranslationSession(installedSource:)` 要到更新的系统才可用，且要求语言已安装；
//  - Service / VM 不能直接持有 View，因此用 Configuration 触发 task，把 Session
//    交给等待中的续体完成一批 `translations(from:)`。
//

import Foundation
import Observation
import SwiftUI
#if canImport(Translation)
@preconcurrency import Translation

// TranslationSession 不是 Sendable，但 Session 仅在 MainActor 宿主回调里使用。
extension TranslationSession: @unchecked @retroactive Sendable {}
#endif

/// 系统翻译请求失败。
enum SystemTranslationError: Error, LocalizedError, Equatable {
    case frameworkUnavailable
    case sessionUnavailable
    case emptyBatch
    case cancelled

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return String.l10n("readme.translate.error.systemUnavailable")
        case .sessionUnavailable:
            return String.l10n("readme.translate.error.systemSession")
        case .emptyBatch:
            return String.l10n("readme.translate.error.emptySource")
        case .cancelled:
            return nil
        }
    }
}

/// App 根视图挂载的系统翻译会话桥。
@MainActor
@Observable
final class SystemTranslationSessionBroker {

    static let shared = SystemTranslationSessionBroker()

    /// 非 nil 时触发 `.translationTask`；完成后由 `consumeSession` 清空。
    private(set) var configuration: TranslationSession.Configuration?

    private var pending: PendingRequest?

    private struct PendingRequest {
        let target: Locale.Language
        let requests: [TranslationSession.Request]
        let continuation: CheckedContinuation<[TranslationSession.Response], Error>
    }

    /// 用系统 Session 翻译一批同语种文本。`clientIdentifier` 用 sourceHash 回填。
    func translateBatch(
        items: [(sourceHash: String, text: String)],
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> [TranslationSession.Response] {
        #if canImport(Translation)
        guard !items.isEmpty else { throw SystemTranslationError.emptyBatch }

        // 若上一次还挂着，先取消，避免续体泄漏。
        if let stale = pending {
            pending = nil
            configuration = nil
            stale.continuation.resume(throwing: SystemTranslationError.cancelled)
        }

        let target = targetLanguage.localeLanguage
        let requests = items.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.sourceHash)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending = PendingRequest(
                target: target,
                requests: requests,
                continuation: continuation
            )
            // source nil：让系统识别原文语种；version bump 靠 invalidate/新 Configuration。
            var config = TranslationSession.Configuration(source: nil, target: target)
            config.invalidate()
            configuration = config
        }
        #else
        throw SystemTranslationError.frameworkUnavailable
        #endif
    }

    /// 由根视图 `.translationTask` 回调；完成当前 pending 后清空 configuration。
    func consumeSession(_ session: TranslationSession) async {
        #if canImport(Translation)
        guard let pending else { return }
        self.pending = nil
        defer { configuration = nil }

        do {
            // macOS 15：translationTask 提供的 session 会处理语言包下载提示。
            // isReady 仅较新系统提供，且跨 actor 边界不友好，这里直接译；失败再 prepare 重试。
            let responses = try await session.translations(from: pending.requests)
            pending.continuation.resume(returning: responses)
        } catch {
            do {
                try await session.prepareTranslation()
                let responses = try await session.translations(from: pending.requests)
                pending.continuation.resume(returning: responses)
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
        #endif
    }
}

/// 挂在 App 根上的零尺寸宿主，专门喂 `translationTask`。
struct SystemTranslationSessionHost: View {
    @Bindable var broker: SystemTranslationSessionBroker

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            #if canImport(Translation)
            .translationTask(broker.configuration) { session in
                await broker.consumeSession(session)
            }
            #endif
    }
}
