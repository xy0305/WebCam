import SwiftUI
import UIKit

/// 根页面在 UINavigationController 里，全屏页 push 上去，左滑走系统 interactivePop。
struct NativeSwipeStack<Root: View, Cover: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var root: () -> Root
    var cover: () -> Cover

    init(
        isPresented: Binding<Bool>,
        @ViewBuilder root: @escaping () -> Root,
        @ViewBuilder cover: @escaping () -> Cover
    ) {
        _isPresented = isPresented
        self.root = root
        self.cover = cover
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> SwipeNavController {
        let host = UIHostingController(rootView: wrappedRoot())
        host.view.backgroundColor = UIColor.systemBackground
        let nav = SwipeNavController(rootViewController: host)
        context.coordinator.nav = nav
        bind(nav, coordinator: context.coordinator)
        return nav
    }

    func updateUIViewController(_ nav: SwipeNavController, context: Context) {
        bind(nav, coordinator: context.coordinator)
        context.coordinator.nav = nav

        let count = nav.viewControllers.count
        if isPresented, count == 1, !context.coordinator.isTransitioning {
            context.coordinator.isTransitioning = true
            let page = UIHostingController(rootView: wrappedCover(nav: nav))
            page.view.backgroundColor = .black
            page.hidesBottomBarWhenPushed = true
            nav.pushViewController(page, animated: true)
        } else if !isPresented, count > 1, !context.coordinator.isTransitioning {
            context.coordinator.isTransitioning = true
            nav.popToRootViewController(animated: true)
        }
    }

    private func bind(_ nav: SwipeNavController, coordinator: Coordinator) {
        coordinator.onDismiss = { isPresented = false }
        nav.onDidShowRoot = { [weak coordinator] in
            coordinator?.isTransitioning = false
            coordinator?.onDismiss?()
        }
        nav.onDidShowCover = { [weak coordinator] in
            coordinator?.isTransitioning = false
        }
    }

    private func wrappedRoot() -> AnyView {
        AnyView(
            root()
                .environmentObject(AppState.shared)
                .environmentObject(AuthManager.shared)
        )
    }

    private func wrappedCover(nav: UINavigationController) -> AnyView {
        AnyView(
            cover()
                .environment(\.nativeDismiss) { nav.popViewController(animated: true) }
                .environmentObject(AppState.shared)
                .environmentObject(AuthManager.shared)
        )
    }

    final class Coordinator {
        weak var nav: SwipeNavController?
        var onDismiss: (() -> Void)?
        var isTransitioning = false
    }
}

final class SwipeNavController: UINavigationController, UIGestureRecognizerDelegate, UINavigationControllerDelegate {
    var onDidShowRoot: (() -> Void)?
    var onDidShowCover: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        setNavigationBarHidden(true, animated: false)
        interactivePopGestureRecognizer?.isEnabled = true
        interactivePopGestureRecognizer?.delegate = self
        delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        if navigationController.viewControllers.count == 1 {
            onDidShowRoot?()
        } else {
            onDidShowCover?()
        }
    }

    override var childForStatusBarHidden: UIViewController? { topViewController }
    override var prefersStatusBarHidden: Bool { topViewController?.prefersStatusBarHidden ?? false }
}

private struct NativeDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var nativeDismiss: () -> Void {
        get { self[NativeDismissKey.self] }
        set { self[NativeDismissKey.self] = newValue }
    }
}
