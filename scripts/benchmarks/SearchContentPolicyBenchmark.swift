//
//  SearchContentPolicyBenchmark.swift
//
//  只使用人工构造的公开元数据；预热后测量整批延迟，避免将模型、网络或
//  Swift 编译耗时计入匹配时间。与 App 的源文件一起编译，防止基准另写一套逻辑。
//

import Foundation

/// 提供正常中英文元数据与少量命中场景，输出可重复比较的热态 P50/P95。
@main
struct SearchContentPolicyBenchmark {
    /// 加载指定规则，对正常批次与混入少量命中的批次分别测量。
    static func main() throws {
        let rulesURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let policy = try SearchContentPolicy(data: Data(contentsOf: rulesURL))
        let documents = (0..<100).map { index in
            SearchContentDocument(
                id: "repo:example/project-\(index)",
                repositoryFullName: "example/project-\(index)",
                urls: [URL(string: "https://github.com/example/project-\(index)")!],
                fields: [
                    .title: ["example/project-\(index)"],
                    .description: [index.isMultiple(of: 4)
                        ? "药物研发与枪声检测，反人口贩卖公益项目"
                        : "A fast GitHub stars manager with semantic search, tags and release tracking."],
                    .topic: ["github", "developer-tools", "linux"]
                ]
            )
        }
        // 混合少量精确命中与危险交易，避免只测无需上下文核验的无命中路径。
        let mixed = documents.enumerated().map { index, document in
            if index.isMultiple(of: 20) {
                return SearchContentDocument(
                    id: document.id, repositoryFullName: "cirosantilli/china-dictatorship"
                )
            }
            if index.isMultiple(of: 10) {
                return SearchContentDocument(id: document.id, fields: [.description: ["出售毒品"]])
            }
            return document
        }
        print("Rules: \(policy.version); mode: Swift -O; samples: 100 batches after 10 warmups")
        measure("normal", documents: documents, policy: policy, expectedMatches: 0)
        measure("mixed", documents: mixed, policy: policy, expectedMatches: 10)
    }

    /// 校验每批结果，再统计延迟；不把机器相关耗时写成有抖动的单测断言。
    private static func measure(
        _ name: String, documents: [SearchContentDocument],
        policy: SearchContentPolicy, expectedMatches: Int
    ) {
        var samples: [Double] = []
        for iteration in 0..<110 {
            let elapsed = autoreleasepool {
                let start = ContinuousClock.now
                let count = documents.reduce(0) { $0 + (policy.match($1) == nil ? 0 : 1) }
                precondition(count == expectedMatches, "Unexpected filtering result in benchmark")
                let duration = start.duration(to: .now)
                return Double(duration.components.seconds) * 1_000
                    + Double(duration.components.attoseconds) / 1e15
            }
            if iteration >= 10 { samples.append(elapsed) }
        }
        samples.sort()
        print(String(
            format: "%@: %d candidates, P50=%.3f ms, P95=%.3f ms",
            name, documents.count, samples[49], samples[94]
        ))
    }
}
