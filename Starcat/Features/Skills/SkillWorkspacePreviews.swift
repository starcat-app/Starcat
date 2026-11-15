//
//  SkillWorkspacePreviews.swift
//  Starcat
//
//  原生 Preview 与单测共用的确定性样例；只编译进 DEBUG，
//  生产协调器从不引用此工厂，样例路径不会被打开或写入数据库。
//

#if DEBUG
import SwiftUI

/// 每种状态单独可评审，避免用演示开关污染真实本机会话。
enum SkillWorkspacePreviewScenario: CaseIterable {
    case managed, external, shared, conflict, empty, error, initialFailure, loading
}

/// 样例 ID 固定，允许测试刷新、同名来源和选择收敛，路径仅用于展示。
@MainActor
enum SkillWorkspacePreviewFixtures {
    static func items() -> [SkillLibraryItem] {
        [
            SkillLibraryItem(
                id: identifier(1), name: "release-notes",
                summary: "Résumé and release notes from repository changes.",
                managementKind: .managed, source: "github.com/starcat-app/skills",
                locations: [.init(path: "/ExampleHome/.codex/skills/release-notes", agentNames: ["Codex"])],
                hasUpdate: true, revision: "a1b2c3d",
                markdown: "# Release notes\n\nReview commits and produce a concise changelog.\n\n- Keep the source links.\n- Ask before publishing.",
                files: ["SKILL.md", "references/changelog.md", "scripts/build.sh"]
            ),
            SkillLibraryItem(
                id: identifier(2), name: "release-notes",
                summary: "An independent Skill from a different source.",
                managementKind: .external, source: "github.com/example/release-tools",
                locations: [.init(path: "/ExampleHome/.claude/skills/release-notes", agentNames: ["Claude Code"])],
                markdown: "# External Skill\n\nThis copy remains read-only.",
                files: ["SKILL.md"]
            ),
            SkillLibraryItem(
                id: identifier(3), name: "daily-review",
                summary: "One physical directory shared by more than one Agent.",
                managementKind: .external, source: nil,
                locations: [.init(
                    path: "/ExampleHome/.agents/skills/daily-review",
                    agentNames: ["Codex", "OpenCode"]
                )],
                markdown: "# Daily review\n\nShared visibility is not proof that an Agent loaded this Skill.",
                files: ["SKILL.md", "references/checklist.md"]
            ),
            SkillLibraryItem(
                id: identifier(4), name: "invalid-manifest",
                summary: "The original content remains available for diagnosis.",
                managementKind: .managed, source: nil, locations: [],
                diagnostic: "SKILL.md: missing description",
                markdown: "---\nname: invalid-manifest\n---\n\nOriginal document.",
                files: ["SKILL.md"]
            )
        ]
    }

    /// 同一套条目覆盖正常、失败保留快照及首次加载，不触发真实 I/O。
    static func model(for scenario: SkillWorkspacePreviewScenario) -> SkillWorkspaceViewModel {
        let model = SkillWorkspaceViewModel()
        let samples = items()
        switch scenario {
        case .empty:
            return model
        case .initialFailure:
            model.setLoadState(.failed("Permission denied: /ExampleHome/.claude/skills"))
            return model
        case .loading:
            model.setLoadState(.loading)
            return model
        case .managed, .external, .shared, .conflict, .error:
            model.applySnapshot(samples)
        }
        let selectedIndex: Int
        switch scenario {
        case .managed, .error: selectedIndex = 0
        case .external: selectedIndex = 1
        case .shared: selectedIndex = 2
        case .conflict: selectedIndex = 3
        case .empty, .initialFailure, .loading: return model
        }
        model.selectedIDs = [samples[selectedIndex].id]
        if scenario == .error {
            model.setLoadState(.failed("Permission denied: /ExampleHome/.claude/skills"))
        }
        return model
    }

    private static func identifier(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }
}

/// Preview 只承载内容布局；真实窗口 chrome 由独立 Window Scene 负责。
private struct SkillWorkspacePreviewHost: View {
    @State private var model: SkillWorkspaceViewModel
    @State private var chromeState = WorkspaceChromeState()

    init(_ scenario: SkillWorkspacePreviewScenario) {
        _model = State(initialValue: SkillWorkspacePreviewFixtures.model(for: scenario))
    }

    var body: some View {
        SkillWorkspaceView(viewModel: model, chromeState: chromeState)
            .environment(\.starcatInterfaceScale, .standard)
            .appLocaleEnvironment()
            .frame(width: 1440, height: 860)
    }
}

#Preview("Skill 工作台 · 受管") { SkillWorkspacePreviewHost(.managed) }
#Preview("Skill 工作台 · 外部") { SkillWorkspacePreviewHost(.external) }
#Preview("Skill 工作台 · 共享") { SkillWorkspacePreviewHost(.shared) }
#Preview("Skill 工作台 · 冲突") { SkillWorkspacePreviewHost(.conflict) }
#Preview("Skill 工作台 · 空库") { SkillWorkspacePreviewHost(.empty) }
#Preview("Skill 工作台 · 错误") { SkillWorkspacePreviewHost(.error) }
#Preview("Skill 工作台 · 首次读取失败") { SkillWorkspacePreviewHost(.initialFailure) }
#Preview("Skill 工作台 · 加载") { SkillWorkspacePreviewHost(.loading) }
#endif
