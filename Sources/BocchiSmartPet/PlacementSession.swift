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
    private enum SearchState {
        case ready
        case waitingForFullCapture(until: Double)
        case exhausted
    }
    private var searchState = SearchState.ready
    private var lastFullCapture = -Double.infinity
    private var manualPlacement: PetRect?
    private var searchOrigin: PetRect?
    private struct Attachment {
        let supportID: SupportID
        let offsetX: Double
    }
    private var attachment: Attachment?
    private var perchSearchFinished = false
    private var perchingSuppressed = false
    private struct RejectedPerch {
        let supportID: SupportID
        let supportBounds: PetRect
        let supportSpans: [HorizontalSpan]
        let placement: PetRect
    }
    private var rejectedPerches: [RejectedPerch] = []
    private static let perchSize = PetSize(width: 128, height: 156)
    private static let seatOffset = 112.0

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
            attachment = nil
            perchSearchFinished = false
            perchingSuppressed = false
            rejectedPerches = []
        }
        searchState = .ready
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
        if contentMoved {
            perchSearchFinished = false
            rejectedPerches = []
        }
        invalidate()
        return true
    }

    func escape() {
        guard enabled, let placement = overlay.lastPlacement else { return }
        detachPerch()
        perchingSuppressed = true
        activityAreas.removeAll { $0 == placement }
        activityAreas.append(placement)
        activityAreas = Array(activityAreas.suffix(8))
        relocationPending = true
        invalidate()
    }

    func beginDragging() {
        detachPerch()
        perchingSuppressed = true
        verified = nil
        invalidate()
    }

    func drop(at placement: PetRect) {
        activityAreas = []
        detachPerch()
        perchingSuppressed = true
        manualPlacement = Self.standingOrigin(placement)
        searchOrigin = manualPlacement
        verified = nil
        invalidate()
    }

    private func detachPerch() {
        if attachment != nil {
            verified = nil
            verificationRequired = false
        }
        attachment = nil
        overlay.leavePerch()
    }

    private static func standingOrigin(_ rect: PetRect) -> PetRect {
        PetRect(x: rect.x + (rect.width - PetOverlay.size.width) / 2, y: rect.y,
                width: PetOverlay.size.width, height: PetOverlay.size.height)
    }

    private static func padded(_ rect: PetRect) -> PetRect {
        PetRect(x: rect.x - 12, y: rect.y - 12, width: rect.width + 24, height: rect.height + 24)
    }

    private static func collides(_ rect: PetRect, with obstacles: [PetRect]) -> Bool {
        obstacles.contains { rect.intersects(padded($0)) }
    }

    private static func hasSupportEdge(for rect: PetRect, in spans: [HorizontalSpan]) -> Bool {
        spans.contains { $0.minX <= rect.x + 1 && $0.maxX >= rect.maxX - 1 }
    }

    private static func changedRects(_ previous: [PetRect], _ current: [PetRect]) -> [PetRect] {
        func ordered(_ lhs: PetRect, _ rhs: PetRect) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            return lhs.height < rhs.height
        }
        let old = previous.sorted(by: ordered)
        let new = current.sorted(by: ordered)
        var changed: [PetRect] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count, newIndex < new.count {
            if old[oldIndex] == new[newIndex] {
                oldIndex += 1
                newIndex += 1
            } else if ordered(old[oldIndex], new[newIndex]) {
                changed.append(old[oldIndex])
                oldIndex += 1
            } else {
                changed.append(new[newIndex])
                newIndex += 1
            }
        }
        changed.append(contentsOf: old[oldIndex...])
        changed.append(contentsOf: new[newIndex...])
        return changed
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
        capturePerch: ((PetRect, Double) async throws -> PixelSample)? = nil,
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
        func take(_ region: PetRect, supportEdgeY: Double? = nil) async throws -> PixelSample? {
            let started = now()
            let sample: PixelSample
            if let supportEdgeY, let capturePerch {
                sample = try await capturePerch(region, supportEdgeY)
            } else {
                sample = try await capture(region)
            }
            guard relevant(), now() - started <= 2.5 else { return nil }
            guard sample.bounds == region else { throw SessionError.invalidCaptureRegion }
            if tracePlacement {
                let largest = sample.obstacles.max { $0.width * $0.height < $1.width * $1.height }
                NSLog("Bocchi visual geometry: region=%@ obstacles=%d largest=%@", String(describing: region),
                      sample.obstacles.count, String(describing: largest))
            }
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
            let supportsChanged = previousSystem?.supports != system.supports
            let contentsChanged = previousSystem?.obstacles != system.obstacles
                || previousSystem?.unknownAreas != system.unknownAreas
                || previousSystem?.accessibilityAvailable != system.accessibilityAvailable
            if screenChanged || visualModeChanged {
                verified = nil
                verificationRequired = false
                detachPerch()
            } else if boundsChanged || windowsChanged || contentsChanged {
                verificationRequired = verified != nil
            }
            if screenChanged || visualModeChanged || boundsChanged {
                perchSearchFinished = false
                rejectedPerches = []
            } else if supportsChanged || contentsChanged {
                perchSearchFinished = false
                if !rejectedPerches.isEmpty {
                    var supportsByID: [SupportID: PerchSupport] = [:]
                    for support in system.supports { supportsByID[support.id] = support }
                    let changedGeometry = Self.changedRects(
                        (previousSystem?.obstacles ?? []) + (previousSystem?.unknownAreas ?? []),
                        system.obstacles + system.unknownAreas
                    )
                    rejectedPerches.removeAll { rejected in
                        guard let support = supportsByID[rejected.supportID],
                              support.bounds == rejected.supportBounds,
                              support.spans == rejected.supportSpans else { return true }
                        let area = Self.padded(rejected.placement)
                        return changedGeometry.contains { area.intersects($0) }
                    }
                }
            }
            if supportsChanged && attachment == nil { perchingSuppressed = false }
            if screenChanged || visualModeChanged {
                searchState = .ready
                overlay.panel.orderOut(nil)
            } else if boundsChanged || windowsChanged || contentsChanged {
                searchState = .ready
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

            if !perchingSuppressed, attachment != nil || !perchSearchFinished {
                var candidates = system.supports.filter {
                    visualAllowed || !$0.requiresVisualVerification
                }
                var perchOrigin = overlay.lastPlacement
                if let attachment,
                   let support = candidates.first(where: { $0.id == attachment.supportID }) {
                    candidates = [support]
                    perchOrigin = PetRect(x: support.bounds.x + attachment.offsetX,
                        y: support.bounds.y - Self.seatOffset,
                        width: Self.perchSize.width, height: Self.perchSize.height)
                } else if attachment != nil {
                    detachPerch()
                }
                var blocked = system.obstacles + activityAreas
                    + rejectedPerches.map(\.placement)
                if !visualAllowed { blocked += system.unknownAreas }
                let cursorBlock = attachment == nil ? Self.cursorObstacle(cursor()) : nil
                for _ in 0..<3 {
                    guard let candidate = SupportGeometry.choose(in: bounds,
                        avoiding: (blocked + [cursorBlock].compactMap { $0 }).map(Self.padded),
                        size: Self.perchSize,
                        seatOffset: Self.seatOffset, supports: candidates, nearestTo: perchOrigin),
                          let support = candidates.first(where: { $0.id == candidate.supportID }) else { break }
                    let rect = candidate.placement
                    let requiresPixels = support.requiresVisualVerification
                        || (visualAllowed && Self.collides(rect, with: system.unknownAreas))
                    if requiresPixels {
                        let region = Self.region(around: rect, in: screenBounds)
                        let reuse = verified.map { $0.placement == rect
                            && !verificationRequired && now() - $0.checkedAt < 5
                            && (!support.requiresVisualVerification
                                || attachment?.supportID == candidate.supportID) } ?? false
                        if !reuse {
                            guard let sample = try await take(region, supportEdgeY: support.bounds.y)
                            else { return discard() }
                            let active = verified.map { verification in
                                verification.placement == rect
                                    && (sample.fingerprint.changedFraction(comparedTo: verification.baseline) ?? 1) >= 0.10
                            } ?? false
                            let missingSupportEdge = support.requiresVisualVerification
                                && !Self.hasSupportEdge(for: rect, in: sample.supportEdges)
                            if Self.collides(rect, with: sample.obstacles) || active
                                || missingSupportEdge {
                                blocked += sample.obstacles
                                blocked.append(rect)
                                rejectedPerches.append(RejectedPerch(
                                    supportID: support.id, supportBounds: support.bounds,
                                    supportSpans: support.spans, placement: rect
                                ))
                                continue
                            }
                            remember(rect, region: region, sample: sample)
                            verificationRequired = false
                        }
                    } else {
                        verified = nil
                        verificationRequired = false
                    }
                    let following = attachment?.supportID == candidate.supportID && overlay.isSitting
                    attachment = Attachment(supportID: candidate.supportID,
                        offsetX: rect.x - support.bounds.x)
                    rejectedPerches = []
                    searchOrigin = rect
                    if following {
                        overlay.followPerch(at: rect, generation: generation)
                    } else {
                        overlay.perch(at: rect, generation: generation)
                    }
                    if tracePlacement {
                        NSLog("Bocchi perch: window=%u element=%d following=%d position=%@",
                              candidate.supportID.windowID,
                              candidate.supportID.elementToken == nil ? 0 : 1,
                              following, String(describing: rect))
                    }
                    return .shown(visual: requiresPixels)
                }
                let remaining = SupportGeometry.choose(in: bounds,
                    avoiding: (blocked + [cursorBlock].compactMap { $0 }).map(Self.padded),
                    size: Self.perchSize, seatOffset: Self.seatOffset,
                    supports: candidates, nearestTo: perchOrigin) != nil
                let blockedOnlyByCursor = cursorBlock != nil && !remaining
                    && SupportGeometry.choose(in: bounds, avoiding: blocked.map(Self.padded),
                        size: Self.perchSize, seatOffset: Self.seatOffset,
                        supports: candidates, nearestTo: perchOrigin) != nil
                perchSearchFinished = !remaining && !blockedOnlyByCursor
                detachPerch()
            }
            let obstacles = system.obstacles + activityAreas
            let searchingObstacles = obstacles + [Self.cursorObstacle(cursor())]
            let origin = (manualPlacement ?? (screenChanged ? nil : searchOrigin ?? overlay.lastPlacement))
                .map(Self.standingOrigin)
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
                searchState = .ready
            } else {
                verified = nil
                verificationRequired = false
            }

            switch searchState {
            case .ready:
                break
            case .waitingForFullCapture(let until) where now() >= until:
                searchState = .ready
            default:
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

            guard now() - lastFullCapture >= 10 else {
                searchState = .waitingForFullCapture(until: lastFullCapture + 10)
                overlay.publish(placement: nil, generation: generation)
                return .noSpace
            }
            lastFullCapture = now()
            guard let map = try await take(screenBounds) else { return discard() }
            // A completed failed search waits for a scene/input change, never for the timer alone.
            searchState = .exhausted
            for _ in 0..<3 {
                guard let candidate = PlacementEngine.choose(in: bounds,
                    avoiding: searchingObstacles + map.obstacles + rejected, size: PetOverlay.size,
                    previous: nil, nearestTo: origin) else { break }
                let region = Self.region(around: candidate, in: screenBounds)
                guard let sample = try await take(region) else { return discard() }
                if !Self.collides(candidate, with: sample.obstacles) {
                    remember(candidate, region: region, sample: sample)
                    searchState = .ready
                    return show(candidate, visual: true)
                }
                rejected.append(contentsOf: sample.obstacles)
            }
            overlay.publish(placement: nil, generation: generation)
            return .noSpace
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
