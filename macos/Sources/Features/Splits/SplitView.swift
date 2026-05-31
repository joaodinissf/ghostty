import SwiftUI

/// Configures the optional junction-drag overlay on a `SplitView`. A junction
/// appears when at least one of the split's children is itself a split of the
/// perpendicular orientation, so an inner divider terminates against the outer
/// divider, forming a `T` (3 panes) or — when both children are perpendicular
/// and their inner ratios align — a `+` (4 panes).
///
/// - `leftInnerRatio` is the inner perpendicular split ratio on the left/top
///   child, or nil if that child isn't a perpendicular split.
/// - `rightInnerRatio` is the same for the right/bottom child.
///
/// `onJunctionDrag` is invoked once per drag tick with the new outer ratio and
/// the new inner ratios (nil for a side that should not move), so the embedder
/// can apply a single combined tree edit rather than several independent ones.
struct SplitJunctionConfig {
    let leftInnerRatio: CGFloat?
    let rightInnerRatio: CGFloat?
    let onJunctionDrag: (_ outerRatio: CGFloat, _ leftInner: CGFloat?, _ rightInner: CGFloat?) -> Void
}

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

    /// Optional junction overlay describing perpendicular inner splits. When
    /// present, one or two junction-drag handles are rendered at the ends of
    /// the outer divider.
    let junction: SplitJunctionConfig?

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

    /// Side length (in points) of the invisible square hit zone placed where
    /// two perpendicular dividers meet. Sized slightly larger than the regular
    /// divider hit zone so it wins the top-most hit test inside the small
    /// corner area while leaving the rest of the divider untouched.
    private let junctionHitSize: CGFloat = 12

    /// Maximum difference between the two inner ratios of a `+` junction for
    /// them to be treated as aligned and dragged in lockstep, rather than as
    /// two independent stacked `T` junctions.
    private let junctionAlignmentEpsilon: CGFloat = 0.005

    var body: some View {
        GeometryReader { geo in
            let leftRect = self.leftRect(for: geo.size)
            let rightRect = self.rightRect(for: geo.size, leftRect: leftRect)
            let splitterPoint = self.splitterPoint(for: geo.size, leftRect: leftRect)
            let handles = self.junctionHandles(for: geo.size)

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
                ForEach(handles) { handle in
                    JunctionHandleView(
                        handle: handle,
                        size: geo.size,
                        direction: direction,
                        hitSize: junctionHitSize,
                        minSize: minSize,
                        alignmentEpsilon: junctionAlignmentEpsilon,
                        onJunctionDrag: junction?.onJunctionDrag ?? { _, _, _ in })
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(splitViewLabel)
            // Publish the divider + junction handle hit-regions (in
            // window/global coordinates) so the AppKit surface event monitor
            // can let seam clicks through the focus-transfer gate. Re-runs
            // whenever layout, origin or junction geometry changes.
            .onChange(of: seamRegistrations(in: geo, handles: handles)) { registrations in
                updateSeamRegistrations(registrations)
            }
            .onAppear {
                updateSeamRegistrations(seamRegistrations(in: geo, handles: handles))
            }
            .onDisappear {
                guard let seamRegistry, let seamID else { return }
                seamRegistry.unregister(id: seamID)
                for handle in handles {
                    seamRegistry.unregister(id: handle.seamID(parent: seamID))
                }
            }
        }
    }

    /// The divider + junction handle hit-regions for this split, in SwiftUI
    /// global coordinates (top-left origin). Empty when there's no `seamID` or
    /// no registry to publish into. Made `Equatable` (via `SeamRegistration`)
    /// so `onChange` only fires when a published region actually moves.
    private func seamRegistrations(
        in geo: GeometryProxy,
        handles: [SplitJunctionHandleProxy]
    ) -> [SeamRegistration] {
        guard let seamID else { return [] }
        let globalOrigin = geo.frame(in: .global).origin
        let splitterPoint = self.splitterPoint(for: geo.size, leftRect: leftRect(for: geo.size))

        // The divider hit-region spans the full length of the splitter.
        let hitThickness = splitterVisibleSize + splitterInvisibleSize
        let dividerLocalRect: CGRect = switch direction {
        case .horizontal:
            CGRect(x: splitterPoint.x - hitThickness / 2, y: 0,
                   width: hitThickness, height: geo.size.height)
        case .vertical:
            CGRect(x: 0, y: splitterPoint.y - hitThickness / 2,
                   width: geo.size.width, height: hitThickness)
        }

        var result: [SeamRegistration] = [
            SeamRegistration(
                id: seamID,
                kind: .divider,
                rect: dividerLocalRect.offsetBy(dx: globalOrigin.x, dy: globalOrigin.y)),
        ]

        // Each junction handle is a small square centered on its point.
        for handle in handles {
            let local = CGRect(
                x: handle.point.x - junctionHitSize / 2,
                y: handle.point.y - junctionHitSize / 2,
                width: junctionHitSize,
                height: junctionHitSize)
            result.append(SeamRegistration(
                id: handle.seamID(parent: seamID),
                kind: .junction,
                rect: local.offsetBy(dx: globalOrigin.x, dy: globalOrigin.y)))
        }

        return result
    }

    private func updateSeamRegistrations(_ registrations: [SeamRegistration]) {
        guard let seamRegistry else { return }
        for registration in registrations {
            seamRegistry.register(
                id: registration.id, kind: registration.kind, rect: registration.rect)
        }
    }

    /// A computed seam registration, made `Equatable` so `onChange` only fires
    /// when the published region actually moves.
    private struct SeamRegistration: Equatable {
        let id: AnyHashable
        let kind: SplitSeamRegistry.Kind
        let rect: CGRect
    }

    // MARK: Junction Handles

    /// Build zero, one or two junction handles from the `junction` config. In
    /// the both-children-perpendicular case we always return *two* handles
    /// (never collapsing to a single `+`) so SwiftUI's view identity stays
    /// stable across drags — otherwise the handle the user is holding can
    /// vanish mid-gesture when the two ratios pass through equality.
    private func junctionHandles(for size: CGSize) -> [SplitJunctionHandleProxy] {
        guard let junction else { return [] }
        var result: [SplitJunctionHandleProxy] = []
        if let left = junction.leftInnerRatio {
            result.append(makeJunctionHandle(
                in: size, side: .left,
                myRatio: left, companionRatio: junction.rightInnerRatio))
        }
        if let right = junction.rightInnerRatio {
            result.append(makeJunctionHandle(
                in: size, side: .right,
                myRatio: right, companionRatio: junction.leftInnerRatio))
        }
        return result
    }

    private func makeJunctionHandle(
        in size: CGSize,
        side: SplitJunctionHandleProxy.Side,
        myRatio: CGFloat,
        companionRatio: CGFloat?
    ) -> SplitJunctionHandleProxy {
        let point: CGPoint = switch direction {
        case .horizontal: CGPoint(x: split * size.width, y: myRatio * size.height)
        case .vertical:   CGPoint(x: myRatio * size.width, y: split * size.height)
        }
        return SplitJunctionHandleProxy(
            side: side,
            point: point,
            outerRatio: split,
            myRatio: myRatio,
            companionRatio: companionRatio)
    }

    /// Initialize a split view that can be resized by manually dragging the divider.
    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        seamID: AnyHashable? = nil,
        junction: SplitJunctionConfig? = nil,
        @ViewBuilder left: (() -> L),
        @ViewBuilder right: (() -> R),
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.resizeIncrements = resizeIncrements
        self.seamID = seamID
        self.junction = junction
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

/// A single invisible junction-drag handle, extracted as its own View so it
/// can carry `@State` for latching the lockstep decision at drag-begin. The
/// latch prevents an in-flight drag from "joining the ride" with the other
/// inner split if the two inner ratios happen to cross during the gesture: if
/// at drag-begin they were apart, lockstep stays off for the rest of the drag;
/// if they were aligned (the visual `+`), lockstep stays on and both inners
/// track together.
private struct JunctionHandleView: View {
    let handle: SplitJunctionHandleProxy
    let size: CGSize
    let direction: SplitViewDirection
    let hitSize: CGFloat
    let minSize: CGFloat
    let alignmentEpsilon: CGFloat
    let onJunctionDrag: (_ outerRatio: CGFloat, _ leftInner: CGFloat?, _ rightInner: CGFloat?) -> Void

    /// Lockstep decision for the active drag. `nil` while idle; set on the
    /// first `.onChanged` of a drag and held for the rest of that gesture.
    @State private var lockstepLatched: Bool?

    var body: some View {
        Color.clear
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .position(handle.point)
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        // Latch lockstep on the first event of this gesture.
                        if lockstepLatched == nil {
                            if let companion = handle.companionRatio {
                                lockstepLatched = abs(handle.myRatio - companion) < alignmentEpsilon
                            } else {
                                lockstepLatched = false
                            }
                        }
                        let lockstep = lockstepLatched ?? false

                        let x = min(max(minSize, gesture.location.x), size.width - minSize)
                        let y = min(max(minSize, gesture.location.y), size.height - minSize)

                        // Along the outer split's axis the gesture moves the
                        // outer divider; perpendicular to it, the inner divider.
                        let (outerRatio, inner): (CGFloat, CGFloat) = switch direction {
                        case .horizontal: (x / size.width, y / size.height)
                        case .vertical:   (y / size.height, x / size.width)
                        }

                        let leftInner: CGFloat?
                        let rightInner: CGFloat?
                        switch handle.side {
                        case .left:
                            leftInner = inner
                            rightInner = lockstep ? inner : nil
                        case .right:
                            leftInner = lockstep ? inner : nil
                            rightInner = inner
                        }
                        onJunctionDrag(outerRatio, leftInner, rightInner)
                    }
                    .onEnded { _ in
                        lockstepLatched = nil
                    }
            )
            .backport.pointerStyle(.crosshair)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(axLabel)
            .accessibilityValue(axValue)
            .accessibilityHint(axHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { adjustment in
                // Mirror the divider's adjustable action: nudge the outer
                // ratio (and the inner ratio when aligned) by a small step.
                let step: CGFloat = 0.025
                let delta: CGFloat = switch adjustment {
                case .increment: step
                case .decrement: -step
                @unknown default: 0
                }
                guard delta != 0 else { return }
                let lockstep = handle.companionRatio.map {
                    abs(handle.myRatio - $0) < alignmentEpsilon
                } ?? false
                let newInner = min(max(0.1, handle.myRatio + delta), 0.9)
                switch handle.side {
                case .left:
                    onJunctionDrag(handle.outerRatio, newInner, lockstep ? newInner : nil)
                case .right:
                    onJunctionDrag(handle.outerRatio, lockstep ? newInner : nil, newInner)
                }
            }
    }

    private var axLabel: String {
        switch direction {
        case .horizontal: return "Horizontal split junction"
        case .vertical: return "Vertical split junction"
        }
    }

    private var axValue: String {
        "\(Int(handle.outerRatio * 100))%"
    }

    private var axHint: String {
        "Drag to resize the panes that meet at this junction"
    }
}

/// A plain-value description of a junction handle passed to
/// ``JunctionHandleView``, decoupled from `SplitView`'s generic parameters.
struct SplitJunctionHandleProxy: Identifiable {
    enum Side: Hashable { case left, right }

    /// Which child of the outer split this handle's inner divider belongs to.
    let side: Side
    /// Position of the handle in the outer split's local coordinate space.
    let point: CGPoint
    /// The current outer split ratio.
    let outerRatio: CGFloat
    /// The inner ratio of this handle's own inner split.
    let myRatio: CGFloat
    /// The other inner split's ratio, or nil if there's only one perpendicular
    /// inner split.
    let companionRatio: CGFloat?

    var id: Side { side }

    /// A stable registry id derived from the parent split's seam id, so the
    /// handle's hit-region replaces rather than accumulates across re-layouts.
    func seamID(parent: AnyHashable) -> AnyHashable {
        AnyHashable([AnyHashable("junction"), parent, AnyHashable(side)])
    }
}

enum SplitViewDirection: Codable {
    case horizontal, vertical
}
