import AppKit
import BocchiCore

@MainActor
enum RunAnimationCheck {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        let asset = Bundle.main.url(forResource: "bocchi-run-parts", withExtension: "png")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Assets/bocchi-run-parts.png")
        let frames = try NativeRunRig.frames(asset: asset)
        try check(frames.right.count == RunCycle.phaseCount
                  && frames.left.count == RunCycle.phaseCount,
                  "native rig produces all eight phases in both directions")

        var now = 100.0
        let overlay = try PetOverlay(clock: { now }, runPartsAsset: asset)
        defer { overlay.stop() }
        let start = PetRect(x: 20, y: 40, width: 120, height: 156)
        let end = PetRect(x: 220, y: 140, width: 120, height: 156)
        try check(overlay.publish(placement: start, generation: overlay.generation),
                  "run fixture publishes the 120-point protected footprint")
        guard let sprite = overlay.panel.contentView as? SpriteView else {
            throw RunAnimationCheckFailure.missingSprite
        }
        try check(overlay.panel.frame.size == NSSize(width: 120, height: 156)
                  && !sprite.artworkContains(NSPoint(x: 2, y: 78))
                  && !sprite.artworkContains(NSPoint(x: 118, y: 78)),
                  "standing art stays centered at 84 by 156 inside the wider footprint")

        try check(overlay.move(to: end, generation: overlay.generation),
                  "production overlay starts a rightward run")
        var renderedPhases: [Data] = []
        var firstImage: NSBitmapImageRep?
        let phaseZero = RunCycle.pose(index: 0)
        let phaseFour = RunCycle.pose(index: 4)
        let rightCalf = midpoint(phaseZero.nearLeg.knee, phaseZero.nearLeg.ankle)
        let leftCalf = midpoint(phaseFour.nearLeg.knee, phaseFour.nearLeg.ankle)
        var halfCycleSamples: [Int: (right: Double, left: Double)] = [:]
        for phase in 0..<RunCycle.phaseCount {
            now = 100.001 + Double(phase) * 0.12
            sprite.tick()
            let image = try rendered(sprite)
            if phase == 0 { firstImage = image }
            if phase == 0 || phase == 4 {
                halfCycleSamples[phase] = (
                    luminance(around: rightCalf, in: image),
                    luminance(around: leftCalf, in: image)
                )
            }
            guard let png = image.representation(using: .png, properties: [:]) else {
                throw RunAnimationCheckFailure.fixture
            }
            renderedPhases.append(png)
        }
        try check(Set(renderedPhases).count == RunCycle.phaseCount,
                  "actual NSPanel renders eight distinct ordered run phases")
        let expectedPhases = try frames.right.map(renderedPhase)
        try check(renderedPhases == expectedPhases,
                  "actual NSPanel presents native rig phases zero through seven in order")
        guard let zero = halfCycleSamples[0], let four = halfCycleSamples[4] else {
            throw RunAnimationCheckFailure.missingPixel
        }
        try check(zero.right > four.right + 0.015 && four.left > zero.left + 0.015,
                  "rendered half-cycle visibly exchanges the bright near leg and shadowed far leg")

        guard let firstImage else { throw RunAnimationCheckFailure.fixture }
        let naturalView = RunFrameFixtureView(frame: NSRect(x: 0, y: 0, width: 160, height: 208))
        naturalView.image = frames.right[0]
        let naturalPanel = PetPanel(contentRect: naturalView.frame, styleMask: [.borderless],
                                    backing: .buffered, defer: false)
        naturalPanel.contentView = naturalView
        naturalPanel.backgroundColor = .clear
        naturalPanel.isOpaque = false
        naturalPanel.isReleasedWhenClosed = false
        naturalPanel.orderFrontRegardless()
        defer { naturalPanel.orderOut(nil) }
        let natural = try rendered(naturalView)
        guard let runBounds = opaqueBounds(firstImage), let naturalBounds = opaqueBounds(natural) else {
            throw RunAnimationCheckFailure.missingPixel
        }
        let scaleX = runBounds.width / naturalBounds.width
        let scaleY = runBounds.height / naturalBounds.height
        try check(abs(scaleX - 0.75) < 0.03 && abs(scaleY - 0.75) < 0.03,
                  "native run rendering preserves one scale on both axes without squashing")

        now = 100.961
        sprite.tick()
        let wrapped = try rendered(sprite).representation(using: .png, properties: [:])
        try check(wrapped == renderedPhases[0],
                  "run cycle closes from phase seven back to phase zero")

        _ = overlay.publish(placement: end, generation: overlay.generation)
        now = 500
        try check(overlay.move(to: start, generation: overlay.generation),
                  "production overlay restarts in the opposite direction")
        sprite.tick()
        let restarted = try rendered(sprite).representation(using: .png, properties: [:])
        let expectedLeft = try renderedPhase(frames.left[0])
        try check(restarted != renderedPhases[0]
                  && restarted == expectedLeft,
                  "a new movement resets to the opposite direction phase zero")

        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/run-check-fixtures/\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalidInputs = try [
            invalidCopy(of: asset, in: directory, named: "reordered") { manifest in
                var parts = manifest["parts"] as! [[String: Any]]
                parts.swapAt(0, 1)
                manifest["parts"] = parts
            },
            invalidCopy(of: asset, in: directory, named: "zero-rect") { manifest in
                var parts = manifest["parts"] as! [[String: Any]]
                parts[0]["width"] = 0
                manifest["parts"] = parts
            },
            invalidCopy(of: asset, in: directory, named: "extreme-rect") { manifest in
                var parts = manifest["parts"] as! [[String: Any]]
                parts[0]["x"] = Int64.max
                manifest["parts"] = parts
            },
            invalidCopy(of: asset, in: directory, named: "invalid-anchor") { manifest in
                var anchor = manifest["torsoRightHip"] as! [String: Any]
                anchor["x"] = 2.0
                manifest["torsoRightHip"] = anchor
            },
            invalidCopy(of: asset, in: directory, named: "missing-part") { manifest in
                var parts = manifest["parts"] as! [[String: Any]]
                parts.removeLast()
                manifest["parts"] = parts
            },
            try transparentCopy(of: asset, in: directory)
        ]
        for invalid in invalidInputs {
            let rejected: Bool
            do {
                _ = try SpriteView(runPartsAsset: invalid, startsTimer: false)
                rejected = false
            } catch {
                rejected = true
            }
            try check(rejected,
                      "invalid run-parts input \(invalid.deletingPathExtension().lastPathComponent) is rejected")
        }
        try FileManager.default.removeItem(at: directory)
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
        let bitmap = try rendered(view)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RunAnimationCheckFailure.fixture
        }
        return data
    }

    private static func invalidCopy(of asset: URL, in directory: URL, named name: String,
                                    mutate: (inout [String: Any]) -> Void) throws -> URL {
        let copy = directory.appendingPathComponent(name).appendingPathExtension("png")
        try FileManager.default.copyItem(at: asset, to: copy)
        let sourceMetadata = asset.deletingPathExtension().appendingPathExtension("json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceMetadata))
            as! [String: Any]
        mutate(&manifest)
        let metadata = copy.deletingPathExtension().appendingPathExtension("json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: metadata)
        return copy
    }

    private static func transparentCopy(of asset: URL, in directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(asset as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: atlas.width, height: atlas.height,
                  bitsPerComponent: 8, bytesPerRow: atlas.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) else {
            throw RunAnimationCheckFailure.fixture
        }
        let copy = directory.appendingPathComponent("transparent").appendingPathExtension("png")
        try data.write(to: copy)
        try FileManager.default.copyItem(
            at: asset.deletingPathExtension().appendingPathExtension("json"),
            to: copy.deletingPathExtension().appendingPathExtension("json")
        )
        return copy
    }

    private static func rendered(_ view: NSView) throws -> NSBitmapImageRep {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RunAnimationCheckFailure.fixture
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private static func opaqueBounds(_ image: NSBitmapImageRep) -> NSRect? {
        var minX = image.pixelsWide, minY = image.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func luminance(around point: PetPoint, in image: NSBitmapImageRep) -> Double {
        let pixelScale = Double(image.pixelsWide) / 120
        let x = Int((point.x * 0.75 * pixelScale).rounded())
        let drawnY = point.y * 0.75 * pixelScale
        let y = Int(drawnY.rounded())
        var sample: (count: Int, total: Double) = (0, 0)
        let radius = max(2, Int((4 * pixelScale).rounded()))
        for py in max(0, y - radius)...min(image.pixelsHigh - 1, y + radius) {
            for px in max(0, x - radius)...min(image.pixelsWide - 1, x + radius) {
                guard let color = image.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.2 else { continue }
                sample.count += 1
                sample.total += 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            }
        }
        return sample.count == 0 ? 0 : sample.total / Double(sample.count)
    }

    private static func midpoint(_ first: PetPoint, _ second: PetPoint) -> PetPoint {
        PetPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }
}

@MainActor
private final class RunFrameFixtureView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

private enum RunAnimationCheckFailure: Error {
    case fixture
    case missingSprite
    case missingPixel
}
