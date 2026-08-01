import SwiftUI

/// Per-window hit-regions for split dividers (SwiftUI global / top-left coords).
///
/// `SurfaceView`'s AppKit mouse-down monitor swallows clicks on unfocused panes
/// so they only transfer focus. That also blocks SwiftUI's divider `DragGesture`
/// on the first press. The monitor consults this registry and lets seam clicks
/// through without changing focus-transfer for normal pane clicks.
@MainActor
final class SplitSeamRegistry: ObservableObject {
    struct Region: Identifiable, Equatable {
        let id: AnyHashable
        let rect: CGRect
    }

    @Published private(set) var regions: [Region] = []

    func register(id: AnyHashable, rect: CGRect) {
        let region = Region(id: id, rect: rect)
        if let i = regions.firstIndex(where: { $0.id == id }) {
            guard regions[i] != region else { return }
            regions[i] = region
        } else {
            regions.append(region)
        }
    }

    func unregister(id: AnyHashable) {
        regions.removeAll { $0.id == id }
    }

    func contains(globalPoint point: CGPoint) -> Bool {
        regions.contains { $0.rect.contains(point) }
    }
}

// MARK: - Environment

private struct SplitSeamRegistryKey: EnvironmentKey {
    static let defaultValue: SplitSeamRegistry? = nil
}

extension EnvironmentValues {
    var splitSeamRegistry: SplitSeamRegistry? {
        get { self[SplitSeamRegistryKey.self] }
        set { self[SplitSeamRegistryKey.self] = newValue }
    }
}

extension View {
    func splitSeamRegistry(_ registry: SplitSeamRegistry?) -> some View {
        environment(\.splitSeamRegistry, registry)
    }
}
