@testable import StackNavigation
import Foundation
import Testing

@MainActor
struct NavigationMembershipTests {
    enum Route: Hashable { case a, b, c }

    @Test func insertionIsOncePerRegistrationAndCoveringIsNotRemoval() {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        var log: [String] = []
        let root = page(nav.rootID, "R", into: { log.append($0) })
        attach([root], nav, host)
        let a = page(nav.push(.a), "A", into: { log.append($0) })
        attach([a], nav, host)
        let b = page(nav.push(.a), "B", into: { log.append($0) })
        attach([b], nav, host)
        attach([root, a, b], nav, host)
        nav.pop()
        nav.pop()
        #expect(!nav.pop())
        #expect(
            log == [
                "RI", "R+", "R-", "AI", "A+", "A-", "BI", "B+",
                "B-", "BX", "A+", "A-", "AX", "R+",
            ])
        #expect(root.isInserted)
        #expect(a.isInvalidated && b.isInvalidated)
        withExtendedLifetime((root, a, b)) {}
    }

    @Test(arguments: [0, 1, 2])
    func batchRemovalOrdersHiddenPagesFromTopDown(operation: Int) {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let aID = nav.push(.a), bID = nav.push(.b), cID = nav.push(.c)
        var log: [String] = []
        let root = page(nav.rootID, "R", into: { log.append($0) })
        let a = page(aID, "A", into: { log.append($0) })
        let b = page(bID, "B", into: { log.append($0) })
        let c = page(cID, "C", into: { log.append($0) })
        attach([b, root, c, a], nav, host)  // Deliberately unrelated to path order.
        #expect(log == ["BI", "RI", "CI", "AI", "C+"])
        log.removeAll()
        let token = nav.observeChanges { _ in log.append("change") }
        defer { token.cancel() }
        if operation == 0 {
            nav.pop(to: aID)
        } else if operation == 1 {
            nav.popToRoot()
        } else {
            nav.pathBinding(for: host).wrappedValue = Array(nav.entries.prefix(1))
        }
        let expected =
            operation == 1
            ? ["change", "C-", "CX", "BX", "AX", "R+"]
            : ["change", "C-", "CX", "BX", "A+"]
        #expect(log == expected)
        withExtendedLifetime((root, a, b, c)) {}
    }

    @Test(arguments: [[0, 1, 2, 3], [3, 2, 1, 0], [2, 0, 3, 1], [1, 3, 0, 2]])
    func separateModifiersFinishInsertionAndActivationBeforeReentrantPop(order: [Int]) {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let id = nav.push(.a)
        var log: [String] = []
        let observers = [
            NavigationPageObserver(
                entryID: id,
                onInsert: {
                    log.append("I-begin")
                    #expect(nav.pop())
                    #expect(nav.topEntry?.id == id)
                    log.append("I-end")
                }),
            NavigationPageObserver(entryID: id, onRemove: { log.append("X") }),
            NavigationPageObserver(entryID: id, onActivate: { log.append("+") }),
            NavigationPageObserver(entryID: id, onDeactivate: { log.append("-") }),
        ]
        attach(order.map { observers[$0] }, nav, host)
        #expect(log == ["I-begin", "I-end", "+", "-", "X"])
        #expect(nav.entries.isEmpty)
        #expect(observers.allSatisfy { $0.isInvalidated })
    }

    @Test(arguments: [false, true])
    func eachMembershipCallbackWorksAlone(removeOnly: Bool) {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let id = nav.push(.a)
        var calls = 0
        let observer = NavigationPageObserver(
            entryID: id, onInsert: { if !removeOnly { calls += 1 } },
            onRemove: { if removeOnly { calls += 1 } })
        attach([observer], nav, host)
        #expect(calls == (removeOnly ? 0 : 1))
        nav.pop()
        #expect(calls == 1)
        withExtendedLifetime(observer) {}
    }

    @Test func removalReentryWaitsForAllRemovedPagesAndReturningTop() {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let aID = nav.push(.a), bID = nav.push(.b)
        var log: [String] = []
        let root = page(nav.rootID, "R", into: { log.append($0) })
        let a = page(aID, "A", into: { log.append($0) })
        let b = NavigationPageObserver(
            entryID: bID,
            onRemove: {
                log.append("BX-begin")
                let c = nav.push(.c)
                #expect(!nav.pop(to: c))
                #expect(nav.pop())
                #expect(!nav.pop())
                #expect(nav.entries.isEmpty)
                log.append("BX-end")
            })
        attach([root, a, b], nav, host)
        log.removeAll()
        let token = nav.observeChanges { _ in log.append("change") }
        defer { token.cancel() }
        nav.popToRoot()
        #expect(log == ["change", "BX-begin", "BX-end", "AX", "R+", "change", "R-", "change", "R+"])
        #expect(nav.entries.isEmpty)
        withExtendedLifetime((root, a, b)) {}
    }

    @Test(arguments: [false, true])
    func callbackCanReleaseOrInvalidateLaterRegistration(duringRemoval: Bool) {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let id = nav.push(.a)
        var later: NavigationPageObserver? = NavigationPageObserver(
            entryID: id, onInsert: { Issue.record("Released registration inserted") },
            onRemove: { Issue.record("Released registration removed") })
        weak var released = later
        let first = NavigationPageObserver(
            entryID: id, onInsert: { if !duringRemoval { later = nil } },
            onRemove: { later?.invalidate() })
        if duringRemoval {
            later?.updateCallbacks(
                onActivate: {}, onDeactivate: {},
                onRemove: {
                    Issue.record("Invalidated registration removed")
                })
        }
        let boxes = [WeakNavigationPageObserver(value: first), .init(value: later)]
        nav.observePages(boxes, host: host)
        if !duringRemoval { #expect(released == nil) }
        nav.pop()
        withExtendedLifetime((first, later)) {}
    }

    @Test func changeSubscriptionCanCancelRemovalBeforePageDelivery() {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let observer = NavigationPageObserver(
            entryID: nav.push(.a),
            onRemove: {
                Issue.record("Cancelled registration removed")
            })
        attach([observer], nav, host)
        let token = nav.observeChanges { _ in observer.invalidate() }
        defer { token.cancel() }
        nav.pop()
        #expect(observer.isInvalidated)
    }

    @Test(arguments: [false, true])
    func takeoverQueuedInMembershipCallbackDoesNotInterruptCurrentBatch(onRemoval: Bool) {
        let nav = Navigator<Route>(), old = NavigationHostSession(), next = NavigationHostSession()
        nav.activateHost(old)
        let id = nav.push(.a)
        var log: [String] = []
        let newRoot = NavigationPageObserver(entryID: nav.rootID, onInsert: { log.append("newRI") })
        let takeover = {
            nav.activateHost(next)
            nav.observePages([.init(value: newRoot)], host: next)
        }
        let first = NavigationPageObserver(
            entryID: id, onInsert: { if !onRemoval { log.append("I1"); takeover() } },
            onRemove: {
                log.append("X1"); takeover()
            })
        let second = NavigationPageObserver(
            entryID: id, onInsert: { log.append("I2") }, onRemove: { log.append("X2") })
        attach([first, second], nav, old)
        if onRemoval {
            nav.pop()
        } else {
            nav.pathBinding(for: old).wrappedValue = []
            #expect(nav.entries.count == 1)
            nav.pop()
        }
        #expect(log == (onRemoval ? ["I2", "X1", "X2", "newRI"] : ["I1", "I2", "newRI"]))
        #expect(old.isRevoked && nav.isCurrentHost(next))
        withExtendedLifetime((first, second, newRoot)) {}
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingRegistrationRefreshUsesLatestCallbacksAndDoesNotReplay() async {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let id = nav.push(.a)
        let registration = NavigationPageRegistration()
        var log: [String] = []
        registration.update(
            context: context(id, nav, host), onActivate: {}, onDeactivate: {},
            onInsert: { log.append("staleI") }, onRemove: { log.append("staleX") })
        await withCheckedContinuation { done in
            registration.update(
                context: context(id, nav, host), onActivate: {}, onDeactivate: {},
                onInsert: {
                    log.append("I"); done.resume()
                }, onRemove: { log.append("oldX") })
            #expect(log.isEmpty)
        }
        registration.update(
            context: context(id, nav, host), onActivate: {}, onDeactivate: {},
            onInsert: { log.append("duplicateI") }, onRemove: { log.append("X") })
        nav.pop()
        registration.update(
            context: context(id, nav, host), onActivate: {}, onDeactivate: {},
            onInsert: { log.append("revivedI") }, onRemove: { log.append("revivedX") })
        nav.push(.a); nav.pop()
        #expect(log == ["I", "X"])
        withExtendedLifetime(registration) {}
    }

    @Test(.timeLimit(.minutes(1)))
    func alreadyPoppedOrOutsideHostRegistrationHasNoMembershipCallbacks() async {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        let id = nav.push(.a)
        let transient = NavigationPageRegistration(), outside = NavigationPageRegistration()
        transient.update(
            context: context(id, nav, host), onActivate: {}, onDeactivate: {},
            onInsert: { Issue.record("Historical insertion replayed") },
            onRemove: { Issue.record("Unregistered removal replayed") })
        outside.update(
            context: nil, onActivate: {}, onDeactivate: {},
            onInsert: { Issue.record("Outside Host") }, onRemove: { Issue.record("Outside Host") })
        nav.pop()
        let sentinel = NavigationPageRegistration()
        await withCheckedContinuation { done in
            sentinel.update(
                context: context(nav.rootID, nav, host), onActivate: {}, onDeactivate: {},
                onInsert: { done.resume() })
        }
        withExtendedLifetime((transient, outside, sentinel)) {}
    }

    @Test(.timeLimit(.minutes(1)))
    func rebindingToNewHostReplaysInsertionWithoutSyntheticRemoval() async {
        let nav = Navigator<Route>(), old = NavigationHostSession(), next = NavigationHostSession()
        nav.activateHost(old)
        let id = nav.push(.a)
        let registration = NavigationPageRegistration()
        var log: [String] = []
        await withCheckedContinuation { done in
            registration.update(
                context: context(id, nav, old), onActivate: {}, onDeactivate: {},
                onInsert: {
                    log.append("oldI"); done.resume()
                }, onRemove: { log.append("oldX") })
        }
        nav.activateHost(next)
        await withCheckedContinuation { done in
            registration.update(
                context: context(id, nav, next), onActivate: {}, onDeactivate: {},
                onInsert: {
                    log.append("newI"); done.resume()
                }, onRemove: { log.append("newX") })
        }
        nav.pop()
        #expect(log == ["oldI", "newI", "newX"])
        withExtendedLifetime(registration) {}
    }

    @Test func cancelledSystemBackDoesNotRemoveAndCompletedBackRemovesOnce() {
        let nav = Navigator<Route>(), host = NavigationHostSession()
        nav.activateHost(host)
        var count = 0
        let observer = NavigationPageObserver(entryID: nav.push(.a), onRemove: { count += 1 })
        attach([observer], nav, host)
        let binding = nav.pathBinding(for: host)
        binding.wrappedValue = nav.entries  // Models unchanged path after cancellation.
        #expect(count == 0)
        binding.wrappedValue = []
        binding.wrappedValue = []
        #expect(count == 1)
        withExtendedLifetime(observer) {}
    }

    private func page(_ id: UUID, _ name: String, into log: @escaping (String) -> Void)
        -> NavigationPageObserver
    {
        NavigationPageObserver(
            entryID: id, onActivate: { log(name + "+") },
            onDeactivate: { log(name + "-") }, onInsert: { log(name + "I") },
            onRemove: { log(name + "X") })
    }

    private func attach(
        _ observers: [NavigationPageObserver], _ nav: Navigator<Route>, _ host: NavigationHostSession
    ) {
        nav.observePages(observers.map { .init(value: $0) }, host: host)
    }

    private func context(_ id: UUID, _ nav: Navigator<Route>, _ host: NavigationHostSession)
        -> NavigationPageContext
    {
        NavigationPageContext(
            id: id, host: host, readTopID: { nav.topEntry?.id ?? nav.rootID },
            isCurrentHost: { nav.isCurrentHost(host) },
            observe: { nav.observeMountedPage($0, host: host) })
    }
}
