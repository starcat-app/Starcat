//
//  SkillPreviewHandoffTests.swift
//  StarcatTests
//
//  验证文件退场被回切中断后，可以直接恢复已有预览，不依赖下一次读取成功。
//

import Testing
@testable import Starcat

/// 复用真实预览快照类型，验证切换、刷新失败和首载的展示边界。
@MainActor
struct SkillPreviewHandoffTests {
    @Test("A 退场时切 B 再回 A，读取完成前就恢复 A")
    func interruptedFadeRestoresRetainedFile() {
        var presentation = SkillContentView.PreviewPresentation(
            file: "A.md", content: .text("cached A"), isVisible: true
        )
        let reusesDifferentFile = presentation.begin(file: "B.md")
        #expect(!reusesDifferentFile)
        presentation.isVisible = false

        let reusesRetainedFile = presentation.begin(file: "A.md")
        #expect(reusesRetainedFile)
        #expect(presentation.isVisible)
        #expect(presentation.file == "A.md")
        #expect(presentation.content == .text("cached A"))

        presentation.failure = "read failed"
        #expect(presentation.isVisible)
        #expect(presentation.content == .text("cached A"))
    }

    @Test("同文件刷新清理旧错误并保留正文")
    func refreshKeepsExistingPreview() {
        var presentation = SkillContentView.PreviewPresentation(
            file: "A.md", content: .text("old"), failure: "previous failure", isVisible: true
        )
        let reusesRetainedFile = presentation.begin(file: "A.md")
        #expect(reusesRetainedFile)
        #expect(presentation.failure == nil)
        #expect(presentation.content == .text("old"))
        #expect(presentation.isVisible)
    }

    @Test("不同文件不提前替换或重新显示离场快照")
    func differentFileWaitsForHandoff() {
        var presentation = SkillContentView.PreviewPresentation(
            file: "A.md", content: .text("old A"), isVisible: false
        )
        let reusesDifferentFile = presentation.begin(file: "B.md")
        #expect(!reusesDifferentFile)
        #expect(!presentation.isVisible)
        #expect(presentation.file == "A.md")
        #expect(presentation.content == .text("old A"))
    }

    @Test("首载和只有文件名的空快照不能当作已缓存正文")
    func missingContentIsNotRefresh() {
        var empty = SkillContentView.PreviewPresentation()
        let reusesEmpty = empty.begin(file: "A.md")
        #expect(!reusesEmpty)
        #expect(!empty.isVisible)
        var incomplete = SkillContentView.PreviewPresentation(file: "A.md")
        let reusesIncomplete = incomplete.begin(file: "A.md")
        #expect(!reusesIncomplete)
        #expect(!incomplete.isVisible)
    }
}
