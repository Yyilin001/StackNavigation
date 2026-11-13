@testable import StackNavigation
import Foundation
import Testing

@MainActor
struct NavigationRegistrationLifetimeTests {
    enum Route: Hashable { case a, b, c }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func releasingLaterPageRegistrationDuringDeactivationStopsIt(clearContext: Bool) async {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        var later: NavigationPageRegistration? = NavigationPageRegistration()
        weak var weakRegistration = later
        let first = NavigationPageRegistration()
        var log: [String] = []
        first.update(
            context: context(nav, host), onActivate: {},
            onDeactivate: {
                log.append("first-")
                if clearContext {
                    later?.update(context: nil, onActivate: {}, onDeactivate: {})
                } else {
                    later = nil
                    #expect(weakRegistration == nil)
                }
            })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            later?.update(
                context: context(nav, host), onActivate: { done.resume() },
                onDeactivate: { log.append("released-") })
        }
        withExtendedLifetime(first) { nav.push(.a) }
        #expect(log == ["first-"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func releasingLaterPageRegistrationDuringInitialActivationStopsIt(clearContext: Bool) async {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        var later: NavigationPageRegistration? = NavigationPageRegistration()
        weak var weakRegistration = later
        let first = NavigationPageRegistration()
        let sentinel = NavigationPageRegistration()
        var log: [String] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            first.update(
                context: context(nav, host),
                onActivate: {
                    log.append("first+")
                    if clearContext {
                        later?.update(context: nil, onActivate: {}, onDeactivate: {})
                    } else {
                        later = nil
                        #expect(weakRegistration == nil)
                    }
                }, onDeactivate: {})
            later?.update(
                context: context(nav, host), onActivate: { log.append("released+") }, onDeactivate: {})
            sentinel.update(context: context(nav, host), onActivate: { done.resume() }, onDeactivate: {})
        }
        withExtendedLifetime((first, sentinel)) {
            #expect(log == ["first+"])
        }
    }

    @Test func invalidatedObserverCannotBeRevivedByCallbackRefresh() {
        var log: [String] = []
        let observer = NavigationPageObserver(
            entryID: UUID(), onActivate: { log.append("old+") },
            onDeactivate: { log.append("old-") })
        observer.setActive(true)
        observer.invalidate()
        observer.updateCallbacks(onActivate: { log.append("new+") }, onDeactivate: { log.append("new-") })
        observer.setActive(true)
        observer.setActive(false)
        #expect(log == ["old+"])
        #expect(observer.isInvalidated)
        #expect(!observer.isActive)
    }

    @Test func rebindingInvalidatesEvenAnExternallyRetainedOldObserver() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        var retained: [NavigationPageObserver] = []
        var log: [String] = []
        func capturedContext(_ id: UUID) -> NavigationPageContext {
            NavigationPageContext(
                id: id, host: host, readTopID: { nav.rootID },
                isCurrentHost: { true }, observe: { retained.append($0) })
        }
        let registration = NavigationPageRegistration()
        registration.update(
            context: capturedContext(nav.rootID), onActivate: { log.append("old+") },
            onDeactivate: { log.append("old-") })
        retained[0].setActive(true)
        registration.update(
            context: capturedContext(UUID()), onActivate: { log.append("new+") },
            onDeactivate: {})
        retained[0].setActive(true)
        retained[0].setActive(false)
        retained[1].setActive(true)
        #expect(log == ["old+", "new+"])
        #expect(retained[0].isInvalidated)
    }

    @Test(.timeLimit(.minutes(1)))
    func activationCanRevokeItselfThenQueueNavigationWithoutDeactivation() async {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let registration = NavigationPageRegistration()
        var log: [String] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            registration.update(
                context: context(nav, host),
                onActivate: {
                    log.append("begin")
                    registration.update(context: nil, onActivate: {}, onDeactivate: {})
                    let id = nav.push(.a)
                    #expect(!nav.pop(to: id))
                    #expect(nav.pop())
                    #expect(nav.entries.isEmpty)
                    log.append("end")
                    done.resume()
                }, onDeactivate: { log.append("unexpected-") })
        }
        #expect(log == ["begin", "end"])
        #expect(nav.entries.isEmpty)
        withExtendedLifetime(registration) {
            nav.push(.b); nav.pop()
        }
        #expect(log == ["begin", "end"])
    }

    @Test(.timeLimit(.minutes(1)))
    func changeListenerCanReleasePageBeforeLifecycleDelivery() async {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        var registration: NavigationPageRegistration? = NavigationPageRegistration()
        weak var released = registration
        var calls = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            registration?.update(
                context: context(nav, host), onActivate: { done.resume() },
                onDeactivate: { calls += 1 })
        }
        let token = nav.observeChanges { _ in registration = nil }
        defer { token.cancel() }
        nav.push(.a)
        #expect(released == nil)
        #expect(calls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func sameBatchRecreationSkipsOldObserverAndActivatesNewOneOnce() async {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let first = NavigationPageRegistration(), later = NavigationPageRegistration()
        var log: [String] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            first.update(
                context: context(nav, host),
                onActivate: {
                    log.append("first+")
                    later.update(context: nil, onActivate: {}, onDeactivate: {})
                    later.update(
                        context: context(nav, host),
                        onActivate: {
                            log.append("new+"); done.resume()
                        }, onDeactivate: { log.append("new-") })
                }, onDeactivate: { log.append("first-") })
            later.update(
                context: context(nav, host), onActivate: { log.append("stale+") },
                onDeactivate: { log.append("stale-") })
        }
        withExtendedLifetime((first, later)) { nav.push(.a) }
        #expect(log == ["first+", "new+", "first-", "new-"])
    }

    @Test(.timeLimit(.minutes(1)))
    func initialActivationTakeoverAndPushRespectBatchThenQueueOrder() async {
        let nav = Navigator<Route>()
        let old = NavigationHostSession(), next = NavigationHostSession()
        nav.activateHost(old)
        let first = NavigationPageRegistration(), later = NavigationPageRegistration()
        let newRoot = NavigationPageObserver(entryID: nav.rootID)
        var log: [String] = []
        newRoot.updateCallbacks(onActivate: { log.append("new+") }, onDeactivate: { log.append("new-") })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            first.update(
                context: context(nav, old),
                onActivate: {
                    log.append("old1+")
                    nav.activateHost(next)
                    nav.observePages([.init(value: newRoot)], host: next)
                    nav.push(.a)
                }, onDeactivate: { log.append("old1-") })
            later.update(
                context: context(nav, old),
                onActivate: {
                    log.append("old2+"); done.resume()
                }, onDeactivate: { log.append("old2-") })
        }
        #expect(log == ["old1+", "old2+", "new+", "new-"])
        #expect(nav.isCurrentHost(next))
        #expect(old.isRevoked)
        #expect(nav.entries.map(\.route) == [.a])
        withExtendedLifetime((first, later, newRoot)) { nav.pop() }
        #expect(log == ["old1+", "old2+", "new+", "new-", "new+"])
    }

    @Test func subscriptionCanCancelItselfBeforeQueuingFollowupNavigation() {
        let nav = Navigator<Route>()
        var first: NavigationSubscription?
        var log: [String] = []
        first = nav.observeChanges { _ in
            log.append("first")
            first?.cancel()
            nav.push(.b)
            nav.pop()
        }
        let second = nav.observeChanges { change in log.append(String(describing: change.currentTop!.route)) }
        defer { first?.cancel(); second.cancel() }
        nav.push(.a)
        #expect(log == ["first", "a", "b", "a"])
        #expect(nav.entries.map(\.route) == [.a])
    }

    @Test(.timeLimit(.minutes(1)))
    func discardedAndMultiplePendingHostsLeaveOnlyLatestOwnerAndOpenWriteGate() async {
        let nav = Navigator<Route>()
        let first = NavigationHostSession(), last = NavigationHostSession()
        nav.scheduleHostMount(first)
        var discarded: NavigationHostSession? = NavigationHostSession()
        nav.scheduleHostMount(discarded!)
        discarded = nil
        nav.scheduleHostMount(last)
        let stale = NavigationPageRegistration(), current = NavigationPageRegistration()
        var oldCalls = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            stale.update(context: context(nav, first), onActivate: { oldCalls += 1 }, onDeactivate: {})
            current.update(context: context(nav, last), onActivate: { done.resume() }, onDeactivate: {})
        }
        current.update(context: context(nav, last), onActivate: {}, onDeactivate: {})
        withExtendedLifetime((stale, current)) {
            nav.push(.a)
            nav.pathBinding(for: first).wrappedValue = []
            #expect(nav.entries.count == 1)
            nav.pathBinding(for: last).wrappedValue = []
            #expect(nav.entries.isEmpty)
        }
        #expect(oldCalls == 0)
        #expect(first.isRevoked)
        #expect(nav.isCurrentHost(last))
    }

    private func context(_ nav: Navigator<Route>, _ host: NavigationHostSession) -> NavigationPageContext {
        NavigationPageContext(
            id: nav.rootID, host: host,
            readTopID: { nav.topEntry?.id ?? nav.rootID },
            isCurrentHost: { nav.isCurrentHost(host) },
            observe: { nav.observeMountedPage($0, host: host) })
    }
}
