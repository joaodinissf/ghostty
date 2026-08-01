import XCTest
@testable import Ghostty

@MainActor
final class SplitSeamRegistryTests: XCTestCase {
    func testContainsPointInRegisteredRegion() {
        let registry = SplitSeamRegistry()
        registry.register(id: "d1", rect: CGRect(x: 10, y: 20, width: 8, height: 100))

        XCTAssertTrue(registry.contains(globalPoint: CGPoint(x: 12, y: 50)))
        XCTAssertFalse(registry.contains(globalPoint: CGPoint(x: 0, y: 0)))
    }

    func testRegisterReplacesSameId() {
        let registry = SplitSeamRegistry()
        registry.register(id: "d1", rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        registry.register(id: "d1", rect: CGRect(x: 50, y: 50, width: 10, height: 10))

        XCTAssertEqual(registry.regions.count, 1)
        XCTAssertTrue(registry.contains(globalPoint: CGPoint(x: 55, y: 55)))
        XCTAssertFalse(registry.contains(globalPoint: CGPoint(x: 5, y: 5)))
    }

    func testUnregisterRemovesRegion() {
        let registry = SplitSeamRegistry()
        registry.register(id: "d1", rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        registry.unregister(id: "d1")

        XCTAssertTrue(registry.regions.isEmpty)
        XCTAssertFalse(registry.contains(globalPoint: CGPoint(x: 10, y: 10)))
    }
}
