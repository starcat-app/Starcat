//
//  AgentWorkspaceColumnLayoutTests.swift
//  StarcatTests
//
//  测量原生分栏中的实际视图坐标，防止时间线撑宽后把标题和输入区推到窗口外。
//  只在内存中布局 NSHostingView，不创建窗口、不截屏、不操作用户界面。
//

import AppKit
import SwiftUI
import Testing
@testable import Starcat

/// 普通栏宽常量测试无法发现后代视图撑大整栏；这里验证真实时间线参与布局后的边界。
@Suite("Agent 工作台分栏坐标", .serialized)
@MainActor
struct AgentWorkspaceColumnLayoutTests {
    @Test("检查器展开或收起时，标题、时间线和输入区均留在中栏",
          arguments: [1200.0, 1440.0, 1880.0], [false, true])
    func runSurfaceStaysInsideAllocatedColumn(width: Double, inspectorPresented: Bool) throws {
        for hasResult in [false, true] {
            let viewModel = makeViewModel(hasResult: hasResult)
            let host = NSHostingView(rootView: AgentColumnLayoutFixture(
                viewModel: viewModel,
                inspectorPresented: inspectorPresented
            ))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 820)
            host.layoutSubtreeIfNeeded()

            let frames = measuredFrames(in: host)
            let column = try #require(frames["column"])
            #expect(column.width >= AgentWorkspaceLayoutMetrics.runMinimumWidth)
            for name in ["header", "timeline", "composer"] {
                let frame = try #require(frames[name])
                #expect(abs(frame.minX - column.minX) < 1,
                        "\(name) 偏离中栏起点：\(frame)，分配区域：\(column)")
                #expect(abs(frame.width - column.width) < 1,
                        "\(name) 宽于分配区域：\(frame)，分配区域：\(column)")
                #expect(frame.minY >= column.minY - 1)
                #expect(frame.maxY <= column.maxY + 1)
            }
        }
    }

    /// 同时覆盖截图里的空任务，以及包含宽表、代码和长文本的完成态。
    private func makeViewModel(hasResult: Bool) -> AgentWorkspaceViewModel {
        let model = AgentWorkspaceViewModel(agents: [BuiltInAgents.githubWeeklyReport])
        model.configureRuntimeSelection(
            backend: .deepSeekHarness,
            providerName: "DeepSeek",
            modelName: "deepseek-v4-flash",
            reasoningEffort: nil,
            isAvailable: true
        )
        if hasResult {
            model.status = .completed
            model.messages = [
                AgentMessage(
                    runID: UUID(), role: .user, turn: 0, sequence: 0,
                    parts: [.text("Generate this week's GitHub report")]
                )
            ]
            model.artifacts = [
                AgentArtifact(
                    type: .markdown, title: "Weekly report",
                    content: """
                    # GitHub Weekly Report

                    \(String(repeating: "A repository with a long description. ", count: 20))

                    | Project | Description | Notes |
                    | --- | --- | --- |
                    | \(String(repeating: "long-repository-name-", count: 12)) | Report | Verified |

                    ```text
                    \(String(repeating: "long-command-argument ", count: 30))
                    ```
                    """,
                    sequence: 1
                )
            ]
        }
        return model
    }

    /// 读取本测试创建的无窗口视图树；不访问屏幕、辅助功能树或运行中的 App。
    private func measuredFrames(in host: NSView) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if let identifier = view.identifier?.rawValue,
               identifier.hasPrefix("agent-layout-") {
                result[String(identifier.dropFirst("agent-layout-".count))] =
                    host.convert(view.bounds, from: view)
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return result
    }
}

/// 复现生产环境的 NavigationSplitView + 原生 Inspector，时间线使用真实产品视图。
private struct AgentColumnLayoutFixture: View {
    let viewModel: AgentWorkspaceViewModel
    let inspectorPresented: Bool

    var body: some View {
        NavigationSplitView {
            Text("Agent rail")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 250, ideal: 312, max: 380)
        } detail: {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Text("GitHub Weekly Report")
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(AgentColumnLayoutMarker(name: "header"))
                    AgentMessageTimelineView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AgentColumnLayoutMarker(name: "timeline"))
                    Text("Composer")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(AgentColumnLayoutMarker(name: "composer"))
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
            }
            .background(AgentColumnLayoutMarker(name: "column"))
        }
        .inspector(isPresented: .constant(inspectorPresented)) {
            GeometryReader { proxy in
                AgentRunInspectorView(viewModel: viewModel)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
            }
            .inspectorColumnWidth(min: 320, ideal: 320, max: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 透明背景标记随父视图布局，供测试读取坐标，不改变内容的尺寸建议。
private struct AgentColumnLayoutMarker: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("agent-layout-\(name)")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
