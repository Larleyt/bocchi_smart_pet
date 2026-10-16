import AppKit
import BocchiCore
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum RunAnimationCheck {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let leftAsset = Bundle.main.url(forResource: "bocchi-run-left", withExtension: "png")
            ?? root.appendingPathComponent("Assets/bocchi-run-left.png")
        let rightAsset = Bundle.main.url(forResource: "bocchi-run-right", withExtension: "png")
            ?? root.appendingPathComponent("Assets/bocchi-run-right.png")
        let frames = try PaintedRunFrames.frames(leftAsset: leftAsset, rightAsset: rightAsset)
        try check(frames.right.count == PaintedRunFrames.frameCount
                  && frames.left.count == PaintedRunFrames.frameCount,
                  "painted run loads four ordered phases in both directions")

        let fixtureDirectory = root.appendingPathComponent("artifacts/run-check-fixtures")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureDirectory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let orderedFixture = fixtureDirectory.appendingPathComponent("row-major.png")
        let reorderedFixture = fixtureDirectory.appendingPathComponent("rows-swapped.png")
        try writeAtlas(colors: [.red, .green, .blue, .yellow], to: orderedFixture)
        try writeAtlas(colors: [.blue, .yellow, .red, .green], to: reorderedFixture)
        let ordered = try PaintedRunFrames.frames(
            leftAsset: orderedFixture, rightAsset: orderedFixture
        ).left.map(colorSignature)
        let reordered = try PaintedRunFrames.frames(
            leftAsset: reorderedFixture, rightAsset: reorderedFixture
        ).left.map(colorSignature)
        try check(ordered == ["red", "green", "blue", "yellow"],
                  "independent colored fixture proves top-left row-major frame order")
        try check(reordered != ordered,
                  "row-order negative control detects swapped atlas rows")

        var now = 100.0
        let overlay = try PetOverlay(clock: { now }, runLeftAsset: leftAsset,
                                     runRightAsset: rightAsset)
        defer { overlay.stop() }
        let start = PetRect(x: 20, y: 40, width: 120, height: 156)
        let rightEnd = PetRect(x: 240, y: 140, width: 120, height: 156)
        try check(overlay.publish(placement: start, generation: overlay.generation),
                  "run fixture publishes the 120 by 156 protected footprint")
        guard let sprite = overlay.panel.contentView as? SpriteView else {
            throw RunAnimationCheckFailure.missingSprite
        }
        let standing = try rendered(sprite)
        guard let standingBounds = opaqueBounds(standing) else {
            throw RunAnimationCheckFailure.missingPixel
        }
        try check(overlay.panel.frame.size == NSSize(width: 120, height: 156)
                  && standingBounds.height >= 140
                  && !sprite.artworkContains(NSPoint(x: 2, y: 78))
                  && !sprite.artworkContains(NSPoint(x: 118, y: 78)),
                  "standing art remains 84 by 156 and centered inside the ordinary run footprint")

        try check(overlay.move(to: rightEnd, generation: overlay.generation),
                  "production overlay starts a rightward painted run")
        var renderedPhases: [Data] = []
        var renderedBounds: [NSRect] = []
        for phase in 0..<PaintedRunFrames.frameCount {
            now = 100.001 + Double(phase) * 0.12
            sprite.tick()
            let image = try rendered(sprite)
            guard let bounds = opaqueBounds(image),
                  let png = image.representation(using: .png, properties: [:]) else {
                throw RunAnimationCheckFailure.missingPixel
            }
            renderedBounds.append(bounds)
            renderedPhases.append(png)
        }
        try check(Set(renderedPhases).count == PaintedRunFrames.frameCount,
                  "actual NSPanel renders four distinct painted run phases")
        let expectedRight = try frames.right.map(renderedPhase)
        try check(renderedPhases == expectedRight,
                  "actual NSPanel presents rightward phases zero through three in order")

        let naturalBounds = try frames.right.map { frame -> NSRect in
            guard let bounds = opaqueBounds(try renderedNatural(frame)) else {
                throw RunAnimationCheckFailure.missingPixel
            }
            return bounds
        }
        let expectedScale = 156.0 / PaintedRunFrames.commonCrop.height
        let uniformScale = zip(renderedBounds, naturalBounds).allSatisfy { rendered, natural in
            // One point allows rasterized boundary rounding, not independent axis stretching.
            abs(rendered.width - natural.width * expectedScale) <= 1
                && abs(rendered.height - natural.height * expectedScale) <= 1
        }
        let heights = renderedBounds.map(\.height)
        try check(uniformScale && (heights.min() ?? 0) >= 140 && (heights.max() ?? 999) <= 151
                  && (heights.min() ?? 0) >= standingBounds.height * 0.95,
                  "painted run keeps one scale on both axes and remains close to standing height")

        now = 100.481
        sprite.tick()
        let wrapped = try rendered(sprite).representation(using: .png, properties: [:])
        try check(wrapped == renderedPhases[0],
                  "four-frame run cycle closes from phase three back to phase zero")

        _ = overlay.publish(placement: rightEnd, generation: overlay.generation)
        now = 500
        try check(overlay.move(to: start, generation: overlay.generation),
                  "production overlay restarts in the opposite direction")
        sprite.tick()
        let restarted = try rendered(sprite).representation(using: .png, properties: [:])
        let expectedLeft = try renderedPhase(frames.left[0])
        try check(restarted != renderedPhases[0] && restarted == expectedLeft,
                  "leftward movement uses the separately painted non-mirrored atlas")

        let wrongSize = fixtureDirectory.appendingPathComponent("wrong-size.png")
        let transparent = fixtureDirectory.appendingPathComponent("transparent.png")
        try writeSolid(size: 64, color: .red, to: wrongSize)
        try writeAtlas(colors: [.clear, .clear, .clear, .clear], to: transparent)
        for invalid in [wrongSize, transparent,
                        fixtureDirectory.appendingPathComponent("missing.png")] {
            let rejected: Bool
            do {
                _ = try SpriteView(runLeftAsset: invalid, runRightAsset: rightAsset,
                                   startsTimer: false)
                rejected = false
            } catch {
                rejected = true
            }
            try check(rejected,
                      "invalid painted run asset \(invalid.deletingPathExtension().lastPathComponent) is rejected")
        }
    }

    private static func renderedPhase(_ image: NSImage) throws -> Data {
        let view = RunFrameFixtureView(frame: NSRect(x: 0, y: 0, width: 120, height: 156))
        view.image = image
        let panel = PetPanel(contentRect: view.frame, styleMask: [.borderless],
                             backing: .buffered, defer: false)
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        guard let data = try rendered(view).representation(using: .png, properties: [:]) else {
            throw RunAnimationCheckFailure.fixture
        }
        return data
    }

    private static func renderedNatural(_ image: NSImage) throws -> NSBitmapImageRep {
        let view = RunFrameFixtureView(frame: NSRect(origin: .zero, size: image.size))
        view.image = image
        return try rendered(view)
    }

    private static func rendered(_ view: NSView) throws -> NSBitmapImageRep {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RunAnimationCheckFailure.fixture
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        bitmap.size = view.bounds.size
        return bitmap
    }

    private static func opaqueBounds(_ image: NSBitmapImageRep) -> NSRect? {
        var minX = image.pixelsWide, minY = image.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide
                where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let sx = image.size.width / Double(image.pixelsWide)
        let sy = image.size.height / Double(image.pixelsHigh)
        return NSRect(x: Double(minX) * sx, y: Double(minY) * sy,
                      width: Double(maxX - minX + 1) * sx,
                      height: Double(maxY - minY + 1) * sy)
    }

    private static func colorSignature(_ image: NSImage) throws -> String {
        let bitmap = try renderedNatural(image)
        guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2,
                                         y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB) else {
            throw RunAnimationCheckFailure.missingPixel
        }
        if color.redComponent > 0.8 && color.greenComponent < 0.3 { return "red" }
        if color.greenComponent > 0.35 && color.redComponent < 0.3 { return "green" }
        if color.blueComponent > 0.8 && color.redComponent < 0.3 { return "blue" }
        if color.redComponent > 0.8 && color.greenComponent > 0.8 { return "yellow" }
        return "other"
    }

    private static func writeAtlas(colors: [NSColor], to url: URL) throws {
        guard colors.count == 4,
              let context = CGContext(data: nil, width: PaintedRunFrames.atlasSize,
                height: PaintedRunFrames.atlasSize, bitsPerComponent: 8,
                bytesPerRow: PaintedRunFrames.atlasSize * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RunAnimationCheckFailure.fixture
        }
        for (index, color) in colors.enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: (index % 2) * PaintedRunFrames.cellSize,
                                y: (1 - index / 2) * PaintedRunFrames.cellSize,
                                width: PaintedRunFrames.cellSize,
                                height: PaintedRunFrames.cellSize))
        }
        guard let image = context.makeImage() else { throw RunAnimationCheckFailure.fixture }
        try writePNG(image, to: url)
    }

    private static func writeSolid(size: Int, color: NSColor, to url: URL) throws {
        guard let context = CGContext(data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RunAnimationCheckFailure.fixture
        }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { throw RunAnimationCheckFailure.fixture }
        try writePNG(image, to: url)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RunAnimationCheckFailure.fixture
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RunAnimationCheckFailure.fixture
        }
    }
}

@MainActor
private final class RunFrameFixtureView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let destination = NSRect(x: (bounds.width - size.width) / 2,
                                 y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

private enum RunAnimationCheckFailure: Error {
    case fixture
    case missingSprite
    case missingPixel
}
