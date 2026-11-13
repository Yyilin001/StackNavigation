@testable import StackNavigation
import Foundation
import Testing

@MainActor
struct NavigationCallbackRegressionTests {
    enum Route: Hashable { case a, b }

    @Test(arguments: [false, true])
    func releasingLaterSubscriptionDuringDeliveryStopsIt(onPop: Bool) {
        let nav = Navigator<Route>()
        nav.push(.a)
        var second: NavigationSubscription?
        var count = 0
        let first = nav.observeChanges { _ in second = nil }
        second = nav.observeChanges { _ in count += 1 }
        weak var released = second
        defer { first.cancel() }
        if onPop { nav.pop() } else { nav.push(.b) }
        #expect(second == nil)
        #expect(released == nil)
        #expect(count == 0)
    }

    @Test func explicitCancelDuringDeliveryStopsIt() {
        let nav = Navigator<Route>()
        var second: NavigationSubscription?
        var count = 0
        let first = nav.observeChanges { _ in second?.cancel() }
        second = nav.observeChanges { _ in count += 1 }
        defer { first.cancel(); second?.cancel() }
        nav.push(.a)
        #expect(second != nil)
        #expect(count == 0)
    }

    @Test func subscriptionAddedDuringDeliveryStartsWithNextChange() {
        let nav = Navigator<Route>()
        var later: NavigationSubscription?
        var routes: [Route] = []
        let first = nav.observeChanges { change in
            if change.currentTop?.route == .a {
                later = nav.observeChanges { change in
                    routes += change.insertedEntries.map(\.route)
                }
                nav.push(.b)
            }
        }
        defer { first.cancel(); later?.cancel() }
        nav.push(.a)
        #expect(routes == [.b])
    }

    @Test func retainedPageContextReadsLiveCommittedTopIncludingRoot() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        let root = context(nav.rootID, navigator: nav, host: host)
        #expect(root.isTop)
        let a = nav.push(.a)
        let page = context(a, navigator: nav, host: host)
        #expect(!root.isTop)
        #expect(root.topID == a)
        #expect(page.isTop)
        let b = nav.push(.b)
        #expect(!page.isTop)
        #expect(page.topID == b)
        nav.pop()
        #expect(page.isTop)
        nav.popToRoot()
        #expect(root.isTop)
        #expect(!page.isTop)
        #expect(page.topID == nav.rootID)
    }

    @Test func liveContextUsesCommittedStateWhileReentrantCommandIsQueued() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        let root = context(nav.rootID, navigator: nav, host: host)
        let token = nav.observeChanges { change in
            if change.currentTop?.route == .a {
                nav.pop()
                #expect(!root.isTop)
                #expect(root.topID == change.currentTop?.id)
            } else {
                #expect(root.isTop)
            }
        }
        defer { token.cancel() }
        nav.push(.a)
        #expect(root.isTop)
    }

    @Test func refreshingCallbackCacheDoesNotEmitLifecycle() {
        let nav = Navigator<Route>()
        var trace: [String] = []
        let host = NavigationHostSession()
        nav.activateHost(host)
        let root = NavigationPageObserver(
            entryID: nav.rootID, onActivate: { trace.append("R+") },
            onDeactivate: { trace.append("old-") })
        nav.observePages([.init(value: root)], host: host)
        root.updateCallbacks(onActivate: { trace.append("new+") }, onDeactivate: { trace.append("new-") })
        #expect(trace == ["R+"])
        nav.push(.a)
        #expect(trace == ["R+", "new-"])
    }

    @Test func observerScopeIdentityIncludesBothHostAndEntry() {
        let nav = Navigator<Route>()
        let first = NavigationHostSession(), second = NavigationHostSession()
        let a = context(nav.rootID, navigator: nav, host: first)
        let redraw = context(nav.rootID, navigator: nav, host: first)
        let replacement = context(nav.rootID, navigator: nav, host: second)
        let otherPage = context(UUID(), navigator: nav, host: first)
        #expect(a.identity == redraw.identity)
        #expect(a.identity != replacement.identity)
        #expect(a.identity != otherPage.identity)
    }

    @Test(.timeLimit(.minutes(1)))
    func registeredObserverReceivesEverySynchronousRoundTrip() async {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        var log: [String] = []
        var root: NavigationPageObserver?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            root = NavigationPageObserver(
                entryID: nav.rootID,
                onActivate: {
                    log.append("R+"); done.resume()
                }, onDeactivate: {})
            nav.observeMountedPage(root!, host: host)
            #expect(log.isEmpty)  // Explicit attachment stages registration, not user callbacks.
        }
        root?.updateCallbacks(onActivate: { log.append("R+") }, onDeactivate: { log.append("R-") })
        var changes = 0
        var removed: [UUID] = []
        let token = nav.observeChanges { change in
            changes += 1
            removed += change.removedEntries.map(\.id)
        }
        defer { token.cancel() }
        var pushed: [UUID] = []
        for _ in 0..<3 {
            pushed.append(nav.push(.a))
            #expect(nav.pop())
        }
        #expect(nav.entries.isEmpty)
        #expect(changes == 6)
        #expect(removed == pushed)
        #expect(log == ["R+", "R-", "R+", "R-", "R+", "R-", "R+"])
        #expect(root?.isActive == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingObserverForAlreadyPoppedEntryDoesNotReplayPastActivation() async {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        let id = nav.push(.a)
        var calls = 0
        let page = NavigationPageObserver(
            entryID: id,
            onActivate: { calls += 1 }, onDeactivate: { calls += 1 })
        nav.observeMountedPage(page, host: host)
        nav.pop()
        var root: NavigationPageObserver?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            root = NavigationPageObserver(
                entryID: nav.rootID,
                onActivate: { done.resume() }, onDeactivate: {})
            nav.observeMountedPage(root!, host: host)
        }
        #expect(calls == 0)
        #expect(!page.isActive)
        #expect(root?.isActive == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func sameIdentityRefreshesPendingAndRegisteredCallbacksWithoutReregistering() async {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        let registration = NavigationPageRegistration()
        var log: [String] = []
        registration.update(
            context: context(nav.rootID, navigator: nav, host: host),
            onActivate: { log.append("stale+") }, onDeactivate: { log.append("stale-") })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            registration.update(
                context: context(nav.rootID, navigator: nav, host: host),
                onActivate: {
                    log.append("latest+"); done.resume()
                }, onDeactivate: {})
            #expect(log.isEmpty)
        }
        registration.update(
            context: context(nav.rootID, navigator: nav, host: host),
            onActivate: { log.append("latest+") }, onDeactivate: { log.append("latest-") })
        withExtendedLifetime(registration) {
            nav.push(.a)
            nav.pop()
        }
        #expect(log == ["latest+", "latest-", "latest+"])
    }

    @Test(.timeLimit(.minutes(1)))
    func sameEntryInNewHostReplacesRegistrationAndOldCallbacksStaySilent() async {
        let nav = Navigator<Route>()
        let first = NavigationHostSession(), second = NavigationHostSession()
        nav.activateHost(first)
        let registration = NavigationPageRegistration()
        var log: [String] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            registration.update(
                context: context(nav.rootID, navigator: nav, host: first),
                onActivate: {
                    log.append("old+"); done.resume()
                },
                onDeactivate: { log.append("old-") })
        }
        nav.activateHost(second)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            registration.update(
                context: context(nav.rootID, navigator: nav, host: second),
                onActivate: {
                    log.append("new+"); done.resume()
                },
                onDeactivate: { log.append("new-") })
        }
        registration.update(
            context: context(nav.rootID, navigator: nav, host: second),
            onActivate: { log.append("new+") }, onDeactivate: { log.append("new-") })
        withExtendedLifetime(registration) {
            nav.push(.a)
            nav.pop()
        }
        #expect(log == ["old+", "new+", "new-", "new+"])
    }

    private func context(_ id: UUID, navigator: Navigator<Route>, host: NavigationHostSession)
        -> NavigationPageContext
    {
        NavigationPageContext(
            id: id, host: host,
            readTopID: { navigator.topEntry?.id ?? navigator.rootID },
            isCurrentHost: { navigator.isCurrentHost(host) },
            observe: { navigator.observeMountedPage($0, host: host) })
    }
}
