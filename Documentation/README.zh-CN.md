# StackNavigation 使用说明

面向 iOS 17+ / Swift 6 的 SwiftUI 栈导航库。提供强类型路径、页面实例身份、逻辑激活/失活及导航变更订阅，仅依赖 SwiftUI。

StackNavigation 是我结合生产项目中的导航实践，以及排查 SwiftUI 状态和生命周期问题时的踩坑经验，整理出的一个轻量导航库。它把这些经验整理为明确的导航操作、页面身份和回调规则。

[English](../README.md) · [兼容性与验证](Compatibility.md)

当前版本为 **0.2.0（API 预览版）**，采用 MIT 许可证，版权署名为 Yyilin。版本内容见[更新记录](../CHANGELOG.md)。

## 主要处理的问题

- **重复路由与本地状态复用：** 每次 push 都生成独立 UUID，并在页面边界隔离身份，处理同周期 pop 后再 push 时新页面沿用旧页面本地状态的问题。
- **任意修改路径导致状态错位：** 路径只读，只开放 push 和返回操作，避免删除中间项、重排等操作破坏页面状态对应关系。
- **页面生命周期语义不清晰：** 激活/失活直接跟随逻辑栈顶变化，包含根页面，不依赖 SwiftUI 的视觉出现回调；出栈事件可用于清理业务数据。
- **回调内再次导航造成通知交错：** 重入命令按顺序排队，在当前一轮通知完成后执行。
- **Host 重建后的旧回调残留：** 新 Host 接管时撤销旧注册，并拒绝旧 Host 的系统路径写回。

这里的激活/失活表示成为或离开逻辑栈顶，不表示动画完成，也不包含 Sheet 遮挡或 App 前后台变化。具体约束和验证范围见下文。

## 安装

本地开发可在 Xcode 中使用 Add Local Package，选择仓库根目录。远程集成时添加[仓库地址](https://github.com/Yyilin001/StackNavigation)，选择版本 `0.2.0`，或使用以下依赖声明：

```swift
.package(url: "https://github.com/Yyilin001/StackNavigation.git", .upToNextMinor(from: "0.2.0"))
```

`0.x` 为预览阶段，上述约束只接受 `0.2.x` 补丁版本，不会自动升级到可能包含破坏性变更的 `0.3.0`。

## 快速使用

```swift
import SwiftUI
import StackNavigation

enum Route: Hashable { case detail(Int) }

struct Flow: View {
    @State private var navigator = Navigator<Route>()

    var body: some View {
        NavigationHost(navigator: navigator) {
            Button("打开详情") { navigator.push(.detail(42)) }
                .onNavigationActivate { print("根页面激活") }
                .onNavigationDeactivate { print("根页面失活") }
        } destination: { entry in
            switch entry.route {
            case .detail(let itemID):
                DetailPage(itemID: itemID)
            }
        }
    }
}

struct DetailPage: View {
    @Environment(Navigator<Route>.self) private var navigator
    @State private var count = 0
    let itemID: Int

    var body: some View {
        VStack {
            Text("条目：\(itemID)")
            Button("计数：\(count)") { count += 1 }
            Button("再打开相同路由") { navigator.push(.detail(itemID)) }
            Button("返回") { navigator.pop() }
            Button("返回根页面") { navigator.popToRoot() }
        }
        .onNavigationEnter { print("详情注册在栈中") }
        .onNavigationExit { print("详情出栈") }
        .onNavigationActivate { print("详情激活") }
        .onNavigationDeactivate { print("详情失活") }
    }
}
```

将上面的代码放入 App 并展示 `Flow()` 即可；重复打开相同路由时，每个页面有独立计数。将生命周期修饰符挂在受管页面的稳定根视图上。根页面也支持这两个激活/失活修饰符，可以单独使用或组合使用。

## API

| API | 契约 |
| --- | --- |
| `Navigator<Route: Hashable>` | `@MainActor @Observable`，每个导航流持有一个实例 |
| `push(_:) -> UUID` | 新建页面实例并返回 ID；相同 Route 每次 push 都有不同 ID |
| `pop() -> Bool` | 弹出一个栈顶页面 |
| `pop(to: UUID) -> Bool` | 返回路径中的指定实例，保留目标并移除其上方全部页面 |
| `popToRoot() -> Bool` | 移除全部路径项并返回根页面 |
| `entries` / `topEntry` / `canPop` / `rootID` | 只读已提交状态；根页面不占 entries，rootID 在 Navigator 生命周期内稳定 |
| `NavigationHost(navigator:root:destination:)` | 构建根页面和目标页面，注入 Navigator、页面上下文及页面身份边界 |
| `onNavigationActivate` / `onNavigationDeactivate` | 页面成为/离开逻辑栈顶时回调 |
| `onNavigationEnter` / `onNavigationExit` | 首次注册时补发在栈状态 / 页面实际出栈 |
| `navigationPage: NavigationPageContext?` | 环境中的页面上下文，提供 `id`、`topID`、`isTop`；Host 外为 nil |
| `navigationEntryID: UUID?` | 从 `navigationPage?.id` 派生的页面实例 ID |
| `observeChanges(_:) -> NavigationSubscription` | 按提交顺序订阅导航变更，持有 token 才持续接收 |

返回操作的 Bool 表示是否接受了有效命令。目标不存在、已是预计栈顶或预计路径已为空时返回 false；它不表示动画完成。返回根页面使用 `popToRoot()`。

`NavigationEntry<Route>` 的 `id`、`route` 不可变，相等性与 hash 仅按实例 ID 判断。外部不能构造 entry 写入路径。Route 应使用轻量、稳定的 Hashable 值，业务模型由外部 Store 管理。

## 导航变更与订阅

`NavigationChange<Route>` 包含 `previousTop`、`currentTop`、`insertedEntries`、`removedEntries`。top 为 nil 表示根页面；移除项按栈顶到栈底排列。隐藏页面出栈不会重复失活，但仍出现在 `removedEntries`。

```swift
// subscription 由调用方持有；store 为业务模型容器。
subscription = navigator.observeChanges { [weak store] change in
    store?.register(change.insertedEntries)
    store?.unregister(change.removedEntries)
}
```

调用 `cancel()` 或释放 token，立即停止同批尚未执行的后续调用；正在执行的回调会完成。新订阅不接收当前正在分发的事件，也不重放历史。闭包避免强捕获持有 token 的 owner，以免形成循环引用。

## 逻辑生命周期与回调顺序

每次提交按以下顺序执行：

1. 更新已提交路径 `entries`。
2. 按订阅顺序发送 `NavigationChange`。
3. 通知已注册的旧栈顶失活。
4. 按栈顶到栈底通知已注册页面出栈，随后激活返回的页面。
5. 处理回调内排队的命令。

同周期连续 push/pop 会逐次提交，已注册页面的生命周期不会因 SwiftUI 合并渲染而合并。首次注册先补发当前在栈状态，再补发激活状态，不重放注册前的历史；尚未构建或注册就已出栈的瞬时页面没有页面级回调，完整路径操作由 `observeChanges` 记录。

注册释放后停止后续通知；上下文清空、身份切换或 Host 被撤销时，旧观察对象静默且永久失效，不额外补发失活或出栈。观察对象失效后，刷新闭包不能复活它。

激活/失活表示逻辑栈顶变化，不表示视觉可见性、转场完成、Sheet/Tab 遮挡、前后台或对象销毁。侧滑取消且路径未变化时，不产生导航生命周期事件。

## 页面入栈与出栈

```swift
Detail(itemID: 42)
    .onNavigationEnter { print("页面已注册且仍在栈中") }
    .onNavigationExit { print("页面已从路径移除") }
```

两个修饰符可独立使用，也可与激活/失活组合，挂在页面稳定根视图上。视图求值只登记回调；延后批处理先挂接全部修饰符，再发送入栈、激活回调，最后执行回调中排队的导航。修饰符书写顺序不改变这些阶段的顺序。

- **入栈：** 每份注册在页面仍在逻辑栈中时补发一次，即使页面已被覆盖。普通重算、被覆盖、返回此页面均不重复触发。
- **出栈：** 页面实际移出路径时触发一次，包括批量返回中被移除的隐藏页面；之后这份注册永久失效并清空回调。
- **根页面：** 作为逻辑栈的常驻成员，首次注册补发入栈；根页面不能被 pop，因此没有出栈回调。
- **Host 或修饰符重建：** 新注册会为仍在栈中的页面重新补发入栈；旧注册的释放、撤销或换绑不会伪造出栈事件。
- **不保证成对：** 页面可能尚未注册就已出栈，也可能先释放注册再出栈。这不是 SwiftUI 对象创建/销毁通知。必须完整记录路径事件或保证业务数据清理时，持有 `observeChanges` 订阅；整个导航流结束时仍由 owner 清理资源。

## 回调内导航与读取状态

回调内的新命令在当前一轮通知后按 FIFO 提交。后续命令依据包含排队操作的预计路径校验，但 `entries` 等公开查询仍读取当前已提交状态。

```swift
// 在导航回调中：
let id = navigator.push(.detail(43))
// 使用返回的 id；此时 entries.last 仍可能是原页面。
navigator.pop() // 弹出刚排队的实例，两个命令依次提交。
```

`navigationPage` 是实时查询引用。在生命周期回调执行时读取 `page?.isTop` 或 `page?.topID`；提前复制出的 Bool 只是快照。生命周期闭包使用最近一次视图求值的版本，若模型刚改变但尚未重算，需要即时数据时读取 Store 或上下文引用。

## 身份与状态所有权

- 同一 Host 视图身份必须固定使用一个 Navigator，否则触发 precondition。切换流程由调用方显式创建新 Host，或以业务 flow ID 明确重建身份。
- 一个 Navigator 同时只有一个有效 Host。新 Host 接管时永久撤销旧会话，旧注册、迟到挂接及系统写回不能夺回权限。接管本身不修改路径、不发导航变更、不补发旧页面失活或出栈。
- 保留 Navigator 重建 Host 时，路径及外部业务数据保留，页面本地 State 重新创建。不同长期导航流应使用不同 Navigator。
- Host 统一在页面边界使用 `.id(entry.id)`，根页面使用 rootID，隔离新旧实例的本地状态；生命周期修饰符不重复添加 `.id`。

页面边界 `.id` 有实际对照依据：移除它后，同周期 pop B 再 push 同路由 C，曾观察到 C 使用新路由 ID，却沿用 B 的计数和 State token。历史应用级回归曾验证保留该边界的效果；当前仓库不包含 UI 测试，详见[验证说明](Testing.md)。

## 支持范围与已知边界

只支持 push 和移除连续栈顶后缀。路径只读，不开放删除中间项、重排、任意替换或通过 value NavigationLink 直接追加；受管页面应通过 Navigator 导航。库不封装 Sheet、深链接、持久化恢复、多 Tab 协调或业务任务。

- **Host 整体移除：** 当前没有显式停用 API；没有继任者时，仍存活的上下文/观察对象可能继续反映逻辑路径。结束导航流时，调用方需结束相关业务资源。
- **系统写回来源：** 仅接受当前 Host 对已提交路径的合法前缀缩短；队列清空后，恰好合法的旧前缀仍无法与新返回操作区分。内部注入已验证这一边界；历史应用级按钮/侧滑返回重入测试在当时配置下未复现误弹新页面，未加入版本拦截。
- **无限导航循环：** 回调需有终止条件，库没有自动打断业务循环的次数上限。
- **验证范围：** 声明最低 iOS 17；实际运行和工具链验证范围见兼容性表。声明版本不等于已经覆盖所有系统版本。

实现细节见[内部设计](Internals.md)，各轮实际测试范围见[验证说明](Testing.md)。
