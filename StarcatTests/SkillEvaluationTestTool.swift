//
//  SkillEvaluationTestTool.swift
//  StarcatTests
//
//  运行器和服务测试共用测试包里的固定 CLI 夹具。
//

import Foundation
import Testing

enum SkillEvaluationTestTool {
    private final class BundleMarker {}

    /// 沙盒允许执行构建时放入测试包的资源，运行时只写入输入快照与报告。
    static func executable(_ name: String = "skillevaluator") throws -> URL {
        let resource = Bundle(for: BundleMarker.self)
            .url(forResource: name, withExtension: nil, subdirectory: "SkillEvaluation")
        let url = try #require(resource)
        try #require(FileManager.default.isExecutableFile(atPath: url.path))
        return url
    }
}
