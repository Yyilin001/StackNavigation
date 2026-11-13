import SwiftUI

/// 同一 entry 可以跨 Host 重建保留，注册身份必须同时包含 Host 和 entry。
struct NavigationPageIdentity: Hashable {
    let host: ObjectIdentifier
    let entry: UUID
}

/// 页面身份及对已提交导航状态的实时查询。
/// 在回调内读取属性可得到当前状态；提前复制出的 Bool 只是当时的快照。
@MainActor
public final class NavigationPageContext {
    /// 当前页面实例 ID；根页面使用 Navigator.rootID。
    public let id: UUID
    let identity: NavigationPageIdentity
    private let readTopID: @MainActor () -> UUID
    private let isCurrentHost: @MainActor () -> Bool
    let observe: @MainActor (NavigationPageObserver) -> Void

    /// 当前已提交的栈顶实例 ID；路径为空时为 rootID。
    public var topID: UUID { readTopID() }
    /// 所属 Host 仍有效且当前页面是逻辑栈顶。
    public var isTop: Bool { isCurrentHost() && id == topID }

    init(
        id: UUID, host: NavigationHostSession, readTopID: @escaping @MainActor () -> UUID,
        isCurrentHost: @escaping @MainActor () -> Bool,
        observe: @escaping @MainActor (NavigationPageObserver) -> Void
    ) {
        self.id = id
        self.identity = NavigationPageIdentity(host: ObjectIdentifier(host), entry: id)
        self.readTopID = readTopID
        self.isCurrentHost = isCurrentHost
        self.observe = observe
    }
}

private struct PageContextKey: EnvironmentKey {
    static let defaultValue: NavigationPageContext? = nil
}

extension EnvironmentValues {
    /// 页面上下文引用；NavigationHost 外为 nil。
    public internal(set) var navigationPage: NavigationPageContext? {
        get { self[PageContextKey.self] }
        set { self[PageContextKey.self] = newValue }
    }
    /// 当前页面实例 ID，直接从 navigationPage 派生。
    public var navigationEntryID: UUID? { navigationPage?.id }
}
