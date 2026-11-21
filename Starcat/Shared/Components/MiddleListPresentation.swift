import SwiftUI

/// 中栏只在切分类和首次加载就绪时做内容交接，刷新和分页沿用原生列表的身份。
struct MiddleListPresentation<Placeholder: View, Content: View>: View {
    let showsSkeleton: Bool
    var retainsContentDuringLoading = false
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let content: () -> Content

    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if !showsSkeleton || retainsContentDuringLoading {
                content()
                    .transaction(value: showsSkeleton) { transaction in
                        transaction.animation = nil
                    }
                    .opacity(showsSkeleton ? 0 : 1)
                    .disabled(showsSkeleton)
                    .allowsHitTesting(!showsSkeleton)
                    .accessibilityHidden(showsSkeleton)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            if showsSkeleton {
                placeholder()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(showsSkeleton ? nil : .easeOut(duration: reduceMotion ? 0.12 : 0.18), value: showsSkeleton)
    }
}

extension MiddleListPresentation where Placeholder == RepoSkeletonListView {
    init(
        showsSkeleton: Bool,
        rowCount: Int = 8,
        retainsContentDuringLoading: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(showsSkeleton: showsSkeleton, retainsContentDuringLoading: retainsContentDuringLoading, placeholder: {
            RepoSkeletonListView(rowCount: rowCount)
        }, content: content)
    }
}

/// 只用于顶级页签互换，离场页仍可见时也要立即让出交互和辅助功能焦点。
struct MiddleListPageFade: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .disabled(phase == .didDisappear)
            .allowsHitTesting(phase != .didDisappear)
            .accessibilityHidden(phase == .didDisappear)
    }
}
