import BocchiCore
import CoreGraphics

@MainActor
enum VisualGeometryCheck {
    static func run(_ check: (Bool, String) throws -> Void) async throws {
        let width = 480
        let height = 360
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenAnalyzerError.invalidGeometry("cannot allocate visual geometry fixture")
        }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0.92, alpha: 1))
        context.setLineWidth(10)
        context.stroke(CGRect(x: 5, y: 5, width: width - 10, height: height - 10))
        guard let image = context.makeImage() else {
            throw ScreenAnalyzerError.invalidGeometry("cannot create visual geometry fixture")
        }

        let bounds = PetRect(x: -240, y: -180, width: 480, height: 360)
        let sample = try await ScreenAnalyzer().sample(image: image, bounds: bounds)
        let topBorder = PetRect(x: -240, y: -180, width: 480, height: 30)
        let leftBorder = PetRect(x: -240, y: -180, width: 32, height: 360)
        try check(sample.obstacles.contains { $0.intersects(topBorder) }
                  && sample.obstacles.contains { $0.intersects(leftBorder) },
                  "visual geometry keeps connected border detail occupied")

        let size = PetSize(width: 84, height: 156)
        let center = PetRect(x: -42, y: -78, width: size.width, height: size.height)
        let placement = PlacementEngine.choose(
            in: bounds,
            avoiding: sample.obstacles,
            size: size,
            previous: nil,
            nearestTo: center
        )
        try check(placement.map { candidate in
            bounds.contains(candidate) && !sample.obstacles.contains { candidate.intersects($0) }
        } == true,
                  "connected visual border preserves its blank interior")
    }
}
