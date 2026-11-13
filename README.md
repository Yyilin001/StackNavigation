# StackNavigation

Typed SwiftUI stack navigation with page-instance identity and logical activation callbacks.

I built StackNavigation from my navigation work in production apps and the pitfalls I encountered while investigating SwiftUI state and lifecycle behavior. It brings those lessons into a small library with explicit rules for navigation, page identity and callbacks.

[中文说明](Documentation/README.zh-CN.md) · [Compatibility](Documentation/Compatibility.md) · [Testing](Documentation/Testing.md)

**Status: API preview, unreleased.** Licensed under MIT. The repository starts with a fresh history; the previous tag and release have been retired. See the [changelog](CHANGELOG.md) for the current scope.

## Problems it addresses

- **Repeated routes and reused local state.** Each push gets its own UUID and page identity boundary, including a pop followed by a push in the same update cycle.
- **State mismatches after arbitrary path edits.** A read-only path and explicit push/return commands prevent middle removal and reordering.
- **Unclear page lifecycle semantics.** Separate activation/deactivation callbacks track the logical stack top, including the root page, without depending on SwiftUI appearance callbacks. Change events also identify removed entries for business-data cleanup.
- **Navigation inside callbacks.** Reentrant commands are queued in order, so a callback's push or pop does not interrupt the current notification round.
- **Old callbacks after Host replacement.** A new Host revokes its predecessor's registrations and rejects system path writes from the retired Host.

Activation means **being the logical stack top**. It does not mean that an animation finished or that the page is visually unobscured.

## Installation

For local development, use Xcode's **Add Local Package** and select this repository root.

Add [this repository](https://github.com/Yyilin001/StackNavigation) in Xcode's Package Dependencies and select branch `main`, or use the following manifest entry:

```swift
.package(url: "https://github.com/Yyilin001/StackNavigation.git", branch: "main")
```

The `main` branch can change. Pin a reviewed commit using the dependency’s `revision:` argument when reproducible integration is required; no version tag is currently available.

Link the `StackNavigation` product. The package declares Swift tools 6.0 and iOS 17; see the [compatibility table](Documentation/Compatibility.md) for tested combinations.

## Quick start

```swift
import SwiftUI
import StackNavigation

enum Route: Hashable { case detail(Int) }

struct Flow: View {
    @State private var navigator = Navigator<Route>()

    var body: some View {
        NavigationHost(navigator: navigator) {
            Button("Open detail") { navigator.push(.detail(42)) }
                .onNavigationActivate { print("Root active") }
                .onNavigationDeactivate { print("Root inactive") }
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
            Text("Item: \(itemID)")
            Button("Count: \(count)") { count += 1 }
            Button("Push same route") { navigator.push(.detail(itemID)) }
            Button("Back") { navigator.pop() }
            Button("Back to root") { navigator.popToRoot() }
        }
        .onNavigationActivate { print("Detail active") }
        .onNavigationDeactivate { print("Detail inactive") }
    }
}
```

Place this code in your app and present `Flow()`. Repeated pushes of the same route have separate counters. Attach lifecycle modifiers to the stable root view of a managed page. Routes should be small, stable `Hashable` values; keep business models in an external store.

## API and ordering

| API | Contract |
| --- | --- |
| `push(route) -> UUID` | Allocates a new page identity; use the returned ID inside callbacks |
| `pop() -> Bool` | Removes the projected top entry |
| `pop(to: id) -> Bool` | Keeps the target and removes everything above it |
| `popToRoot() -> Bool` | Removes all path entries |
| `entries`, `topEntry`, `canPop`, `rootID` | Read the committed state; the root is not an entry |
| `onNavigationActivate` / `onNavigationDeactivate` | Become / leave the logical stack top |
| `onNavigationEnter` / `onNavigationExit` | Initial in-stack registration / actual removal from the path |
| `observeChanges { change }` | Retain the returned `NavigationSubscription`; cancel or release it to unsubscribe |
| `@Environment(\.navigationPage)` | Optional context with `id`, live `topID`, and `isTop` |
| `@Environment(\.navigationEntryID)` | The current page ID, derived from its context |

`NavigationChange` includes `previousTop`, `currentTop`, `insertedEntries`, and `removedEntries`. A nil top denotes the root. Removed entries are ordered from top to bottom.

Each commit updates the path, sends change events, deactivates the previous top, sends removal callbacks from top to bottom, and activates the new top. Reentrant commands execute afterward in FIFO order. Return-operation Booleans indicate that a command was accepted, not that a transition completed. New commands are validated against the projected queue; public queries still show committed state.

Only registered pages receive lifecycle transitions. A transient page pushed and popped before registration has change events but no replayed page callbacks. Callbacks use the latest evaluated closure; query a store or page context when you need current values rather than captured snapshots.

## Page insertion and removal

```swift
Detail(itemID: 42)
    .onNavigationEnter { print("Registered in the stack") }
    .onNavigationExit { print("Removed from the path") }
```

Use either modifier alone or combine them with activation/deactivation. Registration is deferred until after view evaluation. A batch registers all modifiers, sends initial insertion callbacks, then activation callbacks, before processing reentrant navigation. Modifier order does not change that phase ordering.

- Insertion is delivered once per registration if the page is still in the stack, even when covered. Covering, returning to the page and ordinary reevaluation do not repeat it.
- Removal is delivered once when the entry leaves the path, including covered entries removed by a multi-page return. It terminates that registration and clears its callbacks.
- The root receives initial insertion as a permanent member of the logical stack. It cannot be popped and never receives removal.
- A new Host or a recreated modifier creates a new registration and delivers insertion again for a surviving page. Revoking/releasing/rebinding an old registration silently stops it, without synthetic removal.
- These callbacks describe a registered page's logical membership, not SwiftUI allocation/deallocation. They are not guaranteed to pair: a page may never register, or its registration may be released before removal. Use a retained `observeChanges` subscription for complete path events and mandatory business-data cleanup. Whole-flow cleanup remains the owner's responsibility.

## Ownership and limits

- One Navigator is fixed for a Host's view identity. Recreate the Host explicitly to switch flows. A replacement Host retires its predecessor permanently.
- Page boundaries use a stable `.id(entry.id)` to isolate local state, including same-turn pop/push replacement. Host recreation preserves the path and external models, but recreates local view state.
- Middle removal, reordering, arbitrary path replacement, and direct value NavigationLink appends are not supported. Use Navigator commands for managed navigation.
- Removing the whole Host without a successor does not explicitly end the flow or synthesize deactivation/removal. The owner must stop flow-level resources.
- A delayed system write that is still a valid prefix cannot be distinguished from a new back operation by its path payload alone. Earlier app-based button/gesture checks passed on a specific configuration; see [test scope](Documentation/Testing.md). Those UI tests are not included in this package.
- Callbacks must terminate; the library does not cap navigation loops. Sheet, Tab visibility, app foregrounding, and animation completion are outside logical stack lifecycle.

## Development

The repository contains the library and package tests; it does not include an example application or UI test target.

```sh
python3 Scripts/check_repository.py
python3 Scripts/verify.py package
python3 Scripts/verify.py package-build --configuration Release
python3 Scripts/check_integration.py
```

The test runner chooses an available iPhone simulator automatically. Set `SIMULATOR_OS=18.5` or `SIMULATOR_UDID` to select a device. Plain `swift test` on macOS is not the supported iOS verification path.

See [contributing](CONTRIBUTING.md), [internal design](Documentation/Internals.md), [release preparation](Documentation/Releasing.md), and the [changelog](CHANGELOG.md).

## License

MIT © 2026 Yyilin. See [LICENSE](LICENSE).
