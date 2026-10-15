import BocchiCore
import CoreGraphics
import CoreText
import Vision

@MainActor
enum PerchPixelCheck {
    static func run(_ check: (Bool, String) throws -> Void) async throws {
        let bounds = PetRect(x: -160, y: -30, width: 320, height: 280)
        let edgeY = 112.0
        let edgeImage = try image(width: 320, height: 280) { context in
            context.setFillColor(CGColor(gray: 0.18, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 280))
            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 138))
        }
        let analyzer = ScreenAnalyzer()
        let edgeBand = PetRect(x: bounds.x, y: edgeY - 16, width: bounds.width, height: 32)
        let ordinary = try await analyzer.sample(image: edgeImage, bounds: bounds)
        try check(ordinary.obstacles.contains { $0.intersects(edgeBand) },
                  "window color step remains occupied without a trusted support edge")
        let perched = try await analyzer.sample(
            image: edgeImage,
            bounds: bounds,
            ignoringSupportEdgeY: edgeY
        )
        try check(!perched.obstacles.contains { $0.intersects(edgeBand) },
                  "trusted two-point support edge does not occupy its visual grid row")
        let imprecise = try await analyzer.sample(
            image: edgeImage,
            bounds: bounds,
            ignoringSupportEdgeY: edgeY + 12
        )
        try check(imprecise.obstacles.contains { $0.intersects(edgeBand) },
                  "support-edge exception stays limited to the precise native edge")

        let buttonImage = try image(width: 320, height: 280) { context in
            context.setFillColor(CGColor(gray: 0.18, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 280))
            context.setStrokeColor(CGColor(gray: 0.88, alpha: 1))
            context.setLineWidth(4)
            context.stroke(CGRect(x: 112, y: 102, width: 80, height: 28))
        }
        let button = try await analyzer.sample(
            image: buttonImage,
            bounds: bounds,
            ignoringSupportEdgeY: edgeY
        )
        let buttonArea = PetRect(x: -48, y: 120, width: 80, height: 40)
        try check(button.obstacles.contains { $0.intersects(buttonArea) },
                  "nearby button border outside the support strip remains occupied")

        let textImage = try image(width: 320, height: 280) { context in
            context.setFillColor(CGColor(gray: 0.96, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 280))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 40, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 0.04, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "ROCK", attributes: attributes)
            )
            context.textPosition = CGPoint(x: 96, y: 122)
            CTLineDraw(line, context)
        }
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: textImage, options: [:]).perform([recognition])
        let recognized = (recognition.results ?? []).contains {
            $0.topCandidates(1).first?.string.uppercased().contains("ROCK") == true
        }
        try check(recognized, "fixture contains actual Vision-recognized text near the support edge")
        let text = try await analyzer.sample(
            image: textImage,
            bounds: bounds,
            ignoringSupportEdgeY: edgeY
        )
        let textArea = PetRect(x: -80, y: 80, width: 180, height: 80)
        try check(text.obstacles.contains { $0.intersects(textArea) },
                  "support-edge exception preserves OCR text obstacles")

        try check(await rejects(.nan, image: edgeImage, bounds: bounds, analyzer: analyzer),
                  "non-finite support edge is rejected")
        try check(await rejects(bounds.maxY + 1, image: edgeImage, bounds: bounds, analyzer: analyzer),
                  "support edge outside negative-origin bounds is rejected")
    }

    private static func image(
        width: Int,
        height: Int,
        draw: (CGContext) -> Void
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenAnalyzerError.invalidGeometry("cannot allocate perch pixel fixture")
        }
        draw(context)
        guard let image = context.makeImage() else {
            throw ScreenAnalyzerError.invalidGeometry("cannot create perch pixel fixture")
        }
        return image
    }

    private static func rejects(
        _ edgeY: Double,
        image: CGImage,
        bounds: PetRect,
        analyzer: ScreenAnalyzer
    ) async -> Bool {
        do {
            _ = try await analyzer.sample(
                image: image,
                bounds: bounds,
                ignoringSupportEdgeY: edgeY
            )
            return false
        } catch ScreenAnalyzerError.invalidGeometry {
            return true
        } catch {
            return false
        }
    }
}
