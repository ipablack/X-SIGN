import SwiftUI

/// Per-corner rounding for iOS 15; newer systems keep the native continuous shape.
public struct NBUnevenRoundedRectangle: Shape {
    public var topLeadingRadius: CGFloat
    public var bottomLeadingRadius: CGFloat
    public var bottomTrailingRadius: CGFloat
    public var topTrailingRadius: CGFloat
    public var style: RoundedCornerStyle

    public init(
        topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0,
        bottomTrailingRadius: CGFloat = 0, topTrailingRadius: CGFloat = 0,
        style: RoundedCornerStyle = .continuous
    ) {
        self.topLeadingRadius = topLeadingRadius
        self.bottomLeadingRadius = bottomLeadingRadius
        self.bottomTrailingRadius = bottomTrailingRadius
        self.topTrailingRadius = topTrailingRadius
        self.style = style
    }

    public func path(in rect: CGRect) -> Path {
        if #available(iOS 17.0, *) {
            return UnevenRoundedRectangle(
                topLeadingRadius: topLeadingRadius, bottomLeadingRadius: bottomLeadingRadius,
                bottomTrailingRadius: bottomTrailingRadius, topTrailingRadius: topTrailingRadius,
                style: style
            ).path(in: rect)
        }
        let limit = max(0, min(rect.width, rect.height) / 2)
        let tl = min(max(0, topLeadingRadius), limit)
        let bl = min(max(0, bottomLeadingRadius), limit)
        let br = min(max(0, bottomTrailingRadius), limit)
        let tr = min(max(0, topTrailingRadius), limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tr), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bl), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addQuadCurve(to: CGPoint(x: rect.minX + tl, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
