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
    private(set) var enabled = true
    private(set) var busy = false
    private var previousSystem: SystemSnapshot?
    private var previousBounds: PetRect?
    private var verified: Verification?
    private var activityAreas: [PetRect] = []
    private var searchExhausted = false
    private var lastFullCapture = -Double.infinity

    private struct Verification {
        let placement: PetRect
        let region: PetRect
        var baseline: PixelFingerprint
        var baselineAt: Double
        var checkedAt: Double
    }

    init(overlay: PetOverlay) { self.overlay = overlay }

    static func cursorObstacle(_ cursor: PetPoint) -> PetRect {
        PetRect(x: cursor.x - 40, y: cursor.y - 40, width: 80, height: 80)
    }

    func invalidate() {
        overlay.invalidate()
        verified = nil
        searchExhausted = false
    }

    func setEnabled(_ enabled: Bool) { self.enabled = enabled; invalidate() }

    @discardableResult
    func input(moved: Bool, cursor: PetPoint) -> Bool {
        if moved {
            guard overlay.panel.isVisible, let placement = overlay.lastPlacement,
                  Self.collides(placement, with: [Self.cursorObstacle(cursor)]) else { return false }
        }
        invalidate()
        return true
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
        guard enabled, !busy else { return .discarded }
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
            overlay.publish(placement: rect, generation: generation)
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
            let sceneChanged = previousBounds != bounds || previousSystem?.windows != system.windows
            let contentsChanged = previousSystem?.obstacles != system.obstacles
                || previousSystem?.unknownAreas != system.unknownAreas
                || previousSystem?.accessibilityAvailable != system.accessibilityAvailable
            if sceneChanged || contentsChanged {
                verified = nil
                searchExhausted = false
                overlay.panel.orderOut(nil)
            }
            if sceneChanged { activityAreas = [] }
            previousBounds = bounds
            previousSystem = system
            let obstacles = system.obstacles + [Self.cursorObstacle(cursor())] + activityAreas
            if let known = PlacementEngine.choose(in: bounds, avoiding: obstacles + system.unknownAreas,
                                                   size: PetOverlay.size, previous: overlay.lastPlacement) {
                verified = nil
                return show(known, visual: false)
            }
            if system.unknownAreas.isEmpty {
                overlay.publish(placement: nil, generation: generation)
                return .noSpace
            }
            guard visualAllowed else {
                verified = nil
                overlay.publish(placement: nil, generation: generation)
                return system.unknownAreas.isEmpty ? .noSpace : .needsVisualAccess
            }

            if var verification = verified,
               bounds.contains(verification.placement),
               !Self.collides(verification.placement, with: obstacles) {
                if now() - verification.checkedAt < 5 {
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
                    return show(verification.placement, visual: true)
                }
                overlay.panel.orderOut(nil)
                activityAreas.append(verification.placement)
                activityAreas = Array(activityAreas.suffix(8))
                verified = nil
                searchExhausted = false
            } else { verified = nil }

            guard !searchExhausted else {
                overlay.publish(placement: nil, generation: generation)
                return .noSpace
            }
            var rejected = activityAreas
            for attempt in 0..<3 {
                guard let candidate = PlacementEngine.choose(in: bounds, avoiding: obstacles + rejected,
                    size: PetOverlay.size, previous: nil) else {
                    if attempt == 0 {
                        overlay.publish(placement: nil, generation: generation)
                        return .noSpace
                    }
                    break
                }
                let region = Self.region(around: candidate, in: screenBounds)
                guard let sample = try await take(region) else { return discard() }
                if !Self.collides(candidate, with: sample.obstacles) {
                    remember(candidate, region: region, sample: sample)
                    return show(candidate, visual: true)
                }
                rejected.append(candidate)
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
                avoiding: obstacles + activityAreas + map.obstacles, size: PetOverlay.size, previous: nil)
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
            invalidate()
            return .failed(error.localizedDescription)
        }
    }
}

private enum SessionError: Error, LocalizedError {
    case invalidCaptureRegion
    var errorDescription: String? { "Захват вернул другую область экрана." }
}
