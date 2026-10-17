import BocchiCore
import Foundation

enum CaptureOutcome: Equatable {
    case shown(visual: Bool)
    case noSpace
    case needsVisualAccess
    case discarded
    case failed(String)
}

enum LiveWindowFollowOutcome: Equatable {
    case notApplicable
    case throttled
    case unchanged
    case followed
    case stopped
}

@MainActor
final class PlacementSession {
    let overlay: PetOverlay
    private let tracePlacement: Bool
    private(set) var enabled = true
    private var nextRefreshID: UInt64 = 0
    private var activeRefreshID: UInt64?
    var busy: Bool { activeRefreshID != nil }
    private var previousSystem: SystemSnapshot?
    private var previousBounds: PetRect?
    private var previousScreenBounds: PetRect?
    private var previousVisualAllowed: Bool?
    private var verified: Verification?
    private var activityAreas: [PetRect] = []
    private var pendingEscapeOrigin: PetRect?
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
        let supportBounds: PetRect
        let supportSpans: [HorizontalSpan]
        let ownerBounds: PetRect?
        let placement: PetRect
    }
    private var attachment: Attachment?
    private var lastLiveFollowRead = -Double.infinity
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

    func invalidate(preservingVerification: Bool = true, keepingVisible: Bool = false) {
        overlay.invalidate(hiding: !preservingVerification && !keepingVisible)
        if preservingVerification {
            verificationRequired = verified != nil
        } else {
            activeRefreshID = nil
            verified = nil
            verificationRequired = false
            manualPlacement = nil
            pendingEscapeOrigin = nil
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
        activeRefreshID = nil
        detachPerch()
        perchingSuppressed = true
        pendingEscapeOrigin = placement
        invalidate()
    }

    func beginDragging() {
        activeRefreshID = nil
        pendingEscapeOrigin = nil
        detachPerch()
        perchingSuppressed = true
        verified = nil
        invalidate()
    }

    func drop(at placement: PetRect) {
        activeRefreshID = nil
        pendingEscapeOrigin = nil
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
        lastLiveFollowRead = -Double.infinity
        overlay.leavePerch()
    }

    func followAttachedWindow(
        in bounds: PetRect,
        screenBounds: PetRect,
        cachedWindows: [WindowRegion],
        readOwner: (UInt32, Int32) throws -> WindowRegion?,
        now: () -> Double
    ) -> LiveWindowFollowOutcome {
        guard enabled, !busy, !overlay.isMoving, !overlay.isDragging,
              let current = attachment, let oldOwner = current.ownerBounds,
              overlay.isSitting else { return .notApplicable }
        let time = now()
        guard time - lastLiveFollowRead >= 1.0 / 60.0 else { return .throttled }
        lastLiveFollowRead = time

        let owner: WindowRegion
        do {
            guard let value = try readOwner(current.supportID.windowID, current.supportID.pid) else {
                detachPerch()
                perchSearchFinished = false
                return .stopped
            }
            owner = value
        } catch {
            if tracePlacement {
                NSLog("Bocchi live follow metadata failed: %@", error.localizedDescription)
            }
            detachPerch()
            perchSearchFinished = false
            return .stopped
        }
        guard owner.id == current.supportID.windowID,
              owner.pid == current.supportID.pid,
              owner.isOpaque,
              owner.rawBounds.width == oldOwner.width,
              owner.rawBounds.height == oldOwner.height,
              let ownerIndex = cachedWindows.firstIndex(where: {
                  $0.id == owner.id && $0.pid == owner.pid
              }) else {
            detachPerch()
            perchSearchFinished = false
            return .stopped
        }

        let dx = owner.rawBounds.x - oldOwner.x
        let dy = owner.rawBounds.y - oldOwner.y
        guard dx != 0 || dy != 0 else { return .unchanged }
        func translated(_ rect: PetRect) -> PetRect {
            PetRect(x: rect.x + dx, y: rect.y + dy,
                    width: rect.width, height: rect.height)
        }
        let placement = translated(current.placement)
        let supportBounds = translated(current.supportBounds)
        let support = PerchSupport(
            id: current.supportID,
            bounds: supportBounds,
            spans: current.supportSpans.map {
                HorizontalSpan(minX: $0.minX + dx, maxX: $0.maxX + dx)
            },
            foregroundOcclusions: cachedWindows.prefix(ownerIndex).map(\.bounds)
        )
        let candidate = SupportGeometry.choose(
            in: bounds, avoiding: [], size: Self.perchSize,
            seatOffset: Self.seatOffset, supports: [support], nearestTo: placement
        )
        guard screenBounds.contains(placement), candidate?.placement == placement,
              overlay.followPerch(at: placement, generation: overlay.generation) else {
            detachPerch()
            perchSearchFinished = false
            return .stopped
        }

        verified = nil
        verificationRequired = false
        rejectedPerches = []
        perchSearchFinished = false
        attachment = Attachment(
            supportID: current.supportID, offsetX: current.offsetX,
            supportBounds: supportBounds, supportSpans: support.spans,
            ownerBounds: owner.rawBounds, placement: placement
        )
        return .followed
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

    private static func followsOwnerTranslation(
        attachment: Attachment,
        support: PerchSupport,
        placement: PetRect,
        ownerBounds: PetRect?
    ) -> Bool {
        guard let oldOwnerBounds = attachment.ownerBounds, let ownerBounds,
              oldOwnerBounds.width == ownerBounds.width,
              oldOwnerBounds.height == ownerBounds.height,
              attachment.supportBounds.width == support.bounds.width,
              attachment.supportBounds.height == support.bounds.height else { return false }
        let dx = ownerBounds.x - oldOwnerBounds.x
        let dy = ownerBounds.y - oldOwnerBounds.y
        return support.bounds.x - attachment.supportBounds.x == dx
            && support.bounds.y - attachment.supportBounds.y == dy
            && placement.x - attachment.placement.x == dx
            && placement.y - attachment.placement.y == dy
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
        nextRefreshID &+= 1
        let refreshID = nextRefreshID
        activeRefreshID = refreshID
        var unsafeOrigin: PetRect?
        var unsafeDeadline: Task<Void, Never>?
        defer {
            unsafeDeadline?.cancel()
            if activeRefreshID == refreshID { activeRefreshID = nil }
        }
        let generation = overlay.generation
        func relevant() -> Bool {
            enabled && !Task.isCancelled && current() && overlay.generation == generation
        }
        func originIsStillUnsafe() -> Bool {
            guard let unsafeOrigin else { return false }
            return activeRefreshID == refreshID
                && !overlay.isMoving && !overlay.isDragging
                && overlay.displayedPlacement == unsafeOrigin
        }
        func markUnsafeOrigin() {
            guard unsafeOrigin == nil, overlay.panel.isVisible,
                  let placement = overlay.displayedPlacement else { return }
            unsafeOrigin = placement
            unsafeDeadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(2_500))
                guard !Task.isCancelled, let self,
                      self.activeRefreshID == refreshID,
                      !self.overlay.isMoving, !self.overlay.isDragging,
                      self.overlay.displayedPlacement == placement else { return }
                self.invalidate(preservingVerification: false)
                if self.activeRefreshID == refreshID { self.activeRefreshID = nil }
            }
        }
        func discard() -> CaptureOutcome {
            if originIsStillUnsafe() {
                invalidate(preservingVerification: false)
            } else if overlay.generation == generation {
                invalidate()
            }
            return .discarded
        }
        func show(_ rect: PetRect, visual: Bool) -> CaptureOutcome {
            searchOrigin = rect
            let from = overlay.displayedPlacement ?? overlay.lastPlacement
            let visible = overlay.panel.isVisible
            let moving = overlay.lastPlacement != nil && overlay.lastPlacement != rect
                && overlay.move(to: rect, generation: generation)
            if moving {
                if tracePlacement, from != rect {
                    NSLog("Bocchi placement transition: action=move visible=%d from=%@ to=%@",
                          visible,
                          String(describing: from), String(describing: rect))
                }
            } else {
                guard overlay.publish(placement: rect, generation: generation) else {
                    return discard()
                }
                if tracePlacement, from != rect {
                    NSLog("Bocchi placement transition: action=publish visible=%d from=%@ to=%@",
                          visible, String(describing: from), String(describing: rect))
                }
            }
            pendingEscapeOrigin = nil
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
                if visualModeChanged { overlay.panel.orderOut(nil) }
            } else if boundsChanged || windowsChanged || contentsChanged {
                searchState = .ready
            }
            if screenChanged || windowsChanged {
                if tracePlacement, !activityAreas.isEmpty {
                    NSLog("Bocchi activity reset: boundsChanged=%d oldWindows=%d newWindows=%d areas=%d",
                          boundsChanged, previousSystem?.windows.count ?? 0, system.windows.count,
                          activityAreas.count)
                }
                activityAreas = []
            }
            previousBounds = bounds
            previousScreenBounds = screenBounds
            previousSystem = system
            previousVisualAllowed = visualAllowed
            if overlay.lastPlacement.map({ Self.collides($0, with: system.obstacles) }) == true {
                markUnsafeOrigin()
            }

            let escapeObstacles = pendingEscapeOrigin.map { [$0] } ?? []
            if !perchingSuppressed, attachment != nil || !perchSearchFinished {
                var candidates = system.supports.filter {
                    visualAllowed || !$0.requiresVisualVerification
                }
                var perchOrigin = overlay.lastPlacement
                var recoveredPlacement: PetRect?
                if let attachment,
                   let support = candidates.first(where: { $0.id == attachment.supportID }) {
                    candidates = [support]
                    perchOrigin = PetRect(x: support.bounds.x + attachment.offsetX,
                        y: support.bounds.y - Self.seatOffset,
                        width: Self.perchSize.width, height: Self.perchSize.height)
                } else if let attachment, visualAllowed,
                          attachment.supportID.elementToken == nil,
                          let oldOwner = attachment.ownerBounds,
                          let index = system.windows.firstIndex(where: {
                              $0.id == attachment.supportID.windowID
                                  && $0.pid == attachment.supportID.pid
                          }) {
                    let owner = system.windows[index]
                    let visibility = SystemInspector.visibility(of: system.windows, in: screenBounds)
                    let dx = owner.rawBounds.x - oldOwner.x
                    let dy = owner.rawBounds.y - oldOwner.y
                    let expected = PetRect(
                        x: attachment.placement.x + dx, y: attachment.placement.y + dy,
                        width: attachment.placement.width, height: attachment.placement.height
                    )
                    if owner.isOpaque, owner.rawBounds.width == oldOwner.width,
                       owner.rawBounds.height == oldOwner.height,
                       let support = SystemInspector.perchSupport(
                           for: owner, visibleRegions: visibility.windows[index], in: screenBounds,
                           foregroundWindows: Array(system.windows.prefix(index))
                       ), support.bounds.x == attachment.supportBounds.x + dx,
                       support.bounds.y == attachment.supportBounds.y + dy,
                       support.bounds.width == attachment.supportBounds.width,
                       support.bounds.height == attachment.supportBounds.height {
                        candidates = [support]
                        perchOrigin = expected
                        recoveredPlacement = expected
                    } else {
                        detachPerch()
                    }
                } else if let attachment {
                    if tracePlacement {
                        let windowPresent = system.windows.contains {
                            $0.id == attachment.supportID.windowID
                                && $0.pid == attachment.supportID.pid
                        }
                        let expected = attachment.placement
                        func intersections(_ rects: [PetRect]) -> Int {
                            rects.filter { expected.intersects(Self.padded($0)) }.count
                        }
                        NSLog("Bocchi perch detached: reason=missingSupport window=%u pid=%d windowPresent=%d supportPresent=0 support=%@ expected=%@ system=%d activity=%d rejected=%d unknown=%d",
                              attachment.supportID.windowID, attachment.supportID.pid,
                              windowPresent, String(describing: attachment.supportBounds),
                              String(describing: expected),
                              intersections(system.obstacles), intersections(activityAreas),
                              intersections(rejectedPerches.map(\.placement)),
                              intersections(system.unknownAreas))
                    }
                    detachPerch()
                }
                var blocked = system.obstacles + activityAreas + escapeObstacles
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
                    if let recoveredPlacement, rect != recoveredPlacement { break }
                    let requiresPixels = recoveredPlacement != nil || support.requiresVisualVerification
                        || (visualAllowed && Self.collides(rect, with: system.unknownAreas))
                    if requiresPixels {
                        let region = Self.region(around: rect, in: screenBounds)
                        let reuse = recoveredPlacement == nil && verified.map { $0.placement == rect
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
                            let missingSupportEdge = (recoveredPlacement != nil
                                || support.requiresVisualVerification)
                                && !Self.hasSupportEdge(for: rect, in: sample.supportEdges)
                            if Self.collides(rect, with: sample.obstacles) || active
                                || missingSupportEdge {
                                if tracePlacement {
                                    let windowPresent = system.windows.contains {
                                        $0.id == support.id.windowID && $0.pid == support.id.pid
                                    }
                                    let supportPresent = system.supports.contains { $0.id == support.id }
                                    func intersections(_ rects: [PetRect]) -> Int {
                                        rects.filter { rect.intersects(Self.padded($0)) }.count
                                    }
                                    NSLog("Bocchi perch pixel rejected: window=%u pid=%d windowPresent=%d supportPresent=%d expected=%@ system=%d activity=%d rejected=%d unknown=%d sample=%d missingEdge=%d active=%d",
                                          support.id.windowID, support.id.pid, windowPresent,
                                          supportPresent, String(describing: rect),
                                          intersections(system.obstacles), intersections(activityAreas),
                                          intersections(rejectedPerches.map(\.placement)),
                                          intersections(system.unknownAreas),
                                          intersections(sample.obstacles), missingSupportEdge, active)
                                }
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
                    let attachedAndSitting = attachment?.supportID == candidate.supportID
                        && overlay.isSitting
                    let ownerBounds = system.windows.first(where: {
                        $0.id == candidate.supportID.windowID
                            && $0.pid == candidate.supportID.pid
                    })?.rawBounds
                    let unchanged = attachment?.placement == rect
                    let followsOwner = attachedAndSitting && attachment.map {
                        Self.followsOwnerTranslation(attachment: $0, support: support,
                            placement: rect, ownerBounds: ownerBounds)
                    } == true
                    let following = attachedAndSitting && (unchanged || followsOwner)
                    rejectedPerches = []
                    searchOrigin = rect
                    let accepted = following
                        ? overlay.followPerch(at: rect, generation: generation)
                        : overlay.perch(at: rect, generation: generation)
                    guard accepted else { return discard() }
                    attachment = Attachment(supportID: candidate.supportID,
                        offsetX: rect.x - support.bounds.x, supportBounds: support.bounds,
                        supportSpans: support.spans,
                        ownerBounds: ownerBounds, placement: rect)
                    lastLiveFollowRead = -Double.infinity
                    pendingEscapeOrigin = nil
                    if tracePlacement {
                        NSLog("Bocchi perch accepted: action=%@ window=%u element=%d position=%@",
                              following ? "follow" : "approach",
                              candidate.supportID.windowID,
                              candidate.supportID.elementToken == nil ? 0 : 1,
                              String(describing: rect))
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
                if let attachment, tracePlacement {
                    let expected = attachment.placement
                    func intersections(_ rects: [PetRect]) -> Int {
                        rects.filter { expected.intersects(Self.padded($0)) }.count
                    }
                    let windowPresent = system.windows.contains {
                        $0.id == attachment.supportID.windowID
                            && $0.pid == attachment.supportID.pid
                    }
                    let supportPresent = system.supports.contains {
                        $0.id == attachment.supportID
                    }
                    NSLog("Bocchi perch detached: reason=noCandidate window=%u pid=%d windowPresent=%d supportPresent=%d support=%@ expected=%@ system=%d activity=%d rejected=%d unknown=%d",
                          attachment.supportID.windowID, attachment.supportID.pid,
                          windowPresent, supportPresent,
                          String(describing: attachment.supportBounds),
                          String(describing: expected), intersections(system.obstacles),
                          intersections(activityAreas),
                          intersections(rejectedPerches.map(\.placement)),
                          intersections(system.unknownAreas))
                }
                detachPerch()
            }
            let obstacles = system.obstacles + activityAreas + escapeObstacles
            let searchingObstacles = obstacles + [Self.cursorObstacle(cursor())]
            let origin = (manualPlacement ?? (screenChanged ? nil : searchOrigin ?? overlay.lastPlacement))
                .map(Self.standingOrigin)
            let desired = manualPlacement ?? overlay.lastPlacement
            manualPlacement = nil
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
                markUnsafeOrigin()
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
