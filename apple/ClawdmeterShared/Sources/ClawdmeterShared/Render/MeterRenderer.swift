import SwiftUI

/// SwiftUI Canvas-based primitives kit (plan E6) for rendering Clawdmeter across
/// every Apple surface. Each surface composes its own layout from these primitives;
/// shared ring math + theme + AOD behavior lives here.
public enum MeterRenderer {}

// MARK: - Ring

public extension MeterRenderer {
    /// Circular gauge ring. Filled in normal mode; stroke-only in AOD.
    /// Used for: watch complication accessoryCircular, watch app wrist mode,
    /// iPhone Lock Screen accessoryCircular widget, Mac menu bar gauge, Dynamic Island.
    struct Ring: View {
        public let pct: Int                  // 0...100
        public let mood: UsageData.Mood
        public let stale: Bool
        public let strokeWidth: CGFloat
        public let trackOpacity: Double

        @Environment(\.isLuminanceReduced) private var isLuminanceReduced

        public init(
            pct: Int,
            mood: UsageData.Mood = .active,
            stale: Bool = false,
            strokeWidth: CGFloat = 8,
            trackOpacity: Double = 0.15
        ) {
            self.pct = max(0, min(100, pct))
            self.mood = mood
            self.stale = stale
            self.strokeWidth = strokeWidth
            self.trackOpacity = trackOpacity
        }

        public var body: some View {
            Canvas { context, size in
                let lineWidth = isLuminanceReduced ? max(1, strokeWidth * 0.6) : strokeWidth
                let radius = (min(size.width, size.height) - lineWidth) / 2
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                // Track
                let trackColor = stale
                    ? ClawdmeterTheme.Colors.tertiaryText
                    : ClawdmeterTheme.Colors.primaryText.opacity(trackOpacity)
                let trackPath = Path { path in
                    path.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                }
                context.stroke(trackPath, with: .color(trackColor), lineWidth: lineWidth)

                // Filled arc — start at 12 o'clock, clockwise.
                guard pct > 0 else { return }
                let progressEnd = -90.0 + (Double(pct) / 100.0) * 360.0
                let arcPath = Path { path in
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(progressEnd),
                        clockwise: false
                    )
                }
                let arcColor: Color = stale
                    ? ClawdmeterTheme.Colors.accentStale
                    : (isLuminanceReduced
                        ? ClawdmeterTheme.Colors.aod(ClawdmeterTheme.Colors.accent(for: mood))
                        : ClawdmeterTheme.Colors.accent(for: mood))
                context.stroke(arcPath, with: .color(arcColor), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            .accessibilityHidden(true) // Composed views provide labels.
        }
    }
}

// MARK: - Arc (partial — used for inner weekly ring)

public extension MeterRenderer {
    /// Secondary partial arc — useful as an inner weekly ring inside a session Ring.
    struct Arc: View {
        public let pct: Int
        public let strokeWidth: CGFloat
        public let color: Color

        @Environment(\.isLuminanceReduced) private var isLuminanceReduced

        public init(pct: Int, strokeWidth: CGFloat = 4, color: Color = ClawdmeterTheme.Colors.secondaryText) {
            self.pct = max(0, min(100, pct))
            self.strokeWidth = strokeWidth
            self.color = color
        }

        public var body: some View {
            Canvas { context, size in
                let lineWidth = isLuminanceReduced ? max(1, strokeWidth * 0.6) : strokeWidth
                let radius = (min(size.width, size.height) - lineWidth) / 2
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                guard pct > 0 else { return }
                let progressEnd = -90.0 + (Double(pct) / 100.0) * 360.0
                let arcPath = Path { path in
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(progressEnd),
                        clockwise: false
                    )
                }
                let effective = isLuminanceReduced ? color.opacity(0.5) : color
                context.stroke(arcPath, with: .color(effective), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: - BigNumeral

public extension MeterRenderer {
    /// Large session-percent numeral. Used in watch app, Mac popover, StandBy widget.
    /// Plan E6: outline-only in AOD per AOD style spec.
    struct BigNumeral: View {
        public let value: Int
        public let suffix: String
        public let fontSize: CGFloat

        @Environment(\.isLuminanceReduced) private var isLuminanceReduced

        public init(value: Int, suffix: String = "%", fontSize: CGFloat = 48) {
            self.value = value
            self.suffix = suffix
            self.fontSize = fontSize
        }

        public var body: some View {
            let display = isLuminanceReduced ? fontSize * 0.95 : fontSize
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(value)")
                    .font(ClawdmeterTheme.Typography.display(size: display, weight: isLuminanceReduced ? .medium : .bold))
                    .monospacedDigit()
                Text(suffix)
                    .font(ClawdmeterTheme.Typography.body(size: display * 0.45, weight: .medium))
                    .foregroundStyle(ClawdmeterTheme.Colors.secondaryText)
            }
            .foregroundStyle(isLuminanceReduced
                ? ClawdmeterTheme.Colors.primaryText.opacity(0.7)
                : ClawdmeterTheme.Colors.primaryText)
        }
    }
}

// MARK: - StaleBadge

public extension MeterRenderer {
    /// Visible indicator that the displayed data is older than 90 seconds.
    /// Plan: appears in every surface that renders `UsageData` when `isStale(...) == true`.
    struct StaleBadge: View {
        public let ageSeconds: TimeInterval

        @Environment(\.isLuminanceReduced) private var isLuminanceReduced

        public init(ageSeconds: TimeInterval) {
            self.ageSeconds = ageSeconds
        }

        public var body: some View {
            Label {
                Text(formattedAge)
                    .font(ClawdmeterTheme.Typography.mono(size: 10, weight: .medium))
            } icon: {
                Circle()
                    .fill(isLuminanceReduced
                        ? ClawdmeterTheme.Colors.tertiaryText
                        : ClawdmeterTheme.Colors.statusWarning)
                    .frame(width: 4, height: 4)
            }
            .foregroundStyle(ClawdmeterTheme.Colors.tertiaryText)
            .accessibilityLabel("Last update \(formattedAge) ago")
        }

        private var formattedAge: String {
            let mins = Int(ageSeconds / 60)
            if mins < 1 { return "<1m" }
            if mins < 60 { return "\(mins)m" }
            let hrs = mins / 60
            return "\(hrs)h"
        }
    }
}

// MARK: - AODStyle (shared modifier)

public extension MeterRenderer {
    /// Modifier that ensures a view respects the plan's AOD style spec: stroke-only
    /// fills, saturation at 50%, no animations. Apply at the root of any composed surface.
    struct AODStyleModifier: ViewModifier {
        @Environment(\.isLuminanceReduced) private var isLuminanceReduced
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        public func body(content: Content) -> some View {
            content
                .saturation(isLuminanceReduced ? 0.6 : 1.0)
                .opacity(isLuminanceReduced ? 0.85 : 1.0)
                .animation(reduceMotion || isLuminanceReduced ? nil : .easeOut, value: isLuminanceReduced)
        }
    }
}

public extension View {
    /// Apply Clawdmeter's AOD-aware styling envelope.
    func clawdmeterAODStyle() -> some View {
        modifier(MeterRenderer.AODStyleModifier())
    }
}
