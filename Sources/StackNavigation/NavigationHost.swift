import SwiftUI

/// 承载导航流，并向根页面和目标页面注入 Navigator 与页面上下文。
/// 同一 Host 视图身份必须固定使用一个 Navigator；切换流程需显式重建 Host。
/// 每个页面边界按实例 ID 隔离本地状态，新 Host 接管时撤销旧 Host 的注册。
public struct NavigationHost<Route: Hashable, Root: View, Destination: View>: View {
    private let navigator: Navigator<Route>
    private let root: () -> Root
    private let destination: (NavigationEntry<Route>) -> Destination
    @State private var host = NavigationHostSession()

    /// root 构建根页面，destination 按导航实例构建目标页面。
    public init(
        navigator: Navigator<Route>, @ViewBuilder root: @escaping () -> Root,
        @ViewBuilder destination: @escaping (NavigationEntry<Route>) -> Destination
    ) {
        self.navigator = navigator
        self.root = root
        self.destination = destination
    }

    public var body: some View {
        // 会话构造没有副作用；保留的会话只登记一次，普通重算不会重复接管。
        navigator.scheduleHostMount(host)
        return NavigationStack(path: navigator.pathBinding(for: host)) {
            page(root(), id: navigator.rootID)
                .navigationDestination(for: NavigationEntry<Route>.self) { entry in
                    page(destination(entry), id: entry.id)
                }
        }
        .environment(navigator)
    }

    private func page<Content: View>(_ content: Content, id: UUID) -> some View {
        content
            // 唯一的页面状态边界，隔离同周期 pop 后 push 的新实例。
            .id(id)
            .environment(
                \.navigationPage,
                NavigationPageContext(
                    id: id, host: host,
                    readTopID: { navigator.topEntry?.id ?? navigator.rootID },
                    isCurrentHost: { navigator.isCurrentHost(host) },
                    observe: { navigator.observeMountedPage($0, host: host) }
                ))
    }
}

/// Host 的稳定会话身份。构造无副作用，撤销后不能重新挂接。
/// 视觉出现或消失不会改变会话所有权。
@MainActor
final class NavigationHostSession {
    private(set) var isRevoked = false

    private var hasRequestedMount = false
    private var navigatorID: UUID?

    // 用 Navigator 的 rootID 校验固定绑定，无需持有 Navigator。
    func bind(to navigatorID: UUID) -> Bool {
        if let existing = self.navigatorID { return existing == navigatorID }
        self.navigatorID = navigatorID
        return true
    }

    func requestMountOnce() -> Bool {
        guard !isRevoked, !hasRequestedMount else { return false }
        hasRequestedMount = true
        return true
    }

    func revoke() { isRevoked = true }
}
