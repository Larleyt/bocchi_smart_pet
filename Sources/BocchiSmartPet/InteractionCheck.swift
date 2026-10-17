import AppKit
import BocchiCore
import ImageIO

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

        try await crossDisplayRetarget(check)
        try await sameMonitorRelocation(check)

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
        for point in [NSPoint(x: 40, y: 30), NSPoint(x: 80, y: 30),
                      NSPoint(x: 40, y: 82), NSPoint(x: 80, y: 82), NSPoint(x: 60, y: 78)] {
            try await steadyHover(at: point, check)
        }
        try await steadyHover(at: NSPoint(x: 48, y: 40), seated: true, check)
        try await escapeRecovery(check)
        try standingAnimation(check)
    }

    private static func crossDisplayRetarget(
        _ check: (Bool, String) throws -> Void
    ) async throws {
        var now = 500.0
        let overlay = try PetOverlay(clock: { now })
        defer { overlay.stop() }
        let session = PlacementSession(overlay: overlay)
        let oldID: UInt32 = 101
        let newID: UInt32 = 202
        let oldDisplay = PetRect(x: 0, y: 0, width: 900, height: 640)
        let newDisplay = PetRect(x: 1000, y: 900, width: 900, height: 640)
        let fingerprint = try PixelFingerprint(rgb: [UInt8](repeating: 220, count: 64 * 3))

        func refresh(in bounds: PetRect) async -> CaptureOutcome {
            await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
                inspect: { SystemSnapshot(obstacles: [], unknownAreas: [bounds], windows: [],
                    accessibilityAvailable: true) }, capture: { region in
                    PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint)
                }, current: { true }, cursor: { PetPoint(x: -1000, y: -1000) },
                now: { now })
        }

        _ = await refresh(in: oldDisplay)
        guard let oldPlacement = overlay.lastPlacement else {
            try check(false, "cross-display fixture publishes its verified old placement")
            return
        }
        let liveDisplays = [(id: oldID, bounds: oldDisplay), (id: newID, bounds: newDisplay)]
        let keepingVisible = AppDelegate.canKeepVisibleForDisplayRetarget(
            oldDisplayID: oldID, oldBounds: oldDisplay, panelVisible: overlay.panel.isVisible,
            liveDisplays: liveDisplays)
        try check(keepingVisible,
                  "live unchanged old display permits a visible cross-display retarget")
        try check(!AppDelegate.canKeepVisibleForDisplayRetarget(
            oldDisplayID: oldID, oldBounds: oldDisplay, panelVisible: false,
            liveDisplays: liveDisplays), "hidden panel cannot request visible retarget")
        try check(!AppDelegate.canKeepVisibleForDisplayRetarget(
            oldDisplayID: oldID, oldBounds: oldDisplay, panelVisible: true,
            liveDisplays: [(id: newID, bounds: newDisplay)]),
            "removed old display requires a hard hide")
        try check(!AppDelegate.canKeepVisibleForDisplayRetarget(
            oldDisplayID: oldID, oldBounds: oldDisplay, panelVisible: true,
            liveDisplays: [(id: oldID,
                            bounds: PetRect(x: 0, y: 0, width: 800, height: 640))]),
            "changed old display bounds require a hard hide")

        session.invalidate(preservingVerification: false, keepingVisible: keepingVisible)
        try check(overlay.panel.isVisible && overlay.displayedPlacement == oldPlacement,
                  "cross-display state reset keeps the last safe panel visible")
        let outcome = await refresh(in: newDisplay)
        try check(outcome == .shown(visual: true) && overlay.isMoving && overlay.panel.isVisible,
                  "verified new display starts a real cross-display movement")
        now += 0.5
        try await Task.sleep(for: .milliseconds(40))
        let intermediate = overlay.displayedPlacement
        now += 2
        try await Task.sleep(for: .milliseconds(40))
        guard let destination = overlay.lastPlacement, let intermediate else {
            try check(false, "cross-display movement exposes intermediate and final frames")
            return
        }
        try check(intermediate.x > min(oldPlacement.x, destination.x)
                  && intermediate.x < max(oldPlacement.x, destination.x)
                  && intermediate.y > min(oldPlacement.y, destination.y)
                  && intermediate.y < max(oldPlacement.y, destination.y),
                  "cross-display NSPanel crosses real intermediate X and Y")
        try check(!overlay.isMoving && destination != oldPlacement
                  && newDisplay.contains(destination)
                  && ScreenCoordinates.quartz(overlay.panel.frame) == destination,
                  "cross-display movement finishes at the verified new display placement")
    }

    private static func sameMonitorRelocation(
        _ check: (Bool, String) throws -> Void
    ) async throws {
        let bounds = PetRect(x: 0, y: 0, width: 900, height: 640)
        let farCursor = PetPoint(x: -1000, y: -1000)
        let calm = try PixelFingerprint(rgb: [UInt8](repeating: 220, count: 64 * 3))
        let changed = try PixelFingerprint(rgb: [UInt8](repeating: 10, count: 64 * 3))

        func axisBlockers(around placement: PetRect) -> [PetRect] {
            let gap = 13.0
            return [
                PetRect(x: bounds.x, y: placement.y,
                        width: max(0, placement.x - gap - bounds.x), height: placement.height),
                PetRect(x: placement.maxX + gap, y: placement.y,
                        width: max(0, bounds.maxX - placement.maxX - gap), height: placement.height),
                PetRect(x: placement.x, y: bounds.y, width: placement.width,
                        height: max(0, placement.y - gap - bounds.y)),
                PetRect(x: placement.x, y: placement.maxY + gap, width: placement.width,
                        height: max(0, bounds.maxY - placement.maxY - gap)),
            ].filter { $0.width > 0 && $0.height > 0 }
        }
        func finishMovement(_ overlay: PetOverlay, from start: PetRect, now: inout Double,
                            label: String) async throws {
            now += 0.1
            try await Task.sleep(for: .milliseconds(40))
            guard let middle = overlay.displayedPlacement else {
                try check(false, "\(label) exposes an intermediate frame")
                return
            }
            now += 2.4
            try await Task.sleep(for: .milliseconds(40))
            guard let target = overlay.lastPlacement else {
                try check(false, "\(label) exposes its endpoint frame")
                return
            }
            try check(middle.x > min(start.x, target.x) && middle.x < max(start.x, target.x)
                      && middle.y > min(start.y, target.y) && middle.y < max(start.y, target.y),
                      "\(label) crosses real intermediate X and Y")
            try check(!overlay.isMoving && overlay.panel.isVisible
                      && overlay.displayedPlacement == target
                      && ScreenCoordinates.quartz(overlay.panel.frame) == target
                      && bounds.contains(target),
                      "\(label) finishes at its checked endpoint")
        }

        do {
            var now = 700.0
            let overlay = try PetOverlay(clock: { now })
            defer { overlay.stop() }
            let session = PlacementSession(overlay: overlay)
            func refresh(_ obstacles: [PetRect]) async -> CaptureOutcome {
                await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: false,
                    inspect: { SystemSnapshot(obstacles: obstacles, unknownAreas: [], windows: [],
                        accessibilityAvailable: true) }, capture: { region in
                        PixelSample(bounds: region, obstacles: [], fingerprint: calm)
                    }, current: { true }, cursor: { farCursor }, now: { now })
            }
            _ = await refresh([])
            guard let start = overlay.lastPlacement else { throw InteractionCheckFailure.event }
            let relocated = await refresh(axisBlockers(around: start)
                + [PetRect(x: start.x + 24, y: start.y + 24, width: 16, height: 16)])
            try check(relocated == .shown(visual: false) && overlay.isMoving
                      && overlay.panel.isVisible,
                      "AX collision starts a visible forced relocation")
            try await finishMovement(overlay, from: start, now: &now, label: "AX forced relocation")
        }

        do {
            var now = 800.0
            let overlay = try PetOverlay(clock: { now })
            defer { overlay.stop() }
            let session = PlacementSession(overlay: overlay)
            var oldRegion: PetRect?
            var changing = false
            func refresh(_ obstacles: [PetRect]) async -> CaptureOutcome {
                await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
                    inspect: { SystemSnapshot(obstacles: obstacles, unknownAreas: [bounds], windows: [],
                        accessibilityAvailable: true) }, capture: { region in
                        if oldRegion == nil { oldRegion = region }
                        return PixelSample(bounds: region, obstacles: [],
                            fingerprint: changing && region == oldRegion ? changed : calm)
                    }, current: { true }, cursor: { farCursor }, now: { now })
            }
            _ = await refresh([])
            guard let start = overlay.lastPlacement else { throw InteractionCheckFailure.event }
            changing = true
            session.input(moved: false, contentMoved: true)
            let relocated = await refresh(axisBlockers(around: start))
            try check(relocated == .shown(visual: true) && overlay.isMoving
                      && overlay.panel.isVisible,
                      "pixel activity starts a visible forced relocation")
            try await finishMovement(overlay, from: start, now: &now,
                                     label: "pixel forced relocation")
        }

        do {
            let overlay = try PetOverlay()
            defer { overlay.stop() }
            let session = PlacementSession(overlay: overlay)
            _ = await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
                inspect: { SystemSnapshot(obstacles: [], unknownAreas: [], windows: [],
                    accessibilityAvailable: true) }, capture: { region in
                    PixelSample(bounds: region, obstacles: [], fingerprint: calm)
                }, current: { true }, cursor: { farCursor })
            guard let unsafeStart = overlay.lastPlacement else {
                throw InteractionCheckFailure.event
            }
            let support = PerchSupport(
                id: SupportID(windowID: 808, pid: 77, elementToken: 1),
                bounds: PetRect(x: 500, y: 420, width: 300, height: 180),
                spans: [HorizontalSpan(minX: 500, maxX: 800)]
            )
            var perchRegion: PetRect?
            var perchContinuation: CheckedContinuation<PixelSample, Never>?
            let suspended = Task { @MainActor in
                await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
                    inspect: { SystemSnapshot(obstacles: [unsafeStart], unknownAreas: [],
                        windows: [], accessibilityAvailable: true, supports: [support]) },
                    capture: { region in
                        PixelSample(bounds: region, obstacles: [], fingerprint: calm)
                    }, capturePerch: { region, _ in
                        perchRegion = region
                        return await withCheckedContinuation { perchContinuation = $0 }
                    }, current: { true }, cursor: { farCursor })
            }
            for _ in 0..<20 where perchContinuation == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(perchContinuation != nil && session.busy && overlay.panel.isVisible,
                      "AX-unsafe perch fixture suspends inside the alternative support capture")
            try await Task.sleep(for: .milliseconds(2_600))
            let deadlineApplied = !session.busy && !overlay.panel.isVisible
            if !deadlineApplied { session.invalidate(preservingVerification: false) }
            let replacement = PetRect(x: 700, y: 460,
                                      width: PetOverlay.size.width, height: PetOverlay.size.height)
            _ = overlay.publish(placement: replacement, generation: overlay.generation)
            guard let perchRegion else { throw InteractionCheckFailure.event }
            perchContinuation?.resume(returning: PixelSample(
                bounds: perchRegion, obstacles: [], fingerprint: calm,
                supportEdges: [HorizontalSpan(minX: perchRegion.x, maxX: perchRegion.maxX)]
            ))
            let lateOutcome = await suspended.value
            try check(deadlineApplied,
                      "AX collision deadline starts before a suspended alternative perch capture")
            try check(lateOutcome == .discarded && overlay.panel.isVisible
                      && overlay.lastPlacement == replacement && !session.busy,
                      "late alternative perch sample cannot replace newer published state")
        }

        do {
            let overlay = try PetOverlay()
            defer { overlay.stop() }
            let session = PlacementSession(overlay: overlay)
            _ = await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: false,
                inspect: { SystemSnapshot(obstacles: [], unknownAreas: [], windows: [],
                    accessibilityAvailable: true) }, capture: { region in
                    PixelSample(bounds: region, obstacles: [], fingerprint: calm)
                }, current: { true }, cursor: { farCursor })
            guard let start = overlay.lastPlacement else { throw InteractionCheckFailure.event }
            let noSpace = await session.refresh(bounds: bounds, screenBounds: bounds,
                visualAllowed: false, inspect: {
                    SystemSnapshot(obstacles: [bounds], unknownAreas: [], windows: [],
                                   accessibilityAvailable: true)
                }, capture: { region in
                    PixelSample(bounds: region, obstacles: [], fingerprint: calm)
                }, current: { true }, cursor: { farCursor })
            try check(noSpace == .noSpace && !overlay.panel.isVisible
                      && overlay.lastPlacement == nil && start != overlay.lastPlacement,
                      "forced relocation still hides when no checked endpoint exists")
        }

        do {
            var oldRegion: PetRect?
            var changing = false
            var current = true
            let overlay = try PetOverlay()
            defer { overlay.stop() }
            let session = PlacementSession(overlay: overlay)
            func refresh(fails: Bool = false, staleCandidate: Bool = false) async -> CaptureOutcome {
                await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
                    inspect: { SystemSnapshot(obstacles: [], unknownAreas: [bounds], windows: [],
                        accessibilityAvailable: true) }, capture: { region in
                        if oldRegion == nil { oldRegion = region }
                        if fails && changing && region == oldRegion {
                            throw InteractionCheckFailure.capture
                        }
                        if staleCandidate && changing && region != oldRegion { current = false }
                        return PixelSample(bounds: region, obstacles: [],
                            fingerprint: changing && region == oldRegion ? changed : calm)
                    }, current: { current }, cursor: { farCursor })
            }
            _ = await refresh()
            changing = true
            session.input(moved: false, contentMoved: true)
            let failed = await refresh(fails: true)
            try check(ifCaseFailed(failed) && !overlay.panel.isVisible,
                      "capture error hard-hides an unsafe origin")

            session.invalidate(preservingVerification: false)
            current = true
            changing = false
            oldRegion = nil
            _ = await refresh()
            changing = true
            session.input(moved: false, contentMoved: true)
            let stale = await refresh(staleCandidate: true)
            try check(stale == .discarded && !overlay.panel.isVisible,
                      "stale capture hard-hides the unchanged unsafe origin")
        }

        do {
            let overlay = try PetOverlay()
            defer { overlay.stop() }
            let session = PlacementSession(overlay: overlay)
            var oldRegion: PetRect?
            var changing = false
            var continuation: CheckedContinuation<PixelSample, Never>?
            func refresh() async -> CaptureOutcome {
                await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
                    inspect: { SystemSnapshot(obstacles: [], unknownAreas: [bounds], windows: [],
                        accessibilityAvailable: true) }, capture: { region in
                        if oldRegion == nil { oldRegion = region }
                        if changing && region != oldRegion {
                            return await withCheckedContinuation { continuation = $0 }
                        }
                        return PixelSample(bounds: region, obstacles: [],
                            fingerprint: changing ? changed : calm)
                    }, current: { true }, cursor: { farCursor })
            }
            _ = await refresh()
            changing = true
            session.input(moved: false, contentMoved: true)
            let suspended = Task { @MainActor in await refresh() }
            for _ in 0..<20 where continuation == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(continuation != nil && session.busy && overlay.panel.isVisible,
                      "slow-capture fixture suspends after marking the visible origin unsafe")
            try check(session.input(moved: false, contentMoved: true),
                      "ordinary content input invalidates the suspended capture")
            try await Task.sleep(for: .milliseconds(2_600))
            try check(!session.busy && !overlay.panel.isVisible,
                      "one-shot deadline hides the same unsafe origin after stale input and releases session")
            let replacement = PetRect(x: 700, y: 460,
                                      width: PetOverlay.size.width, height: PetOverlay.size.height)
            try check(overlay.publish(placement: replacement, generation: overlay.generation),
                      "new publication proceeds after the suspended refresh deadline")
            continuation?.resume(returning: PixelSample(
                bounds: PetRect(x: 0, y: 0, width: 1, height: 1),
                obstacles: [], fingerprint: calm))
            let oldOutcome = await suspended.value
            try check(oldOutcome == .discarded && overlay.panel.isVisible
                      && overlay.lastPlacement == replacement && !session.busy,
                      "late capture cannot hide or retain ownership of newer state")

            session.invalidate(preservingVerification: false)
            changing = false
            oldRegion = nil
            continuation = nil
            _ = await refresh()
            changing = true
            session.input(moved: false, contentMoved: true)
            let abandoned = Task { @MainActor in await refresh() }
            for _ in 0..<20 where continuation == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(continuation != nil && session.busy && overlay.panel.isVisible,
                      "manual-cancel fixture suspends at an unsafe visible origin")
            session.beginDragging()
            try check(!session.busy && overlay.panel.isVisible,
                      "manual drag revokes the old refresh ownership without hiding")
            try await Task.sleep(for: .milliseconds(2_600))
            try check(overlay.panel.isVisible,
                      "revoked unsafe deadline cannot hide the manual state")
            continuation?.resume(returning: PixelSample(
                bounds: PetRect(x: 0, y: 0, width: 1, height: 1),
                obstacles: [], fingerprint: calm))
            _ = await abandoned.value
            try check(overlay.panel.isVisible && !session.busy,
                      "late capture remains inert after manual ownership change")
        }
    }

    private static func ifCaseFailed(_ outcome: CaptureOutcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }

    private static func standingAnimation(_ check: (Bool, String) throws -> Void) throws {
        var fakeNow = 100.0
        var fakePointer = NSPoint.zero
        let sprite = try SpriteView(pointer: { fakePointer }, clock: { fakeNow }, startsTimer: false)
        defer { sprite.stop() }
        let panel = PetPanel(contentRect: NSRect(x: 180, y: 180, width: 120, height: 156),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = sprite
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let frame = panel.frame
        let atlasURL = Bundle.main.url(forResource: "bocchi-spritesheet", withExtension: "png")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Assets/bocchi-spritesheet.png")
        guard let source = CGImageSourceCreateWithURL(atlasURL as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AtlasError.invalidAsset
        }
        let reference = StandingFrameFixtureView(frame: sprite.bounds)
        func rendered(_ view: NSView) throws -> Data {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw InteractionCheckFailure.event
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw InteractionCheckFailure.event
            }
            return png
        }
        // Eye midpoint measured in the unchanged atlas, after its crop and 0.75 scale.
        let eyes = NSPoint(x: 62.25, y: 39)
        let targets: [(NSPoint, Int?, String)] = [
            (NSPoint(x: 0, y: -40), 0, "above"),
            (NSPoint(x: 40, y: -40), 2, "upper right"),
            (NSPoint(x: 40, y: 0), 4, "right at eye height"),
            (NSPoint(x: 40, y: 40), 6, "lower right"),
            (NSPoint(x: 0, y: 12), 8, "below eyes but above the hoodie center"),
            (NSPoint(x: -40, y: 40), 10, "lower left"),
            (NSPoint(x: -40, y: 0), 12, "left at eye height"),
            (NSPoint(x: -40, y: -40), 14, "upper left"),
            (NSPoint(x: 0, y: -299), 0, "299pt above the eyes inside gaze range"),
            (NSPoint(x: 0, y: 300), nil, "300pt below the eyes at the idle boundary"),
            (NSPoint(x: 0, y: 301), nil, "301pt below the eyes outside gaze range")]
        for (offset, index, label) in targets {
            fakePointer = panel.convertPoint(toScreen: sprite.convert(
                NSPoint(x: eyes.x + offset.x, y: eyes.y + offset.y), to: nil))
            sprite.tick()
            let column = index.map { $0 % 8 } ?? 0
            let row = index.map { 9 + $0 / 8 } ?? 0
            guard let image = atlas.cropping(to: CGRect(x: column * 192 + 40,
                y: row * 208, width: 112, height: 208)) else {
                throw AtlasError.invalidAsset
            }
            reference.image = NSImage(cgImage: image, size: NSSize(width: 112, height: 208))
            let actual = try rendered(sprite)
            panel.contentView = reference
            let expected = try rendered(reference)
            panel.contentView = sprite
            try check(actual == expected,
                      "gaze uses the eye midpoint for a cursor \(label)")
        }
        try check(panel.frame == frame && sprite.bounds == reference.bounds,
                  "eye-based gaze preserves the hoodie-centered panel and sprite geometry")

        fakePointer = NSPoint(x: -10_000, y: -10_000)
        let idleTargets: [(Double, Int, String)] = [
            (0.001, 0, "starts with the first calm open frame"),
            (2.999, 0, "keeps the first calm open frame for three seconds"),
            (3.001, 1, "enters the first short blink after the calm pause"),
            (3.119, 1, "keeps the first blink under 0.12 seconds"),
            (3.121, 2, "shows the first brief head gesture after the blink"),
            (3.519, 2, "keeps the first head gesture for 0.4 seconds"),
            (3.521, 3, "returns to the second calm open frame"),
            (6.519, 3, "keeps the second calm open frame for three seconds"),
            (6.521, 4, "enters the second short blink after the calm pause"),
            (6.639, 4, "keeps the second blink under 0.12 seconds"),
            (6.641, 5, "shows the second brief head gesture after the blink"),
            (7.039, 5, "keeps the second head gesture for 0.4 seconds"),
            (7.041, 0, "wraps the calm idle cycle back to its first frame")]
        for (offset, column, label) in idleTargets {
            fakeNow = 100 + offset
            sprite.tick()
            guard let image = atlas.cropping(to: CGRect(
                x: column * 192 + 40, y: 0, width: 112, height: 208
            )) else { throw AtlasError.invalidAsset }
            reference.image = NSImage(cgImage: image, size: NSSize(width: 112, height: 208))
            let actual = try rendered(sprite)
            panel.contentView = reference
            let expected = try rendered(reference)
            panel.contentView = sprite
            try check(actual == expected, "standing animation \(label)")
        }
    }

    private static func escapeRecovery(_ check: (Bool, String) throws -> Void) async throws {
        var fakeNow = 200.0
        var fakePointer = NSPoint(x: -1000, y: -1000)
        let overlay = try PetOverlay(clock: { fakeNow }, pointer: { fakePointer })
        defer { overlay.stop() }
        guard let sprite = overlay.panel.contentView as? SpriteView else {
            throw InteractionCheckFailure.event
        }
        let session = PlacementSession(overlay: overlay)
        var bounds = PetRect(x: 0, y: 0, width: 900, height: 640)
        var visual = true
        var windows: [WindowRegion] = []
        var fresh = true
        var staleCapture = false
        var escapes = 0
        var fingerprint = try PixelFingerprint(rgb: [UInt8](repeating: 220, count: 64 * 3))
        overlay.onInteraction = { event in
            switch event {
            case .hoverEscapeRequested:
                escapes += 1
                session.escape()
            case .movementEnded: session.invalidate()
            default: break
            }
        }
        func refresh() async -> CaptureOutcome {
            fresh = true
            return await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: visual,
                inspect: { SystemSnapshot(obstacles: [], unknownAreas: visual ? [bounds] : [],
                    windows: windows, accessibilityAvailable: true) }, capture: { region in
                    if staleCapture { fresh = false }
                    return PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint)
                }, current: { fresh }, cursor: {
                    PetPoint(x: fakePointer.x, y: ScreenCoordinates.primaryHeight - fakePointer.y)
                }, now: { fakeNow })
        }
        func hover() {
            fakePointer = NSPoint(x: -1000, y: -1000)
            sprite.tick()
            fakePointer = overlay.panel.convertPoint(toScreen:
                sprite.convert(NSPoint(x: 40, y: 30), to: nil))
            sprite.tick()
            fakeNow += 5
            sprite.tick()
        }
        func finishMovement() async throws {
            fakeNow += 2
            try await Task.sleep(for: .milliseconds(40))
        }
        _ = await refresh()
        let original = overlay.lastPlacement
        hover()
        staleCapture = true
        let stale = await refresh()
        try check(escapes == 1 && stale == .discarded && overlay.panel.isVisible,
                  "actual hover escape survives an external capture becoming stale")
        staleCapture = false
        windows = [WindowRegion(id: 91, pid: 77,
            bounds: PetRect(x: 880, y: 620, width: 1, height: 1))]
        _ = await refresh()
        try check(overlay.isMoving,
                  "unrelated window churn cannot cancel a pending hover escape")
        try await finishMovement()
        try check(overlay.lastPlacement != original && overlay.panel.isVisible && !overlay.isMoving,
                  "escape after stale capture reaches a different actual panel position")

        session.invalidate(preservingVerification: false)
        bounds = PetRect(x: 0, y: 0, width: 300, height: 156)
        windows = []
        visual = false
        fakePointer = NSPoint(x: -1000, y: -1000)
        _ = await refresh()
        let firstSlot = overlay.lastPlacement
        for attempt in 1...3 {
            let previous = overlay.lastPlacement
            hover()
            let result = await refresh()
            try check(result == .shown(visual: false) && overlay.isMoving && overlay.panel.isVisible,
                      "two-slot scene starts hover escape \(attempt) without exhausting safe places")
            try await finishMovement()
            try check(overlay.lastPlacement != previous && overlay.panel.isVisible && !overlay.isMoving,
                      "two-slot escape \(attempt) finishes as a visible run")
            if attempt == 2 {
                try check(overlay.lastPlacement == firstSlot,
                          "a previous voluntary departure does not mark that safe place as pixel activity")
            }
        }
        let beforeReset = overlay.lastPlacement
        hover()
        session.invalidate(preservingVerification: false)
        fakePointer = NSPoint(x: -1000, y: -1000)
        _ = await refresh()
        try check(overlay.lastPlacement == beforeReset && overlay.panel.isVisible && !overlay.isMoving,
                  "hard reset cancels an unfulfilled hover escape")
        hover()
        session.beginDragging()
        guard let drop = overlay.lastPlacement else { throw InteractionCheckFailure.event }
        session.drop(at: drop)
        fakePointer = NSPoint(x: -1000, y: -1000)
        _ = await refresh()
        try check(overlay.lastPlacement == drop && overlay.panel.isVisible && !overlay.isMoving,
                  "manual drag and drop overrides an unfulfilled hover escape")

        visual = true
        _ = await refresh()
        let activeSlot = overlay.lastPlacement
        fingerprint = try PixelFingerprint(rgb: [UInt8](repeating: 10, count: 64 * 3))
        session.invalidate()
        _ = await refresh()
        try await finishMovement()
        try check(overlay.lastPlacement != activeSlot && overlay.panel.isVisible,
                  "real fingerprint activity moves the pet out of that slot")
        let pendingOrigin = overlay.lastPlacement
        hover()
        let noSafeSlot = await refresh()
        try check(noSafeSlot == .noSpace && !overlay.panel.isVisible,
                  "hover escape still refuses a slot excluded by actual pixel activity")
        fakePointer = NSPoint(x: -1000, y: -1000)
        windows = [WindowRegion(id: 92, pid: 77,
            bounds: PetRect(x: 290, y: 140, width: 1, height: 1))]
        let retry = await refresh()
        try check(retry == .shown(visual: true) && overlay.panel.isVisible
                  && overlay.lastPlacement == activeSlot && overlay.lastPlacement != pendingOrigin,
                  "pending escape survives noSpace even after the cursor leaves and the scene changes")
    }

    private static func steadyHover(at point: NSPoint, seated: Bool = false,
                                    _ check: (Bool, String) throws -> Void) async throws {
        var fakeNow = 100.0
        var fakePointer = NSPoint.zero
        let overlay = try PetOverlay(clock: { fakeNow }, pointer: { fakePointer })
        defer { overlay.stop() }
        guard let sprite = overlay.panel.contentView as? SpriteView else {
            throw InteractionCheckFailure.event
        }
        let session = PlacementSession(overlay: overlay)
        let bounds = PetRect(x: 0, y: 0, width: 900, height: 640)
        let support = PerchSupport(id: SupportID(windowID: 501, pid: 77, elementToken: 501),
            bounds: PetRect(x: 100, y: 300, width: 700, height: 340),
            spans: [HorizontalSpan(minX: 100, maxX: 800)])
        let fakeSystem = SystemSnapshot(obstacles: [], unknownAreas: [bounds],
            windows: [], accessibilityAvailable: true, supports: seated ? [support] : [])
        let fingerprint = try PixelFingerprint(rgb: [UInt8](repeating: 220, count: 64 * 3))
        func refresh() async -> CaptureOutcome {
            await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
                inspect: { fakeSystem }, capture: { region in
                    PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint)
                }, capturePerch: { region, _ in
                    PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint,
                                supportEdges: [HorizontalSpan(minX: region.x, maxX: region.maxX)])
                }, current: { true }, cursor: {
                    PetPoint(x: fakePointer.x, y: ScreenCoordinates.primaryHeight - fakePointer.y)
                }, now: { fakeNow })
        }
        func rendered() -> Data? {
            guard let bitmap = sprite.bitmapImageRepForCachingDisplay(in: sprite.bounds) else { return nil }
            sprite.cacheDisplay(in: sprite.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        var escapes = 0
        var movementEnds = 0
        overlay.onInteraction = { event in
            switch event {
            case .hoverEscapeRequested:
                escapes += 1
                session.escape()
            case .movementEnded:
                movementEnds += 1
                session.invalidate()
            default: break
            }
        }
        _ = await refresh()
        if seated {
            fakeNow += 1
            try await Task.sleep(for: .milliseconds(40))
            try check(overlay.isSitting && !overlay.isMoving,
                      "hover fixture reaches the actual seated pose through the session")
            movementEnds = 0
        }
        guard let start = overlay.lastPlacement else { throw InteractionCheckFailure.event }
        fakePointer = overlay.panel.convertPoint(toScreen:
            sprite.convert(NSPoint(x: 1, y: 1), to: nil))
        sprite.tick()
        fakeNow += 6
        sprite.tick()
        try check(escapes == 0 && overlay.panel.ignoresMouseEvents,
                  "six seconds on transparent pixels neither intercept input nor trigger escape")
        fakePointer = overlay.panel.convertPoint(toScreen:
            sprite.convert(point, to: nil))
        sprite.tick()
        guard let bitmap = sprite.bitmapImageRepForCachingDisplay(in: sprite.bounds) else {
            throw InteractionCheckFailure.event
        }
        sprite.cacheDisplay(in: sprite.bounds, to: bitmap)
        let alpha = bitmap.colorAt(x: Int(point.x * Double(bitmap.pixelsWide) / sprite.bounds.width),
                                   y: Int(point.y * Double(bitmap.pixelsHigh) / sprite.bounds.height))?
            .alphaComponent ?? 0
        try check(alpha > 0.95 && sprite.artworkContains(point),
                  "hover fixture \(point) is visibly opaque and receives input")
        let gaze = rendered()
        let repeated = await refresh()
        try check(gaze != nil && gaze == rendered() && repeated == .shown(visual: true)
                  && overlay.panel.isVisible && !overlay.isMoving,
                  "unchanged session refresh preserves the rendered off-center gaze without flashing")
        let hoveredAt = fakeNow
        for step in 1...100 {
            fakeNow = hoveredAt + Double(step) * 0.05
            sprite.tick()
            if step < 100 && step % 10 == 0 { _ = await refresh() }
            if step == 99 {
                try check(escapes == 0 && overlay.lastPlacement == start && !overlay.isMoving,
                          "off-center hover stays stationary through repeated refreshes before five seconds")
            }
        }
        try check(escapes == 1, "off-center native hover reaches the session once at five seconds")
        _ = await refresh()
        try check(overlay.isMoving && overlay.panel.isVisible && !overlay.isPerched,
                  "off-center hover starts an actual visible escape through PlacementSession")
        fakeNow += 0.15
        try await Task.sleep(for: .milliseconds(40))
        let intermediate = overlay.displayedPlacement
        try check(overlay.isMoving && intermediate != start && overlay.panel.isVisible,
                  "off-center escape crosses a real intermediate NSPanel position")
        fakeNow += 2
        try await Task.sleep(for: .milliseconds(40))
        _ = await refresh()
        try check(!overlay.isMoving && overlay.panel.isVisible && overlay.lastPlacement != start
                  && movementEnds == 1 && escapes == 1,
                  "off-center escape finishes once and remains visible after revalidation")
    }
}

private enum InteractionCheckFailure: Error {
    case event
    case capture
}

@MainActor
private final class StandingFrameFixtureView: NSView {
    var image: NSImage?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: NSRect(x: 18, y: 0, width: 84, height: 156), from: .zero,
                    operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
    }
}
