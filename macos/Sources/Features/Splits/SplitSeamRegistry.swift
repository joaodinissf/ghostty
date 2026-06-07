import SwiftUI

/// Publishes the hit-regions of split "seams" (divider drag zones and, later,
/// junction-drag handles) out of the SwiftUI `SplitView` geometry so that
/// AppKit code can consult them.
///
/// ## Why this exists
///
/// The divider drag is a SwiftUI `DragGesture`. However, the very first
/// mouse-down on an *unfocused* pane is intercepted by an AppKit local event
/// monitor (`Ghostty.SurfaceView.localEventLeftMouseDown`) so that the click
/// only transfers split focus rather than being forwarded to the pty. That
/// interception swallows the event before SwiftUI's gesture recognizer ever
/// sees it, which means a divider bordering an unfocused pane can't be grabbed
/// on the first click.
///
/// The fix is for the event monitor to recognize when a swallowed click
/// actually landed on a divider/handle and let it through to SwiftUI instead.
/// To do that, the monitor needs to know *where* those hit-regions are. The
/// geometry only exists inside the `SplitView` `GeometryReader`, so this
/// registry is the conduit: the SwiftUI side registers regions (in window
/// coordinates) and the AppKit side queries them.
///
/// ## Coordinate space
///
/// Regions are stored in **SwiftUI global coordinates**: the origin is the
/// top-left of the window's content area and the y-axis points down. The
/// SwiftUI side obtains these directly from `GeometryProxy.frame(in: .global)`.
/// The AppKit side must convert its (bottom-left origin) window point into this
/// space before querying; see `contains(globalPoint:)`.
@MainActor
final class SplitSeamRegistry: ObservableObject {
    /// The kind of seam a region represents. Both kinds participate in the
    /// focus-transfer gate, but distinguishing them is useful for debugging
    /// overlays and tests.
    enum Kind: Equatable {
        case divider
        case junction
    }

    /// A single registered hit-region in SwiftUI global coordinates.
    struct Region: Identifiable, Equatable {
        /// Stable identity for the owning seam, so re-registrations from the
        /// same divider/handle replace rather than accumulate.
        let id: AnyHashable
        let kind: Kind
        let rect: CGRect
    }

    /// All currently-registered regions. `@Published` so a debug overlay can
    /// observe and draw them; AppKit reads it directly via `regions`.
    @Published private(set) var regions: [Region] = []

    /// Register (or update) the region for a seam identified by `id`. Passing a
    /// region with the same `id` replaces the previous one, keeping the
    /// registry in sync as layout and resize events move seams around.
    func register(id: AnyHashable, kind: Kind, rect: CGRect) {
        let region = Region(id: id, kind: kind, rect: rect)
        if let index = regions.firstIndex(where: { $0.id == id }) {
            // Avoid spurious objectWillChange churn if nothing actually moved.
            guard regions[index] != region else { return }
            regions[index] = region
        } else {
            regions.append(region)
        }
    }

    /// Remove the region for a seam, e.g. when its view leaves the hierarchy.
    func unregister(id: AnyHashable) {
        regions.removeAll { $0.id == id }
    }

    /// Returns the first region containing the given point, expressed in
    /// SwiftUI global coordinates (top-left origin, y-down).
    func region(atGlobalPoint point: CGPoint) -> Region? {
        // Iterate in reverse so the most-recently-registered (top-most, e.g. a
        // junction handle drawn over a divider) wins the hit test.
        regions.reversed().first { $0.rect.contains(point) }
    }

    /// Convenience: whether any seam covers the given SwiftUI global point.
    func contains(globalPoint point: CGPoint) -> Bool {
        region(atGlobalPoint: point) != nil
    }
}

// MARK: - Environment

private struct SplitSeamRegistryKey: EnvironmentKey {
    static let defaultValue: SplitSeamRegistry? = nil
}

extension EnvironmentValues {
    /// The per-window registry of split seam hit-regions, if any. Injected by
    /// the terminal view so descendant `SplitView`s can publish their regions.
    var splitSeamRegistry: SplitSeamRegistry? {
        get { self[SplitSeamRegistryKey.self] }
        set { self[SplitSeamRegistryKey.self] = newValue }
    }
}

extension View {
    /// Inject the per-window split seam registry into the environment.
    func splitSeamRegistry(_ registry: SplitSeamRegistry?) -> some View {
        environment(\.splitSeamRegistry, registry)
    }
}
