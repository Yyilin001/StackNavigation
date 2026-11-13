import SwiftUI

/// 页面持有回调与去重状态，Navigator 仅弱引用，避免回调捕获页面/导航器后形成环。
@MainActor
final class NavigationPageObserver {
    let entryID: UUID
    private(set) var isActive = false
    private(set) var isInserted = false
    private(set) var isInvalidated = false
    private var onActivate: () -> Void
    private var onDeactivate: () -> Void
    private var onInsert: () -> Void
    private var onRemove: () -> Void

    /// 构造只保存身份和回调；注册对象取得所有权后再显式登记挂接。
    init(
        entryID: UUID, onActivate: @escaping () -> Void = {},
        onDeactivate: @escaping () -> Void = {},
        onInsert: @escaping () -> Void = {}, onRemove: @escaping () -> Void = {}
    ) {
        self.entryID = entryID
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onInsert = onInsert
        self.onRemove = onRemove
    }

    /// 只刷新闭包缓存，不改变激活状态；失效观察对象不能借此复活。
    func updateCallbacks(
        onActivate: @escaping () -> Void, onDeactivate: @escaping () -> Void,
        onInsert: @escaping () -> Void = {}, onRemove: @escaping () -> Void = {}
    ) {
        guard !isInvalidated else { return }
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onInsert = onInsert
        self.onRemove = onRemove
    }

    /// Host 撤销或注册换绑时静默失效，不补发失活或出栈回调。
    func invalidate() {
        isInvalidated = true
        isActive = false
        isInserted = false
        onActivate = {}
        onDeactivate = {}
        onInsert = {}
        onRemove = {}
    }

    /// 首次注册补发当前在栈状态；重算或返回本页面不重复发送。
    func insert() {
        guard !isInvalidated, !isInserted else { return }
        isInserted = true
        onInsert()
    }

    /// 真正出栈后终结本份注册，先失效再回调，防止重入或迟到重算复活它。
    func remove() {
        guard !isInvalidated, isInserted else { return }
        let action = onRemove
        invalidate()
        action()
    }

    func setActive(_ active: Bool) {
        guard !isInvalidated, active != isActive else { return }
        // 先更新状态再通知，回调中再次导航时不会重复发送同一个状态。
        isActive = active
        if active { onActivate() } else { onDeactivate() }
    }
}

struct WeakNavigationPageObserver {
    weak var value: NavigationPageObserver?
}

/// 修饰符持有当前 Host/页面身份的一份注册。缓存不参与 Observation；
/// 换绑先撤销旧观察对象，再登记新观察对象，不同步分发生命周期。
@MainActor
final class NavigationPageRegistration {
    private var current: (identity: NavigationPageIdentity, observer: NavigationPageObserver)?

    func update(
        context: NavigationPageContext?, onActivate: @escaping () -> Void,
        onDeactivate: @escaping () -> Void,
        onInsert: @escaping () -> Void = {}, onRemove: @escaping () -> Void = {}
    ) {
        guard let context else {
            current?.observer.invalidate()
            current = nil
            return
        }
        if let current, current.identity == context.identity {
            current.observer.updateCallbacks(
                onActivate: onActivate, onDeactivate: onDeactivate,
                onInsert: onInsert, onRemove: onRemove)
            return
        }
        current?.observer.invalidate()
        let observer = NavigationPageObserver(
            entryID: context.id, onActivate: onActivate,
            onDeactivate: onDeactivate, onInsert: onInsert, onRemove: onRemove)
        current = (context.identity, observer)
        context.observe(observer)
    }
}

private struct NavigationPageLifecycleModifier: ViewModifier {
    @Environment(\.navigationPage) private var context
    @State private var registration = NavigationPageRegistration()
    var onActivate: @MainActor () -> Void = {}
    var onDeactivate: @MainActor () -> Void = {}
    var onInsert: @MainActor () -> Void = {}
    var onRemove: @MainActor () -> Void = {}

    func body(content: Content) -> some View {
        // 视图求值时更新注册缓存，实际挂接与首次生命周期回调由 Navigator 延后处理。
        registration.update(
            context: context, onActivate: onActivate, onDeactivate: onDeactivate,
            onInsert: onInsert, onRemove: onRemove)
        // 转发页面环境作用域。修饰符不绑定 .id，页面状态隔离由 Host 负责。
        return content.environment(\.navigationPage, context)
    }
}

public extension View {
    /// 页面成为逻辑栈顶时调用，可单独使用或与 onNavigationDeactivate 组合。
    /// 首次挂载补发当前状态；不代表动画完成、Sheet 遮挡或 App 前后台。
    /// 挂在 NavigationHost 管理的页面稳定根视图上，包含根页面。
    func onNavigationActivate(_ action: @escaping @MainActor () -> Void) -> some View {
        modifier(NavigationPageLifecycleModifier(onActivate: action))
    }

    /// 页面离开逻辑栈顶时调用，包括被新页覆盖和从栈顶弹出。
    /// 可独立使用；已隐藏的页面出栈不会重复调用，不监听 SwiftUI 视觉 onDisappear。
    func onNavigationDeactivate(_ action: @escaping @MainActor () -> Void) -> some View {
        modifier(NavigationPageLifecycleModifier(onDeactivate: action))
    }

    /// 首次注册且页面仍在逻辑栈中时调用一次，随后被覆盖或重新激活不重复调用。
    /// 根页面也补发一次。新 Host 或新修饰符注册会重新补发，不是全局只发生一次的 push 事件。
    /// 注册前已出栈的页面不补发；需要完整入栈事件时使用 observeChanges。
    func onNavigationEnter(_ action: @escaping @MainActor () -> Void) -> some View {
        modifier(NavigationPageLifecycleModifier(onInsert: action))
    }

    /// 已注册页面从路径中移除时调用，包括被覆盖的页面随 pop(to:) 或 popToRoot() 出栈。
    /// 先失活、再按栈顶到栈底通知出栈，最后激活返回的页面；回调内导航按 FIFO 排队。
    /// 根页面不可出栈。Host 接管、注册释放或换绑不会补发，不代表 SwiftUI 对象销毁。
    func onNavigationExit(_ action: @escaping @MainActor () -> Void) -> some View {
        modifier(NavigationPageLifecycleModifier(onRemove: action))
    }
}
