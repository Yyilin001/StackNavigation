import StackNavigation
import SwiftUI
import Testing
import UIKit
import XCTest

/// Exercises the public modifiers in a rendered NavigationHost, without an example app.
/// This covers SwiftUI registration, not gesture recognition or animation completion.
@Suite(.serialized)
@MainActor
struct NavigationModifierHostingTests {
    @Test(arguments: [false, true])
    func renderedModifiersInsertCoverReturnAndRemove(reverse: Bool) async {
        let nav = Navigator<String>()
        let events = Events()
        let rootReady = events.expect("root+")
        let window = show(nav, events, reverse: reverse)
        defer { window.isHidden = true; window.rootViewController = nil }
        await passed(rootReady)
        let aReady = events.expect("A+")
        nav.push("A")
        await passed(aReady)
        let bReady = events.expect("B+")
        nav.push("B")
        await passed(bReady)
        nav.pop()
        #expect(events.log == ["rootI", "root+", "root-", "AI", "A+", "A-", "BI", "B+", "B-", "BX", "A+"])
        nav.pop()
        #expect(Array(events.log.suffix(3)) == ["A-", "AX", "root+"])
        #expect(events.log.filter { $0 == "AI" }.count == 1)
        #expect(!events.log.contains("rootX"))
    }

    @Test(arguments: [false, true])
    func renderedInsertionReentryStillDeliversSeparateRemoval(reverse: Bool) async {
        let nav = Navigator<String>()
        let events = Events()
        let rootReady = events.expect("root+")
        let window = show(nav, events, reverse: reverse)
        defer { window.isHidden = true; window.rootViewController = nil }
        await passed(rootReady)
        events.onEvent = { event in
            if event == "AI" {
                #expect(nav.pop())
                #expect(nav.topEntry?.route == "A")
            }
        }
        let removed = events.expect("AX")
        nav.push("A")
        await passed(removed)
        #expect(events.log == ["rootI", "root+", "root-", "AI", "A+", "A-", "AX", "root+"])
        #expect(nav.entries.isEmpty)
    }

    @Test func renderedRemovalCanPushSameRouteWithNewRegistration() async {
        let nav = Navigator<String>()
        let events = Events()
        let rootReady = events.expect("root+")
        let window = show(nav, events)
        defer { window.isHidden = true; window.rootViewController = nil }
        await passed(rootReady)
        let firstReady = events.expect("A+")
        let oldID = nav.push("A")
        await passed(firstReady)
        events.onEvent = { event in
            if event == "AX" {
                nav.push("A")
                #expect(nav.entries.isEmpty)
            }
        }
        let replacementReady = events.expect("A+")
        nav.pop()
        await passed(replacementReady)
        #expect(nav.topEntry?.id != oldID)
        #expect(nav.entries.map(\.route) == ["A"])
        #expect(
            events.log == [
                "rootI", "root+", "root-", "AI", "A+", "A-", "AX",
                "root+", "root-", "AI", "A+",
            ])
        events.onEvent = nil
        nav.pop()
        #expect(events.log.filter { $0 == "AX" }.count == 2)
    }

    @Test(arguments: [false, true])
    func renderedMembershipModifierCanBeUsedAlone(removeOnly: Bool) async {
        let nav = Navigator<String>()
        let events = Events()
        let rootReady = events.expect("root+")
        let window = show(nav, events, onlyMembership: removeOnly ? "remove" : "insert")
        defer { window.isHidden = true; window.rootViewController = nil }
        await passed(rootReady)
        // Root uses all modifiers; the destination uses only one membership modifier.
        let ready = events.expect(removeOnly ? "page registered" : "AI")
        nav.push("A")
        await passed(ready)
        nav.pop()
        #expect(events.log.filter { $0 == (removeOnly ? "AX" : "AI") }.count == 1)
        #expect(!events.log.contains(removeOnly ? "AI" : "AX"))
    }

    private func show(
        _ nav: Navigator<String>, _ events: Events, reverse: Bool = false,
        onlyMembership: String? = nil
    ) -> UIWindow {
        let view = NavigationHost(navigator: nav) {
            page("root", events, reverse: reverse)
        } destination: { entry in
            if onlyMembership == "insert" {
                AnyView(Text(entry.route).onNavigationEnter { events.emit(entry.route + "I") })
            } else if onlyMembership == "remove" {
                AnyView(
                    VStack {
                        Text(entry.route).onNavigationExit { events.emit(entry.route + "X") }
                        // Independent test probe: wait for the registration batch, not a fixed delay.
                        Color.clear.frame(width: 0, height: 0)
                            .onNavigationEnter { events.emit("page registered") }
                    })
            } else {
                page(entry.route, events, reverse: reverse)
            }
        }
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func page(_ name: String, _ events: Events, reverse: Bool) -> AnyView {
        if reverse {
            return AnyView(
                Text(name)
                    .onNavigationExit { events.emit(name + "X") }
                    .onNavigationDeactivate { events.emit(name + "-") }
                    .onNavigationActivate { events.emit(name + "+") }
                    .onNavigationEnter { events.emit(name + "I") })
        }
        return AnyView(
            Text(name)
                .onNavigationEnter { events.emit(name + "I") }
                .onNavigationActivate { events.emit(name + "+") }
                .onNavigationDeactivate { events.emit(name + "-") }
                .onNavigationExit { events.emit(name + "X") })
    }

    private func passed(_ expectation: XCTestExpectation) async {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10)
        #expect(result == .completed)
    }

    private final class Events {
        var log: [String] = []
        var onEvent: ((String) -> Void)?
        private var expectations: [String: XCTestExpectation] = [:]

        func expect(_ event: String) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: event)
            expectations[event] = expectation
            return expectation
        }

        func emit(_ event: String) {
            log.append(event)
            onEvent?(event)
            expectations.removeValue(forKey: event)?.fulfill()
        }
    }
}
