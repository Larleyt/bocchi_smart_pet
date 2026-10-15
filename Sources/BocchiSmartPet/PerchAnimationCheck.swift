import AppKit
import BocchiCore

@MainActor
enum PerchAnimationCheck {
    static func run(_ check: (Bool, String) throws -> Void) async throws {
        let start = PetRect(x: 40, y: 80, width: 84, height: 156)
        let perch = PetRect(x: 200, y: 80, width: 128, height: 156)
        let overlay = try PetOverlay()
        defer { overlay.stop() }
        try check(overlay.publish(placement: start, generation: overlay.generation),
                  "perch fixture publishes its standing start")

        var events: [PetInteractionEvent] = []
        overlay.onInteraction = { events.append($0) }
        try check(overlay.perch(at: perch, generation: overlay.generation),
                  "perch starts from a visible standing position")
        try await Task.sleep(for: .milliseconds(120))
        try check(overlay.isPerched && overlay.isMoving && !overlay.isSitting
                  && overlay.displayedPlacement.map { $0.x > start.x && $0.x < perch.x } == true,
                  "perch approach crosses a real intermediate panel position")
        try await Task.sleep(for: .milliseconds(350))
        try check(overlay.isPerched && overlay.isMoving && !overlay.isSitting
                  && overlay.displayedPlacement == perch,
                  "arrival at the support plays the climb before sitting")
        try await Task.sleep(for: .milliseconds(100))
        try check(overlay.isMoving && !overlay.isSitting,
                  "climb remains visible instead of collapsing into one frame")
        try await Task.sleep(for: .milliseconds(1_150))
        try check(overlay.isPerched && overlay.isSitting && !overlay.isMoving
                  && overlay.displayedPlacement == perch,
                  "climb finishes in the seated loop at the support edge")
        try check(events.filter {
            if case .movementEnded = $0 { true } else { false }
        }.count == 1, "perch emits the existing movement completion once")

        let followed = PetRect(x: 230, y: 95, width: 128, height: 156)
        try check(overlay.followPerch(at: followed, generation: overlay.generation)
                  && overlay.displayedPlacement == followed && overlay.isSitting
                  && !overlay.isMoving,
                  "moving support follows immediately without replaying the climb")

        overlay.leavePerch()
        try check(!overlay.isPerched && !overlay.isSitting,
                  "leaving a support restores the standing pose")
        try check(overlay.perch(at: perch, generation: overlay.generation),
                  "hard-cancel fixture starts another perch")
        try await Task.sleep(for: .milliseconds(70))
        overlay.invalidate(hiding: true)
        let cancelledFrame = overlay.panel.frame
        try await Task.sleep(for: .milliseconds(100))
        try check(!overlay.isMoving && !overlay.isPerched && !overlay.panel.isVisible
                  && overlay.panel.frame == cancelledFrame,
                  "hard invalidation cancels approach and perch animation")

        let hiddenPerch = PetRect(x: 320, y: 120, width: 128, height: 156)
        try check(overlay.perch(at: hiddenPerch, generation: overlay.generation)
                  && overlay.panel.isVisible && overlay.isMoving && !overlay.isSitting,
                  "hidden pet appears directly in the climb instead of a blank teleport")
        try await Task.sleep(for: .milliseconds(1_300))
        try check(overlay.isSitting && !overlay.isMoving,
                  "hidden-start climb reaches the seated loop")

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
        for index in 0..<16 {
            try check(!pose.perchFrameContains(index, point: NSPoint(x: 1, y: 1)),
                      "cleaned perch frame \(index) keeps its blank corner transparent")
        }
        try check(!pose.perchFrameContains(8, point: NSPoint(x: 118, y: 9)),
                  "cleaned seated frame removes the detached light above Bocchi")
        let posePanel = PetPanel(contentRect: NSRect(x: 500, y: 300, width: 128, height: 156),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        posePanel.contentView = pose
        posePanel.backgroundColor = .clear
        posePanel.isOpaque = false
        posePanel.isReleasedWhenClosed = false
        posePanel.orderFrontRegardless()
        defer { posePanel.orderOut(nil) }
        pose.finishClimbing()
        fakePointer = posePanel.convertPoint(toScreen: NSPoint(x: 1, y: 1))
        fakeNow += 0.1
        pose.tick()
        try check(posePanel.ignoresMouseEvents,
                  "transparent corner of the seated pose stays click-through")
    }
}

private enum PerchAnimationCheckFailure: Error {
    case event
}
