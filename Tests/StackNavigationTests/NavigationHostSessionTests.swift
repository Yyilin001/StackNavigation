@testable import StackNavigation
import Foundation
import Testing

@MainActor
struct NavigationHostSessionTests {
    enum Route: Hashable { case a, b, c }

    @Test func takeoverSilentlyInvalidatesRetainedOldPageObservers() {
        let nav = Navigator<Route>()
        let first = NavigationHostSession(), second = NavigationHostSession()
        nav.activateHost(first)
        let id = nav.push(.a)
        var trace: [String] = []
        let old = observer(id, appear: { trace.append("old+") }, disappear: { trace.append("old-") })
        nav.observePages([.init(value: old)], host: first)
        let path = nav.entries
        var changes = 0
        let token = nav.observeChanges { _ in changes += 1 }
        defer { token.cancel() }
        nav.activateHost(second)
        #expect(nav.entries == path)
        #expect(changes == 0)
        #expect(!old.isActive)
        #expect(trace == ["old+"])
        let new = observer(id, appear: { trace.append("new+") }, disappear: { trace.append("new-") })
        nav.observePages([.init(value: new)], host: second)
        nav.pop()
        #expect(trace == ["old+", "new+", "new-"])
        #expect(changes == 1)
    }

    @Test func revokedHostCannotReactivateOrRegisterEvenWhileRetained() {
        let nav = Navigator<Route>()
        let old = NavigationHostSession(), current = NavigationHostSession()
        nav.activateHost(old)
        nav.activateHost(current)
        nav.activateHost(old)
        var calls = 0
        let late = observer(nav.rootID, appear: { calls += 1 }, disappear: { calls += 1 })
        nav.observePages([.init(value: late)], host: old)
        nav.push(.a)
        nav.pop()
        #expect(calls == 0)
        #expect(old.isRevoked)
        #expect(nav.isCurrentHost(current))
        #expect(!late.isActive)
    }

    @Test func oldSystemBindingCannotPopCurrentHostsPath() {
        let nav = Navigator<Route>()
        let old = NavigationHostSession(), current = NavigationHostSession()
        nav.activateHost(old)
        nav.push(.a)
        nav.push(.a)
        let oldBinding = nav.pathBinding(for: old)
        let prefix = Array(nav.entries.prefix(1))
        nav.activateHost(current)
        oldBinding.wrappedValue = prefix
        #expect(nav.entries.count == 2)
        nav.pathBinding(for: current).wrappedValue = prefix
        #expect(nav.entries == prefix)
        oldBinding.wrappedValue = []
        #expect(nav.entries == prefix)
    }

    @Test func activationIsIdempotentForTheSameHost() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        var trace: [String] = []
        let root = observer(nav.rootID, appear: { trace.append("+") }, disappear: { trace.append("-") })
        nav.observePages([.init(value: root)], host: host)
        nav.activateHost(host)
        nav.observePages([.init(value: root)], host: host)
        nav.push(.a)
        nav.pop()
        #expect(trace == ["+", "-", "+"])
        #expect(!host.isRevoked)
    }

    @Test func reentrantTakeoverCompletesCurrentDeliveryThenRejectsQueuedOldRegistration() {
        let nav = Navigator<Route>()
        let old = NavigationHostSession(), current = NavigationHostSession()
        nav.activateHost(old)
        var trace: [String] = []
        let late = observer(nav.rootID, appear: { trace.append("late-old+") }, disappear: {})
        let new = observer(nav.rootID, appear: { trace.append("new+") }, disappear: { trace.append("new-") })
        let root = observer(
            nav.rootID,
            appear: {
                trace.append("old+begin")
                nav.activateHost(current)
                nav.observePages([.init(value: late)], host: old)
                nav.observePages([.init(value: new)], host: current)
                nav.push(.a)
                #expect(nav.isCurrentHost(old))
                #expect(nav.entries.isEmpty)
                trace.append("old+end")
            }, disappear: { trace.append("old-") })
        nav.observePages([.init(value: root)], host: old)
        #expect(trace == ["old+begin", "old+end", "new+", "new-"])
        #expect(nav.isCurrentHost(current))
        #expect(!root.isActive)
        #expect(!late.isActive)
        #expect(nav.entries.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingMountRegistrationsCannotCrossHostTakeover() async {
        let nav = Navigator<Route>()
        let old = NavigationHostSession(), current = NavigationHostSession()
        nav.activateHost(old)
        var trace: [String] = []
        let oldPage = observer(
            nav.rootID, appear: { trace.append("old+") }, disappear: { trace.append("old-") })
        let newPage = NavigationPageObserver(entryID: nav.rootID)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            newPage.updateCallbacks(
                onActivate: {
                    trace.append("new+")
                    done.resume()
                }, onDeactivate: { trace.append("new-") })
            nav.observeMountedPage(oldPage, host: old)
            nav.activateHost(current)
            nav.observeMountedPage(oldPage, host: old)  // 旧 Host 的迟到注册必须忽略。
            nav.observeMountedPage(newPage, host: current)
        }
        nav.push(.a)
        #expect(trace == ["new+", "new-"])
        #expect(!oldPage.isActive)
    }

    @Test func retiredPageContextIsNotTopEvenWhenItsEntryIsStillTheStackTop() {
        let nav = Navigator<Route>()
        let old = NavigationHostSession(), current = NavigationHostSession()
        nav.activateHost(old)
        let page = NavigationPageContext(
            id: nav.rootID, host: old, readTopID: { nav.topEntry?.id ?? nav.rootID },
            isCurrentHost: { nav.isCurrentHost(old) },
            observe: { nav.observeMountedPage($0, host: old) }
        )
        #expect(page.isTop)
        nav.activateHost(current)
        #expect(page.topID == nav.rootID)
        #expect(!page.isTop)
    }

    @Test func queuedTakeoverRejectsOldBindingWithoutChangingProjectedCommands() {
        let nav = Navigator<Route>()
        let old = NavigationHostSession(), current = NavigationHostSession()
        nav.activateHost(old)
        nav.push(.a)
        let prefix = nav.entries
        let binding = nav.pathBinding(for: old)
        var trace: [Route?] = []
        let token = nav.observeChanges { change in
            trace.append(change.currentTop?.route)
            if change.insertedEntries.last?.route == .b {
                nav.activateHost(current)
                nav.activateHost(old)  // Still unrevoked now, but cannot reclaim after takeover.
                binding.wrappedValue = prefix
                nav.push(.c)
                #expect(nav.pop())  // Must remove C, not B or A.
            }
        }
        defer { token.cancel() }
        nav.push(.b)
        #expect(nav.entries.map(\.route) == [.a, .b])
        #expect(trace == [.b, .c, .b])
        #expect(nav.isCurrentHost(current))
        #expect(old.isRevoked)
        // Rejection does not leave the gate closed after queued activation jobs finish.
        nav.pathBinding(for: current).wrappedValue = prefix
        #expect(nav.entries == prefix)
        #expect(trace == [.b, .c, .b, .a])
    }

    @Test func admittedSystemPopCommitsBeforeLaterTakeoverAndBusinessCommands() {
        let nav = Navigator<Route>()
        let old = NavigationHostSession(), current = NavigationHostSession()
        nav.activateHost(old)
        nav.push(.a)
        let prefix = nav.entries
        var trace: [Route?] = []
        let token = nav.observeChanges { change in
            trace.append(change.currentTop?.route)
            if change.insertedEntries.last?.route == .b {
                nav.pathBinding(for: old).wrappedValue = prefix
                nav.activateHost(current)
                #expect(nav.pop())  // Uses the accepted system pop's projected path.
                #expect(!nav.pop())
            }
        }
        defer { token.cancel() }
        nav.push(.b)
        #expect(nav.entries.isEmpty)
        #expect(trace == [.b, .a, nil])
        #expect(nav.isCurrentHost(current))
    }

    @Test(arguments: [false, true])
    func systemEchoOrShorteningCannotUndoQueuedPush(shorten: Bool) {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        nav.push(.a)
        var trace: [Route?] = []
        let token = nav.observeChanges { change in
            trace.append(change.currentTop?.route)
            if change.insertedEntries.last?.route == .b {
                let committed = nav.entries
                nav.push(.c)
                nav.pathBinding(for: host).wrappedValue = shorten ? Array(committed.prefix(1)) : committed
            }
        }
        defer { token.cancel() }
        nav.push(.b)
        #expect(nav.entries.map(\.route) == [.a, .b, .c])
        #expect(trace == [.b, .c])
        // A fresh system back after the queue drains must still work normally.
        nav.pathBinding(for: host).wrappedValue = Array(nav.entries.prefix(2))
        #expect(nav.entries.map(\.route) == [.a, .b])
        #expect(trace == [.b, .c, .b])
    }

    @Test func systemEchoCannotResurrectQueuedPopAndLaterPushUsesProjectedPath() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        nav.push(.a)
        var trace: [Route?] = []
        let token = nav.observeChanges { change in
            trace.append(change.currentTop?.route)
            if change.insertedEntries.last?.route == .b {
                let committed = nav.entries
                #expect(nav.pop())
                nav.pathBinding(for: host).wrappedValue = committed
                nav.push(.c)
            }
        }
        defer { token.cancel() }
        nav.push(.b)
        #expect(nav.entries.map(\.route) == [.a, .c])
        #expect(trace == [.b, .a, .c])
    }

    @Test func sameHostActivationDoesNotBlockValidReentrantSystemPop() {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        nav.activateHost(host)
        nav.push(.a)
        let prefix = nav.entries
        var changes = 0
        let token = nav.observeChanges { change in
            changes += 1
            if change.insertedEntries.last?.route == .b {
                nav.activateHost(host)
                nav.pathBinding(for: host).wrappedValue = prefix
            }
        }
        defer { token.cancel() }
        nav.push(.b)
        #expect(nav.entries == prefix)
        #expect(changes == 2)
        #expect(nav.isCurrentHost(host))
    }

    @Test(.timeLimit(.minutes(1)))
    func installedSessionClaimsOwnershipBeforeItsBatchedPageActivation() async {
        let nav = Navigator<Route>()
        let old = NavigationHostSession()
        nav.activateHost(old)
        nav.push(.a)
        let current = NavigationHostSession()
        nav.scheduleHostMount(current)
        let page = NavigationPageObserver(entryID: nav.entries[0].id)
        #expect(nav.isCurrentHost(old))  // Staging a request does not mutate observable ownership.
        nav.pathBinding(for: old).wrappedValue = []
        #expect(nav.entries.count == 1)  // Pending ownership already blocks old system writes.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            page.updateCallbacks(
                onActivate: {
                    #expect(nav.isCurrentHost(current))
                    #expect(old.isRevoked)
                    done.resume()
                }, onDeactivate: {})
            nav.observeMountedPage(page, host: current)
        }
        nav.pathBinding(for: current).wrappedValue = []
        #expect(nav.entries.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func discardedSessionCannotClaimOwnershipOrLeaveSystemWriteGateClosed() async {
        let nav = Navigator<Route>()
        let current = NavigationHostSession()
        nav.activateHost(current)
        var discarded: NavigationHostSession? = NavigationHostSession()
        nav.scheduleHostMount(discarded!)
        weak var weakSession = discarded
        var discardedCalls = 0
        let discardedPage = observer(nav.rootID, appear: { discardedCalls += 1 }, disappear: {})
        nav.observeMountedPage(discardedPage, host: discarded!)
        discarded = nil
        #expect(weakSession == nil)
        let root = NavigationPageObserver(entryID: nav.rootID)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            root.updateCallbacks(onActivate: { done.resume() }, onDeactivate: {})
            nav.observeMountedPage(root, host: current)
        }
        #expect(nav.isCurrentHost(current))
        #expect(!current.isRevoked)
        #expect(discardedCalls == 0)
        root.updateCallbacks(onActivate: {}, onDeactivate: {})
        nav.push(.a)
        nav.pathBinding(for: current).wrappedValue = []
        #expect(nav.entries.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func multipleInstalledSessionsResolveBeforeAnyPageActivation() async {
        let nav = Navigator<Route>()
        let first = NavigationHostSession()
        let second = NavigationHostSession()
        nav.scheduleHostMount(first)
        nav.scheduleHostMount(second)
        var oldCalls = 0
        let oldPage = observer(nav.rootID, appear: { oldCalls += 1 }, disappear: { oldCalls += 1 })
        let newPage = NavigationPageObserver(entryID: nav.rootID)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            newPage.updateCallbacks(onActivate: { done.resume() }, onDeactivate: {})
            nav.observeMountedPage(oldPage, host: first)
            nav.observeMountedPage(newPage, host: second)
        }
        #expect(first.isRevoked)
        #expect(nav.isCurrentHost(second))
        #expect(oldCalls == 0)
        newPage.updateCallbacks(onActivate: {}, onDeactivate: {})
        nav.push(.a)
        nav.pathBinding(for: second).wrappedValue = []
        #expect(nav.entries.isEmpty)
        #expect(oldCalls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedExplicitMountRequestsDoNotReactivateOrBlockSystemWrites() async {
        let nav = Navigator<Route>()
        let host = NavigationHostSession()
        for _ in 0..<20 { nav.scheduleHostMount(host) }
        var log: [String] = []
        let root = NavigationPageObserver(entryID: nav.rootID)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            root.updateCallbacks(
                onActivate: {
                    log.append("R+"); done.resume()
                },
                onDeactivate: {})
            nav.observeMountedPage(root, host: host)
        }
        root.updateCallbacks(onActivate: { log.append("R+") }, onDeactivate: { log.append("R-") })
        for _ in 0..<20 { nav.scheduleHostMount(host) }
        nav.push(.a)
        nav.pathBinding(for: host).wrappedValue = []
        #expect(nav.entries.isEmpty)
        #expect(log == ["R+", "R-", "R+"])
        #expect(root.isActive)
        let replacement = NavigationHostSession()
        nav.activateHost(replacement)
        nav.scheduleHostMount(host)
        nav.push(.a)
        nav.pathBinding(for: replacement).wrappedValue = []
        #expect(nav.entries.isEmpty)
        #expect(nav.isCurrentHost(replacement))
        #expect(log == ["R+", "R-", "R+"])
    }

    @Test func allocatingUnusedTokensDoesNotClaimOwnership() {
        let nav = Navigator<Route>()
        let current = NavigationHostSession()
        nav.activateHost(current)
        for _ in 0..<100 {
            let unused = NavigationHostSession()
            #expect(!unused.isRevoked)
        }
        #expect(nav.isCurrentHost(current))
        #expect(!current.isRevoked)
        nav.push(.a)
        nav.pathBinding(for: current).wrappedValue = []
        #expect(nav.entries.isEmpty)
    }

    @Test func hostSessionCannotRebindToAnotherNavigator() {
        let original = Navigator<Route>(), replacement = Navigator<Route>()
        let host = NavigationHostSession()
        #expect(host.bind(to: original.rootID))
        #expect(host.bind(to: original.rootID))
        #expect(host.requestMountOnce())
        #expect(!host.bind(to: replacement.rootID))
        #expect(host.bind(to: original.rootID))
        #expect(!host.requestMountOnce())
        host.revoke()
        #expect(!host.bind(to: replacement.rootID))
        #expect(!host.requestMountOnce())
        let newHost = NavigationHostSession()
        #expect(newHost.bind(to: replacement.rootID))
        #expect(newHost.requestMountOnce())
    }

    private func observer(
        _ id: UUID, appear: @escaping () -> Void,
        disappear: @escaping () -> Void
    ) -> NavigationPageObserver {
        let observer = NavigationPageObserver(entryID: id, onActivate: appear, onDeactivate: disappear)
        return observer
    }
}
