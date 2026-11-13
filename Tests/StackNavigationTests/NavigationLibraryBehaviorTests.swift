@testable import StackNavigation
import Foundation
import Testing

@MainActor
struct NavigationLibraryBehaviorTests {
    enum Route: Hashable { case a, b, c }

    @Test func rootAppearsInitiallyAndReturnsWithoutDuplicateAttachment() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        var log: [String] = []
        let root = observer(nav.rootID, appear: { log.append("R+") }, disappear: { log.append("R-") })
        nav.observePages([.init(value: root)], host: host)
        nav.observePages([.init(value: root)], host: host)
        let id = nav.push(.a)
        let a = observer(id, appear: { log.append("A+") }, disappear: { log.append("A-") })
        nav.observePages([.init(value: a)], host: host)
        nav.popToRoot()
        nav.observePages([.init(value: root)], host: host)
        #expect(log == ["R+", "R-", "A+", "A-", "R+"])
        #expect(nav.entries.isEmpty)
    }

    @Test func batchPopEmitsAllRemovedEntriesButOnlyTopDisappears() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        var log: [String] = []
        var retained: [NavigationPageObserver] = []
        var removed: [UUID] = []
        let token = nav.observeChanges { change in
            removed += change.removedEntries.map(\.id)
            if !change.removedEntries.isEmpty { log.append("removed") }
        }
        defer { token.cancel() }
        let root = observer(nav.rootID, appear: { log.append("R+") }, disappear: { log.append("R-") })
        nav.observePages([.init(value: root)], host: host)
        for (name, route) in [("A", Route.a), ("B", .b), ("C", .c)] {
            let id = nav.push(route)
            let page = observer(id, appear: { log.append(name + "+") }, disappear: { log.append(name + "-") })
            retained.append(page)
            nav.observePages([.init(value: page)], host: host)
        }
        let ids = nav.entries.map(\.id)
        log.removeAll()
        nav.popToRoot()
        #expect(removed == ids.reversed())
        #expect(log == ["removed", "C-", "R+"])
        #expect(retained.allSatisfy { !$0.isActive })
        nav.popToRoot()
        #expect(removed.count == 3)
    }

    @Test func reentrantChangeCallbackQueuesPopUntilEveryListenerFinishes() {
        let nav = Navigator<Route>()
        var log: [String] = []
        let first = nav.observeChanges { change in
            if !change.insertedEntries.isEmpty {
                log.append("push-first")
                #expect(nav.pop())
                #expect(nav.entries.count == 1)
            } else {
                log.append("pop-first")
            }
        }
        let second = nav.observeChanges { change in
            #expect(nav.topEntry?.id == change.currentTop?.id)
            log.append(change.insertedEntries.isEmpty ? "pop-second" : "push-second")
        }
        defer { first.cancel(); second.cancel() }
        nav.push(.a)
        #expect(nav.entries.isEmpty)
        #expect(log == ["push-first", "push-second", "pop-first", "pop-second"])
    }

    @Test func commandsInsideCallbackValidateAgainstAlreadyQueuedCommands() {
        let nav = Navigator<Route>()
        var changes: [String] = []
        let token = nav.observeChanges { change in
            if change.insertedEntries.first?.route == .a {
                let b = nav.push(.b)
                #expect(nav.pop(to: b) == false)
                #expect(nav.pop())
                #expect(nav.pop())
                #expect(!nav.pop())
                #expect(nav.entries.map(\.route) == [.a])
            }
            changes.append("\(nav.entries.count)")
        }
        defer { token.cancel() }
        nav.push(.a)
        #expect(changes == ["1", "2", "1", "0"])
        #expect(nav.entries.isEmpty)
    }

    @Test func initialAppearanceCanNavigateWithoutInterruptingCallback() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        var log: [String] = []
        let root = observer(
            nav.rootID,
            appear: {
                log.append("R+begin")
                nav.push(.a)
                #expect(nav.entries.isEmpty)
                log.append("R+end")
            }, disappear: { log.append("R-") })
        let token = nav.observeChanges { _ in log.append("change") }
        defer { token.cancel() }
        nav.observePages([.init(value: root)], host: host)
        #expect(log == ["R+begin", "R+end", "change", "R-"])
        #expect(nav.entries.map(\.route) == [.a])
    }

    @Test func disappearanceReentryFinishesOldTransitionBeforeStartingNext() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        var log: [String] = []
        let root = observer(nav.rootID, appear: { log.append("R+") }, disappear: { log.append("R-") })
        nav.observePages([.init(value: root)], host: host)
        let id = nav.push(.a)
        let a = observer(
            id, appear: { log.append("A+") },
            disappear: {
                log.append("A-")
                nav.push(.b)
                #expect(nav.entries.isEmpty)
            })
        nav.observePages([.init(value: a)], host: host)
        log.removeAll()
        let token = nav.observeChanges { change in
            log.append(change.insertedEntries.isEmpty ? "pop" : "push")
        }
        defer { token.cancel() }
        nav.pop()
        #expect(log == ["pop", "A-", "R+", "push", "R-"])
        #expect(nav.entries.map(\.route) == [.b])
    }

    @Test(arguments: [false, true])
    func separateModifierObserversRegisterBeforeReentrantAppearance(reverse: Bool) {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        let id = nav.push(.a)
        var log: [String] = []
        let appear = observer(
            id,
            appear: {
                log.append("A+")
                nav.push(.b)
            }, disappear: {})
        let disappear = observer(id, appear: {}, disappear: { log.append("A-") })
        nav.observePages(
            (reverse ? [disappear, appear] : [appear, disappear]).map {
                WeakNavigationPageObserver(value: $0)
            }, host: host)
        #expect(log == ["A+", "A-"])
        #expect(nav.entries.map(\.route) == [.a, .b])
    }

    @Test func subscriptionsCanCancelAndReleaseWithoutBeingRetainedByNavigator() {
        let nav = Navigator<Route>()
        var count = 0
        var released: NavigationSubscription? = nav.observeChanges { _ in count += 10 }
        weak var weakToken = released
        released = nil
        #expect(weakToken == nil)
        let token = nav.observeChanges { _ in count += 1 }
        nav.push(.a)
        token.cancel()
        nav.pop()
        #expect(count == 1)
    }

    @Test func cancellationDuringDeliverySkipsCancelledListener() {
        let nav = Navigator<Route>()
        var second: NavigationSubscription?
        var calls = 0
        let first = nav.observeChanges { _ in second?.cancel() }
        second = nav.observeChanges { _ in calls += 1 }
        defer { first.cancel(); second?.cancel() }
        nav.push(.a)
        #expect(calls == 0)
    }

    @Test func rootIDsAndEventsAreIsolatedBetweenNavigators() {
        let a = Navigator<Route>(), b = Navigator<Route>()
        #expect(a.rootID != b.rootID)
        var calls = 0
        let token = b.observeChanges { _ in calls += 1 }
        defer { token.cancel() }
        a.push(.a)
        #expect(b.entries.isEmpty)
        #expect(calls == 0)
    }

    private func observer(
        _ id: UUID, appear: @escaping () -> Void,
        disappear: @escaping () -> Void
    ) -> NavigationPageObserver {
        let observer = NavigationPageObserver(entryID: id, onActivate: appear, onDeactivate: disappear)
        return observer
    }
}
