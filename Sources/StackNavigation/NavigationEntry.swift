import Foundation

/// 导航页面实例。相同路由可以有多个实例，相等性和 hash 仅由 id 决定。
public struct NavigationEntry<Route: Hashable>: Hashable, Identifiable {
    /// 每次 push 新建的稳定实例 ID。
    public let id: UUID
    /// 用于构建目标页面的业务路由值。
    public let route: Route

    // 生产代码只由 Navigator 创建实例；内部测试可构造非法路径验证写回校验。
    init(id: UUID = UUID(), route: Route) { self.id = id; self.route = route }
    init(_ route: Route) { self.init(route: route) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
