import AppKit
import BocchiCore

@MainActor
enum PerchAnimationCheck {
    static func run(_ check: (Bool, String) throws -> Void) async throws {
        let start = PetRect(x: 40, y: 80, width: 120, height: 156)
        let perch = PetRect(x: 200, y: 80, width: 128, height: 156)
        var overlayNow = 100.0
        let overlay = try PetOverlay(clock: { overlayNow })
        defer { overlay.stop() }
        try check(overlay.publish(placement: start, generation: overlay.generation),
                  "perch fixture publishes its standing start")

        var events: [PetInteractionEvent] = []
        overlay.onInteraction = { events.append($0) }
        try check(overlay.perch(at: perch, generation: overlay.generation),
                  "perch starts from a visible standing position")
        overlayNow += 0.12
        try await Task.sleep(for: .milliseconds(40))
        try check(overlay.isPerched && overlay.isMoving && !overlay.isSitting
                  && overlay.displayedPlacement.map { $0.x > start.x && $0.x < perch.x } == true,
                  "perch approach crosses a real intermediate panel position")
        guard let running = overlay.panel.contentView as? SpriteView,
              let runningBitmap = running.bitmapImageRepForCachingDisplay(in: running.bounds) else {
            throw PerchAnimationCheckFailure.render
        }
        running.cacheDisplay(in: running.bounds, to: runningBitmap)
        var occupiedRows: [Int] = []
        for y in 0..<runningBitmap.pixelsHigh {
            if (0..<runningBitmap.pixelsWide).contains(where: {
                (runningBitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.5
            }) { occupiedRows.append(y) }
        }
        let runningHeight = Double((occupiedRows.last ?? 0) - (occupiedRows.first ?? 0) + 1)
            * running.bounds.height / Double(runningBitmap.pixelsHigh)
        try check(overlay.panel.frame.width == PetOverlay.size.width && runningHeight >= 140,
                  "front approach keeps the ordinary run footprint and painted figure size")
        overlayNow += 0.45
        try await Task.sleep(for: .milliseconds(40))
        try check(overlay.isPerched && overlay.isMoving && !overlay.isSitting
                  && overlay.displayedPlacement == perch,
                  "arrival at the support plays the sit-down before sitting")
        overlayNow += 0.1
        try await Task.sleep(for: .milliseconds(40))
        try check(overlay.isMoving && !overlay.isSitting,
                  "sit-down remains visible instead of collapsing into one frame")
        overlayNow += 0.4
        try await Task.sleep(for: .milliseconds(40))
        try check(overlay.isPerched && overlay.isSitting && !overlay.isMoving
                  && overlay.displayedPlacement == perch,
                  "sit-down finishes in the seated loop at the support edge")
        try check(events.filter {
            if case .movementEnded = $0 { true } else { false }
        }.count == 1, "perch emits the existing movement completion once")

        let followed = PetRect(x: 230, y: 95, width: 128, height: 156)
        try check(overlay.followPerch(at: followed, generation: overlay.generation)
                  && overlay.displayedPlacement == followed && overlay.isSitting
                  && !overlay.isMoving,
                  "moving support follows immediately without replaying the sit-down")

        let otherPerch = PetRect(x: 500, y: 95, width: 128, height: 156)
        try check(overlay.perch(at: otherPerch, generation: overlay.generation)
                  && overlay.panel.frame.width == PetOverlay.size.width
                  && overlay.panel.frame.midX == followed.x + followed.width / 2,
                  "moving from another seat immediately restores run width without shifting its center")
        try check(overlay.publish(placement: followed, generation: overlay.generation)
                  && overlay.move(to: start, generation: overlay.generation)
                  && overlay.panel.frame.width == PetOverlay.size.width
                  && overlay.panel.frame.midX == followed.x + followed.width / 2,
                  "leaving a seat for free placement restores run width before the first timer tick")

        overlay.leavePerch()
        try check(!overlay.isPerched && !overlay.isSitting,
                  "leaving a support restores the standing pose")
        try check(overlay.perch(at: perch, generation: overlay.generation),
                  "hard-cancel fixture starts another perch")
        overlayNow += 0.07
        try await Task.sleep(for: .milliseconds(40))
        overlay.invalidate(hiding: true)
        let cancelledFrame = overlay.panel.frame
        overlayNow += 0.1
        try await Task.sleep(for: .milliseconds(40))
        try check(!overlay.isMoving && !overlay.isPerched && !overlay.panel.isVisible
                  && overlay.panel.frame == cancelledFrame,
                  "hard invalidation cancels approach and perch animation")

        let hiddenPerch = PetRect(x: 320, y: 120, width: 128, height: 156)
        try check(overlay.perch(at: hiddenPerch, generation: overlay.generation)
                  && overlay.panel.isVisible && overlay.isMoving && !overlay.isSitting,
                  "hidden pet appears directly in the sit-down instead of a blank teleport")
        overlayNow += 0.55
        try await Task.sleep(for: .milliseconds(40))
        try check(overlay.isSitting && !overlay.isMoving,
                  "hidden-start sit-down reaches the seated loop")

        guard let sprite = overlay.panel.contentView as? SpriteView else {
            try check(false, "perch overlay exposes its production sprite handler")
            return
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.panel.windowNumber, context: nil,
                eventNumber: 7, clickCount: 1, pressure: 1
            ) else { throw PerchAnimationCheckFailure.event }
            return event
        }
        let artwork = NSPoint(x: 42, y: 78)
        sprite.mouseDown(with: try mouse(.leftMouseDown, artwork))
        sprite.mouseUp(with: try mouse(.leftMouseUp, artwork))
        sprite.tick()
        try check(overlay.isSitting, "seated click reaction returns to the seated state")

        sprite.mouseDown(with: try mouse(.leftMouseDown, artwork))
        sprite.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 64, y: 78)))
        try check(!overlay.isPerched && !overlay.isSitting,
                  "dragging a seated pet switches to standing before moving the panel")
        sprite.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 64, y: 78)))

        var fakeNow = 500.0
        var fakePointer = NSPoint.zero
        let pose = try SpriteView(pointer: { fakePointer }, clock: { fakeNow }, startsTimer: false)
        defer { pose.stop() }
        for index in 0..<5 {
            try check(!pose.perchFrameContains(index, point: NSPoint(x: 1, y: 1)),
                      "cleaned perch frame \(index) keeps its blank corner transparent")
        }
        let posePanel = PetPanel(contentRect: NSRect(x: 500, y: 300, width: 128, height: 156),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        posePanel.contentView = pose
        posePanel.backgroundColor = .clear
        posePanel.isOpaque = false
        posePanel.isReleasedWhenClosed = false
        posePanel.orderFrontRegardless()
        defer { posePanel.orderOut(nil) }
        pose.beginSittingDown()
        var phases = Set<Data>()
        for phase in 0..<8 {
            fakeNow = 500.001 + Double(phase) * SpriteView.sitDownDuration / 8
            pose.tick()
            guard let bitmap = pose.bitmapImageRepForCachingDisplay(in: pose.bounds) else {
                throw PerchAnimationCheckFailure.render
            }
            pose.cacheDisplay(in: pose.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw PerchAnimationCheckFailure.render
            }
            phases.insert(data)
            try check(raisedShoePixels(bitmap) == 0,
                      "front sit-down phase \(phase) keeps the shoes below the seat")
        }
        try check(phases.count == 3,
                  "native front sit-down renders distinct standing, lowering and seated poses")
        pose.finishSittingDown()
        fakePointer = posePanel.convertPoint(toScreen: NSPoint(x: 1, y: 1))
        fakeNow += 0.1
        pose.tick()
        try check(posePanel.ignoresMouseEvents,
                  "transparent corner of the seated pose stays click-through")
    }

    private static func raisedShoePixels(_ bitmap: NSBitmapImageRep) -> Int {
        let sx = Double(bitmap.pixelsWide) / 128
        let sy = Double(bitmap.pixelsHigh) / 156
        var count = 0
        // The rejected vault lifted a white sneaker to the side above the 112pt seat.
        for y in Int(82 * sy)..<Int(100 * sy) {
            for x in 0..<bitmap.pixelsWide where Double(x) / sx < 35 || Double(x) / sx > 93 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.7 && color.redComponent > 0.6
                    && abs(color.redComponent - color.greenComponent) < 0.035
                    && abs(color.greenComponent - color.blueComponent) < 0.035 {
                    count += 1
                }
            }
        }
        return count
    }

}

private enum PerchAnimationCheckFailure: Error {
    case event
    case render
}
