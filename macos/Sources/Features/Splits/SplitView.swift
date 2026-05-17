import SwiftUI

/// Configures the optional junction-drag overlay on a `SplitView`. A junction
/// appears when at least one of the split's children is itself a split of the
/// perpendicular orientation, so the inner divider terminates against the
/// outer divider.
///
/// - `left` describes the inner perpendicular split on the left/top child.
/// - `right` describes the inner perpendicular split on the right/bottom child.
///
/// When both are set and the two inner ratios are within `plusEpsilon` of
/// each other, the overlay renders a single 4-way `+` handle that updates
/// the outer ratio and both inner ratios in lockstep. When they differ it
/// renders two independent T handles, one at each end of the outer divider.
struct SplitJunctionConfig {
    struct Inner {
        let ratio: CGFloat
        let onRatioChanged: (CGFloat) -> Void
    }

    let left: Inner?
    let right: Inner?
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

    /// Optional junction overlay describing perpendicular inner splits.
    let junction: SplitJunctionConfig?

    /// The minimum size (in points) of a split
    let minSize: CGFloat = 10

    /// The current fractional width of the split view. 0.5 means L/R are equally sized, for example.
    @Binding var split: CGFloat

    /// The visible size of the splitter, in points. The invisible size is a transparent hitbox that can still
    /// be used for getting a resize handle. The total width/height of the splitter is the sum of both.
    private let splitterVisibleSize: CGFloat = 1
    private let splitterInvisibleSize: CGFloat = 6

    /// Side length of the invisible square hit zone placed where two
    /// perpendicular dividers meet. Sized slightly larger than the regular
    /// divider hit zone so it wins the top-most hit test inside the small
    /// corner area while leaving the rest of the divider untouched.
    private let junctionHitSize: CGFloat = 12

    /// Maximum difference between two inner ratios for them to count as a
    /// single 4-way `+` junction instead of two stacked T-junctions.
    private let plusEpsilon: CGFloat = 0.005

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
                ForEach(0..<handles.count, id: \.self) { i in
                    let handle = handles[i]
                    JunctionHandleView(
                        point: handle.point,
                        size: geo.size,
                        direction: direction,
                        hitSize: junctionHitSize,
                        minSize: minSize,
                        plusEpsilon: plusEpsilon,
                        myRatio: handle.myRatio,
                        companionRatio: handle.companionRatio,
                        primaryCallback: handle.primaryCallback,
                        companionCallback: handle.companionCallback,
                        outerSplit: $split
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(splitViewLabel)
        }
    }

    /// Initialize a split view that can be resized by manually dragging the divider.
    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        junction: SplitJunctionConfig? = nil,
        @ViewBuilder left: (() -> L),
        @ViewBuilder right: (() -> R),
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.resizeIncrements = resizeIncrements
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

    /// A single junction handle. `myRatio` is the inner ratio this handle's
    /// inner split currently sits at; `companionRatio` is the *other* inner
    /// split's current ratio (nil when there's only one perpendicular inner).
    /// Both are used at drag-begin to decide whether to engage lockstep for
    /// the duration of this gesture (when the two inner ratios are within
    /// `plusEpsilon`, the two perpendicular dividers form a visual `+` and
    /// the user expects dragging the `+` to move both inners together).
    ///
    /// When both children of the outer split are perpendicular splits we
    /// always render two handles (never collapsing them into a single `+`)
    /// so that SwiftUI's view-identity stays stable across drags — otherwise
    /// the handle the user is currently holding can vanish mid-gesture when
    /// the two ratios pass through equality, breaking the drag.
    private struct JunctionHandle {
        let point: CGPoint
        let myRatio: CGFloat
        let companionRatio: CGFloat?
        let primaryCallback: (CGFloat) -> Void
        let companionCallback: ((CGFloat) -> Void)?
    }

    /// Build zero, one or two junction handles from the `junction` config.
    /// In the both-children-perpendicular case we always return *two* handles
    /// (never collapsing to one `+`) for the view-identity reason described
    /// on `JunctionHandle`.
    private func junctionHandles(for size: CGSize) -> [JunctionHandle] {
        guard let junction else { return [] }
        switch (junction.left, junction.right) {
        case (nil, nil):
            return []
        case (let l?, nil):
            return [makeJunctionHandle(
                in: size,
                innerRatio: l.ratio,
                primary: l.onRatioChanged,
                companion: nil,
                companionRatio: nil
            )]
        case (nil, let r?):
            return [makeJunctionHandle(
                in: size,
                innerRatio: r.ratio,
                primary: r.onRatioChanged,
                companion: nil,
                companionRatio: nil
            )]
        case (let l?, let r?):
            return [
                makeJunctionHandle(
                    in: size,
                    innerRatio: l.ratio,
                    primary: l.onRatioChanged,
                    companion: r.onRatioChanged,
                    companionRatio: r.ratio
                ),
                makeJunctionHandle(
                    in: size,
                    innerRatio: r.ratio,
                    primary: r.onRatioChanged,
                    companion: l.onRatioChanged,
                    companionRatio: l.ratio
                ),
            ]
        }
    }

    private func makeJunctionHandle(
        in size: CGSize,
        innerRatio: CGFloat,
        primary: @escaping (CGFloat) -> Void,
        companion: ((CGFloat) -> Void)?,
        companionRatio: CGFloat?
    ) -> JunctionHandle {
        let point: CGPoint = switch direction {
        case .horizontal: CGPoint(x: split * size.width, y: innerRatio * size.height)
        case .vertical:   CGPoint(x: innerRatio * size.width, y: split * size.height)
        }
        return JunctionHandle(
            point: point,
            myRatio: innerRatio,
            companionRatio: companionRatio,
            primaryCallback: primary,
            companionCallback: companion
        )
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
/// latch is what prevents an in-flight drag from "joining the ride" with
/// the other inner split if the two inner ratios happen to cross during
/// the gesture: if at drag-begin they were apart, lockstep stays off for
/// the rest of the drag; if they were aligned (the visual `+`), lockstep
/// stays on and both inners track together.
private struct JunctionHandleView: View {
    let point: CGPoint
    let size: CGSize
    let direction: SplitViewDirection
    let hitSize: CGFloat
    let minSize: CGFloat
    let plusEpsilon: CGFloat
    let myRatio: CGFloat
    let companionRatio: CGFloat?
    let primaryCallback: (CGFloat) -> Void
    let companionCallback: ((CGFloat) -> Void)?
    @Binding var outerSplit: CGFloat

    /// Lockstep decision for the active drag. `nil` while idle; set on the
    /// first `.onChanged` of a drag and held for the rest of that gesture.
    @State private var lockstepLatched: Bool? = nil

    var body: some View {
        Color.clear
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        // Latch lockstep on the first event of this gesture.
                        if lockstepLatched == nil {
                            if let companion = companionRatio {
                                lockstepLatched = abs(myRatio - companion) < plusEpsilon
                            } else {
                                lockstepLatched = false
                            }
                        }
                        let lockstep = lockstepLatched ?? false

                        let x = min(max(minSize, gesture.location.x), size.width - minSize)
                        let y = min(max(minSize, gesture.location.y), size.height - minSize)
                        switch direction {
                        case .horizontal:
                            outerSplit = x / size.width
                            let inner = y / size.height
                            primaryCallback(inner)
                            if lockstep, let companionCallback {
                                companionCallback(inner)
                            }
                        case .vertical:
                            outerSplit = y / size.height
                            let inner = x / size.width
                            primaryCallback(inner)
                            if lockstep, let companionCallback {
                                companionCallback(inner)
                            }
                        }
                    }
                    .onEnded { _ in
                        lockstepLatched = nil
                    }
            )
            .backport.pointerStyle(.crosshair)
            .accessibilityHidden(true)
    }
}

enum SplitViewDirection: Codable {
    case horizontal, vertical
}
