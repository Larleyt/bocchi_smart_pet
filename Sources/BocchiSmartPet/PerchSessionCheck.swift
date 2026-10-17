import AppKit
import BocchiCore

@MainActor
enum PerchSessionCheck {
    static func run(_ check: (Bool, String) throws -> Void) async throws {
        let bounds = PetRect(x: 0, y: 0, width: 900, height: 640)
        let windowID = SupportID(windowID: 501, pid: 77, elementToken: 501)
        let fingerprint = try PixelFingerprint(rgb: [UInt8](repeating: 220, count: 64 * 3))
        let overlay = try PetOverlay()
        defer { overlay.stop() }
        let session = PlacementSession(overlay: overlay)
        let state = CaptureFixtureState()

        @MainActor func scene(x: Double = 100, y: Double = 300,
                   supportX: Double? = nil, supportY: Double? = nil,
                   supports: Bool = true, blocked: [PetRect] = []) -> SystemSnapshot {
            let window = PetRect(x: x, y: y, width: 700, height: 340)
            let support = PetRect(x: supportX ?? x, y: supportY ?? y,
                                  width: 700, height: 340)
            return SystemSnapshot(obstacles: blocked, unknownAreas: [window],
                windows: [WindowRegion(id: windowID.windowID, pid: windowID.pid, bounds: window)],
                accessibilityAvailable: true,
                supports: supports ? [PerchSupport(id: windowID, bounds: support,
                    spans: [HorizontalSpan(minX: support.x, maxX: support.maxX)])] : [])
        }
        @MainActor func refresh(_ snapshot: SystemSnapshot, visual: Bool = true) async -> CaptureOutcome {
            await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: visual,
                inspect: { snapshot }, capture: { region in
                    state.crops.append(region)
                    return PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint)
                }, capturePerch: { region, edge in
                    state.crops.append(region)
                    state.edgeCrops += 1
                    guard region.y < edge, edge < region.maxY else {
                        throw PerchSessionCheckError.edgeOutsideCrop
                    }
                    let obstacles = state.rejectEdges > 0 ? [region] : []
                    state.rejectEdges = max(0, state.rejectEdges - 1)
                    let supportEdges = state.drawsSupportEdge
                        ? [HorizontalSpan(minX: region.x, maxX: region.maxX)] : []
                    return PixelSample(bounds: region, obstacles: obstacles,
                                       fingerprint: fingerprint, supportEdges: supportEdges)
                }, current: { true }, cursor: { PetPoint(x: -1000, y: -1000) }, now: { state.clock })
        }
        @MainActor func finishMovement(of target: PetOverlay) async throws {
            let deadline = ContinuousClock.now + .seconds(4)
            while target.isMoving && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(!target.isMoving, "native perch session movement finishes within its bound")
        }
        @MainActor func finishMovement() async throws {
            try await finishMovement(of: overlay)
        }

        let initial = await refresh(scene())
        try check(initial == .shown(visual: true) && overlay.isPerched && state.edgeCrops == 1,
                  "session verifies an unknown window edge before starting its climb")
        try await finishMovement()
        guard let first = overlay.lastPlacement else { throw PerchSessionCheckError.noPlacement }
        try check(overlay.isSitting && first.width == 128 && first.y + 112 == 300,
                  "session seats the generated pose on the real support coordinate")
        let verifiedCount = state.crops.count
        _ = await refresh(scene())
        try check(overlay.isSitting && !overlay.isMoving && state.crops.count == verifiedCount,
                  "unchanged support reuses its local verification without replaying the climb")

        let recoveryOverlay = try PetOverlay()
        defer { recoveryOverlay.stop() }
        let recoverySession = PlacementSession(overlay: recoveryOverlay)
        let recoveryID = SupportID(windowID: 550, pid: 76)
        let changedFingerprint = try PixelFingerprint(rgb: [UInt8](repeating: 40, count: 64 * 3))
        let recoveryOwner = WindowRegion(
            id: recoveryID.windowID, pid: recoveryID.pid,
            bounds: PetRect(x: 100, y: 300, width: 700, height: 340)
        )
        let recoveryState = CaptureFixtureState()
        @MainActor func recoverySnapshot(
            window: WindowRegion = recoveryOwner, includeSupport: Bool,
            obstacles: [PetRect] = [], windows: [WindowRegion]? = nil
        ) -> SystemSnapshot {
            let currentWindows = windows ?? [window]
            let visibility = SystemInspector.visibility(of: currentWindows, in: bounds)
            let index = currentWindows.firstIndex { $0.id == window.id && $0.pid == window.pid }
            let support = index.flatMap {
                SystemInspector.perchSupport(
                    for: window, visibleRegions: visibility.windows[$0], in: bounds,
                    foregroundWindows: Array(currentWindows.prefix($0))
                )
            }
            return SystemSnapshot(
                obstacles: obstacles, unknownAreas: visibility.unknown + [window.bounds],
                windows: currentWindows, accessibilityAvailable: true,
                supports: includeSupport ? [support].compactMap { $0 } : []
            )
        }
        @MainActor func refreshRecovery(
            _ snapshot: SystemSnapshot, visual: Bool = true
        ) async -> CaptureOutcome {
            await recoverySession.refresh(
                bounds: bounds, screenBounds: bounds, visualAllowed: visual,
                inspect: { snapshot }, capture: { region in
                    PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint)
                }, capturePerch: { region, _ in
                    recoveryState.edgeCrops += 1
                    if recoveryState.failCapture {
                        throw PerchSessionCheckError.edgeOutsideCrop
                    }
                    if recoveryState.invalidateDuringCapture { recoveryState.fresh = false }
                    let obstacles = recoveryState.rejectEdges > 0 ? [region] : []
                    recoveryState.rejectEdges = max(0, recoveryState.rejectEdges - 1)
                    return PixelSample(
                        bounds: region, obstacles: obstacles,
                        fingerprint: recoveryState.changedFingerprint
                            ? changedFingerprint : fingerprint,
                        supportEdges: recoveryState.drawsSupportEdge
                            ? [HorizontalSpan(minX: region.x, maxX: region.maxX)] : []
                    )
                }, current: { recoveryState.fresh },
                cursor: { PetPoint(x: -1000, y: -1000) }, now: { recoveryState.clock }
            )
        }
        _ = await refreshRecovery(recoverySnapshot(includeSupport: true))
        try await finishMovement(of: recoveryOverlay)
        guard let recoveryPlacement = recoveryOverlay.lastPlacement else {
            throw PerchSessionCheckError.noPlacement
        }
        let recoveryCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(includeSupport: false))
        try check(
            recoveryOverlay.isSitting && recoveryOverlay.lastPlacement == recoveryPlacement
                && recoveryState.edgeCrops == recoveryCrops + 1,
            "accepted native window edge survives transient AX support loss after a fresh crop"
        )
        let movedRecoveryOwner = WindowRegion(
            id: recoveryID.windowID, pid: recoveryID.pid,
            bounds: PetRect(x: 120, y: 310, width: 700, height: 340)
        )
        let movedRecoveryCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(
            window: movedRecoveryOwner, includeSupport: false
        ))
        let translatedRecovery = PetRect(
            x: recoveryPlacement.x + 20, y: recoveryPlacement.y + 10,
            width: recoveryPlacement.width, height: recoveryPlacement.height
        )
        try check(
            recoveryOverlay.isSitting && !recoveryOverlay.isMoving
                && recoveryOverlay.lastPlacement == translatedRecovery
                && recoveryState.edgeCrops == movedRecoveryCrops + 1,
            "recovered native edge follows only the exact owner translation after fresh pixels"
        )

        @MainActor func reseatRecovery() async throws {
            recoverySession.invalidate(preservingVerification: false)
            recoveryState.drawsSupportEdge = true
            recoveryState.rejectEdges = 0
            recoveryState.changedFingerprint = false
            recoveryState.invalidateDuringCapture = false
            recoveryState.failCapture = false
            recoveryState.fresh = true
            _ = await refreshRecovery(recoverySnapshot(includeSupport: true))
            try await finishMovement(of: recoveryOverlay)
            guard recoveryOverlay.isSitting else { throw PerchSessionCheckError.noPlacement }
        }

        try await reseatRecovery()
        let identityCrops = recoveryState.edgeCrops
        let missingSnapshot = SystemSnapshot(
            obstacles: [], unknownAreas: [], windows: [], accessibilityAvailable: true
        )
        _ = await refreshRecovery(missingSnapshot)
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == identityCrops,
                  "missing native owner cannot recover an accepted edge")
        try await reseatRecovery()
        let wrongID = WindowRegion(
            id: recoveryID.windowID + 1, pid: recoveryID.pid,
            bounds: recoveryOwner.rawBounds
        )
        let wrongIDCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(
            window: wrongID, includeSupport: false
        ))
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == wrongIDCrops,
                  "wrong native window ID cannot recover an accepted edge")
        try await reseatRecovery()
        let wrongPID = WindowRegion(
            id: recoveryID.windowID, pid: recoveryID.pid + 1,
            bounds: recoveryOwner.rawBounds
        )
        let wrongPIDCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(
            window: wrongPID, includeSupport: false
        ))
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == wrongPIDCrops,
                  "wrong native owner PID cannot recover an accepted edge")

        try await reseatRecovery()
        let recoveryResized = WindowRegion(
            id: recoveryID.windowID, pid: recoveryID.pid,
            bounds: PetRect(x: 100, y: 300, width: 710, height: 340)
        )
        let translucent = WindowRegion(
            id: recoveryID.windowID, pid: recoveryID.pid,
            bounds: recoveryOwner.rawBounds, isOpaque: false
        )
        let metadataCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(
            window: recoveryResized, includeSupport: false
        ))
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == metadataCrops,
                  "resized native owner cannot reuse the accepted support geometry")
        try await reseatRecovery()
        let opacityCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(window: translucent, includeSupport: false))
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == opacityCrops,
                  "translucent native owner cannot recover an opaque accepted edge")

        try await reseatRecovery()
        let recoveryForeground = WindowRegion(
            id: recoveryID.windowID + 2, pid: recoveryID.pid + 2,
            bounds: PetRect(x: 100, y: 250, width: 700, height: 200)
        )
        let occlusionCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(
            includeSupport: false, windows: [recoveryForeground, recoveryOwner]
        ))
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == occlusionCrops,
                  "foreground occlusion cannot recover a hidden native edge")

        try await reseatRecovery()
        let visualCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(includeSupport: false), visual: false)
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == visualCrops,
                  "visual opt-out cannot recover an AX-missing native edge")

        try await reseatRecovery()
        let accepted = recoveryOverlay.lastPlacement!
        let blockedCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(
            includeSupport: false, obstacles: [accepted]
        ))
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == blockedCrops,
                  "current AX obstacle blocks recovery before pixel capture")

        try await reseatRecovery()
        recoveryState.rejectEdges = 1
        let pixelCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(includeSupport: false))
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == pixelCrops + 1,
                  "fresh pixel obstacle rejects recovered native geometry")

        try await reseatRecovery()
        recoveryState.drawsSupportEdge = false
        let missingEdgeCrops = recoveryState.edgeCrops
        _ = await refreshRecovery(recoverySnapshot(includeSupport: false))
        try check(!recoveryOverlay.isPerched && recoveryState.edgeCrops == missingEdgeCrops + 1,
                  "fresh crop without the continuous edge rejects native recovery")

        try await reseatRecovery()
        recoveryState.changedFingerprint = true
        _ = await refreshRecovery(recoverySnapshot(includeSupport: false))
        try check(!recoveryOverlay.isPerched,
                  "fresh local activity rejects an otherwise matching recovered edge")

        try await reseatRecovery()
        recoveryState.invalidateDuringCapture = true
        let beforeStaleRecovery = recoveryOverlay.lastPlacement
        let staleRecovery = await refreshRecovery(recoverySnapshot(includeSupport: false))
        try check(staleRecovery == .discarded
                  && recoveryOverlay.lastPlacement == beforeStaleRecovery,
                  "stale recovery crop cannot publish a recovered attachment state")

        try await reseatRecovery()
        recoveryState.failCapture = true
        let failedRecovery = await refreshRecovery(recoverySnapshot(includeSupport: false))
        try check({ if case .failed = failedRecovery { true } else { false } }()
                  && !recoveryOverlay.panel.isVisible,
                  "recovery capture error follows the existing hard-hide path")

        let oldEdgeChecks = state.edgeCrops
        _ = await refresh(scene(blocked: [PetRect(x: 10, y: 10, width: 8, height: 8)]))
        try check(overlay.isSitting && !overlay.isMoving && state.edgeCrops == oldEdgeChecks + 1,
                  "changed accessibility content forces a fresh crop at the same support")

        state.clock += 1
        let movedOwnerScene = scene(x: 140, y: 320)
        state.fresh = true
        let staleOwnerMove = await session.refresh(
            bounds: bounds, screenBounds: bounds, visualAllowed: true,
            inspect: { movedOwnerScene }, capture: { region in
                PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint)
            }, capturePerch: { region, _ in
                state.edgeCrops += 1
                state.fresh = false
                return PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint,
                    supportEdges: [HorizontalSpan(minX: region.x, maxX: region.maxX)])
            }, current: { state.fresh }, cursor: { PetPoint(x: -1000, y: -1000) },
            now: { state.clock }
        )
        try check(staleOwnerMove == .discarded && overlay.isSitting
                  && overlay.lastPlacement == first,
                  "stale owner movement cannot replace the last accepted attachment baseline")
        state.fresh = true
        _ = await refresh(movedOwnerScene)
        let followed = PetRect(x: first.x + 40, y: first.y + 20, width: 128, height: 156)
        try check(overlay.isSitting && overlay.lastPlacement == followed && !overlay.isMoving,
                  "repeated owner movement follows immediately from the accepted baseline")

        state.clock += 1
        let internallyMovedScene = scene(x: 140, y: 320, supportX: 140, supportY: 480)
        _ = await refresh(internallyMovedScene)
        let internalDestination = PetRect(x: followed.x, y: 480 - 112,
                                          width: 128, height: 156)
        try check(overlay.isMoving && overlay.isPerched && !overlay.isSitting
                  && overlay.displayedPlacement != internalDestination,
                  "same internal support moving inside its owner starts a visible approach")
        try await Task.sleep(for: .milliseconds(120))
        try check(overlay.isMoving
                  && overlay.displayedPlacement.map {
                      $0.y > followed.y && $0.y < internalDestination.y
                  } == true,
                  "internal support relocation crosses a real intermediate vertical panel position")
        try await finishMovement()
        try check(overlay.isSitting && overlay.lastPlacement == internalDestination,
                  "internal support relocation finishes by sitting at the new edge")
        let stationaryInternal = overlay.displayedPlacement
        _ = await refresh(internallyMovedScene)
        try check(overlay.isSitting && !overlay.isMoving
                  && overlay.displayedPlacement == stationaryInternal,
                  "unchanged internal support remains an immediate seated no-op")

        state.clock += 1
        let differentlyMovedScene = scene(x: 160, y: 340, supportX: 160, supportY: 560)
        _ = await refresh(differentlyMovedScene)
        try check(overlay.isMoving && overlay.isPerched && !overlay.isSitting,
                  "internal support moving differently from its owner starts another approach")
        try await finishMovement()
        try check(overlay.isSitting && overlay.lastPlacement?.y == 560 - 112,
                  "differently translated support finishes at its own verified edge")

        state.clock += 1
        _ = await refresh(scene(x: 140, y: 320, supports: false))
        try await finishMovement()
        try check(!overlay.isPerched && overlay.lastPlacement?.width == PetOverlay.size.width,
                  "lost or covered support returns to ordinary free placement")

        state.clock += 1
        _ = await refresh(scene())
        try await finishMovement()
        session.beginDragging()
        let manual = PetRect(x: 40, y: 80, width: 128, height: 156)
        session.drop(at: manual)
        _ = await refresh(scene())
        try await finishMovement()
        let expectedDrop = PetRect(x: 40 + (128 - PetOverlay.size.width) / 2, y: 80,
                                   width: PetOverlay.size.width, height: PetOverlay.size.height)
        try check(!overlay.isPerched && overlay.lastPlacement ==
                  expectedDrop,
                  "manual drop detaches the perch and retains the requested center")

        state.clock += 1
        session.invalidate(preservingVerification: false)
        _ = await refresh(scene(), visual: false)
        try await finishMovement()
        try check(!overlay.isPerched,
                  "visual opt-out never seats dangling legs in an unknown window")

        session.invalidate(preservingVerification: false)
        state.drawsSupportEdge = false
        _ = await refresh(scene())
        try await finishMovement()
        try check(!overlay.isPerched,
                  "invisible accessibility wrapper is rejected without a painted top edge")

        session.invalidate(preservingVerification: false)
        state.drawsSupportEdge = true
        _ = await refresh(scene())
        try await finishMovement()
        try check(overlay.isSitting,
                  "painted top edge admits the same non-actionable accessibility container")

        session.invalidate(preservingVerification: false)
        let obstruction = PetRect(x: 100, y: 200, width: 700, height: 150)
        _ = await refresh(scene(blocked: [obstruction]))
        try await finishMovement()
        try check(!overlay.isPerched && overlay.lastPlacement.map { !$0.intersects(obstruction) } == true,
                  "known active controls block every overlapping perch before pixels")

        state.clock += 1
        _ = await refresh(scene())
        try await finishMovement()
        try check(overlay.isSitting,
                  "removing an active control retries the same stationary support")

        session.invalidate(preservingVerification: false)
        let multipleSupports = (0..<4).map { index -> PerchSupport in
            let edge = PetRect(x: 80 + Double(index) * 180, y: 300, width: 128, height: 300)
            return PerchSupport(
                id: SupportID(windowID: 600, pid: 78, elementToken: UInt64(index + 1)),
                bounds: edge, spans: [HorizontalSpan(minX: edge.x, maxX: edge.maxX)]
            )
        }
        let multipleSnapshot = SystemSnapshot(
            obstacles: [], unknownAreas: [bounds],
            windows: [WindowRegion(id: 600, pid: 78, bounds: bounds)],
            accessibilityAvailable: true, supports: multipleSupports
        )
        state.rejectEdges = 3
        overlay.publish(placement: PetRect(x: 80, y: 188,
                            width: PetOverlay.size.width, height: PetOverlay.size.height),
                        generation: overlay.generation)
        let checksBeforeRetries = state.edgeCrops
        _ = await refresh(multipleSnapshot)
        try await finishMovement()
        try check(!overlay.isPerched && state.edgeCrops == checksBeforeRetries + 3,
                  "one refresh keeps the perch pixel budget at three rejected candidates")
        let irrelevantSupportBounds = PetRect(x: 820, y: 500, width: 64, height: 80)
        let changedElsewhereSnapshot = SystemSnapshot(
            obstacles: [PetRect(x: 880, y: 620, width: 5, height: 5)],
            unknownAreas: [bounds, PetRect(x: 880, y: 620, width: 5, height: 5)],
            windows: multipleSnapshot.windows,
            accessibilityAvailable: true,
            supports: multipleSupports + [PerchSupport(
                id: SupportID(windowID: 601, pid: 79, elementToken: 1),
                bounds: irrelevantSupportBounds,
                spans: [HorizontalSpan(minX: irrelevantSupportBounds.x,
                                       maxX: irrelevantSupportBounds.maxX)]
            )]
        )
        _ = await refresh(changedElsewhereSnapshot)
        try await finishMovement()
        try check(overlay.isSitting && state.edgeCrops == checksBeforeRetries + 4
                  && overlay.lastPlacement?.x == multipleSupports[3].bounds.x,
                  "unrelated snapshot churn preserves rejects and continues with the fourth support")

        session.invalidate(preservingVerification: false)
        let changingID = SupportID(windowID: 602, pid: 80, elementToken: 1)
        let originalBounds = PetRect(x: 200, y: 340, width: 128, height: 120)
        let originalSupport = PerchSupport(id: changingID, bounds: originalBounds,
            spans: [HorizontalSpan(minX: originalBounds.x, maxX: originalBounds.maxX)])
        let originalSnapshot = SystemSnapshot(
            obstacles: [], unknownAreas: [bounds],
            windows: [WindowRegion(id: 602, pid: 80, bounds: bounds)],
            accessibilityAvailable: true, supports: [originalSupport]
        )
        state.drawsSupportEdge = false
        let checksBeforeSupportChange = state.edgeCrops
        _ = await refresh(originalSnapshot)
        try await finishMovement()
        try check(!overlay.isPerched && state.edgeCrops == checksBeforeSupportChange + 1,
                  "missing edge rejects the original support geometry once")
        let movedBounds = PetRect(x: 240, y: 360, width: 128, height: 120)
        let movedSupport = PerchSupport(id: changingID, bounds: movedBounds,
            spans: [HorizontalSpan(minX: movedBounds.x, maxX: movedBounds.maxX)])
        let movedSnapshot = SystemSnapshot(
            obstacles: [], unknownAreas: [bounds], windows: originalSnapshot.windows,
            accessibilityAvailable: true, supports: [movedSupport]
        )
        state.drawsSupportEdge = true
        _ = await refresh(movedSnapshot)
        try await finishMovement()
        try check(overlay.isSitting && state.edgeCrops == checksBeforeSupportChange + 2
                  && overlay.lastPlacement?.x == movedBounds.x,
                  "changed support bounds discard its old reject and verify the new edge")

        session.invalidate(preservingVerification: false)
        state.drawsSupportEdge = false
        let checksBeforeLocalChange = state.edgeCrops
        _ = await refresh(originalSnapshot)
        try await finishMovement()
        try check(!overlay.isPerched && state.edgeCrops == checksBeforeLocalChange + 1,
                  "unchanged support retains its missing-edge rejection")
        let locallyChangedSnapshot = SystemSnapshot(
            obstacles: [], unknownAreas: [], windows: originalSnapshot.windows,
            accessibilityAvailable: true, supports: [originalSupport]
        )
        state.drawsSupportEdge = true
        _ = await refresh(locallyChangedSnapshot)
        try await finishMovement()
        try check(overlay.isSitting && state.edgeCrops == checksBeforeLocalChange + 2,
                  "local unknown-area removal reopens the rejected placement")

        session.invalidate(preservingVerification: false)
        let cursorSupport = multipleSupports[0]
        let cursorSnapshot = SystemSnapshot(
            obstacles: [], unknownAreas: [bounds],
            windows: [WindowRegion(id: 600, pid: 78, bounds: bounds)],
            accessibilityAvailable: true, supports: [cursorSupport]
        )
        let checksBeforeCursor = state.edgeCrops
        _ = await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
            inspect: { cursorSnapshot }, capture: {
                PixelSample(bounds: $0, obstacles: [], fingerprint: fingerprint)
            }, capturePerch: { region, _ in
                state.edgeCrops += 1
                return PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint,
                    supportEdges: [HorizontalSpan(minX: region.x, maxX: region.maxX)])
            }, current: { true }, cursor: {
                PetPoint(x: cursorSupport.bounds.x + 64, y: cursorSupport.bounds.y - 40)
            }, now: { state.clock })
        try check(!overlay.isPerched && state.edgeCrops == checksBeforeCursor,
                  "cursor-only rejection does not spend a pixel capture")
        _ = await refresh(cursorSnapshot)
        try await finishMovement()
        try check(overlay.isSitting && state.edgeCrops == checksBeforeCursor + 1,
                  "cursor-only rejection stays retryable after the pointer leaves")

        session.invalidate(preservingVerification: false)
        state.fresh = true
        let stale = await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
            inspect: { scene() }, capture: {
                PixelSample(bounds: $0, obstacles: [], fingerprint: fingerprint)
            }, capturePerch: { region, _ in
                state.fresh = false
                return PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint,
                    supportEdges: [HorizontalSpan(minX: region.x, maxX: region.maxX)])
            }, current: { state.fresh }, cursor: { PetPoint(x: -1000, y: -1000) }, now: { state.clock })
        try check(stale == .discarded && !overlay.isPerched,
                  "stale edge capture cannot start an unverified climb")

        let trackedOverlay = try PetOverlay()
        defer { trackedOverlay.stop() }
        let trackedSession = PlacementSession(overlay: trackedOverlay)
        let trackedID = SupportID(windowID: 701, pid: 79, elementToken: 701)
        let trackedOwner = PetRect(x: 100, y: 300, width: 700, height: 340)
        let trackedState = CaptureFixtureState()
        trackedState.clock = 200
        @MainActor func trackedScene(_ owner: PetRect) -> SystemSnapshot {
            SystemSnapshot(
                obstacles: [], unknownAreas: [owner],
                windows: [WindowRegion(
                    id: trackedID.windowID, pid: trackedID.pid, bounds: owner
                )],
                accessibilityAvailable: true,
                supports: [PerchSupport(
                    id: trackedID, bounds: owner,
                    spans: [HorizontalSpan(minX: owner.x, maxX: owner.maxX)]
                )]
            )
        }
        @MainActor func refreshTracked(
            _ owner: PetRect, drawsEdge: Bool = true
        ) async -> CaptureOutcome {
            await trackedSession.refresh(
                bounds: bounds, screenBounds: bounds, visualAllowed: true,
                inspect: { trackedScene(owner) },
                capture: { region in
                    trackedState.captures += 1
                    return PixelSample(
                        bounds: region, obstacles: [], fingerprint: fingerprint
                    )
                },
                capturePerch: { region, _ in
                    trackedState.captures += 1
                    return PixelSample(
                        bounds: region, obstacles: [], fingerprint: fingerprint,
                        supportEdges: drawsEdge
                            ? [HorizontalSpan(minX: region.x, maxX: region.maxX)] : []
                    )
                },
                current: { true }, cursor: { PetPoint(x: -1000, y: -1000) },
                now: { trackedState.clock }
            )
        }
        @MainActor func finishTrackedMovement() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while trackedOverlay.isMoving && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !trackedOverlay.isMoving else {
                throw PerchSessionCheckError.movementTimeout
            }
        }
        @MainActor func seatTracked(_ owner: PetRect = trackedOwner) async throws {
            trackedSession.invalidate(preservingVerification: false)
            _ = await refreshTracked(owner)
            try await finishTrackedMovement()
            guard trackedOverlay.isSitting else { throw PerchSessionCheckError.noPlacement }
        }
        @MainActor func liveFollow(
            eventType: NSEvent.EventType = .leftMouseDragged,
            cached: [WindowRegion], owner: WindowRegion?, advance: Double = 1
        ) -> (LiveWindowFollowOutcome?, Int) {
            trackedState.clock += advance
            var reads = 0
            let result = AppDelegate.routeLiveWindowFollow(
                eventType: eventType, session: trackedSession,
                bounds: bounds, screenBounds: bounds, cachedWindows: cached,
                readOwner: { _, _ in reads += 1; return owner },
                now: { trackedState.clock }
            )
            return (result, reads)
        }

        try check(!AppDelegate.canStartFullRefresh(pressedMouseButtons: 1)
                  && !AppDelegate.canStartFullRefresh(pressedMouseButtons: 3),
                  "holding left mouse pauses full analysis even between drag events")
        try check(AppDelegate.canStartFullRefresh(pressedMouseButtons: 0)
                  && AppDelegate.canStartFullRefresh(pressedMouseButtons: 2),
                  "release permits full analysis without blocking a right-only input")
        try await seatTracked()
        guard let trackedStart = trackedOverlay.displayedPlacement else {
            throw PerchSessionCheckError.noPlacement
        }
        let capturesBeforeDrag = trackedState.captures
        let ownerStep1 = WindowRegion(
            id: trackedID.windowID, pid: trackedID.pid,
            bounds: PetRect(x: 120, y: 310, width: 700, height: 340)
        )
        let wrongDrag = liveFollow(
            eventType: .rightMouseDragged,
            cached: trackedScene(trackedOwner).windows, owner: ownerStep1
        )
        let pointerMove = liveFollow(
            eventType: .mouseMoved,
            cached: trackedScene(trackedOwner).windows, owner: ownerStep1
        )
        try check(
            wrongDrag == (nil, 0) && pointerMove == (nil, 0)
                && trackedOverlay.displayedPlacement == trackedStart,
            "only leftMouseDragged enters the targeted live-window reader"
        )
        let firstFollow = liveFollow(
            cached: trackedScene(trackedOwner).windows, owner: ownerStep1
        )
        let firstTrackedPlacement = PetRect(
            x: trackedStart.x + 20, y: trackedStart.y + 10,
            width: trackedStart.width, height: trackedStart.height
        )
        try check(
            firstFollow == (.followed, 1)
                && trackedOverlay.displayedPlacement == firstTrackedPlacement
                && trackedOverlay.isSitting && trackedState.captures == capturesBeforeDrag,
            "left-drag metadata moves the actual seated NSPanel before release without capture"
        )

        let ownerStep2 = WindowRegion(
            id: trackedID.windowID, pid: trackedID.pid,
            bounds: PetRect(x: 140, y: 320, width: 700, height: 340)
        )
        let throttled = liveFollow(
            cached: [ownerStep1], owner: ownerStep2, advance: 0
        )
        try check(
            throttled == (.throttled, 0)
                && trackedOverlay.displayedPlacement == firstTrackedPlacement,
            "live-follow throttle runs before the external single-window reader"
        )
        let shortInterval = liveFollow(
            cached: [ownerStep1], owner: ownerStep2, advance: 0.005
        )
        try check(
            shortInterval == (.throttled, 0)
                && trackedOverlay.displayedPlacement == firstTrackedPlacement,
            "five-millisecond drag sample remains below the live-follow limit"
        )
        let secondFollow = liveFollow(
            cached: [ownerStep1], owner: ownerStep2, advance: 0.02
        )
        let secondTrackedPlacement = PetRect(
            x: trackedStart.x + 40, y: trackedStart.y + 20,
            width: trackedStart.width, height: trackedStart.height
        )
        try check(
            secondFollow == (.followed, 1)
                && trackedOverlay.displayedPlacement == secondTrackedPlacement
                && trackedState.captures == capturesBeforeDrag,
            "successive targeted owner samples preserve live seated translation"
        )

        trackedState.clock += 1
        let capturesBeforeRelease = trackedState.captures
        _ = await refreshTracked(ownerStep2.rawBounds)
        try check(
            trackedOverlay.isSitting && trackedState.captures == capturesBeforeRelease + 1,
            "post-release refresh freshly verifies the transient followed attachment"
        )

        let ownerStep3 = WindowRegion(
            id: trackedID.windowID, pid: trackedID.pid,
            bounds: PetRect(x: 160, y: 330, width: 700, height: 340)
        )
        _ = liveFollow(cached: [ownerStep2], owner: ownerStep3)
        let capturesBeforeFailedRelease = trackedState.captures
        _ = await refreshTracked(ownerStep3.rawBounds, drawsEdge: false)
        try await finishTrackedMovement()
        try check(
            !trackedOverlay.isPerched
                && trackedState.captures > capturesBeforeFailedRelease,
            "failed post-release verification never accepts the transient attachment"
        )

        try await seatTracked()
        let missing = liveFollow(
            cached: trackedScene(trackedOwner).windows, owner: nil
        )
        try check(
            missing == (.stopped, 1) && !trackedOverlay.isPerched
                && trackedOverlay.panel.isVisible,
            "missing tracked owner detaches to a visible standing fallback"
        )

        try await seatTracked()
        let resizedOwner = WindowRegion(
            id: trackedID.windowID, pid: trackedID.pid,
            bounds: PetRect(x: 120, y: 310, width: 710, height: 340)
        )
        let resized = liveFollow(
            cached: trackedScene(trackedOwner).windows, owner: resizedOwner
        )
        try check(resized == (.stopped, 1) && !trackedOverlay.isPerched,
                  "owner resize stops transient follow instead of stretching the attachment")

        try await seatTracked()
        let foreground = WindowRegion(
            id: 700, pid: 80,
            bounds: PetRect(x: 350, y: 170, width: 220, height: 250)
        )
        let occluded = liveFollow(
            cached: [foreground, trackedScene(trackedOwner).windows[0]], owner: ownerStep1
        )
        try check(occluded == (.stopped, 1) && !trackedOverlay.isPerched,
                  "cached foreground occlusion stops live follow at the last safe frame")

        try await seatTracked()
        let offscreenOwner = WindowRegion(
            id: trackedID.windowID, pid: trackedID.pid,
            bounds: PetRect(x: 100, y: 700, width: 700, height: 340)
        )
        let offscreen = liveFollow(
            cached: trackedScene(trackedOwner).windows, owner: offscreenOwner
        )
        try check(offscreen == (.stopped, 1) && !trackedOverlay.isPerched,
                  "offscreen owner translation stops live follow before moving the panel")

        func trackedMetadata(onscreen: Bool) -> [String: Any] {
            [
                kCGWindowNumber as String: NSNumber(value: trackedID.windowID),
                kCGWindowOwnerPID as String: NSNumber(value: trackedID.pid),
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowAlpha as String: NSNumber(value: 1),
                kCGWindowIsOnscreen as String: NSNumber(value: onscreen),
                kCGWindowBounds as String: CGRect(
                    x: trackedOwner.x, y: trackedOwner.y,
                    width: trackedOwner.width, height: trackedOwner.height
                ).dictionaryRepresentation,
            ]
        }
        try check(
            SystemInspector.decodeTargetWindow(
                [trackedMetadata(onscreen: true)], id: trackedID.windowID,
                pid: trackedID.pid, in: bounds
            )?.id == trackedID.windowID
                && SystemInspector.decodeTargetWindow(
                    [trackedMetadata(onscreen: false)], id: trackedID.windowID,
                    pid: trackedID.pid, in: bounds
                ) == nil
                && SystemInspector.decodeTargetWindow(
                    [trackedMetadata(onscreen: true)], id: trackedID.windowID + 1,
                    pid: trackedID.pid, in: bounds
                ) == nil
                && SystemInspector.decodeTargetWindow(
                    [trackedMetadata(onscreen: true)], id: trackedID.windowID,
                    pid: trackedID.pid + 1, in: bounds
                ) == nil,
            "targeted metadata rejects offscreen, wrong-ID and wrong-PID windows"
        )
    }
}

@MainActor
private final class CaptureFixtureState {
    var clock = 100.0
    var captures = 0
    var crops: [PetRect] = []
    var edgeCrops = 0
    var rejectEdges = 0
    var drawsSupportEdge = true
    var fresh = true
    var changedFingerprint = false
    var invalidateDuringCapture = false
    var failCapture = false
}

private enum PerchSessionCheckError: Error {
    case edgeOutsideCrop
    case movementTimeout
    case noPlacement
}
