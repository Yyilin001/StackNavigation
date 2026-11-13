/// 持有 token 以持续接收导航变更；取消或释放后停止后续通知。
@MainActor
public final class NavigationSubscription {
    private var action: ((Any) -> Void)?
    var isCancelled: Bool { action == nil }
    init(action: @escaping (Any) -> Void) { self.action = action }
    /// 立即取消尚未执行的回调；正在执行的回调会执行完毕。可重复调用。
    public func cancel() { action = nil }
    func send(_ value: Any) { action?(value) }
}
