//
//  LayaMLXDecisionRuntimeTests.swift
//  StarcatTests
//
//  常规单测验证三种文本题型的 prompt 与解码，不加载真实模型或访问网络。
//  真实 checkpoint 的 Python 黄金对拍与状态/日志联调由独立 opt-in suite 承担。
//  已在 Starcat 下载模型时只需打开开关；也可显式传入其它 checkpoint：
//  TEST_RUNNER_STARCAT_LAYA_MLX_POC=1 \
//  TEST_RUNNER_STARCAT_LAYA_MLX_MODEL_DIR=/path/to/checkpoint \
//  make test TEST_ARGS="-only-testing:StarcatTests/LayaMLXCheckpointParityTests"
//


import Foundation
import MLX
import Testing

@testable import Starcat

@Suite("Laya MLX Decision Runtime")
struct LayaMLXDecisionRuntimeTests {
    @Test("Noul prompt 固定 false/true marker 顺序并清除用户 mask token")
    func buildsNoulMarkersInStableOrder() throws {
        let tokenizer = ScalarTokenizer()
        let question = try LayaTextQuestion(.noul(instructions: "Decide whether <mask> this repository is useful", criteria: nil))
        let input = try LayaPromptBuilder(
            maximumLength: 256,
            headMaximumLength: 96
        ).build(
            state: "repository is a local <mask> developer tool",
            question: question,
            tokenizer: tokenizer
        )

        #expect(input.tokenIDs.first == tokenizer.classTokenID)
        #expect(input.tokenIDs.last == tokenizer.separatorTokenID)
        #expect(input.markerPositions.count == 2)
        #expect(input.markerPositions[0] < input.markerPositions[1])
        #expect(input.tokenIDs[input.markerPositions[0]] == tokenizer.maskTokenID)
        #expect(input.tokenIDs[input.markerPositions[1]] == tokenizer.maskTokenID)
        // marker 后是前导空格，再分别进入 false / true 文本。
        #expect(input.tokenIDs[input.markerPositions[0] + 2] == tokenizer.id(for: "f"))
        #expect(input.tokenIDs[input.markerPositions[1] + 2] == tokenizer.id(for: "t"))
        #expect(!input.tokenIDs.contains(tokenizer.id(for: "<")))
    }

    @Test("超长 state 从右侧截断并严格受 max_len 约束")
    func truncatesStateFromTheRight() throws {
        let tokenizer = ScalarTokenizer()
        let question = try LayaTextQuestion(.noul(instructions: "Is this relevant?", criteria: nil))
        let input = try LayaPromptBuilder(
            maximumLength: 96,
            headMaximumLength: 48
        ).build(
            state: "A" + String(repeating: "z", count: 500),
            question: question,
            tokenizer: tokenizer
        )

        #expect(input.tokenIDs.count == 96)
        let separators = input.tokenIDs.indices.filter {
            input.tokenIDs[$0] == tokenizer.separatorTokenID
        }
        #expect(separators.count == 3)
        let stateStart = try #require(separators.dropFirst().first).advanced(by: 1)
        #expect(input.tokenIDs[stateStart] == tokenizer.id(for: "A"))
        #expect(input.tokenIDs.last == tokenizer.separatorTokenID)
    }

    @Test("Choice 按选项名稳定映射概率，移除说明内的 mask token")
    func mapsChoiceOptions() throws {
        let tokenizer = ScalarTokenizer()
        let question = try LayaTextQuestion(DecisionQuestion(
            type: .choice,
            criteria: .object(["support": .string("<mask> Need help"), "billing": .null])
        ))
        let input = try LayaPromptBuilder(maximumLength: 256, headMaximumLength: 96)
            .build(state: "Refund requested", question: question, tokenizer: tokenizer)
        #expect(question.kind.rawValue == 0)
        #expect(question.options == ["billing", "support: <mask> Need help"])
        #expect(input.markerPositions.count == 2)
        #expect(!input.tokenIDs.contains(tokenizer.id(for: "<")))
        let answer = try question.answer(logits: [2, 0], temperature: 1)
        #expect(answer.choice == "billing")
        #expect(answer.probabilities == ["billing": 0.8808, "support": 0.1192])
        #expect(answer.confidence == 0.4729)
    }

    @Test("Score 使用零基分布的期望值并保留结构化评分描述")
    func calculatesExpectedScore() throws {
        let levels: [AgentJSONValue] = [.string("low"), .array([.string("medium")]), .string("high")]
        let question = try LayaTextQuestion(DecisionQuestion(type: .score, criteria: .array(levels)))
        let calibration = LayaTemperatureCalibration(base: [1, 2, 3], byOptions: ["score:3-5": 0.25])
        #expect(question.kind.rawValue == 1)
        #expect(calibration.temperature(kind: .score, count: 3) == 0.5)
        #expect(calibration.temperature(kind: .choice, count: 6) == 1)
        #expect(calibration.temperature(kind: .noul, count: 2) == 3)
        let answer = try question.answer(logits: [0, 0, 0], temperature: 0.5)
        #expect(answer.score == 1)
        #expect(answer.legend == .object(["0": levels[0], "1": levels[1], "2": levels[2]]))
        #expect(answer.probabilities == ["0": 0.3333, "1": 0.3333, "2": 0.3333])
        #expect(answer.confidence == 0)
    }

    @Test("Laya 在加载模型前拒绝含图片或 Box 的整个批次")
    @MainActor
    func rejectsImageBatchBeforeLoading() async throws {
        let runtimeStore = LayaDecisionRuntimeStore()
        let engine = LayaDecisionEngine(runtimeStore: runtimeStore)
        let questions: [String: DecisionQuestion] = [
            "valid": .noul(instructions: "Is this a receipt?", criteria: nil),
            "locate": DecisionQuestion(type: .box, instructions: .string("Locate the receipt")),
        ]
        await #expect(throws: DecisionInputError.self) {
            try await engine.evaluate(DecisionEvaluationRequest(
                state: .text("Receipt"), questions: questions, operation: .external
            ))
        }
        let snapshot = await runtimeStore.snapshot()
        #expect(snapshot.model == nil)
        #expect(!snapshot.isMLXInitialized)
    }
}

/// 只读加载显式传入的 checkpoint；不会下载模型，也不会接入生产 Local AI runtime。
@Suite(
    "Laya MLX Checkpoint Parity",
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(if: ProcessInfo.processInfo.environment["STARCAT_LAYA_MLX_POC"] == "1")
)
struct LayaMLXCheckpointParityTests {
    @Test("laya-multilingual-mlx FP16 与 Python 黄金 logits/概率一致")
    func matchesPythonGoldenOutput() async throws {
        let directory = try installedModelDirectory()
        // 只统计本次 checkpoint load + inference，避免测试进程此前的 MLX 峰值污染结果。
        Memory.clearCache()
        Memory.peakMemory = 0
        let startingMemory = Memory.snapshot()
        let clock = ContinuousClock()
        let loadStart = clock.now
        let runtime = try await LayaMLXDecisionRuntime.load(
            from: directory
        )
        let loadedAt = clock.now
        Memory.clearCache()
        let loadedMemory = Memory.snapshot()
        let state = "Starcat 是一款原生 macOS GitHub Star 管理工具，支持本地搜索、标签、README 浏览和 AI 知识库。"
        let isAITool = try LayaTextQuestion(.noul(instructions: "这个仓库属于 AI 开发工具。", criteria: nil))
        let single = try await runtime.predictBatch(state: state, questions: ["ai": isAITool])
        let prediction = try #require(single["ai"])
        let firstInferenceAt = clock.now
        // 首次 forward 包含 Metal kernel JIT；第二次才代表常驻模型的交互延迟。
        let warmPrediction = try await runtime.predictBatch(state: state, questions: ["ai": isAITool])
        let warmInferenceAt = clock.now
        let choice = try LayaTextQuestion(DecisionQuestion(
            type: .choice, instructions: .string("这个软件属于哪个类别？"),
            criteria: .object(["开发工具": .null, "烹饪": .null, "体育": .null])
        ))
        let score = try LayaTextQuestion(DecisionQuestion(
            type: .score, instructions: .string("这个软件对 GitHub Star 管理有多大帮助？"),
            criteria: .array([.string("没有帮助"), .string("非常有帮助")])
        ))
        let batchPredictions = try await runtime.predictBatch(
            state: state,
            questions: [
                "ai": isAITool,
                "choice": choice,
                "score": score,
            ]
        )
        let batchInferenceAt = clock.now
        Memory.clearCache()
        let completedMemory = Memory.snapshot()

        #expect(prediction.inputTokenCount == 59)
        #expect(prediction.logits.count == 2)
        #expect(abs(prediction.logits[0] - (-4.359_375)) < 0.01)
        #expect(abs(prediction.logits[1] - 0.258_300_78) < 0.01)
        // MLX Swift 0.31.6 与 Python MLX 0.32.2 的 FP16 kernel 有 1e-4 级舍入差异。
        let trueProbability = try #require(prediction.answer.noul)
        #expect(abs(trueProbability - 0.9902) < 0.0002)
        #expect(warmPrediction["ai"]?.answer == prediction.answer)
        let batchedProbability = try #require(batchPredictions["ai"]?.answer.noul)
        #expect(abs(batchedProbability - trueProbability) < 0.0002)
        #expect(batchPredictions["choice"]?.answer.choice == "开发工具")
        #expect(batchPredictions["choice"]?.logits.count == 3)
        let expectedScore = try #require(batchPredictions["score"]?.answer.score)
        #expect(expectedScore > 0.5)
        #expect(batchPredictions["score"]?.logits.count == 2)
        print(
            "Laya MLX Swift parity load=\(loadStart.duration(to: loadedAt)) "
                + "firstInference=\(loadedAt.duration(to: firstInferenceAt)) "
                + "warmInference=\(firstInferenceAt.duration(to: warmInferenceAt)) "
                + "batchInference=\(warmInferenceAt.duration(to: batchInferenceAt)) "
                + "tokens=\(prediction.inputTokenCount) logits=\(prediction.logits) "
                + "noul=\(trueProbability) "
                + "loadedActiveMiB=\(mebibytes(loadedMemory.activeMemory - startingMemory.activeMemory)) "
                + "completedActiveMiB=\(mebibytes(completedMemory.activeMemory - startingMemory.activeMemory)) "
                + "peakMiB=\(mebibytes(completedMemory.peakMemory))"
        )
    }

    @Test("状态快照与结构化日志覆盖手动加载和卸载")
    func publishesResidentStateAndLogs() async throws {
        let directory = try installedModelDirectory()
        let runtimeStore = LayaDecisionRuntimeStore()
        let logStore = LocalAILogStore(persistenceEnabled: false)

        try await LocalAILogContext.$store.withValue(logStore) {
            try await runtimeStore.preload(from: directory)
            let loaded = await runtimeStore.snapshot()
            #expect(loaded.model?.phase == .ready)
            #expect(loaded.model?.directory.standardizedFileURL == directory.standardizedFileURL)
            #expect(loaded.isMLXInitialized)

            try await runtimeStore.unload(reason: "test")
            let unloaded = await runtimeStore.snapshot()
            #expect(unloaded.model?.phase == .unloaded)
            #expect(unloaded.model?.loadedBytes == 0)
        }

        let events = await logStore.snapshot().events
        #expect(events.contains { $0.stage == "model.load.completed" })
        #expect(events.contains { $0.stage == "model.unloaded" })
        #expect(events.allSatisfy {
            $0.modelID == LayaDecisionModelCatalog.multilingual.id
        })
    }

    /// 测试宿主带 App Group entitlement，可直接读取 Starcat 已安装模型；显式路径仅用于
    /// 对拍外部 checkpoint。两种来源都只读，不下载、不删除用户模型。
    private func installedModelDirectory() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["STARCAT_LAYA_MLX_MODEL_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try #require(LayaDecisionModelStorage.installedModel()?.directory)
    }

    /// 用固定精度输出 MiB，便于在不同机器上比较而不把硬件差异写成测试断言。
    private func mebibytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

/// Unicode scalar tokenizer 让测试能精确观察 prompt 拼接，不复制生产 tokenizer 实现。
private struct ScalarTokenizer: LayaTokenizing {
    let classTokenID = 1
    let separatorTokenID = 2
    let paddingTokenID = 0
    let maskToken = "<mask>"
    let maskTokenID = 3

    func encodeWithoutSpecialTokens(_ text: String) -> [Int] {
        text.unicodeScalars.map { Int($0.value) + 1_000 }
    }

    func id(for scalar: Character) -> Int {
        Int(String(scalar).unicodeScalars.first!.value) + 1_000
    }
}
