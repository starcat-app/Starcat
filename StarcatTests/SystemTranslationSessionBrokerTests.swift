//
//  SystemTranslationSessionBrokerTests.swift
//  StarcatTests
//
//  系统翻译宿主生命周期回归测试。
//
//  这些测试不调用真实 Apple Translation 语言包，而是验证 Broker 的两个关键约束：
//  同一进程内只能有一个有效宿主，以及空批次必须在进入 Translation framework 前失败。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("SystemTranslationSessionBroker")
struct SystemTranslationSessionBrokerTests {

    @Test("多个窗口同时存活时只保留一个翻译宿主 owner")
    func keepsOneHostOwner() {
        let broker = SystemTranslationSessionBroker()
        let mainHost = UUID()
        let detailHost = UUID()

        broker.registerHost(mainHost)
        broker.registerHost(detailHost)

        #expect(broker.registeredHostCountForTesting == 2)
        #expect(broker.activeHostIDForTesting == mainHost)

        broker.unregisterHost(detailHost)

        #expect(broker.registeredHostCountForTesting == 1)
        #expect(broker.activeHostIDForTesting == mainHost)
    }

    @Test("当前 owner 消失后翻译宿主所有权转移到仍存活的窗口")
    func transfersHostOwnershipAfterOwnerDisappears() {
        let broker = SystemTranslationSessionBroker()
        let mainHost = UUID()
        let detailHost = UUID()

        broker.registerHost(mainHost)
        broker.registerHost(detailHost)
        broker.unregisterHost(mainHost)

        #expect(broker.registeredHostCountForTesting == 1)
        #expect(broker.activeHostIDForTesting == detailHost)
    }

    @Test("空批次在进入 Translation framework 前直接失败")
    func rejectsEmptyBatchesBeforeCreatingSession() async {
        let broker = SystemTranslationSessionBroker()

        await #expect(throws: SystemTranslationError.emptyBatch) {
            try await broker.translateBatches(
                batches: [[]],
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese
            )
        }
    }

    @Test("连续 README 请求复用同一语言对的 Configuration")
    func retainsConfigurationBetweenSequentialRequests() {
        let broker = SystemTranslationSessionBroker()

        broker.activateSyntheticRequestForTesting(
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let firstVersion = broker.configuration?.version
        broker.finishActiveForTesting()

        // 请求完成不能销毁 Configuration，否则下一次请求会走旧 task 销毁 + 新 task 创建。
        #expect(broker.configuration != nil)

        broker.activateSyntheticRequestForTesting(
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        #expect(broker.configuration?.version != firstVersion)
    }
}
