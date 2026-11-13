# 内部设计与源码导读

本文说明实现上的不变量。对外契约和调用示例以[中文使用说明](README.zh-CN.md)为准。

## 源码职责

| 文件 | 职责 |
| --- | --- |
| `Navigator.swift` | 路径命令、变更订阅、串行队列、Host 接管、延后挂接与生命周期分发 |
| `NavigationHost.swift` | SwiftUI NavigationStack 适配、页面身份边界、内部 Host 会话 |
| `NavigationLifecycle.swift` | 页面观察对象、注册记录和四个公开修饰符 |
| `NavigationPageContext.swift` | 页面环境上下文及 Host/entry 注册身份 |
| `NavigationEntry.swift` | 不可变导航实例 |
| `NavigationChange.swift` | 一次已提交变更的数据 |
| `NavigationSubscription.swift` | 订阅持有与取消 |

内部类型留在其主要使用点附近；没有全局导航器或单独的生命周期管理器。

## 状态与所有权

| 状态 | 所有者与用途 |
| --- | --- |
| `entries` | Navigator 的已提交路径，供视图和回调查询 |
| `scheduledEntries` | 包含已接受排队命令的预计路径，供新命令校验 |
| `jobs` / `isDelivering` | 串行化导航、接管和初次注册，防止回调重入打断当前通知 |
| `activeHost` | 当前 Host 会话；页面上下文据此判断所属 Host 是否有效 |
| `pendingHostActivations` | 尚未处理完的接管请求数量，暂时拒绝系统返回写回 |
| `pendingHostMounts` / `pendingAttachments` | 弱引用挂接请求，合并到下一次 MainActor 调度 |
| `NavigationPageRegistration.current` | 修饰符持有的一份可选记录，身份与观察对象一起建立、清除 |

Host 和修饰符通过普通 `@State` 保留无副作用的引用缓存。不使用 `StateObject` 或手动包装器初始化，也不以 SwiftUI onAppear/onChange 或 UIKit 回调驱动库生命周期。

## 提交与分发

命令先更新预计路径，再排队提交。队列空闲时同步处理；若正在分发回调，只追加任务。一次提交完成路径更新、变更订阅和页面通知后，才处理下一个任务。

队列逐项将已消费槽位置空，释放闭包捕获，同时避免反复移动数组头部。已提交状态和预计状态不能合并，否则回调内连续 push/pop 的校验与返回值会出错。

订阅和页面分发均只快照弱引用成员，不跨回调强持有整批对象。取消或释放后，尚未执行的通知可以跳过；正在执行的回调正常完成。新订阅注册及一轮分发结束时，清理已取消和已释放的订阅记录。

`NavigationPageObserver` 的 entry ID 不可变。`invalidate()` 清空回调并永久禁止后续生命周期通知；上下文换绑会先撤销旧观察对象，再登记新对象。身份同时包含 Host 与 entry，因为相同 entry 可以在新 Host 中重建页面。

入栈去重保存在每份观察对象中，不保存在 Navigator 的 entry 上，因此新 Host/新修饰符可以重新初始化自己的页面资源。初次注册补发在栈状态不等于重放 push 事件。提交时先失活、再按移除项的栈序发送出栈、最后激活新栈顶；出栈先终结注册并清空回调，再调用保存的出栈闭包。所有阶段均处于同一串行任务内。

## Host 与初次注册

会话构造不接管导航。Host 求值时提交幂等挂接请求，每个保留会话只登记一次；请求处理前已释放的会话不会取得所有权。

挂接批处理先确定最终 Host，再登记该 Host 的页面观察对象。先收集独立修饰符，再分发初次入栈和激活（两个阶段），避免一个修饰符的激活回调发起导航时，另一个尚未注册。

接管通过同一串行队列执行，永久撤销旧会话并静默清理旧观察对象。普通重算不能重新接管，已撤销会话不能复活。Host 独立销毁没有自动停用机制，这是公开的范围限制。

## 页面身份与系统写回

页面内容只有 Host 提供的一层 `.id`，用于新旧实例状态隔离。Host 自身不根据 Navigator 对象自动重建身份。修饰符转发 `navigationPage` 环境作用域，不再添加内容身份边界。

系统 Binding 仅在当前 Host 有效、无待接管请求、预计路径与已提交路径一致时接受原样前缀缩短。校验只认当前状态，没有系统写回的来源版本；因此不能宣称它排除了所有延迟旧写回。

## 测试定位

| 测试文件 | 重点 |
| --- | --- |
| `NavigationMembershipTests.swift` | 入栈/出栈顺序、独立注册、闭包刷新、撤销与回调重入 |
| `NavigationModifierHostingTests.swift` | 模拟器挂载真实 SwiftUI 页面，验证公开修饰符组合、独立使用与双向回调重入 |
| `NavigationStackCoreTests.swift` | 实例身份和重复路由 |
| `NavigationLibraryBehaviorTests.swift` | 命令、变更顺序与基本生命周期 |
| `NavigationCallbackRegressionTests.swift` | 订阅取消、实时上下文与闭包更新 |
| `NavigationRegistrationLifetimeTests.swift` | 注册释放、换绑及六个组合重入场景 |
| `NavigationHostSessionTests.swift` | 接管、撤销、延后挂接和系统写回门控 |

核心测试位于 `Tests/StackNavigationTests`，覆盖导航命令、Host 所有权、注册及回调重入。仓库不包含应用工程或 XCUITest target；Package 内的 hosting 测试覆盖公开修饰符的实际 SwiftUI 注册，侧滑手势和页面本地状态仍需要应用级验证。当前检查命令、历史结果和未覆盖范围见[验证说明](Testing.md)。
