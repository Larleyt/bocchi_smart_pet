import BocchiCore
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

struct ScreenSnapshot: Sendable {
    let obstacles: [PetRect]
    let controlsAvailable: Bool
    let pixelWidth: Int
    let pixelHeight: Int
}

struct PixelSample: Sendable {
    let bounds: PetRect
    let obstacles: [PetRect]
    let fingerprint: PixelFingerprint
    let supportEdges: [HorizontalSpan]

    init(bounds: PetRect, obstacles: [PetRect], fingerprint: PixelFingerprint,
         supportEdges: [HorizontalSpan] = []) {
        self.bounds = bounds
        self.obstacles = obstacles
        self.fingerprint = fingerprint
        self.supportEdges = supportEdges
    }
}

enum ScreenAnalyzerError: Error, LocalizedError {
    case invalidGeometry(String)
    case displayNotFound(UInt32)
    case capturePermissionDenied

    var errorDescription: String? {
        switch self {
        case .invalidGeometry(let detail):
            "Invalid screen geometry: \(detail)"
        case .displayNotFound(let displayID):
            "Display \(displayID) is not available for capture"
        case .capturePermissionDenied:
            "Screen capture permission is not granted"
        }
    }
}

actor ScreenAnalyzer {
    func capture(
        displayID: UInt32,
        screenBounds: PetRect,
        region: PetRect,
        ownBundleID: String,
        ignoringSupportEdgeY: Double? = nil
    ) async throws -> PixelSample {
        try Self.validate(screenBounds)
        try Self.validate(region)
        try Self.validate(ignoringSupportEdgeY, in: region)
        guard screenBounds.contains(region) else {
            throw ScreenAnalyzerError.invalidGeometry("capture region is outside the display")
        }
        guard !ownBundleID.isEmpty else {
            throw ScreenAnalyzerError.invalidGeometry("own bundle identifier is empty")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenAnalyzerError.capturePermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenAnalyzerError.displayNotFound(displayID)
        }

        let ownApplications = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let scale = Double(SCShareableContent.info(for: filter).pointPixelScale)
        guard scale.isFinite, scale > 0 else {
            throw ScreenAnalyzerError.invalidGeometry("display scale is invalid")
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: region.x - screenBounds.x,
            y: region.y - screenBounds.y,
            width: region.width,
            height: region.height
        )
        let pixelWidth = region.width * scale
        let pixelHeight = region.height * scale
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth < Double(Int.max), pixelHeight < Double(Int.max)
        else {
            throw ScreenAnalyzerError.invalidGeometry("capture output size is invalid")
        }
        configuration.width = max(1, Int(pixelWidth.rounded()))
        configuration.height = max(1, Int(pixelHeight.rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return try sample(image: image, bounds: region, ignoringSupportEdgeY: ignoringSupportEdgeY)
    }

    func sample(
        image: CGImage,
        bounds: PetRect,
        ignoringSupportEdgeY: Double? = nil
    ) throws -> PixelSample {
        try Self.validateImage(image, bounds: bounds)
        try Self.validate(ignoringSupportEdgeY, in: bounds)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let textRects = (request.results ?? []).compactMap { observation in
            Self.screenRect(for: observation.boundingBox, in: bounds)
        }
        let details = try Self.visualDetailRects(
            image: image, screenBounds: bounds, ignoringSupportEdgeY: ignoringSupportEdgeY
        )
        return PixelSample(
            bounds: bounds,
            obstacles: textRects + details.rects,
            fingerprint: try Self.fingerprint(image: image),
            supportEdges: details.supportEdges
        )
    }

    func analyze(
        image: CGImage,
        screenBounds: PetRect,
        controls: [PetRect] = []
    ) throws -> ScreenSnapshot {
        let sampled = try sample(image: image, bounds: screenBounds)
        let validControls = try controls.compactMap { rect -> PetRect? in
            try Self.validate(rect)
            return Self.intersection(rect, screenBounds)
        }
        return ScreenSnapshot(
            obstacles: validControls + sampled.obstacles,
            controlsAvailable: true,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private static func validate(_ rect: PetRect) throws {
        guard rect.x.isFinite, rect.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0,
              rect.maxX.isFinite, rect.maxY.isFinite
        else {
            throw ScreenAnalyzerError.invalidGeometry("rectangle must be finite and non-empty")
        }
    }

    private static func validate(_ edgeY: Double?, in bounds: PetRect) throws {
        guard let edgeY else { return }
        guard edgeY.isFinite, edgeY >= bounds.y, edgeY <= bounds.maxY else {
            throw ScreenAnalyzerError.invalidGeometry("support edge must be finite and inside the image bounds")
        }
    }

    private static func validateImage(_ image: CGImage, bounds: PetRect) throws {
        try validate(bounds)
        guard image.width > 0, image.height > 0 else {
            throw ScreenAnalyzerError.invalidGeometry("image is empty")
        }
        let imageAspect = Double(image.width) / Double(image.height)
        let boundsAspect = bounds.width / bounds.height
        guard abs(imageAspect / boundsAspect - 1) <= 0.02 else {
            throw ScreenAnalyzerError.invalidGeometry("image and screen aspect ratios differ")
        }
    }

    private static func screenRect(for normalized: CGRect, in screen: PetRect) -> PetRect? {
        guard normalized.minX.isFinite, normalized.minY.isFinite,
              normalized.width.isFinite, normalized.height.isFinite,
              normalized.width > 0, normalized.height > 0
        else { return nil }

        return intersection(
            PetRect(
                x: screen.x + normalized.minX * screen.width,
                y: screen.y + (1 - normalized.maxY) * screen.height,
                width: normalized.width * screen.width,
                height: normalized.height * screen.height
            ),
            screen
        )
    }

    private static func intersection(_ lhs: PetRect, _ rhs: PetRect) -> PetRect? {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.maxX, rhs.maxX)
        let maxY = min(lhs.maxY, rhs.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return PetRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func fingerprint(image: CGImage) throws -> PixelFingerprint {
        let scale = min(1, min(64 / Double(image.width), 96 / Double(image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw ScreenAnalyzerError.invalidGeometry("cannot allocate fingerprint buffer")
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(width * height * 3)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(contentsOf: rgba[index..<(index + 3)])
        }
        return try PixelFingerprint(rgb: rgb)
    }

    private static func visualDetailRects(
        image: CGImage,
        screenBounds: PetRect,
        ignoringSupportEdgeY: Double?
    ) throws -> (rects: [PetRect], supportEdges: [HorizontalSpan]) {
        let sampleWidth = min(image.width, 512)
        let sampleHeight = min(image.height, 320)
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                throw ScreenAnalyzerError.invalidGeometry("cannot allocate image analysis buffer")
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        }

        let columns = max(1, min(96, Int(ceil(screenBounds.width / 32))))
        let rows = max(1, min(64, Int(ceil(screenBounds.height / 32))))
        var detailed = [Bool](repeating: false, count: columns * rows)
        let ignoredRows: Range<Int>? = ignoringSupportEdgeY.map { edgeY in
            let scale = Double(sampleHeight) / screenBounds.height
            let start = max(0, Int(floor((edgeY - 1 - screenBounds.y) * scale)))
            let end = min(sampleHeight, Int(ceil((edgeY + 1 - screenBounds.y) * scale)))
            return start..<max(start, end)
        }
        // An AX layout rectangle is a support only where its top edge is actually drawn.
        var supportEdges: [HorizontalSpan] = []
        if let ignoredRows {
            let edgeRows = max(1, ignoredRows.lowerBound)..<min(sampleHeight, ignoredRows.upperBound + 1)
            var start: Int?
            for x in 0...sampleWidth {
                let hasEdge = x < sampleWidth && edgeRows.contains { y in
                    abs(Int(pixels[y * sampleWidth + x])
                        - Int(pixels[(y - 1) * sampleWidth + x])) >= 16
                }
                if hasEdge, start == nil { start = x }
                if !hasEdge, let first = start {
                    supportEdges.append(HorizontalSpan(
                        minX: screenBounds.x + Double(first) * screenBounds.width / Double(sampleWidth),
                        maxX: screenBounds.x + Double(x) * screenBounds.width / Double(sampleWidth)
                    ))
                    start = nil
                }
            }
        }

        for row in 0..<rows {
            let y0 = row * sampleHeight / rows
            let y1 = max(y0 + 1, (row + 1) * sampleHeight / rows)
            for column in 0..<columns {
                let x0 = column * sampleWidth / columns
                let x1 = max(x0 + 1, (column + 1) * sampleWidth / columns)
                var minimum = UInt8.max
                var maximum = UInt8.min
                var maximumContrast = 0
                var hasValues = false
                var edges = 0
                var comparisons = 0

                for y in y0..<min(y1, sampleHeight) {
                    if ignoredRows?.contains(y) == true {
                        if hasValues {
                            maximumContrast = max(maximumContrast, Int(maximum) - Int(minimum))
                            minimum = .max
                            maximum = .min
                            hasValues = false
                        }
                        continue
                    }
                    for x in x0..<min(x1, sampleWidth) {
                        let value = pixels[y * sampleWidth + x]
                        hasValues = true
                        minimum = min(minimum, value)
                        maximum = max(maximum, value)
                        if x > x0 {
                            edges += abs(Int(value) - Int(pixels[y * sampleWidth + x - 1])) >= 8 ? 1 : 0
                            comparisons += 1
                        }
                        if y > y0, ignoredRows?.contains(y - 1) != true {
                            edges += abs(Int(value) - Int(pixels[(y - 1) * sampleWidth + x])) >= 8 ? 1 : 0
                            comparisons += 1
                        }
                    }
                }
                if hasValues {
                    maximumContrast = max(maximumContrast, Int(maximum) - Int(minimum))
                }
                let edgeRatio = comparisons == 0 ? 0 : Double(edges) / Double(comparisons)
                // Low-contrast native button borders are occupied too, even when their title is outside the crop.
                detailed[row * columns + column] = maximumContrast >= 16 && edgeRatio >= 0.015
            }
        }

        var rectangles: [PetRect] = []
        for row in 0..<rows {
            var column = 0
            while column < columns {
                guard detailed[row * columns + column] else {
                    column += 1
                    continue
                }
                let firstColumn = column
                while column < columns, detailed[row * columns + column] {
                    column += 1
                }

                let x = screenBounds.x + Double(firstColumn) * screenBounds.width / Double(columns)
                let y = screenBounds.y + Double(row) * screenBounds.height / Double(rows)
                let maxX = screenBounds.x + Double(column) * screenBounds.width / Double(columns)
                let maxY = screenBounds.y + Double(row + 1) * screenBounds.height / Double(rows)
                rectangles.append(PetRect(x: x, y: y, width: maxX - x, height: maxY - y))
            }
        }
        return (rectangles, supportEdges)
    }
}
