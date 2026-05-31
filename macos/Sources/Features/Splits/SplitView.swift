import SwiftUI

/// A split view shows a left and right (or top and bottom) view with a divider in the middle to do resizing.
/// The terminlogy "left" and "right" is always used but for vertical splits "left" is "top" and "right" is "bottom".
///
/// This view is purpose built for our use case and I imagine we'll continue to make it more configurable
/// as time goes on. For example, the splitter divider size and styling is all hardcoded.
struct SplitView<L: View, R: View>: View {
    /// Direction of the split
    let direction: SplitViewDirection

    /// Divider color
    let dividerColor: Color

    /// Minimum increment (in points) that this split can be resized by, in
    /// each direction. Both `height` and `width` should be whole numbers
    /// greater than or equal to 1.0
    let resizeIncrements: NSSize

    /// The left and right views to render.
    let left: L
    let right: R

    /// Called when the divider is double-tapped to equalize splits.
    let onEqualize: () -> Void

    /// Stable identity for this split's divider seam, used to publish its
    /// hit-region to the ``SplitSeamRegistry``. Nil disables registration.
    let seamID: AnyHashable?

    /// The minimum size (in points) of a split
    let minSize: CGFloat = 10

    /// Registry that the divider publishes its window-space hit-region into so
    /// the AppKit event monitor can let seam clicks through the focus gate.
    @Environment(\.splitSeamRegistry) private var seamRegistry

    /// The current fractional width of the split view. 0.5 means L/R are equally sized, for example.
    @Binding var split: CGFloat

    /// The visible size of the splitter, in points. The invisible size is a transparent hitbox that can still
    /// be used for getting a resize handle. The total width/height of the splitter is the sum of both.
    private let splitterVisibleSize: CGFloat = 1
    private let splitterInvisibleSize: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let leftRect = self.leftRect(for: geo.size)
            let rightRect = self.rightRect(for: geo.size, leftRect: leftRect)
            let splitterPoint = self.splitterPoint(for: geo.size, leftRect: leftRect)

            ZStack(alignment: .topLeading) {
                left
                    .frame(width: leftRect.size.width, height: leftRect.size.height)
                    .offset(x: leftRect.origin.x, y: leftRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(leftPaneLabel)
                right
                    .frame(width: rightRect.size.width, height: rightRect.size.height)
                    .offset(x: rightRect.origin.x, y: rightRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(rightPaneLabel)
                Divider(direction: direction,
                        visibleSize: splitterVisibleSize,
                        invisibleSize: splitterInvisibleSize,
                        color: dividerColor,
                        split: $split)
                    .position(splitterPoint)
                    .gesture(dragGesture(geo.size, splitterPoint: splitterPoint))
                    .onTapGesture(count: 2) {
                        onEqualize()
                    }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(splitViewLabel)
            // Publish the divider hit-region (in window/global coordinates) so
            // the AppKit surface event monitor can let seam clicks through the
            // focus-transfer gate. Re-runs whenever layout or origin changes.
            .onChange(of: dividerRegistration(in: geo)) { registration in
                updateSeamRegistration(registration)
            }
            .onAppear {
                updateSeamRegistration(dividerRegistration(in: geo))
            }
            .onDisappear {
                if let seamID { seamRegistry?.unregister(id: seamID) }
            }
        }
    }

    /// The divider's hit-region as `(id, globalRect)`, or nil when there's no
    /// `seamID` or no registry to publish into. Computed in SwiftUI global
    /// coordinates (top-left origin) by offsetting the local splitter geometry
    /// by the view's global origin.
    private func dividerRegistration(in geo: GeometryProxy) -> SeamRegistration? {
        guard let seamID else { return nil }
        let globalOrigin = geo.frame(in: .global).origin
        let splitterPoint = self.splitterPoint(for: geo.size, leftRect: leftRect(for: geo.size))
        let hitThickness = splitterVisibleSize + splitterInvisibleSize
        let localRect: CGRect = switch direction {
        case .horizontal:
            CGRect(x: splitterPoint.x - hitThickness / 2, y: 0,
                   width: hitThickness, height: geo.size.height)
        case .vertical:
            CGRect(x: 0, y: splitterPoint.y - hitThickness / 2,
                   width: geo.size.width, height: hitThickness)
        }
        let globalRect = localRect.offsetBy(dx: globalOrigin.x, dy: globalOrigin.y)
        return SeamRegistration(id: seamID, rect: globalRect)
    }

    private func updateSeamRegistration(_ registration: SeamRegistration?) {
        guard let seamRegistry else { return }
        guard let registration else {
            if let seamID { seamRegistry.unregister(id: seamID) }
            return
        }
        seamRegistry.register(id: registration.id, kind: .divider, rect: registration.rect)
    }

    /// A computed divider registration, made `Equatable` so `onChange` only
    /// fires when the published region actually moves.
    private struct SeamRegistration: Equatable {
        let id: AnyHashable
        let rect: CGRect
    }

    /// Initialize a split view that can be resized by manually dragging the divider.
    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        seamID: AnyHashable? = nil,
        @ViewBuilder left: (() -> L),
        @ViewBuilder right: (() -> R),
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.resizeIncrements = resizeIncrements
        self.seamID = seamID
        self.left = left()
        self.right = right()
        self.onEqualize = onEqualize
    }

    private func dragGesture(_ size: CGSize, splitterPoint: CGPoint) -> some Gesture {
        return DragGesture()
            .onChanged { gesture in
                switch direction {
                case .horizontal:
                    let new = min(max(minSize, gesture.location.x), size.width - minSize)
                    split = new / size.width

                case .vertical:
                    let new = min(max(minSize, gesture.location.y), size.height - minSize)
                    split = new / size.height
                }
            }
    }

    /// Calculates the bounding rect for the left view.
    private func leftRect(for size: CGSize) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            result.size.width *= split
            result.size.width -= splitterVisibleSize / 2
            result.size.width -= result.size.width.truncatingRemainder(dividingBy: self.resizeIncrements.width)

        case .vertical:
            result.size.height *= split
            result.size.height -= splitterVisibleSize / 2
            result.size.height -= result.size.height.truncatingRemainder(dividingBy: self.resizeIncrements.height)
        }

        return result
    }

    /// Calculates the bounding rect for the right view.
    private func rightRect(for size: CGSize, leftRect: CGRect) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            // For horizontal layouts we offset the starting X by the left rect
            // and make the width fit the remaining space.
            result.origin.x += leftRect.size.width
            result.origin.x += splitterVisibleSize / 2
            result.size.width -= result.origin.x

        case .vertical:
            result.origin.y += leftRect.size.height
            result.origin.y += splitterVisibleSize / 2
            result.size.height -= result.origin.y
        }

        return result
    }

    /// Calculates the point at which the splitter should be rendered.
    private func splitterPoint(for size: CGSize, leftRect: CGRect) -> CGPoint {
        switch direction {
        case .horizontal:
            return CGPoint(x: leftRect.size.width, y: size.height / 2)

        case .vertical:
            return CGPoint(x: size.width / 2, y: leftRect.size.height)
        }
    }

    // MARK: Accessibility

    private var splitViewLabel: String {
        switch direction {
        case .horizontal:
            return "Horizontal split view"
        case .vertical:
            return "Vertical split view"
        }
    }

    private var leftPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Left pane"
        case .vertical:
            return "Top pane"
        }
    }

    private var rightPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Right pane"
        case .vertical:
            return "Bottom pane"
        }
    }
}

enum SplitViewDirection: Codable {
    case horizontal, vertical
}
