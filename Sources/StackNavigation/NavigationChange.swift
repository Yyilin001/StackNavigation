/// 一次已提交的导航变更；不等待视图渲染或动画完成。
public struct NavigationChange<Route: Hashable> {
    /// 变更前的栈顶，nil 表示根页面。
    public let previousTop: NavigationEntry<Route>?
    /// 变更后的栈顶，nil 表示根页面。
    public let currentTop: NavigationEntry<Route>?
    /// 本次新加入的实例。
    public let insertedEntries: [NavigationEntry<Route>]
    /// 本次出栈的实例，按栈顶到栈底排列。
    public let removedEntries: [NavigationEntry<Route>]
}
