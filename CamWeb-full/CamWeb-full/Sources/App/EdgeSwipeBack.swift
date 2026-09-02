import SwiftUI

/// 屏幕左缘右滑返回，宽度约等于系统 interactivePop 手势。
struct EdgeSwipeBack: ViewModifier {
    var enabled: Bool = true
    var edgeWidth: CGFloat = 22
    var onBack: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if enabled {
                Color.clear
                    .frame(width: edgeWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 16, coordinateSpace: .local)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = abs(value.translation.height)
                                if dx > 50, dy < 90 {
                                    onBack()
                                }
                            }
                    )
                    .ignoresSafeArea()
            }
        }
    }
}

extension View {
    func edgeSwipeBack(enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, onBack: perform))
    }
}
