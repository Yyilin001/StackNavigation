import SwiftUI

private struct WeakSubscription { weak var value: NavigationSubscription? }

private struct WeakHostSession { weak var value: NavigationHostSession? }

private struct PendingPageAttachment {
    weak var host: NavigationHostSession?
    weak var observer: NavigationPageObserver?
}

/// 管理一个导航流的强类型路径、页面实例和逻辑生命周期。
/// 仅支持追加页面与移除连续栈顶后缀；所有操作均在 MainActor 上执行。
@MainActor
@Observable
public final class Navigator<Route: Hashable> {
    /// 已提交的路径，不包含根页面。回调内排队的命令尚未反映在这里。
    public private(set) var entries: [NavigationEntry<Route>] = []
    /// 根页面实例 ID，在 Navigator 生命周期内保持稳定。
    public let rootID = UUID()
    /// 已提交的栈顶；路径为空时为 nil，表示根页面。
    public var topEntry: NavigationEntry<Route>? { entries.last }
    /// 当前已提交的路径是否包含可返回的页面。
    public var canPop: Bool { !entries.isEmpty }

    // 预计路径包含已接受但尚未提交的命令，供回调重入时校验后续操作。
    @ObservationIgnored private var scheduledEntries: [NavigationEntry<Route>] = []
    @ObservationIgnored private var jobs: [(() -> Void)?] = []
    @ObservationIgnored private var isDelivering = false
    @ObservationIgnored private var subscriptions: [WeakSubscription] = []
    @ObservationIgnored private var pageObservers: [WeakNavigationPageObserver] = []
    @ObservationIgnored private var pendingAttachments: [PendingPageAttachment] = []
    private var activeHost: NavigationHostSession?
    @ObservationIgnored private var pendingHostActivations = 0
    @ObservationIgnored private var pendingHostMounts: [WeakHostSession] = []
    @ObservationIgnored private var mountFlushScheduled = false

    /// 创建路径为空的导航流。
    public init() {}

    // MARK: - 导航命令

    /// 创建新页面实例并返回其 ID；相同 Route 每次 push 也有不同身份。
    /// 回调内调用时延后提交，应使用返回值取得新实例 ID。
    @discardableResult
    public func push(_ route: Route) -> UUID {
        let entry = NavigationEntry(route)
        scheduledEntries.append(entry)
        scheduleCommit(scheduledEntries)
        return entry.id
    }

    /// 弹出一个栈顶页面。true 表示接受了有效命令，不代表动画已经完成。
    @discardableResult
    public func pop() -> Bool { truncate(keeping: scheduledEntries.count - 1) }

    /// 弹出全部路径项并返回根页面；预计路径已为空时返回 false。
    @discardableResult
    public func popToRoot() -> Bool { truncate(keeping: 0) }

    /// 返回指定实例并保留它；ID 不在预计路径中或已是预计栈顶时返回 false。
    /// 返回根页面请使用 popToRoot()。
    @discardableResult
    public func pop(to id: UUID) -> Bool {
        guard let index = scheduledEntries.firstIndex(where: { $0.id == id }) else { return false }
        return truncate(keeping: index + 1)
    }

    // MARK: - 变更订阅

    /// 按提交顺序订阅变更；持有返回的 token 才持续接收通知。
    /// cancel() 或释放 token 会停止后续调用，新订阅不重放历史事件。
    public func observeChanges(_ action: @escaping @MainActor (NavigationChange<Route>) -> Void)
        -> NavigationSubscription
    {
        let token = NavigationSubscription { value in
            if let change = value as? NavigationChange<Route> { action(change) }
        }
        subscriptions.removeAll { $0.value?.isCancelled != false }
        subscriptions.append(WeakSubscription(value: token))
        return token
    }

    // MARK: - Host 所有权与系统返回

    // 路径 Binding 仅供 Host 内部使用，写入必须携带所属会话。
    func pathBinding(for host: NavigationHostSession) -> Binding<[NavigationEntry<Route>]> {
        Binding(get: { self.entries }, set: { self.acceptSystemPath($0, from: host) })
    }

    func isCurrentHost(_ host: NavigationHostSession) -> Bool {
        activeHost === host && !host.isRevoked
    }

    /// 接管与导航、初次注册共用串行队列，不能中断正在分发的回调。
    func activateHost(_ host: NavigationHostSession) {
        requireHostOwner(host)
        guard !host.isRevoked, pendingHostActivations > 0 || activeHost !== host else { return }
        pendingHostActivations += 1
        enqueue { [self] in
            defer { pendingHostActivations -= 1 }
            guard !host.isRevoked, activeHost !== host else { return }
            activeHost?.revoke()
            for box in pageObservers { box.value?.invalidate() }
            pageObservers.removeAll()
            for pending in pendingAttachments where pending.host?.isRevoked != false {
                pending.observer?.invalidate()
            }
            pendingAttachments.removeAll { $0.host?.isRevoked != false || $0.observer == nil }
            activeHost = host
        }
    }

    private func acceptSystemPath(_ proposed: [NavigationEntry<Route>], from host: NavigationHostSession) {
        // 系统返回基于已提交路径。存在排队命令或待接管 Host 时拒绝写回。
        // 接受后按 FIFO 提交；拒绝时不影响预计路径和后续命令的返回值。
        // 这里没有写回来源版本，无法识别队列清空后仍恰好合法的旧前缀。
        guard isCurrentHost(host), pendingHostActivations == 0,
            scheduledEntries == entries,
            proposed.count < entries.count,
            zip(proposed, entries).allSatisfy({ $0.id == $1.id && $0.route == $1.route })
        else { return }
        truncate(keeping: proposed.count)
    }

    // MARK: - 提交与回调重入

    @discardableResult
    private func truncate(keeping count: Int) -> Bool {
        guard count >= 0, count < scheduledEntries.count else { return false }
        scheduledEntries.removeLast(scheduledEntries.count - count)
        scheduleCommit(scheduledEntries)
        return true
    }

    private func scheduleCommit(_ next: [NavigationEntry<Route>]) {
        enqueue { [self] in
            let previous = entries
            entries = next
            let change = NavigationChange(
                previousTop: previous.last, currentTop: next.last,
                insertedEntries: Array(next.dropFirst(previous.count)),
                removedEntries: Array(previous.dropFirst(next.count).reversed())
            )
            // 先通知变更订阅，便于业务在页面激活前登记模型。
            // 只快照弱引用成员，前一个回调取消或释放后一个 token 时立即生效。
            let listeners = subscriptions
            for listener in listeners { listener.value?.send(change) }
            notifyPages(removedEntries: change.removedEntries)
            subscriptions.removeAll { $0.value?.isCancelled != false }
        }
    }

    /// 当前一轮通知完成后再处理重入命令；初次激活回调也走同一队列。
    private func enqueue(_ job: @escaping () -> Void) {
        jobs.append(job)
        guard !isDelivering else { return }
        isDelivering = true
        var index = 0
        while index < jobs.count {
            let next = jobs[index]
            jobs[index] = nil  // 及时释放已消费闭包的捕获，避免移除数组头部。
            index += 1
            next?()
        }
        jobs.removeAll(keepingCapacity: true)
        isDelivering = false
    }

    // MARK: - 延后挂接

    private func requireHostOwner(_ host: NavigationHostSession) {
        precondition(
            host.bind(to: rootID),
            "NavigationHost requires the same Navigator for its lifetime. Recreate the Host explicitly when switching navigation flows."
        )
    }

    /// 幂等登记 Host 挂接请求。视图求值期间只更新非观察缓存；
    /// 所有权变更和用户回调延后到 MainActor 批处理。
    func scheduleHostMount(_ host: NavigationHostSession) {
        requireHostOwner(host)
        guard host.requestMountOnce() else { return }
        pendingHostMounts.append(WeakHostSession(value: host))
        pendingHostActivations += 1
        scheduleMountFlush()
    }

    // 合并独立修饰符的挂接请求，避免激活回调导航时另一修饰符尚未注册。
    // 批处理始终先确定 Host 所有权，再处理页面观察对象。
    func observeMountedPage(_ observer: NavigationPageObserver, host: NavigationHostSession) {
        guard !host.isRevoked else { return }
        pendingAttachments.append(PendingPageAttachment(host: host, observer: observer))
        scheduleMountFlush()
    }

    private func scheduleMountFlush() {
        guard !mountFlushScheduled else { return }
        mountFlushScheduled = true
        Task { @MainActor [weak self] in self?.flushMounts() }
    }

    private func flushMounts() {
        let hosts = pendingHostMounts
        let pending = pendingAttachments
        pendingHostMounts.removeAll()
        pendingAttachments.removeAll()
        mountFlushScheduled = false
        for box in hosts {
            pendingHostActivations -= 1
            if let host = box.value { activateHost(host) }
        }
        guard let host = activeHost else { return }
        let observers = pending.filter { $0.host === host }.map {
            WeakNavigationPageObserver(value: $0.observer)
        }
        observePages(observers, host: host)
    }

    // MARK: - 页面生命周期分发

    /// 整批只保存弱引用成员，避免已释放的注册因分发快照而继续收到回调。
    func observePages(_ observers: [WeakNavigationPageObserver], host: NavigationHostSession) {
        enqueue { [self] in
            guard isCurrentHost(host) else { return }
            let ids = Set(entries.map(\.id)).union([rootID])
            let valid = observers.filter { box in
                guard let observer = box.value else { return false }
                return !observer.isInvalidated && ids.contains(observer.entryID)
            }
            pageObservers.removeAll { $0.value == nil || $0.value?.isInvalidated == true }
            for box in valid {
                if !pageObservers.contains(where: { $0.value === box.value }) {
                    pageObservers.append(box)
                }
            }
            // 四个独立修饰符全部登记后，先补发入栈，再补发激活。
            // 两阶段均使用弱引用；前一个回调释放/撤销后一个注册会立即生效。
            for box in valid { box.value?.insert() }
            for box in valid {
                guard let observer = box.value else { continue }
                observer.setActive(observer.entryID == (topEntry?.id ?? rootID))
            }
        }
    }

    private func notifyPages(removedEntries: [NavigationEntry<Route>]) {
        let activeID = topEntry?.id ?? rootID
        let observers = pageObservers
        for box in observers {
            guard let observer = box.value, observer.entryID != activeID else { continue }
            observer.setActive(false)
        }
        // 与 NavigationChange 一致：批量返回时按栈顶到栈底发送出栈，
        // 不依赖 SwiftUI 对被覆盖页面的注册顺序。
        for entry in removedEntries {
            for box in observers {
                guard let observer = box.value, observer.entryID == entry.id else { continue }
                observer.remove()
            }
        }
        for box in observers {
            guard let observer = box.value, observer.entryID == activeID else { continue }
            observer.setActive(true)
        }
        let ids = Set(entries.map(\.id)).union([rootID])
        pageObservers.removeAll { box in
            guard let observer = box.value else { return true }
            return observer.isInvalidated || !ids.contains(observer.entryID)
        }
    }
}
