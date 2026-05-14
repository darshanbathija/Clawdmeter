import SwiftUI

/// The Anthropic "Claude" radial-burst mark, drawn as a vector shape.
///
/// 8 tapered petals radiating from center, with two rotated quartets to give
/// the burst its characteristic dense-but-airy feel. Scales cleanly from 12pt
/// menu-bar size up to a full app logo.
public struct ClaudeBurstShape: Shape {
    /// Ratio of petal length to half-width of the frame. 1.0 = fills.
    public var petalLengthRatio: CGFloat
    /// Ratio of petal base half-width to petal length.
    public var petalWidthRatio: CGFloat

    public init(petalLengthRatio: CGFloat = 0.95, petalWidthRatio: CGFloat = 0.18) {
        self.petalLengthRatio = petalLengthRatio
        self.petalWidthRatio = petalWidthRatio
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let petalLength = radius * petalLengthRatio
        let petalHalfWidth = petalLength * petalWidthRatio

        // 8 petals at 45° intervals — pointy at the tip, narrow at the base.
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4
            let cos_ = cos(angle)
            let sin_ = sin(angle)

            // Tip of the petal (outward along axis).
            let tip = CGPoint(
                x: center.x + cos_ * petalLength,
                y: center.y + sin_ * petalLength
            )
            // Base corners (perpendicular to axis at center).
            let perpCos = -sin_
            let perpSin = cos_
            let baseLeft = CGPoint(
                x: center.x + perpCos * petalHalfWidth,
                y: center.y + perpSin * petalHalfWidth
            )
            let baseRight = CGPoint(
                x: center.x - perpCos * petalHalfWidth,
                y: center.y - perpSin * petalHalfWidth
            )
            // Outer-edge mid-point for a slight curve (gives the petals their tapered, organic feel).
            let midLeft = CGPoint(
                x: center.x + cos_ * petalLength * 0.55 + perpCos * petalHalfWidth * 0.45,
                y: center.y + sin_ * petalLength * 0.55 + perpSin * petalHalfWidth * 0.45
            )
            let midRight = CGPoint(
                x: center.x + cos_ * petalLength * 0.55 - perpCos * petalHalfWidth * 0.45,
                y: center.y + sin_ * petalLength * 0.55 - perpSin * petalHalfWidth * 0.45
            )

            path.move(to: baseLeft)
            path.addQuadCurve(to: tip, control: midLeft)
            path.addQuadCurve(to: baseRight, control: midRight)
            path.closeSubpath()
        }
        return path
    }
}

/// Pre-tinted ClaudeBurstShape view. Use this for the menu bar icon and popover header.
public struct ClaudeBurst: View {
    public let color: Color
    public let stale: Bool

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    public init(color: Color = ClawdmeterTheme.Colors.accent, stale: Bool = false) {
        self.color = color
        self.stale = stale
    }

    public var body: some View {
        ClaudeBurstShape()
            .fill(effectiveColor)
            .accessibilityHidden(true)
    }

    private var effectiveColor: Color {
        if stale { return ClawdmeterTheme.Colors.accentStale }
        if isLuminanceReduced { return ClawdmeterTheme.Colors.aod(color) }
        return color
    }
}
