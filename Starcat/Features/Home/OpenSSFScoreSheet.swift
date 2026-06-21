//
//  OpenSSFScoreSheet.swift
//  Starcat
//
//  OpenSSF Scorecard 详情 sheet。
//
//  设计约束：
//  - 首次无缓存时只触发 Store 的非阻塞预拉，sheet 自身显示加载态，不同步等待网络。
//  - 雷达图过滤 score = -1 的无法评估项；明细列表仍展示它们，避免用户误以为缺项。
//  - 所有 SwiftUI 文案用 key；需要返回 String 的格式化走 `String.l10n`。
//
//  ──────────────────────────────────────────────────────────────────────────
//  v2.0 修订（2026-06-16，dong4j 反馈）：
//  ──────────────────────────────────────────────────────────────────────────
//  1. 弹框最小尺寸 720×560 → 520×460（约 -28% / -18%），让内容紧凑、不留过多空白。
//  2. 检查项卡片：spacing 10→6 / padding 10→8 / 内部 spacing 6→4；reason 字号
//     caption(12pt) → footnote(13pt)，让 dong4j 一眼看清原因文案。
//  3. 雷达图美化：① 最外环加深 0.18→0.45 以勾勒边界 ② 内圈仍浅以保留层次 ③ 增加
//     顶点圆点（白边描边强调）④ 顶点轴线尽头标注检查项简称 ⑤ 填充 + 描边整体加重，
//     视觉重心明显落在数据多边形上。
//  4. 评分日期：原来直接把 `record.scoreDate`（ISO8601 字符串，含 `Z`）塞进 i18n
//     模板会显示成 `2026-06-16T11:35:26Z` 极难读。现在解析成 Date → 本地时区 →
//     `yyyy-MM-dd HH:mm:ss`。Formatter 按 i18n 军规 #4 注入 view 的 `\.locale`，
//     避免不同语言环境拿不同 calendar。
//
//  ──────────────────────────────────────────────────────────────────────────
//  v3 修订（2026-06-16 20:40，dong4j 反馈"默认尺寸下底部超出主窗口 / 雷达图给更
//  大空间"）：
//  ──────────────────────────────────────────────────────────────────────────
//  - minHeight 460 → 400（再 -13%），让 sheet 默认能完整容纳在常见主窗口可视区。
//  - 雷达图 height 240 → 280（+17%），radius 自然增大（min(w,h)×0.32 ≈ 89.6pt
//    → ~89.6pt），雷达图视觉权重明显提升。
//  - 检查项卡片仍保持 ScrollView 包裹，溢出部分滚动消化，与"sheet 默认更紧凑、
//    雷达图占比更大"的视觉意图协同。
//
//  ──────────────────────────────────────────────────────────────────────────
//  v3.1 hotfix（2026-06-16 21:30，dong4j 反馈"还是超出主窗口 + 雷达图没看出更大"）：
//  ──────────────────────────────────────────────────────────────────────────
//  根因：v3 只设了 minHeight,但 macOS SwiftUI sheet 默认按内容 idealSize 撑开,
//  sheet 实际从 460 撑到 ~990pt → 雷达图占比反而下降。
//  修复：`.frame` 升级到带 idealWidth / idealHeight / maxWidth / maxHeight 的完整
//  约束（详见 body 内注释），sheet 默认按 560pt 出现,内层 ScrollView 真正滚动。
//
//  ──────────────────────────────────────────────────────────────────────────
//  v3.2（2026-06-16 21:40，dong4j 反馈"雷达图还是不够大"）：
//  ──────────────────────────────────────────────────────────────────────────
//  根因：Canvas radius 系数 `min(w,h) × 0.32` 让雷达图直径只占 frame 短边 64%,
//  加 frame 高 280pt(宽 ≈488pt)→ min=280 → radius=89.6pt → 雷达图直径 179pt,
//  在 488pt 宽 frame 中左右各空 154pt 巨幅留白。
//  修复：① 雷达图 frame height 280 → 340(再 +21%);② Canvas radius 系数 0.32 →
//  0.42,雷达图直径占 frame 短边 84%(之前 64%);③ 顶点标签 buffer 经计算仍
//  够用(9pt × 14 字符简称 ≈ 90pt,3/9 点方向 label 右边缘距中心 ≈ 200pt,frame
//  半宽 244pt 还有 44pt buffer 不裁标签)。
//
//  ──────────────────────────────────────────────────────────────────────────
//  v3.3（2026-06-16 21:50，dong4j 反馈"还要大 + hint 文字跟顶点标签重合"）：
//  ──────────────────────────────────────────────────────────────────────────
//  两个独立问题：
//  问题 A：hint 文字与 6 点钟顶点标签重合
//    根因：`Text("openssf.chart.hint")` 用 `.overlay(.bottom)` 贴 Canvas frame 底部,
//    6 点钟方向顶点标签(`Binary-Artifa...`)也在 frame 底部 → 同一区域。
//    修复：把 hint 从 OpenSSFRadarChart 内部 .overlay 移到 scoreContent 的 VStack
//    内作独立 row,与 Canvas frame 物理分隔。Chart 文件内不再渲染 hint。
//  问题 B：雷达图还不够大 + sheet 仍被撑开
//    根因：v3.1 仅外层 VStack 设了 idealHeight 560,但 ScrollView 默认 idealHeight
//    = infinity → 内容撑开 ScrollView → sheet 跟着撑开(dong4j 21:43 截图 sheet
//    ~1020pt 就是这个症状)。idealHeight 在外层单独设没用,必须传递到滚动容器内。
//    修复：① scoreContent 内 ScrollView 自己加 `.frame(idealHeight: 540)` 显式
//    宣告默认尺寸,sheet 综合 header+Divider+ScrollView 算出 ~601pt 总 ideal,与
//    外层 idealHeight 620 协同;② 雷达图 frame height 340 → 400(+18%),radius 自然
//    从 143 → 168pt,雷达图直径 285pt → 336pt(+18%);③ Canvas radius 系数仍保持
//    0.42(再激进 0.46+ 会裁 12/6 点 label,frame 400 半高 200pt 距 label 中心
//    182pt 只剩 18pt buffer,系数升 0.46 会让 buffer 跌到 -3pt 直接裁)。
//
//  ──────────────────────────────────────────────────────────────────────────
//  v3.4（2026-06-16 22:00，dong4j 反馈"底部文字被截取,改小窗口高度,只保留最后
//  一行的检查项这个文本"）：
//  ──────────────────────────────────────────────────────────────────────────
//  根因：连续三轮 (v3.1 / v3.2 / v3.3) 试图通过 idealHeight 协商让 sheet 收紧默
//  认尺寸,但 macOS SwiftUI 在「外层 VStack + 内层 ScrollView」嵌套下的 idealSize
//  协商始终不稳定 —— 实测 ScrollView 即使加了 .frame(idealHeight: 540) 仍会被内
//  容撑开,撑过外层 VStack 的 idealHeight 620 约束。
//
//  教训：macOS SwiftUI sheet 的 idealHeight 在涉及滚动容器嵌套时不可靠。要可预
//  期的固定默认尺寸,**必须用 `minHeight = maxHeight` 硬约束**牺牲 resize 弹性。
//
//  修复：① 外层 .frame 改成 `minHeight: 640, maxHeight: 640` 把 sheet 高度强制
//  固定到 640pt(用户不能拖大高度,但仍可调宽);② 删除 scoreContent 内 ScrollView
//  的 .frame(idealHeight: 540)(不再需要,sheet 高度固定后 ScrollView 自然适配);
//  ③ 640pt 计算依据 = header 60 + Divider 1 + padding 28 + summary 80 + spacing
//  14 + chart 400 + spacing 4 + hint 18 + spacing 14 + "检查项"标题 22 = 641pt,
//  首屏正好显示到「检查项」标题行,Code-Review 等卡片完全靠滚动消化。
//
//  设计权衡：macOS settings sheet（Xcode Preferences / TextEdit 文档信息等）大量
//  使用固定高度,用户体验已被验证可接受,优先稳定性胜过 resize 弹性。
//
//  ──────────────────────────────────────────────────────────────────────────
//  v4 修订（2026-06-16 22:30，dong4j 反馈"美化雷达图 + 添加交互效果"）：
//  ──────────────────────────────────────────────────────────────────────────
//  尺寸由 dong4j 自行调到 minHeight=maxHeight=610,本轮不再动 sheet 尺寸,纯
//  雷达图视觉与交互升级。详见 OpenSSFRadarChart 类型注释。
//
//  关键改动只在 OpenSSFRadarChart：
//  1. 静态 Canvas → GeometryReader(ZStack) 架构（Canvas + hit zones 交互层 +
//     中心 chip）,Canvas 仍然画所有几何,hit zones 负责 hover 检测,chip 负责
//     展示选中 check 的分数 + 简称。
//  2. Canvas 美化：背景径向光晕 + 网格透明度分层 + 数据多边形改径向渐变填充 +
//     顶点圆点可高亮（hover 加发光环 + 半径 3→4.5）+ 轴线可高亮（hover 变
//     accent）+ 顶点标签可高亮（hover 9pt/medium/secondary → 10pt/semibold/
//     primary）。
//  3. 交互：每个顶点 32×32 透明圆形 hit zone 锚定轴线尽头,hover 触发上述高亮
//     联动 + 中心 chip 显示分数 + 系统 .help() tooltip 显示 name/score/reason。
//

import SwiftUI

struct OpenSSFScoreSheet: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var store: OpenSSFScoreStore { dependencies.openSSFScoreStore }
    private var record: OpenSSFScoreRecord? { store.record(for: repo.id) }
    private var payload: OpenSSFScorePayload? {
        guard let data = record?.checksJSON else { return nil }
        return try? JSONDecoder().decode(OpenSSFScorePayload.self, from: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        // v3.4（2026-06-16 22:00, dong4j 反馈"底部文字被截取 / 改小窗口高度,
        // 只保留最后一行的检查项这个文本"）：彻底放弃 idealHeight 协商 ——
        // macOS SwiftUI sheet 的 idealHeight 在 ScrollView 嵌套下连续三次不稳定
        // (v3.1 / v3.2 / v3.3 都试过逐层加 idealHeight,sheet 仍被内容撑开)。
        //
        // 这次直接 `minHeight = maxHeight = 640` 把 sheet 高度**固定**,牺牲"拖动
        // 调高度"的灵活性换稳定性(macOS 上 Xcode Preferences / TextEdit 文档信息
        // 等大量 sheet 都是固定高度,用户体验已被验证可接受)。宽度仍可拖动以适应
        // 不同分辨率屏幕。
        //
        // 高度 640pt 计算依据(dong4j 验收路径"首屏到检查项标题为止"):
        //   header 60 + Divider 1 + padding 28(top14+bot14) + summary 80 +
        //   spacing 14 + chart 400 + spacing 4 + hint 18 + spacing 14 +
        //   "检查项"标题 22 = 641pt → 取 640pt(差 1pt 由 SwiftUI 自动调和)。
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 800,
               minHeight: 610, maxHeight: 610)
        .task(id: repo.id) {
            await store.loadCachedScores(for: [repo.id])
            if store.record(for: repo.id) == nil {
                store.prefetchIfNeeded(repo: repo)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("openssf.sheet.title")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(verbatim: repo.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await store.refresh(repo: repo, force: true) }
            } label: {
                // 与 RepoHealthSheet 刷新按钮保持一致:纯图标 + loading 时切换 ProgressView。
                if store.isLoading(repoId: repo.id) {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(store.isLoading(repoId: repo.id))
            .help(store.isLoading(repoId: repo.id) ? "openssf.action.refreshing" : "openssf.action.refresh")
            .accessibilityLabel(store.isLoading(repoId: repo.id) ? "openssf.action.refreshing" : "openssf.action.refresh")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let record, record.fetchStatus == .success, let payload {
            scoreContent(record: record, payload: payload)
        } else if let record {
            statusContent(record: record)
        } else if store.isLoading(repoId: repo.id) {
            loadingContent
        } else {
            loadingContent
        }
    }

    private func scoreContent(record: OpenSSFScoreRecord, payload: OpenSSFScorePayload) -> some View {
        let evaluated = payload.checks.filter(\.isEvaluated)
        // v3.3（21:50, dong4j）：hint 从 Chart 内部 .overlay(.bottom) 移到这里作
        // 独立 VStack row,与 6 点钟顶点标签物理分隔,根除视觉重合。
        //
        // v3.4（22:00, dong4j 反馈"底部被裁 / 改小窗口高度"）：删除 ScrollView 自身
        // 的 .frame(idealHeight: 540) —— 外层 sheet 高度现在已经固定为 640pt
        // （见 body 内 .frame minHeight/maxHeight 同值约束）,ScrollView 自动拿到
        // sheet 剩余空间（≈ 640 - 60 header - 1 divider = 579pt）,内容超出由
        // ScrollView 自身滚动消化,不再需要 idealHeight 协商。
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                scoreSummary(record: record)
                VStack(spacing: 4) {
                    OpenSSFRadarChart(checks: evaluated)
                        .frame(height: 400)
                        .frame(maxWidth: .infinity)
                    Text("openssf.chart.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                checksList(payload.checks)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func scoreSummary(record: OpenSSFScoreRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(record.aggregateScore.map { String(format: "%.1f", $0) } ?? "N/A")
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 3) {
                Text("openssf.score.aggregate")
                    .font(.headline)
                if let scoreDate = record.scoreDate,
                   let parsed = Self.parseScoreDate(scoreDate) {
                    Text(String(format: String.l10n("openssf.score.dateFormat"), formattedScoreDate(parsed)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Link(destination: URL(string: "https://scorecard.dev/viewer/?uri=github.com/\(repo.owner)/\(repo.name)")!) {
                Label("openssf.action.openViewer", systemImage: "safari")
            }
        }
    }

    private func checksList(_ checks: [OpenSSFScoreCheck]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("openssf.checks.title")
                .font(.headline)

            ForEach(checks) { check in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: check.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(check.isEvaluated ? String(format: "%.1f", check.score) : String.l10n("openssf.check.unavailable"))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if let reason = check.reason, !reason.isEmpty {
                        Text(verbatim: reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func statusContent(record: OpenSSFScoreRecord) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(statusTitle(record.fetchStatus))
                .font(.headline)
            if let lastError = record.lastError, !lastError.isEmpty {
                Text(verbatim: lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var loadingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("openssf.loading")
                .font(.headline)
            Text("openssf.loading.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func statusTitle(_ status: OpenSSFScoreFetchStatus) -> LocalizedStringKey {
        switch status {
        case .success: return "openssf.status.success"
        case .notIndexed: return "openssf.status.notIndexed"
        case .networkError: return "openssf.status.networkError"
        case .parseError: return "openssf.status.parseError"
        }
    }

    /// 解析 OpenSSF API 返回的 `score_date` 字段。
    ///
    /// 历史观察：API 返回的字段绝大多数是 ISO8601 `2026-06-16T11:35:26Z`，少数老版本
    /// 是纯日期 `2026-06-16`。这里两套都尝试，保证不同源都能正常显示本地时间。
    private static func parseScoreDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let pure = DateFormatter()
        pure.dateFormat = "yyyy-MM-dd"
        pure.timeZone = TimeZone(identifier: "UTC")
        pure.locale = Locale(identifier: "en_US_POSIX")
        return pure.date(from: raw)
    }

    /// 把 Date 格式化为 `yyyy-MM-dd HH:mm:ss` 形式，使用当前 view 的 locale + 本地时区。
    ///
    /// 这是固定数字格式而非「友好相对时间」，所以不需要 RelativeDateTimeFormatter；
    /// 但 i18n 军规 #4 仍要求注入 `\.locale` —— 中文环境下 calendar 默认是 gregorian，
    /// 但若用户切到阿拉伯/希伯来日历，没有显式注入会出现非 yyyy-MM-dd 的展示，所以这里
    /// 强制走 `en_US_POSIX` 保证字段格式稳定，时间数字本身按本地时区显示。
    private func formattedScoreDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// OpenSSF 雷达图（v4 美化 + 交互版）。
///
/// ──────────────────────────────────────────────────────────────────────────
/// 为什么自绘而不用第三方雷达图库（2026-06-16 22:45 dong4j + 助手共同调研拍板）：
/// ──────────────────────────────────────────────────────────────────────────
/// 系统调研了 8 个候选第三方 SwiftUI 雷达图库,**全部不适配 Starcat**:
/// - **PrettyAxis** (27★ MIT 纯 SwiftUI macOS 12+): 技术上最匹配,但 2022-05 后
///   4 年无更新,macOS 17 / Swift 6.x 升级要自己 fork 修。
/// - **DGCharts / ChartsOrg/Charts** (28k★ Apache-2.0): 老牌活跃,但 AppKit-
///   based,SwiftUI 必须 NSViewRepresentable 包装。本组件已实现的 hover 联动 +
///   中心 chip + 系统 tooltip 全部要在 NSView 内自己重写(NSTrackingArea /
///   NSEvent),换库等于功能降级 + 引入大体积依赖。
/// - **DDSpiderChart** (98★ MIT): Package.swift 只声明 .iOS(.v11),完全不导出
///   macOS target → SPM 集成直接失败(README 上的 "macOS 11+" 是老 podspec 残留)。
/// - **SwiftUICharts (willdale, 960★)** / **AppPear/ChartView (6k★)**: 都明确
///   不支持 radar chart(github issue 4 年没合并 PR)。
/// - **SwiftBI** (3★) / **JKSpiderChartLibrary** (2016) / **Spider-Web-Chart**
///   (2020 一次性 push,无 SPM): 个人玩具 / 死档。
/// - **AAInfographics** (~10k★): WKWebView + Highcharts.js 桥,原生 app 杀鸡用牛刀。
///
/// 结论:**保留自绘 v4 不引入第三方依赖**。理由:
/// 1. 当前实现 ~280 行可控,完整中文注释 + 演进历史 + 关键约束齐全。
/// 2. 已实现的 hover 联动 + chip + tooltip 三件套是上述第三方库默认都没有的,
///    换库 = 功能降级 + 二次开发包装层。
/// 3. 0 新依赖 = 不需要在 About → Credits 登记开源致谢(规则见 CLAUDE.md/AGENTS.md
///    "开源致谢同步规则")。
/// 4. OpenSSF check 维度固定在 15 个以内,数据规模与功能复杂度都不需要功能型 chart
///    库的大而全(标签格式化器 / scale / axis renderer / data set 抽象等)。
///
/// 后续若要再扩"折线 / 柱状"等图表,**应该再次评估**(届时引入一个统一图表库的成本
/// 才有意义,而不是为单个雷达图引入)。
///
/// ──────────────────────────────────────────────────────────────────────────
/// 演进历史：
/// - v2 / v3：纯静态 Canvas（5 层同心环 + 中心放射轴线 + 数据多边形 + 顶点圆点 +
///   外环标签）。视觉静态、无 hover 反馈。
/// - v4（2026-06-16 22:30，dong4j 反馈"美化 + 加交互"）：Canvas 美化 + 32×32 hit
///   zones（锚定轴线尽头）+ hover 联动 + 中心 chip + 系统 .help() tooltip。
/// - **v4.1（2026-06-16 23:10，dong4j 反馈"光标放上去全都是 10.0"）**：本版本。
///   废弃 hit zones,改用 `.onContinuousHover` 按光标到中心的角度反算最近轴。
///
/// ──────────────────────────────────────────────────────────────────────────
/// v4.1 修订（dong4j 真机截图反馈 bug）：
/// ──────────────────────────────────────────────────────────────────────────
/// **症状**：dong4j hover 不同顶点 → 中心 chip 都显示 10.0,与实际不同 check 的分
/// 数差异（截图中 SAST / Token-Permissions 等明显 < 10）对不上。
///
/// **根因（双因素）**：
/// 1. **v4 hit zones 全部锚定在轴线尽头（外环位置 radius）** —— 与"score=低时数据
///    顶点挤近中心"刻意脱钩,本意是命中稳定。但 OpenSSF 高分 check 占多数（License
///    / Maintained / Dangerous-Workflow / Contributors / Branch-Protection /
///    Dependency-Update-Tool / Binary-Artifacts / Security-Policy 等通常都是 10），
///    dong4j 在外环上随手移动,十有八九命中的就是 score=10 的 check → 视觉上"全都
///    是 10.0"。**用户感知体验是: hit zone 太"挑剔",只有对准外环的某些方向才反馈,
///    其余位置都没反应,严重违反"光标放上去就该有反馈"的直觉**。
/// 2. **SwiftUI `.position()` + `.onHover` 在 macOS 上存在已知 hit-test 不稳定**:
///    `.position()` 修饰的 view reported frame 扩展到父 frame,但 `.contentShape`
///    限定的 hit 区域有时不能正确缩回 32×32 圆形,导致 onHover 触发范围错位。
///
/// **修复**：废弃 ForEach 多 hit zones,改在 ZStack 根挂 `.contentShape(Rectangle())`
///  + `.onContinuousHover { phase in ... }`,**按光标到中心的角度反算最近的轴**:
/// - 算法: 极坐标 `atan2(dy, dx) + π/2` 转换到"12 点钟为 0、顺时针递增",再除以
///   `2π/N` round 到最近 index。范围保护: 中心 8pt 内不识别（chip 区域防抖）、
///   `radius + 30pt` 外不识别（避免标签区外的 hover 误识别）。
/// - 用户感知: 光标在 chart 任何位置（任意半径任意方向）都精确识别最近的轴,与
///   "雷达图是放射状结构,光标方向即是 check 方向"的直觉对齐。
/// - 副作用收益: 不依赖 hit zones 位置正确性 → 不再受 `.position()` hit-test
///   quirk 影响 → bug 根治。
///
/// **取舍**：删除 v4 的 `.help()` 系统 tooltip（reason 三段式），由下方 checksList
/// 列表承担 reason 展示。中心 chip 仅显示 score + name 简称已足够即时反馈,1.5s
/// 延迟的 .help() 反而不如即时 chip 实用。
///
/// ──────────────────────────────────────────────────────────────────────────
/// 视觉规格（v4.1 沿用 v4 不变）：
/// 1. **背景径向光晕**：accent 色 0.06 opacity 从中心衰减到外圈。
/// 2. **网格分层**：5 层同心环透明度从内到外 0.16/0.22/0.28/0.32/0.45,最外环
///    加粗到 1.5px。
/// 3. **数据多边形**：径向渐变填充（accent 0.45 → 0.10）+ 描边 2.5px。
/// 4. **顶点圆点**：默认 3pt 半径,hover 时 4.5pt + 18pt 直径径向发光环。
/// 5. **顶点标签**：默认 9pt/medium/secondary,hover 时 10pt/semibold/primary。
/// 6. **轴线**：默认 secondary 0.20/1px,hover 时 accent 0.65/1.5px。
/// 7. **中心 chip**：仅 hover 时显示,Capsule.regularMaterial + accent 描边,
///    17pt rounded bold 分数 + 9pt medium secondary 简称。
///
/// 架构与关键约束：
/// - Canvas 无法对自身内部局部 hit-test → 必须用 `GeometryReader` + `ZStack`
///   在 root 挂 hover handler。`hoveredIndex` 是 `@State`,改变后 Canvas closure
///   重新执行,所有"hovered 联动"都通过分支条件渲染。N≈15 重绘成本可忽略。
/// - **角度变换公式必须与 `point(...)` 同源**: `point()` 内顶点 i 的极角是
///   `(i/N) × 2π - π/2`（顶点 0 在 12 点钟,顺时针递增）。反向算角度时
///   `atan2(dy, dx) + π/2` 把 atan2 默认的"3 点钟为 0"基准转到"12 点钟为 0"。
/// - **内外圈 deadzone**: 内 8pt 避免中心 chip 区域抖动;外 `radius + 30pt`
///   避免标签 buffer 之外的 hover 错觉。
/// - 中心 chip `.allowsHitTesting(false)`：否则 chip 会拦截光标,用户跨越中心
///   时光标先离开 chart contentShape 再进入 chip,触发 .ended → 闪烁。
/// - `.contentShape(Rectangle())` 必须显式声明,否则 GeometryReader 内的 ZStack
///   默认 hit 区域只在子 view 实际像素位置（Canvas 透明区不参与 hit-test）,
///   onContinuousHover 在大面积空白处不触发。Rectangle 让整个 frame 都参与
///   hit-test。
/// - `ZStack` 整体绑定 `.animation(.spring..., value: hoveredIndex)`,让 chip
///   的 `.transition(.scale + .opacity)` 动画化。光标快速移动跨多个 sector 时,
///   spring 会被打断重新开始 → 视觉上 chip "scale 平滑跟随"; Canvas 重绘是
///   imperative 不参与 implicit animation,圆点 / 标签 / 轴线高亮是瞬切（可接受）。
private struct OpenSSFRadarChart: View {
    let checks: [OpenSSFScoreCheck]

    /// 当前 hover 的 check 索引;nil 表示无 hover,所有元素恢复默认样式。
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        if checks.count >= 3 {
            GeometryReader { proxy in
                ZStack {
                    radarCanvas
                    centerChip(size: proxy.size)
                }
                // v4.1 关键: 整个 ZStack frame 都要参与 hit-test,否则 Canvas
                // 透明区域的 hover 不触发。Rectangle 覆盖整个 GeometryReader。
                .contentShape(Rectangle())
                // v4.1 关键: 用 onContinuousHover 在 root 跟踪光标,按角度反算
                // 最近的轴。废弃了 v4 的 ForEach hit zones —— root cause 见类型
                // 注释 v4.1 修订段。
                .onContinuousHover { phase in
                    let newIndex = nearestAxis(for: phase, in: proxy.size)
                    if hoveredIndex != newIndex {
                        hoveredIndex = newIndex
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hoveredIndex)
            }
        } else {
            Text("openssf.chart.notEnoughData")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Canvas 绘制层

    private var radarCanvas: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // v3.2 调过的系数,沿用：雷达图直径占 frame 短边 84%,顶点标签在
            // radius+14 处仍有 44pt 安全 buffer 不裁。
            let radius = min(size.width, size.height) * 0.42
            let count = checks.count

            drawBackgroundGlow(context: context, center: center, radius: radius)
            drawRings(context: context, count: count, center: center, radius: radius)
            drawAxes(context: context, count: count, center: center, radius: radius)
            let valuePoints = drawValuePolygon(context: context, count: count, center: center, radius: radius)
            drawVertexDots(context: context, valuePoints: valuePoints)
            drawLabels(context: context, count: count, center: center, radius: radius)
        }
    }

    /// 背景径向光晕：accent 0.06 → clear,半径 1.15×radius,营造发光氛围。
    private func drawBackgroundGlow(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let glowR = radius * 1.15
        let rect = CGRect(x: center.x - glowR, y: center.y - glowR, width: glowR * 2, height: glowR * 2)
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [.accentColor.opacity(0.06), .clear]),
                center: center,
                startRadius: 0,
                endRadius: glowR
            )
        )
    }

    /// 5 层同心环,透明度内浅外深,最外环加粗。
    private func drawRings(context: GraphicsContext, count: Int, center: CGPoint, radius: CGFloat) {
        let opacities: [Double] = [0.16, 0.22, 0.28, 0.32, 0.45]
        for ring in 1...5 {
            var path = Path()
            let r = radius * CGFloat(ring) / 5
            for index in 0..<count {
                let p = point(index: index, count: count, center: center, radius: r)
                index == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.closeSubpath()
            context.stroke(
                path,
                with: .color(.secondary.opacity(opacities[ring - 1])),
                lineWidth: ring == 5 ? 1.5 : 1.0
            )
        }
    }

    /// 中心放射轴线;hovered 顶点对应轴线变 accent 高亮。
    private func drawAxes(context: GraphicsContext, count: Int, center: CGPoint, radius: CGFloat) {
        for index in 0..<count {
            let end = point(index: index, count: count, center: center, radius: radius)
            var axis = Path()
            axis.move(to: center)
            axis.addLine(to: end)
            if hoveredIndex == index {
                context.stroke(axis, with: .color(.accentColor.opacity(0.65)), lineWidth: 1.5)
            } else {
                context.stroke(axis, with: .color(.secondary.opacity(0.20)), lineWidth: 1.0)
            }
        }
    }

    /// 数据多边形：径向渐变填充 + accent 描边 2.5px。返回各顶点位置供下一步圆点绘制。
    private func drawValuePolygon(context: GraphicsContext, count: Int, center: CGPoint, radius: CGFloat) -> [CGPoint] {
        var path = Path()
        var points: [CGPoint] = []
        for (index, check) in checks.enumerated() {
            let normalized = max(0, min(check.score, 10)) / 10
            let p = point(index: index, count: count, center: center, radius: radius * normalized)
            points.append(p)
            index == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        context.fill(
            path,
            with: .radialGradient(
                Gradient(colors: [.accentColor.opacity(0.45), .accentColor.opacity(0.10)]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
        context.stroke(path, with: .color(.accentColor.opacity(0.90)), lineWidth: 2.5)
        return points
    }

    /// 顶点圆点;hovered 时半径 3→4.5,加 18pt 直径径向发光环。
    private func drawVertexDots(context: GraphicsContext, valuePoints: [CGPoint]) {
        for (index, p) in valuePoints.enumerated() {
            let isHovered = (hoveredIndex == index)
            if isHovered {
                let glowR: CGFloat = 9
                let rect = CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [.accentColor.opacity(0.5), .clear]),
                        center: p,
                        startRadius: 0,
                        endRadius: glowR
                    )
                )
            }
            let r: CGFloat = isHovered ? 4.5 : 3
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            context.fill(dot, with: .color(.accentColor))
            context.stroke(dot, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.5)
        }
    }

    /// 顶点标签（外环 +14pt）;hovered 时 9pt/medium/secondary → 10pt/semibold/primary。
    private func drawLabels(context: GraphicsContext, count: Int, center: CGPoint, radius: CGFloat) {
        for (index, check) in checks.enumerated() {
            let labelPoint = point(index: index, count: count, center: center, radius: radius + 14)
            let isHovered = (hoveredIndex == index)
            let text = Text(verbatim: shortLabel(check.name))
                .font(.system(size: isHovered ? 10 : 9,
                              weight: isHovered ? .semibold : .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            context.draw(context.resolve(text), at: labelPoint, anchor: .center)
        }
    }

    // MARK: - 交互层

    /// 按光标位置反算最近的轴 index（v4.1 onContinuousHover 核心算法）。
    ///
    /// 算法：
    /// 1. 计算光标相对 chart 中心的向量 `(dx, dy)`。
    /// 2. 计算到中心的距离 `distance`,做内外圈 deadzone 保护。
    /// 3. 用 `atan2(dy, dx)` 算极角（默认基准: 3 点钟方向 = 0,顺时针为正）。
    /// 4. 加 `π/2` 转换到"12 点钟为 0,顺时针递增"基准,与 `point(...)` 函数内
    ///    `angle = (i/N) × 2π - π/2` 同源（这是几何上的等价变换:
    ///    `point()` 内 angle 是"从 12 点钟算起的顺时针偏移",反向就是 `atan2 + π/2`）。
    /// 5. 把 `[0, 2π)` 分成 `N` 个等扇区,`round(angle / sectorAngle)` 得到最近 index,
    ///    取模 N 处理 11 点钟方向被分到 sector 0 还是 N-1 的边界 case。
    ///
    /// 范围保护：
    /// - 离中心 < 8pt → 返回 nil（中心 chip 区域 ≈ 32pt 半径; 8pt 保留是为了
    ///   即使没显示 chip 时,光标微小晃动也不会因 angle 在 0/2π 边界跳变反复切轴）。
    /// - 距离 > radius + 30pt → 返回 nil（标签在 radius+14 处,30pt 给了 16pt 余量,
    ///   避开标签外大量空白区被误识别)。
    /// - `phase == .ended` → 返回 nil（光标离开整个 chart frame 时清空 hover）。
    private func nearestAxis(for phase: HoverPhase, in size: CGSize) -> Int? {
        guard case .active(let location) = phase else { return nil }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = Double(min(size.width, size.height)) * 0.42
        let dx = Double(location.x - center.x)
        let dy = Double(location.y - center.y)
        let distance = (dx * dx + dy * dy).squareRoot()

        guard distance > 8 else { return nil }
        guard distance < radius + 30 else { return nil }

        // atan2 默认: 0 弧度 = 3 点钟, 顺时针为正(SwiftUI 屏幕坐标 y 向下,
        // dy>0 对应屏幕下方,等价于数学坐标系下的顺时针)。加 π/2 把基准转到 12 点钟。
        var angleFrom12 = atan2(dy, dx) + .pi / 2
        if angleFrom12 < 0 { angleFrom12 += 2 * .pi }

        let count = checks.count
        let sectorAngle = 2 * .pi / Double(count)
        let index = Int((angleFrom12 / sectorAngle).rounded()) % count
        return index
    }

    /// 中心 chip：仅 hover 时显示。胶囊背景 `.regularMaterial` + accent 描边,
    /// 内含 17pt rounded bold 分数（无评估时显示 N/A 本地化文案）+ 9pt 简称。
    ///
    /// `.allowsHitTesting(false)` 强制,否则 chip 会拦截光标,用户跨中心移动时
    /// hover 闪烁。`.transition(.scale + .opacity)` 配合外层 ZStack 的
    /// `.animation(.spring..., value: hoveredIndex)` 形成柔和的弹出。
    @ViewBuilder
    private func centerChip(size: CGSize) -> some View {
        if let index = hoveredIndex, checks.indices.contains(index) {
            let check = checks[index]
            VStack(spacing: 1) {
                Text(verbatim: check.isEvaluated
                     ? String(format: "%.1f", check.score)
                     : String.l10n("openssf.check.unavailable"))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(verbatim: shortLabel(check.name))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            }
            .position(x: size.width / 2, y: size.height / 2)
            .transition(.scale.combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }

    // MARK: - Helpers

    /// 计算极坐标顶点（顶点 0 在 12 点钟方向，顺时针）。
    private func point(index: Int, count: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = (Double(index) / Double(count)) * 2 * Double.pi - Double.pi / 2
        return CGPoint(
            x: center.x + CGFloat(cos(angle)) * radius,
            y: center.y + CGFloat(sin(angle)) * radius
        )
    }

    /// 雷达图顶点标签简称。OpenSSF check 名最长约 22 字符（如 `Pinned-Dependencies`），
    /// 14 字符截断 + `…` 能覆盖大多数情况；用户要看完整名字看下方 checksList。
    private func shortLabel(_ name: String) -> String {
        guard name.count > 14 else { return name }
        return name.prefix(13) + "…"
    }
}
