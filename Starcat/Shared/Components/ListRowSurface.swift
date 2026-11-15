//
//  ListRowSurface.swift
//  Starcat
//
//  常规信息行与选择行共用的绘制表面；不接管点击、原生选择或业务任务。
//

import SwiftUI

extension View {
    /// 只绘制条纹、悬停和选择；namespace 仅用于单个列表的持续单选，多选时不传。
    func listRowSurface(
        index: Int = 0,
        isSelected: Bool = false,
        selectionNamespace: Namespace.ID? = nil,
        accentColor: Color = .accentColor,
        cornerRadius: CGFloat = 7
    ) -> some View {
        modifier(ListRowSurface(
            index: index, isSelected: isSelected,
            selectionNamespace: selectionNamespace, accentColor: accentColor,
            cornerRadius: cornerRadius
        ))
    }

    /// 原生内容的局部身份交接。不能包住稳定 WebView、运行任务或需要跨选择保留草稿的编辑器。
    func nativeDetailTransition<Value: Equatable & Hashable>(value: Value) -> some View {
        modifier(NativeDetailTransition(value: value))
    }

    /// 长列表、时间线和含读取任务的宿主只做一次淡化，不为动画复制或重置内容身份。
    func stableDetailTransition<Value: Equatable>(value: Value) -> some View {
        modifier(StableDetailTransition(value: value))
    }
}

/// 背景与描边共用几何身份；文字、复选框、行尺寸及点击区域保持原位。
private struct ListRowSurface: ViewModifier {
    let index: Int
    let isSelected: Bool
    let selectionNamespace: Namespace.ID?
    let accentColor: Color
    let cornerRadius: CGFloat
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatListInteractionSuppressed) private var interactionSuppressed
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background {
                Group {
                    if isSelected, let selectionNamespace, !reduceMotion {
                        selection
                            .matchedGeometryEffect(id: "list-row-selection", in: selectionNamespace)
                    } else if isSelected {
                        selection
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(isHovered ? accentColor.opacity(0.08)
                                  : Color.primary.opacity(index.isMultiple(of: 2) ? 0 : 0.045))
                    }
                }
                // 动画交易只进入背景；同帧更新的流式正文、折叠高度和控件不跟随弹簧。
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
                .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: isSelected)
            }
            .onHover { hovering in
                isHovered = !interactionSuppressed && hovering
            }
            .onChange(of: interactionSuppressed) { _, suppressed in
                if suppressed { isHovered = false }
            }
    }

    private var selection: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(accentColor.opacity(isHovered ? 0.18 : 0.12))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(accentColor.opacity(0.28))
            }
    }
}

/// 保留新旧原生展示内容的交接宿主；选择状态和加载任务必须位于调用方稳定外层。
private struct NativeDetailTransition<Value: Equatable & Hashable>: ViewModifier {
    let value: Value
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content
                .id(value)
                .detailContentTransition()
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: value)
        .clipped()
    }
}

/// 直接动画现有绘制层，保留原生滚动容器与子视图状态。
/// 大型可变内容不保留第二棵离场树，也不对整段 Markdown / Trace 施加模糊。
private struct StableDetailTransition<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: value) { view, opacity in
            view.opacity(opacity)
        } keyframes: { _ in
            MoveKeyframe(reduceMotion ? 0.85 : 0.7)
            LinearKeyframe(1.0, duration: reduceMotion ? 0.12 : 0.18)
        }
    }
}
