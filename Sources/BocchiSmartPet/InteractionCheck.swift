import AppKit
import BocchiCore

@MainActor
enum InteractionCheck {
    static func run(_ check: (Bool, String) throws -> Void) async throws {
        var state = PetInteractionState()
        state.hoverChanged(isOverPet: true, now: 10)
        try check(!state.escapeIsDue(now: 14.99), "hover waits for five seconds")
        try check(state.escapeIsDue(now: 15), "five-second hover requests escape")
        try check(!state.escapeIsDue(now: 20), "one hover requests escape only once")

        state.hoverChanged(isOverPet: false, now: 21)
        state.hoverChanged(isOverPet: true, now: 22)
        state.mouseDown()
        try check(!state.escapeIsDue(now: 40), "press cancels pending hover escape")
        state.mouseUp(isOverPet: true, now: 40)
        try check(!state.escapeIsDue(now: 44.99), "release starts a fresh hover delay")
        try check(state.escapeIsDue(now: 45), "hover escape resumes five seconds after release")

        let start = PetRect(x: 10, y: 20, width: PetOverlay.size.width, height: PetOverlay.size.height)
        let end = PetRect(x: 110, y: 220, width: PetOverlay.size.width, height: PetOverlay.size.height)
        try check(PetMotion.placement(from: start, to: end, progress: 0.5)
                  == PetRect(x: 60, y: 120, width: PetOverlay.size.width, height: PetOverlay.size.height),
                  "movement crosses the actual midpoint")
        try check(PetMotion.placement(from: start, to: end, progress: 1) == end,
                  "movement finishes at the requested placement")

        let overlay = try PetOverlay()
        defer { overlay.stop() }
        try check(overlay.publish(placement: start, generation: overlay.generation),
                  "runtime movement fixture publishes its start")
        try check(overlay.move(to: end, generation: overlay.generation),
                  "runtime movement starts without teleporting")
        try await Task.sleep(for: .milliseconds(120))
        guard let intermediate = overlay.displayedPlacement else {
            try check(false, "runtime movement exposes its intermediate frame")
            return
        }
        try check(intermediate.x > start.x && intermediate.x < end.x
                  && ScreenCoordinates.quartz(overlay.panel.frame) == intermediate,
                  "runtime NSPanel crosses an actual intermediate frame")
        try await Task.sleep(for: .milliseconds(600))
        try check(!overlay.isMoving && overlay.lastPlacement == end
                  && ScreenCoordinates.quartz(overlay.panel.frame) == end,
                  "runtime NSPanel finishes at the requested frame")

        let shortEscape = PetRect(x: end.x + 96, y: end.y, width: end.width, height: end.height)
        try check(overlay.move(to: shortEscape, generation: overlay.generation),
                  "short escape starts with the existing run animation")
        try await Task.sleep(for: .milliseconds(250))
        try check(overlay.isMoving && overlay.panel.isVisible
                  && overlay.displayedPlacement.map { $0.x > end.x && $0.x < shortEscape.x } == true,
                  "short escape takes enough time to read as running")
        try await Task.sleep(for: .milliseconds(400))
        overlay.publish(placement: end, generation: overlay.generation)

        try check(overlay.move(to: start, generation: overlay.generation),
                  "soft-invalidation movement starts")
        overlay.invalidate(hiding: false)
        try await Task.sleep(for: .milliseconds(600))
        try check(!overlay.isMoving && overlay.lastPlacement == start,
                  "soft invalidation does not interrupt a safe run")

        try check(overlay.move(to: end, generation: overlay.generation),
                  "hard-cancel movement starts")
        try await Task.sleep(for: .milliseconds(70))
        overlay.invalidate(hiding: true)
        let cancelledFrame = overlay.panel.frame
        try await Task.sleep(for: .milliseconds(100))
        try check(!overlay.isMoving && !overlay.panel.isVisible && overlay.panel.frame == cancelledFrame,
                  "hard invalidation cancels movement without stale frames")

        let realDropStart = PetRect(x: 30, y: 30, width: PetOverlay.size.width, height: PetOverlay.size.height)
        try check(overlay.publish(placement: realDropStart, generation: overlay.generation),
                  "real overlay drop fixture publishes its start")
        guard let realSprite = overlay.panel.contentView as? SpriteView else {
            try check(false, "real overlay exposes its production sprite handler")
            return
        }
        var realEvents: [PetInteractionEvent] = []
        overlay.onInteraction = { realEvents.append($0) }
        func realMouse(_ type: NSEvent.EventType, _ location: NSPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: overlay.panel.windowNumber, context: nil,
                    eventNumber: 2, clickCount: 1, pressure: 1) else {
                throw InteractionCheckFailure.event
            }
            return event
        }
        let realArtwork = NSPoint(x: PetOverlay.size.width / 2, y: 78)
        realSprite.mouseDown(with: try realMouse(.leftMouseDown, realArtwork))
        realSprite.mouseDragged(with: try realMouse(.leftMouseDragged, NSPoint(x: PetOverlay.size.width / 2 + 4, y: 78)))
        realSprite.mouseUp(with: try realMouse(.leftMouseUp, NSPoint(x: PetOverlay.size.width / 2 + 4, y: 78)))
        try check(realEvents.contains(where: {
            if case .dragEnded = $0 { true } else { false }
        }) && !overlay.panel.acceptsPetInput && overlay.panel.ignoresMouseEvents,
        "real overlay drop becomes click-through until async validation publishes")
        guard let dropped = overlay.displayedPlacement else {
            try check(false, "real overlay records its dropped position")
            return
        }
        try check(overlay.publish(placement: dropped, generation: overlay.generation)
                  && overlay.panel.acceptsPetInput,
                  "validated drop restores pet interaction")

        var fakeNow = 200.0
        var fakePointer = NSPoint.zero
        let sprite = try SpriteView(pointer: { fakePointer }, clock: { fakeNow }, startsTimer: false)
        defer { sprite.stop() }
        let panel = PetPanel(contentRect: NSRect(x: 180, y: 180, width: PetOverlay.size.width, height: PetOverlay.size.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = sprite
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        var events: [PetInteractionEvent] = []
        sprite.eventSink = { events.append($0) }

        func mouse(_ type: NSEvent.EventType, _ location: NSPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: fakeNow, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw InteractionCheckFailure.event
            }
            return event
        }
        func rendered(_ view: NSView) -> Data? {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        let artwork = NSPoint(x: PetOverlay.size.width / 2, y: 78)
        let beforeClick = rendered(sprite)
        sprite.mouseDown(with: try mouse(.leftMouseDown, artwork))
        sprite.mouseUp(with: try mouse(.leftMouseUp, artwork))
        sprite.tick()
        let afterClick = rendered(sprite)
        try check(events == [.clicked], "native mouse down and up trigger the click reaction")
        try check(beforeClick != nil && afterClick != nil && beforeClick != afterClick,
                  "native click visibly changes the real sprite to its shirt reaction")

        events = []
        fakePointer = panel.convertPoint(toScreen: NSPoint(x: 2, y: 2))
        sprite.tick()
        try check(panel.ignoresMouseEvents,
                  "transparent pixel in the pet window remains click-through")
        sprite.mouseDown(with: try mouse(.leftMouseDown, artwork))
        fakePointer = NSPoint(x: panel.frame.maxX + 20, y: panel.frame.maxY + 20)
        sprite.tick()
        let capturedPress = panel.pressingPet && !panel.ignoresMouseEvents
        sprite.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 100, y: 170)))
        sprite.tick()
        try check(capturedPress && !panel.pressingPet && panel.ignoresMouseEvents
                  && events == [.clicked],
                  "pressed pet keeps mouse capture across transparent pixels until mouse up")

        events = []
        let originalFrame = panel.frame
        sprite.mouseDown(with: try mouse(.leftMouseDown, artwork))
        sprite.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: PetOverlay.size.width / 2 + 4, y: 78)))
        sprite.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: PetOverlay.size.width / 2 + 4, y: 78)))
        try check(events.first == .dragBegan && events.contains(where: {
            if case .dragChanged = $0 { true } else { false }
        }) && events.last.map {
            if case .dragEnded = $0 { true } else { false }
        } == true && panel.frame.minX > originalFrame.minX,
        "native mouse drag moves the actual panel and emits begin, change and drop")

        events = []
        sprite.mouseUp(with: try mouse(.leftMouseUp, artwork))
        try check(events.isEmpty, "mouse up without a matching press is ignored")

        fakePointer = panel.convertPoint(toScreen: artwork)
        sprite.tick()
        fakeNow += 4.99
        sprite.tick()
        try check(events.isEmpty, "native hover keeps the pet in place before five seconds")
        fakeNow += 0.01
        sprite.tick()
        try check(events.contains(where: {
            if case .hoverEscapeRequested = $0 { true } else { false }
        }), "native five-second hover requests an animated escape")

        events = []
        panel.orderOut(nil)
        sprite.tick()
        fakeNow += 10
        panel.orderFrontRegardless()
        sprite.tick()
        fakeNow += 4.99
        sprite.tick()
        try check(events.isEmpty, "hidden pet clears the old hover deadline")
        fakeNow += 0.01
        sprite.tick()
        try check(events.contains(where: {
            if case .hoverEscapeRequested = $0 { true } else { false }
        }), "reshown pet starts a fresh five-second hover deadline")
    }
}

private enum InteractionCheckFailure: Error {
    case event
}
