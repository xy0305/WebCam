import SwiftUI

/// 全屏页左缘右滑：跟手平移，超过阈值滑出后回调。
struct EdgeSwipeBack: ViewModifier {
    var enabled: Bool = true
    var edgeWidth: CGFloat = 24
    var onBack: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var dragging = false
    @State private var popping = false

    func body(content: Content) -> some View {
        content
            .offset(x: enabled ? dragX : 0)
            .shadow(color: dragging ? .black.opacity(0.28) : .clear, radius: 16, x: -8, y: 0)
            .overlay(alignment: .leading) {
                if enabled && !popping {
                    Color.clear
                        .frame(width: dragging ? nil : edgeWidth)
                        .frame(maxWidth: dragging ? .infinity : nil, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(drag)
                        .ignoresSafeArea()
                }
            }
            .animation(dragging ? nil : .interactiveSpring(response: 0.32, dampingFraction: 0.86), value: dragX)
    }

    private var pageWidth: CGFloat {
        UIScreen.main.bounds.width
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard !popping else { return }
                if !dragging {
                    guard value.startLocation.x <= edgeWidth + 8 else { return }
                    dragging = true
                }
                dragX = max(0, value.translation.width)
            }
            .onEnded { value in
                guard dragging, !popping else { return }
                let width = pageWidth
                let shouldPop = value.translation.width > width * 0.28
                    || value.predictedEndTranslation.width > width * 0.5
                if shouldPop {
                    popping = true
                    withAnimation(.easeOut(duration: 0.22)) {
                        dragX = width
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onBack()
                    }
                } else {
                    dragging = false
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                        dragX = 0
                    }
                }
            }
    }
}

extension View {
    func edgeSwipeBack(enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, onBack: perform))
    }
}
