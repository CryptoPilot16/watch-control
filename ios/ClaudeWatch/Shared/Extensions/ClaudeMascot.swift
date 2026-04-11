import SwiftUI

/// The watch-control brand mark: a red `>_` prompt symbol that matches
/// the chevron + underscore on the app icon.
///
/// Type name kept as `ClaudeMascot` so existing call sites don't have to change.
struct ClaudeMascot: View {
    var size: CGFloat = 32

    var body: some View {
        BrandPromptMark()
            .stroke(
                Color(hex: "dc2626"),
                style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round, lineJoin: .round)
            )
            .frame(width: size, height: size * 0.7)
    }
}

/// The `>_` prompt mark drawn into the rect, matching the icon's geometry:
/// a chevron `>` followed by an underscore `_` on the same baseline.
struct BrandPromptMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Chevron: occupies the left ~45% of the width.
        let chevronLeft   = rect.minX + rect.width * 0.05
        let chevronRight  = rect.minX + rect.width * 0.45
        let chevronTop    = rect.minY + rect.height * 0.10
        let chevronMid    = rect.minY + rect.height * 0.50
        let chevronBottom = rect.minY + rect.height * 0.90

        path.move(to:    CGPoint(x: chevronLeft,  y: chevronTop))
        path.addLine(to: CGPoint(x: chevronRight, y: chevronMid))
        path.addLine(to: CGPoint(x: chevronLeft,  y: chevronBottom))

        // Underscore: occupies the right ~40% of the width, sitting on the chevron baseline.
        let underscoreLeft  = rect.minX + rect.width * 0.55
        let underscoreRight = rect.minX + rect.width * 0.95
        let underscoreY     = chevronBottom

        path.move(to:    CGPoint(x: underscoreLeft,  y: underscoreY))
        path.addLine(to: CGPoint(x: underscoreRight, y: underscoreY))

        return path
    }
}

#Preview {
    HStack(spacing: 16) {
        ClaudeMascot(size: 32)
        ClaudeMascot(size: 48)
        ClaudeMascot(size: 64)
    }
    .padding()
    .background(Color.black)
}
