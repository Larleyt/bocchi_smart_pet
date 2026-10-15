import BocchiCore
import Foundation

enum CaptureOutcome: Equatable {
    case shown(visual: Bool)
    case noSpace
    case needsVisualAccess
    case discarded
    case failed(String)
}

@MainActor
final class PlacementSession {
    let overlay: PetOverlay
    private let tracePlacement: Bool
    private(set) var enabled = true
    private(set) var busy = false
    private var previousSystem: SystemSnapshot?
    private var previousBounds: PetRect?
    private var previousScreenBounds: PetRect?
    private var previousVisualAllowed: Bool?
    private var verified: Verification?
    private var activityAreas: [PetRect] = []
    private var relocationPending = false
    private var verificationRequired = false
    private var searchExhausted = false
    private var lastFullCapture = -Double.infinity
    private var manualPlacement: PetRect?
    private var searchOrigin: PetRect?

    private struct Verification {
        let placement: PetRect
        let region: PetRect
        var baseline: PixelFingerprint
        var baselineAt: Double
        var checkedAt: Double
    }

    init(overlay: PetOverlay, tracePlacement: Bool = false) {
        self.overlay = overlay
        self.tracePlacement = tracePlacement
    }

    static func cursorObstacle(_ cursor: PetPoint) -> PetRect {
        PetRect(x: cursor.x - 40, y: cursor.y - 40, width: 80, height: 80)
    }

    func invalidate(preservingVerification: Bool = true) {
        overlay.invalidate(hiding: !preservingVerification)
        if preservingVerification {
            verificationRequired = verified != nil
        } else {
            verified = nil
            verificationRequired = false
            manualPlacement = nil
        }
        searchExhausted = false
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        invalidate(preservingVerification: false)
    }

    @discardableResult
    func input(moved: Bool, contentMoved: Bool) -> Bool {
        if moved && !contentMoved { return false }
        if tracePlacement, contentMoved, verified != nil, !verificationRequired {
            NSLog("Bocchi content movement: fresh local verification requested")
        }
        invalidate()
        return true
    }

    func escape() {
        guard enabled, let placement = overlay.lastPlacement else { return }
        activityAreas.removeAll { $0 == placement }
        activityAreas.append(placement)
        activityAreas = Array(activityAreas.suffix(8))
        relocationPending = true
        invalidate()
    }

    func beginDragging() {
        verified = nil
        invalidate()
    }

    func drop(at placement: PetRect) {
        activityAreas = []
        manualPlacement = placement
        searchOrigin = placement
        verified = nil
        invalidate()
    }

    private static func padded(_ rect: PetRect) -> PetRect {
        PetRect(x: rect.x - 12, y: rect.y - 12, width: rect.width + 24, height: rect.height + 24)
    }

    private static func collides(_ rect: PetRect, with obstacles: [PetRect]) -> Bool {
        obstacles.contains { rect.intersects(padded($0)) }
    }

    private static func region(around rect: PetRect, in screen: PetRect) -> PetRect {
        let area = padded(rect)
        let x = max(screen.x, area.x), y = max(screen.y, area.y)
        return PetRect(x: x, y: y, width: min(screen.maxX, area.maxX) - x,
                       height: min(screen.maxY, area.maxY) - y)
    }

    func refresh(
        bounds: PetRect,
        screenBounds: PetRect,
        visualAllowed: Bool,
        inspect: () async throws -> SystemSnapshot,
        capture: (PetRect) async throws -> PixelSample,
        current: () -> Bool,
        cursor: () -> PetPoint,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) async -> CaptureOutcome {
        guard enabled, !busy, !overlay.isMoving, !overlay.isDragging else { return .discarded }
        busy = true
        defer { busy = false }
        let generation = overlay.generation
        func relevant() -> Bool {
            enabled && !Task.isCancelled && current() && overlay.generation == generation
        }
        func discard() -> CaptureOutcome {
            if overlay.generation == generation { invalidate() }
            return .discarded
        }
        func show(_ rect: PetRect, visual: Bool) -> CaptureOutcome {
            searchOrigin = rect
            let moving = overlay.lastPlacement != nil && overlay.lastPlacement != rect
                && overlay.move(to: rect, generation: generation)
            if !moving {
                overlay.publish(placement: rect, generation: generation)
            }
            return .shown(visual: visual)
        }
        func take(_ region: PetRect) async throws -> PixelSample? {
            let started = now()
            let sample = try await capture(region)
            guard relevant(), now() - started <= 2.5 else { return nil }
            guard sample.bounds == region else { throw SessionError.invalidCaptureRegion }
            return sample
        }
        func remember(_ rect: PetRect, region: PetRect, sample: PixelSample) {
            verified = Verification(placement: rect, region: region, baseline: sample.fingerprint,
                                    baselineAt: now(), checkedAt: now())
        }

        do {
            let started = now()
            let system = try await inspect()
            guard relevant(), now() - started <= 2.5 else { return discard() }
            let boundsChanged = previousBounds != bounds
            let screenChanged = previousScreenBounds != screenBounds
            let windowsChanged = previousSystem?.windows != system.windows
            let visualModeChanged = previousVisualAllowed != visualAllowed
            let contentsChanged = previousSystem?.obstacles != system.obstacles
                || previousSystem?.unknownAreas != system.unknownAreas
                || previousSystem?.accessibilityAvailable != system.accessibilityAvailable
            if screenChanged || visualModeChanged {
                verified = nil
                verificationRequired = false
            } else if boundsChanged || windowsChanged || contentsChanged {
                verificationRequired = verified != nil
            }
            if screenChanged || visualModeChanged {
                searchExhausted = false
                overlay.panel.orderOut(nil)
            } else if boundsChanged || windowsChanged || contentsChanged {
                searchExhausted = false
            }
            if screenChanged || (windowsChanged && !relocationPending) {
                if tracePlacement, !activityAreas.isEmpty {
                    NSLog("Bocchi activity reset: boundsChanged=%d oldWindows=%d newWindows=%d areas=%d",
                          boundsChanged, previousSystem?.windows.count ?? 0, system.windows.count,
                          activityAreas.count)
                }
                activityAreas = []
            }
            relocationPending = false
            previousBounds = bounds
            previousScreenBounds = screenBounds
            previousSystem = system
            previousVisualAllowed = visualAllowed
            let obstacles = system.obstacles + activityAreas
            let searchingObstacles = obstacles + [Self.cursorObstacle(cursor())]
            let origin = manualPlacement ?? (screenChanged ? nil : searchOrigin ?? overlay.lastPlacement)
            let desired = manualPlacement ?? overlay.lastPlacement
            manualPlacement = nil
            if overlay.lastPlacement.map({ Self.collides($0, with: system.obstacles) }) == true {
                overlay.panel.orderOut(nil)
            }
            let previous = !screenChanged && !visualModeChanged ? desired.flatMap {
                bounds.contains($0) && !Self.collides($0, with: obstacles)
                    && (visualAllowed || !Self.collides($0, with: system.unknownAreas)) ? $0 : nil
            } : nil
            if !visualAllowed {
                if let known = PlacementEngine.choose(in: bounds, avoiding: obstacles + system.unknownAreas,
                                                       size: PetOverlay.size, previous: previous,
                                                       nearestTo: origin) {
                    verified = nil
                    verificationRequired = false
                    return show(known, visual: false)
                }
                verified = nil
                verificationRequired = false
                overlay.publish(placement: nil, generation: generation)
                return system.unknownAreas.isEmpty ? .noSpace : .needsVisualAccess
            }
            guard let preferred = PlacementEngine.choose(in: bounds,
                avoiding: previous == nil ? searchingObstacles : obstacles,
                size: PetOverlay.size, previous: previous, nearestTo: origin) else {
                overlay.publish(placement: nil, generation: generation)
                return .noSpace
            }
            if !Self.collides(preferred, with: system.unknownAreas) {
                verified = nil
                verificationRequired = false
                return show(preferred, visual: false)
            }

            if var verification = verified,
               bounds.contains(verification.placement),
               !Self.collides(verification.placement, with: obstacles) {
                let forced = verificationRequired
                if !forced, now() - verification.checkedAt < 5 {
                    return show(verification.placement, visual: true)
                }
                guard let sample = try await take(verification.region) else { return discard() }
                let delta = sample.fingerprint.changedFraction(comparedTo: verification.baseline)
                if let delta, delta < 0.10,
                   !Self.collides(verification.placement, with: sample.obstacles) {
                    verification.checkedAt = now()
                    if now() - verification.baselineAt >= 10 {
                        verification.baseline = sample.fingerprint
                        verification.baselineAt = now()
                    }
                    verified = verification
                    verificationRequired = false
                    if tracePlacement, forced {
                        NSLog("Bocchi content verification: unchanged delta=%.3f", delta)
                    }
                    return show(verification.placement, visual: true)
                }
                if tracePlacement, forced {
                    NSLog("Bocchi content verification: relocation delta=%@ obstacle=%d",
                          delta.map { String(format: "%.3f", $0) } ?? "unavailable",
                          Self.collides(verification.placement, with: sample.obstacles))
                }
                overlay.panel.orderOut(nil)
                activityAreas.append(verification.placement)
                activityAreas = Array(activityAreas.suffix(8))
                verified = nil
                verificationRequired = false
                searchExhausted = false
            } else {
                verified = nil
                verificationRequired = false
            }

            guard !searchExhausted else {
                overlay.publish(placement: nil, generation: generation)
                return .noSpace
            }
            var rejected = activityAreas
            for attempt in 0..<3 {
                let usePreferred = attempt == 0 && !Self.collides(preferred, with: rejected)
                guard let candidate = usePreferred ? preferred : PlacementEngine.choose(
                    in: bounds, avoiding: searchingObstacles + rejected,
                    size: PetOverlay.size, previous: nil, nearestTo: origin) else {
                    if attempt == 0 {
                        overlay.publish(placement: nil, generation: generation)
                        return .noSpace
                    }
                    break
                }
                if !Self.collides(candidate, with: system.unknownAreas) {
                    verificationRequired = false
                    return show(candidate, visual: false)
                }
                let region = Self.region(around: candidate, in: screenBounds)
                guard let sample = try await take(region) else { return discard() }
                if !Self.collides(candidate, with: sample.obstacles) {
                    remember(candidate, region: region, sample: sample)
                    return show(candidate, visual: true)
                }
                rejected.append(contentsOf: sample.obstacles)
            }

            if let known = PlacementEngine.choose(in: bounds,
                avoiding: searchingObstacles + system.unknownAreas + rejected,
                size: PetOverlay.size, previous: nil, nearestTo: origin) {
                verified = nil
                verificationRequired = false
                return show(known, visual: false)
            }

            // A failed search waits for a scene/input change; the timer never repeats full-screen capture.
            searchExhausted = true
            guard now() - lastFullCapture >= 10 else {
                overlay.publish(placement: nil, generation: generation)
                return .noSpace
            }
            lastFullCapture = now()
            guard let map = try await take(screenBounds) else { return discard() }
            guard let candidate = PlacementEngine.choose(in: bounds,
                avoiding: searchingObstacles + map.obstacles, size: PetOverlay.size,
                previous: nil, nearestTo: origin)
            else {
                overlay.publish(placement: nil, generation: generation)
                return .noSpace
            }
            let region = Self.region(around: candidate, in: screenBounds)
            guard let sample = try await take(region) else { return discard() }
            guard !Self.collides(candidate, with: sample.obstacles) else {
                overlay.publish(placement: nil, generation: generation)
                return .noSpace
            }
            remember(candidate, region: region, sample: sample)
            return show(candidate, visual: true)
        } catch {
            guard relevant() else { return discard() }
            invalidate(preservingVerification: false)
            return .failed(error.localizedDescription)
        }
    }
}

private enum SessionError: Error, LocalizedError {
    case invalidCaptureRegion
    var errorDescription: String? { "Захват вернул другую область экрана." }
}
