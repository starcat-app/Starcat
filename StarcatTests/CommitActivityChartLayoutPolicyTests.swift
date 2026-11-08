//
//  CommitActivityChartLayoutPolicyTests.swift
//  StarcatTests
//
//  验证提交活动日期在不同范围、绘图区宽度和字号下抽稀，尤其避免末端标签相撞。
//

import Foundation
import Testing
@testable import Starcat

/// 用实际分类柱宽检验标签间距，防止仅限制总数却在局部留下拥挤刻度。
@Suite("Commit Activity Chart Layout Policy")
struct CommitActivityChartLayoutPolicyTests {
    @Test("各时间范围在不同窗口宽度与字号下均保留安全间距",
          arguments: [7, 28, 35, 91, 52], [CGFloat(180), 320, 520, 900])
    func labelsRemainSeparated(count: Int, plotWidth: CGFloat) throws {
        for scale in InterfaceScale.allCases.map(\.multiplier) {
            let indices = CommitActivityChartLayoutPolicy.xAxisLabelIndices(
                count: count,
                plotWidth: plotWidth,
                scale: scale
            )

            #expect(indices.count <= 6)
            #expect(indices.first == 0)
            #expect(indices.last == count - 1)
            #expect(Set(indices).count == indices.count)
            for (previous, next) in zip(indices, indices.dropFirst()) {
                let spacing = CGFloat(next - previous) * plotWidth / CGFloat(count)
                #expect(spacing >= 88 * scale)
            }
        }
    }

    @Test("窄窗口和较大字号应减少标签，而不是压缩日期")
    func densityRespondsToWidthAndScale() {
        func indices(width: CGFloat, scale: CGFloat = 1) -> [Int] {
            CommitActivityChartLayoutPolicy.xAxisLabelIndices(
                count: 35,
                plotWidth: width,
                scale: scale
            )
        }

        #expect(indices(width: 320).count < indices(width: 900).count)
        #expect(indices(width: 520, scale: 1.16).count < indices(width: 520).count)
        #expect(indices(width: 60) == [0])
    }

    @Test("空数据和未完成布局不生成刻度，单点数据只显示一次")
    func handlesEmptyAndSinglePoint() {
        #expect(CommitActivityChartLayoutPolicy.xAxisLabelIndices(
            count: 0, plotWidth: 520, scale: 1
        ).isEmpty)
        #expect(CommitActivityChartLayoutPolicy.xAxisLabelIndices(
            count: 35, plotWidth: 0, scale: 1
        ).isEmpty)
        #expect(CommitActivityChartLayoutPolicy.xAxisLabelIndices(
            count: 1, plotWidth: 520, scale: 1
        ) == [0])
    }
}
