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
    var errorDescription: String? { "Не найдены корректные спрайты Боччи." }
}

@MainActor
final class SpriteView: NSView {
    static let climbDuration = 1.2
    private static var perchCache: [URL: ([NSImage], [NSImage])] = [:]
    private let idleFrames: [NSImage]
    private let gazeFrames: [[NSImage]]
    private let runningRight: [NSImage]
    private let runningLeft: [NSImage]
    private let clickReaction: [NSImage]
    private let climbingFrames: [NSImage]
    private let sittingFrames: [NSImage]
    private var timer: Timer?
    private let started: Double
    private var displayedFrame: NSImage
    private var displayedFrameIsPerch = false
    private var displayedFrameIsRunning = false
    private var runningStarted: Double?
    private var runningDirection = 0
    private var interaction = PetInteractionState()
    private var clickReactionStarted: Double?
    private var climbingStarted: Double?
    private(set) var isSitting = false
    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?
    private var dragged = false
    private let pointer: () -> NSPoint
    private let clock: () -> Double
    var eventSink: ((PetInteractionEvent) -> Void)?
    override var isFlipped: Bool { true }

    init(asset: URL? = nil,
         perchAsset: URL? = nil,
         runPartsAsset: URL? = nil,
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
        let runURL = runPartsAsset
                ?? Bundle.main.url(forResource: "bocchi-run-parts", withExtension: "png")
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Assets/bocchi-run-parts.png")
        let runFrames = try NativeRunRig.frames(asset: runURL)
        runningRight = runFrames.right
        runningLeft = runFrames.left
        let waiting = try row(6, count: 6)
        clickReaction = try row(7, count: 6) + waiting.suffix(2)
        gazeFrames = [try row(9, count: 8), try row(10, count: 8)]
        let perchURL = perchAsset
            ?? Bundle.main.url(forResource: "bocchi-perch-spritesheet", withExtension: "png")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Assets/bocchi-perch-spritesheet.png")
        let cacheKey = perchURL.standardizedFileURL
        if let cached = Self.perchCache[cacheKey] {
            (climbingFrames, sittingFrames) = cached
        } else {
            guard let perchSource = CGImageSourceCreateWithURL(perchURL as CFURL, nil),
                  let perchAtlas = CGImageSourceCreateImageAtIndex(perchSource, 0, nil),
                  perchAtlas.width == perchAtlas.height,
                  (512...4096).contains(perchAtlas.width) else {
                throw AtlasError.invalidAsset
            }
            func perchFrames(_ range: Range<Int>) throws -> [NSImage] {
                try range.map { index in
                    let column = index % 4
                    let row = index / 4
                    let side = Double(perchAtlas.width)
                    let x0 = (Double(column) * side / 4).rounded()
                    let x1 = (Double(column + 1) * side / 4).rounded()
                    let y0 = (Double(row) * side / 4).rounded()
                    let y1 = (Double(row + 1) * side / 4).rounded()
                    guard let image = perchAtlas.cropping(to: CGRect(
                        x: x0, y: y0, width: x1 - x0, height: y1 - y0
                    )) else { throw AtlasError.invalidAsset }
                    return try Self.cleanedSpriteFrame(image, size: NSSize(width: 128, height: 128))
                }
            }
            let climbing = try perchFrames(0..<8)
            let sitting = try perchFrames(8..<16)
            climbingFrames = climbing
            sittingFrames = sitting
            Self.perchCache[cacheKey] = (climbing, sitting)
        }
        displayedFrame = idleFrames[0]
        super.init(frame: .zero)
        if startsTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    static func cleanedSpriteFrame(_ image: CGImage, size: NSSize) throws -> NSImage {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let decoded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                    bitmapInfo: bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { throw AtlasError.invalidAsset }

        var visited = [Bool](repeating: false, count: width * height)
        var largest: [Int] = []
        for start in 0..<(width * height) where !visited[start] && pixels[start * 4 + 3] >= 16 {
            visited[start] = true
            var component: [Int] = []
            var queue = [start]
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                component.append(index)
                let x = index % width
                let y = index / width
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbor = ny * width + nx
                        guard !visited[neighbor], pixels[neighbor * 4 + 3] >= 16 else { continue }
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
            }
            if component.count > largest.count { largest = component }
        }
        guard !largest.isEmpty else { throw AtlasError.invalidAsset }
        var kept = [Bool](repeating: false, count: width * height)
        for index in largest { kept[index] = true }
        for index in 0..<(width * height) where !kept[index] {
            let offset = index * 4
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cleaned = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw AtlasError.invalidAsset
        }
        return NSImage(cgImage: cleaned, size: size)
    }

    func stop() { timer?.invalidate(); timer = nil }

    func beginClimbing() {
        endRunning()
        climbingStarted = clock()
        isSitting = false
        clickReactionStarted = nil
        displayedFrame = climbingFrames[0]
        displayedFrameIsPerch = true
        displayedFrameIsRunning = false
        needsDisplay = true
    }

    func finishClimbing() {
        endRunning()
        climbingStarted = nil
        isSitting = true
        displayedFrame = sittingFrames[0]
        displayedFrameIsPerch = true
        displayedFrameIsRunning = false
        needsDisplay = true
    }

    func stand() {
        endRunning()
        climbingStarted = nil
        isSitting = false
        displayedFrame = idleFrames[0]
        displayedFrameIsPerch = false
        displayedFrameIsRunning = false
        needsDisplay = true
    }

    func beginRunning(direction: Int) {
        runningDirection = direction >= 0 ? 1 : -1
        runningStarted = clock()
        displayedFrame = runningDirection > 0 ? runningRight[0] : runningLeft[0]
        displayedFrameIsPerch = false
        displayedFrameIsRunning = true
        needsDisplay = true
    }

    func endRunning() {
        runningStarted = nil
        runningDirection = 0
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pointerIsOverArtwork: Bool {
        guard let window else { return false }
        let point = convert(window.convertPoint(fromScreen: pointer()), from: nil)
        return artworkContains(point)
    }

    func artworkContains(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        let sample = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        return displayedFrame.hitTest(sample, withDestinationRect: frameRect,
                                      context: nil, hints: nil, flipped: true)
    }

    func perchFrameContains(_ index: Int, point: NSPoint) -> Bool {
        let frames = climbingFrames + sittingFrames
        guard frames.indices.contains(index) else { return false }
        let sample = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        return frames[index].hitTest(sample,
            withDestinationRect: NSRect(x: 0, y: 0, width: 128, height: 128),
            context: nil, hints: nil, flipped: true)
    }

    private var frameRect: NSRect {
        if displayedFrameIsPerch {
            return NSRect(x: 0, y: 15, width: 128, height: 128)
        }
        if displayedFrameIsRunning {
            let scale = min(bounds.width / displayedFrame.size.width,
                            bounds.height / displayedFrame.size.height)
            let size = NSSize(width: displayedFrame.size.width * scale,
                              height: displayedFrame.size.height * scale)
            return NSRect(x: (bounds.width - size.width) / 2,
                          y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        }
        return NSRect(x: (bounds.width - 84) / 2, y: 0, width: 84, height: 156)
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
            stand()
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
        if let runningStarted, runningDirection != 0 {
            let frames = runningDirection > 0 ? runningRight : runningLeft
            displayedFrame = frames[Int(max(0, now - runningStarted) / 0.12) % frames.count]
            displayedFrameIsPerch = false
            displayedFrameIsRunning = true
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
                displayedFrameIsPerch = false
                displayedFrameIsRunning = false
                needsDisplay = true
                return
            }
            clickReactionStarted = nil
        }
        if let climbingStarted {
            let index = min(climbingFrames.count - 1,
                            Int((now - climbingStarted) /
                                (Self.climbDuration / Double(climbingFrames.count))))
            displayedFrame = climbingFrames[max(0, index)]
            displayedFrameIsPerch = true
            displayedFrameIsRunning = false
            needsDisplay = true
            return
        }
        if isSitting {
            displayedFrame = sittingFrames[Int(now / 0.22) % sittingFrames.count]
            displayedFrameIsPerch = true
            displayedFrameIsRunning = false
            needsDisplay = true
            return
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
            displayedFrameIsPerch = false
            displayedFrameIsRunning = false
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
            displayedFrameIsPerch = false
            displayedFrameIsRunning = false
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        displayedFrame.draw(in: frameRect, from: .zero, operation: .sourceOver, fraction: 1,
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
    static let size = PetSize(width: 120, height: 156)
    let panel: PetPanel
    private let sprite: SpriteView
    private var movementTimer: Timer?
    private var perchRequested = false
    private let clock: () -> Double
    private(set) var generation: UInt64 = 0
    private(set) var lastPlacement: PetRect?
    private(set) var displayedPlacement: PetRect?
    var onInteraction: ((PetInteractionEvent) -> Void)?
    var isMoving: Bool { movementTimer != nil }
    var isDragging: Bool { panel.draggingPet }
    var isPerched: Bool { perchRequested }
    var isSitting: Bool { perchRequested && sprite.isSitting }

    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         runPartsAsset: URL? = nil) throws {
        self.clock = clock
        sprite = try SpriteView(runPartsAsset: runPartsAsset, clock: clock)
        panel = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.contentView = sprite
        sprite.eventSink = { [weak self] event in
            guard let self else { return }
            switch event {
            case .dragBegan:
                perchRequested = false
                cancelMovement()
                sprite.stand()
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
            perchRequested = false
            sprite.stand()
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
            perchRequested = false
            sprite.stand()
            panel.pressingPet = false
            panel.draggingPet = false
            sprite.cancelInteraction()
            panel.orderOut(nil)
            lastPlacement = nil
            displayedPlacement = nil
            return true
        }
        cancelMovement()
        perchRequested = false
        sprite.stand()
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
        perchRequested = false
        sprite.stand()
        let dx = placement.x - from.x
        let dy = placement.y - from.y
        let distance = hypot(dx, dy)
        guard distance >= 1 else { return publish(placement: placement, generation: expected) }
        let duration = min(1.8, max(0.35, distance / 420))
        let started = clock()
        panel.movementDirection = dx >= 0 ? 1 : -1
        sprite.beginRunning(direction: panel.movementDirection)
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
                    self.sprite.stand()
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

    @discardableResult
    func perch(at placement: PetRect, generation expected: UInt64) -> Bool {
        guard expected == generation else { return false }
        cancelMovement()
        perchRequested = true
        sprite.stand()
        panel.acceptsPetInput = false
        panel.ignoresMouseEvents = true

        guard panel.isVisible, let from = displayedPlacement ?? lastPlacement else {
            panel.setFrame(ScreenCoordinates.appKit(placement), display: true)
            lastPlacement = placement
            displayedPlacement = ScreenCoordinates.quartz(panel.frame)
            panel.orderFrontRegardless()
            startClimbing(at: placement)
            return true
        }

        let distance = hypot(placement.x - from.x, placement.y - from.y)
        guard distance >= 1 else {
            startClimbing(at: placement)
            return true
        }
        let duration = min(1.8, max(0.35, distance / 420))
        let started = clock()
        panel.movementDirection = placement.x >= from.x ? 1 : -1
        sprite.beginRunning(direction: panel.movementDirection)
        movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
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
                    self.startClimbing(at: placement)
                }
            }
        }
        return true
    }

    @discardableResult
    func followPerch(at placement: PetRect, generation expected: UInt64) -> Bool {
        guard expected == generation, perchRequested, sprite.isSitting else { return false }
        panel.setFrame(ScreenCoordinates.appKit(placement), display: true)
        lastPlacement = placement
        displayedPlacement = ScreenCoordinates.quartz(panel.frame)
        panel.orderFrontRegardless()
        return true
    }

    func leavePerch() {
        guard perchRequested else { return }
        cancelMovement()
        perchRequested = false
        sprite.stand()
        panel.acceptsPetInput = true
    }

    private func startClimbing(at placement: PetRect) {
        guard perchRequested else { return }
        panel.movementDirection = 0
        sprite.beginClimbing()
        let started = clock()
        movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.perchRequested else { return }
                if self.clock() - started >= SpriteView.climbDuration {
                    self.movementTimer?.invalidate()
                    self.movementTimer = nil
                    self.sprite.finishClimbing()
                    self.panel.acceptsPetInput = true
                    self.lastPlacement = placement
                    let displayed = ScreenCoordinates.quartz(self.panel.frame)
                    self.displayedPlacement = displayed
                    self.onInteraction?(.movementEnded(displayed))
                }
            }
        }
    }

    private func cancelMovement() {
        movementTimer?.invalidate()
        movementTimer = nil
        panel.movementDirection = 0
        sprite.endRunning()
        panel.acceptsPetInput = true
    }

    func stop() { invalidate(); sprite.stop() }
}
