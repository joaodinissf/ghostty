import Testing
import Foundation
@testable import Ghostty

@MainActor
struct SplitSeamRegistryTests {
    @Test func emptyRegistryHasNoRegions() {
        let registry = SplitSeamRegistry()
        #expect(registry.regions.isEmpty)
        #expect(!registry.contains(globalPoint: CGPoint(x: 5, y: 5)))
        #expect(registry.region(atGlobalPoint: CGPoint(x: 5, y: 5)) == nil)
    }

    @Test func registerAndLookup() {
        let registry = SplitSeamRegistry()
        let rect = CGRect(x: 10, y: 0, width: 8, height: 100)
        registry.register(id: "a", kind: .divider, rect: rect)

        // Inside the rect.
        #expect(registry.contains(globalPoint: CGPoint(x: 14, y: 50)))
        #expect(registry.region(atGlobalPoint: CGPoint(x: 14, y: 50))?.kind == .divider)

        // Outside the rect.
        #expect(!registry.contains(globalPoint: CGPoint(x: 30, y: 50)))
    }

    @Test func registerReplacesSameID() {
        let registry = SplitSeamRegistry()
        registry.register(id: "a", kind: .divider, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        registry.register(id: "a", kind: .divider, rect: CGRect(x: 100, y: 100, width: 10, height: 10))

        #expect(registry.regions.count == 1)
        #expect(!registry.contains(globalPoint: CGPoint(x: 5, y: 5)))
        #expect(registry.contains(globalPoint: CGPoint(x: 105, y: 105)))
    }

    @Test func unregisterRemovesRegion() {
        let registry = SplitSeamRegistry()
        registry.register(id: "a", kind: .divider, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        registry.unregister(id: "a")
        #expect(registry.regions.isEmpty)
    }

    @Test func topMostRegistrationWinsOverlap() {
        let registry = SplitSeamRegistry()
        // A divider that spans an area, then a junction handle drawn on top of
        // it in the overlapping corner. The later (junction) registration must
        // win the hit test.
        registry.register(id: "divider", kind: .divider, rect: CGRect(x: 0, y: 0, width: 100, height: 8))
        registry.register(id: "junction", kind: .junction, rect: CGRect(x: 40, y: 0, width: 12, height: 12))

        #expect(registry.region(atGlobalPoint: CGPoint(x: 46, y: 4))?.kind == .junction)
        // Outside the junction but on the divider stays the divider.
        #expect(registry.region(atGlobalPoint: CGPoint(x: 10, y: 4))?.kind == .divider)
    }
}
