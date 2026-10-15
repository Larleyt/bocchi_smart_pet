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
    private let idleFrames: [NSImage]
    private let gazeFrames: [[NSImage]]
    private let runningRight: [NSImage]
    private let runningLeft: [NSImage]
    private let clickReaction: [NSImage]
    private var timer: Timer?
    private let started: Double
    private var displayedFrame: NSImage
    private var interaction = PetInteractionState()
    private var clickReactionStarted: Double?
    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?
    private var dragged = false
    private let pointer: () -> NSPoint
    private let clock: () -> Double
    var eventSink: ((PetInteractionEvent) -> Void)?
    override var isFlipped: Bool { true }

    init(asset: URL? = nil,
         pointer: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         startsTimer: Bool = true) throws {
        self.pointer = pointer
        self.clock = clock
        self.started = clock()
        let url = asset ?? Bundle.main.url(forResource: "bocchi-spritesheet", withExtension: "png")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Assets/bocchi-spritesheet.png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
              atlas.width == 1536, atlas.height == 2288 else { throw AtlasError.invalidAsset }
        func row(_ row: Int, count: Int, inset: Int = 40, width: Int = 112) throws -> [NSImage] {
            var images: [NSImage] = []
            for column in 0..<count {
                guard let image = atlas.cropping(to: CGRect(
                    x: column * 192 + inset, y: row * 208, width: width, height: 208
                ))
                else { throw AtlasError.invalidAsset }
                images.append(NSImage(cgImage: image, size: NSSize(width: 112, height: 208)))
            }
            return images
        }
        idleFrames = try row(0, count: 6)
        // Running poses are wider than standing poses; retain the full gait inside the fixed pet window.
        runningRight = try row(1, count: 8, inset: 16, width: 160)
        runningLeft = try row(2, count: 8, inset: 16, width: 160)
        let waiting = try row(6, count: 6)
        clickReaction = try row(7, count: 6) + waiting.suffix(2)
        gazeFrames = [try row(9, count: 8), try row(10, count: 8)]
        displayedFrame = idleFrames[0]
        super.init(frame: .zero)
        if startsTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func stop() { timer?.invalidate(); timer = nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pointerIsOverArtwork: Bool {
        guard let window else { return false }
        let point = convert(window.convertPoint(fromScreen: pointer()), from: nil)
        return artworkContains(point)
    }

    private func artworkContains(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        let sample = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        return displayedFrame.hitTest(sample, withDestinationRect: bounds,
                                      context: nil, hints: nil, flipped: true)
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? pointer()
    }

    override func mouseDown(with event: NSEvent) {
        guard artworkContains(convert(event.locationInWindow, from: nil)),
              let panel = window as? PetPanel else { return }
        interaction.mouseDown()
        dragOrigin = screenPoint(for: event)
        windowOrigin = panel.frame.origin
        dragged = false
        panel.pressingPet = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let windowOrigin, let panel = window as? PetPanel else { return }
        let pointer = screenPoint(for: event)
        let distance = hypot(pointer.x - dragOrigin.x, pointer.y - dragOrigin.y)
        if !dragged, distance >= 3 {
            dragged = true
            panel.draggingPet = true
            eventSink?(.dragBegan)
        }
        guard dragged else { return }
        panel.setFrameOrigin(NSPoint(x: windowOrigin.x + pointer.x - dragOrigin.x,
                                     y: windowOrigin.y + pointer.y - dragOrigin.y))
        eventSink?(.dragChanged(ScreenCoordinates.quartz(panel.frame)))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil, let panel = window as? PetPanel else { return }
        panel.pressingPet = false
        let placement = ScreenCoordinates.quartz(panel.frame)
        if dragged {
            panel.draggingPet = false
            eventSink?(.dragEnded(placement))
        } else {
            clickReactionStarted = clock()
            eventSink?(.clicked)
        }
        interaction.mouseUp(isOverPet: pointerIsOverArtwork,
                            now: clock())
        dragOrigin = nil
        windowOrigin = nil
        dragged = false
    }

    func cancelInteraction() {
        interaction.reset()
        (window as? PetPanel)?.pressingPet = false
        dragOrigin = nil
        windowOrigin = nil
        dragged = false
    }

    func tick() {
        guard let window, window.isVisible else {
            cancelInteraction()
            return
        }
        let now = clock()
        defer {
            let overArtwork = pointerIsOverArtwork
            interaction.hoverChanged(isOverPet: overArtwork, now: now)
            if let panel = window as? PetPanel {
                panel.refreshMousePassthrough(overArtwork: overArtwork)
            }
            if interaction.escapeIsDue(now: now) {
                eventSink?(.hoverEscapeRequested(ScreenCoordinates.quartz(window.frame)))
            }
        }
        if let panel = window as? PetPanel, panel.movementDirection != 0 {
            let frames = panel.movementDirection > 0 ? runningRight : runningLeft
            displayedFrame = frames[Int(now / 0.12) % frames.count]
            needsDisplay = true
            return
        }
        if let reaction = clickReactionStarted {
            let durations = [0.12, 0.12, 0.12, 0.12, 0.12, 0.22, 0.15, 0.26]
            var phase = now - reaction
            var index = 0
            while index < durations.count && phase >= durations[index] {
                phase -= durations[index]
                index += 1
            }
            if index < clickReaction.count {
                displayedFrame = clickReaction[index]
                needsDisplay = true
                return
            }
            clickReactionStarted = nil
        }
        let pet = ScreenCoordinates.quartz(window.frame)
        let cocoaPointer = pointer()
        let quartzPointer = PetPoint(x: cocoaPointer.x,
                                    y: ScreenCoordinates.primaryHeight - cocoaPointer.y)
        let dx = quartzPointer.x - (pet.x + pet.width / 2)
        let dy = quartzPointer.y - (pet.y + pet.height / 2)
        if hypot(dx, dy) < 300 {
            let angle = (atan2(dx, -dy) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            let index = Int((angle / (.pi / 8)).rounded()) % 16
            displayedFrame = gazeFrames[index / 8][index % 8]
        } else {
            let durations = [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]
            var phase = (now - started)
                .truncatingRemainder(dividingBy: durations.reduce(0, +))
            var index = 0
            while index < durations.count - 1 && phase >= durations[index] {
                phase -= durations[index]
                index += 1
            }
            displayedFrame = idleFrames[index]
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        displayedFrame.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

final class PetPanel: NSPanel {
    var movementDirection = 0
    var acceptsPetInput = true
    var pressingPet = false
    var draggingPet = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func refreshMousePassthrough(overArtwork: Bool) {
        ignoresMouseEvents = !(acceptsPetInput && (overArtwork || pressingPet || draggingPet))
    }
}

@MainActor
final class PetOverlay {
    static let size = PetSize(width: 84, height: 156)
    let panel: PetPanel
    private let sprite: SpriteView
    private var movementTimer: Timer?
    private let clock: () -> Double
    private(set) var generation: UInt64 = 0
    private(set) var lastPlacement: PetRect?
    private(set) var displayedPlacement: PetRect?
    var onInteraction: ((PetInteractionEvent) -> Void)?
    var isMoving: Bool { movementTimer != nil }
    var isDragging: Bool { panel.draggingPet }

    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) throws {
        self.clock = clock
        sprite = try SpriteView(clock: clock)
        panel = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.contentView = sprite
        sprite.eventSink = { [weak self] event in
            guard let self else { return }
            switch event {
            case .dragChanged(let placement), .movementEnded(let placement):
                displayedPlacement = placement
            case .dragEnded(let placement):
                displayedPlacement = placement
                lastPlacement = placement
                panel.acceptsPetInput = false
                panel.ignoresMouseEvents = true
            default:
                break
            }
            onInteraction?(event)
        }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func invalidate(hiding: Bool = true) {
        generation &+= 1
        if hiding {
            cancelMovement()
            panel.pressingPet = false
            panel.draggingPet = false
            sprite.cancelInteraction()
            panel.orderOut(nil)
            displayedPlacement = nil
        }
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
            cancelMovement()
            panel.pressingPet = false
            panel.draggingPet = false
            sprite.cancelInteraction()
            panel.orderOut(nil)
            lastPlacement = nil
            displayedPlacement = nil
            return true
        }
        cancelMovement()
        panel.setFrame(ScreenCoordinates.appKit(placement), display: true)
        lastPlacement = placement
        displayedPlacement = ScreenCoordinates.quartz(panel.frame)
        panel.acceptsPetInput = true
        panel.orderFrontRegardless()
        return true
    }

    @discardableResult
    func move(to placement: PetRect, generation expected: UInt64) -> Bool {
        guard expected == generation, panel.isVisible, let from = displayedPlacement ?? lastPlacement else {
            return false
        }
        cancelMovement()
        let dx = placement.x - from.x
        let dy = placement.y - from.y
        let distance = hypot(dx, dy)
        guard distance >= 1 else { return publish(placement: placement, generation: expected) }
        let duration = min(1.2, max(0.22, distance / 650))
        let started = clock()
        panel.movementDirection = dx >= 0 ? 1 : -1
        panel.acceptsPetInput = false
        panel.ignoresMouseEvents = true
        movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = min(1, (self.clock() - started) / duration)
                let current = PetMotion.placement(from: from, to: placement, progress: progress)
                self.panel.setFrame(ScreenCoordinates.appKit(current), display: true)
                self.displayedPlacement = ScreenCoordinates.quartz(self.panel.frame)
                if progress >= 1 {
                    self.movementTimer?.invalidate()
                    self.movementTimer = nil
                    self.panel.movementDirection = 0
                    self.panel.acceptsPetInput = true
                    self.lastPlacement = placement
                    let displayed = ScreenCoordinates.quartz(self.panel.frame)
                    self.displayedPlacement = displayed
                    self.onInteraction?(.movementEnded(displayed))
                }
            }
        }
        return true
    }

    private func cancelMovement() {
        movementTimer?.invalidate()
        movementTimer = nil
        panel.movementDirection = 0
        panel.acceptsPetInput = true
    }

    func stop() { invalidate(); sprite.stop() }
}
