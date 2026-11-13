@testable import StackNavigation
import Foundation
import Testing

@MainActor
struct NavigationStackCoreTests {
    private enum Route: Hashable { case first, second }

    @Test func entryEqualityUsesInstanceIdentity() {
        let id = UUID()
        let a = NavigationEntry(id: id, route: Route.first)
        let b = NavigationEntry(id: id, route: Route.second)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func repeatedRoutesHaveDistinctIdentityAndPushReturnsIt() {
        let navigator = Navigator<Route>()
        let a = navigator.push(.first)
        let b = navigator.push(.first)
        #expect(a != b)
        #expect(navigator.entries.map(\.id) == [a, b])
        #expect(navigator.canPop)
        #expect(navigator.topEntry?.id == b)
    }
}
