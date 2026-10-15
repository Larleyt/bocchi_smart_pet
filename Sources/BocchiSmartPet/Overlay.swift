import AppKit
import BocchiCore
import CoreGraphics
import ImageIO

enum ScreenCoordinates {
    static var primaryHeight: Double { CGDisplayBounds(CGMainDisplayID()).height }

    static func quartz(_ rect: NSRect, primaryHeight: Double = primaryHeight) -> PetRect {
        PetRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKit(_ rect: PetRect, primaryHeight: Double = primaryHeight) -> NSRect {
        NSRect(x: rect.x, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static var cursor: PetPoint {
        let point = NSEvent.mouseLocation
        return PetPoint(x: point.x, y: primaryHeight - point.y)
    }
}

enum AtlasError: Error, LocalizedError {
    case invalidAsset
    var errorDescription: String? { "Не найден корректный спрайт Боччи (1536 × 2288)." }
}

@MainActor
final class SpriteView: NSView {
    private let frames: [[NSImage]]
    private var timer: Timer?
    private let started = ProcessInfo.processInfo.systemUptime
    private var displayedFrame: NSImage
    override var isFlipped: Bool { true }

    init(asset: URL? = nil) throws {
        let url = asset ?? Bundle.main.url(forResource: "bocchi-spritesheet", withExtension: "png")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Assets/bocchi-spritesheet.png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
              atlas.width == 1536, atlas.height == 2288 else { throw AtlasError.invalidAsset }
        var rows: [[NSImage]] = []
        for (row, count) in [(0, 6), (9, 8), (10, 8)] {
            var images: [NSImage] = []
            for column in 0..<count {
                // Idle/gaze artwork occupies x=48...144; keep 8 px around it instead of reserving empty atlas padding.
                guard let image = atlas.cropping(to: CGRect(x: column * 192 + 40, y: row * 208, width: 112, height: 208))
                else { throw AtlasError.invalidAsset }
                images.append(NSImage(cgImage: image, size: NSSize(width: 112, height: 208)))
            }
            rows.append(images)
        }
        frames = rows
        displayedFrame = rows[0][0]
        super.init(frame: .zero)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animate() }
        }
    }

    required init?(coder: NSCoder) { nil }

    func stop() { timer?.invalidate(); timer = nil }

    private func animate() {
        guard let window, window.isVisible else { return }
        let pet = ScreenCoordinates.quartz(window.frame)
        let pointer = ScreenCoordinates.cursor
        let dx = pointer.x - (pet.x + pet.width / 2)
        let dy = pointer.y - (pet.y + pet.height / 2)
        if hypot(dx, dy) < 300 {
            let angle = (atan2(dx, -dy) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            let index = Int((angle / (.pi / 8)).rounded()) % 16
            displayedFrame = frames[1 + index / 8][index % 8]
        } else {
            let durations = [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]
            var phase = (ProcessInfo.processInfo.systemUptime - started)
                .truncatingRemainder(dividingBy: durations.reduce(0, +))
            var index = 0
            while index < durations.count - 1 && phase >= durations[index] {
                phase -= durations[index]
                index += 1
            }
            displayedFrame = frames[0][index]
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        displayedFrame.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetOverlay {
    static let size = PetSize(width: 84, height: 156)
    let panel: PetPanel
    private let sprite: SpriteView
    private(set) var generation: UInt64 = 0
    private(set) var lastPlacement: PetRect?

    init() throws {
        sprite = try SpriteView()
        panel = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.contentView = sprite
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func invalidate() {
        generation &+= 1
        panel.orderOut(nil)
    }

    @discardableResult
    func publish(obstacles: [PetRect], bounds: PetRect, generation expected: UInt64) -> Bool {
        guard expected == generation else { return false }
        let placement = PlacementEngine.choose(in: bounds, avoiding: obstacles,
                                               size: Self.size, previous: lastPlacement)
        return publish(placement: placement, generation: expected)
    }

    @discardableResult
    func publish(placement: PetRect?, generation expected: UInt64) -> Bool {
        guard expected == generation else { return false }
        guard let placement else {
            panel.orderOut(nil)
            lastPlacement = nil
            return true
        }
        if placement != lastPlacement { panel.orderOut(nil) }
        panel.setFrame(ScreenCoordinates.appKit(placement), display: true)
        lastPlacement = placement
        panel.orderFrontRegardless()
        return true
    }

    func stop() { invalidate(); sprite.stop() }
}
