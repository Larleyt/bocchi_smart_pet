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

        @MainActor func scene(x: Double = 100, y: Double = 300, supports: Bool = true,
                   blocked: [PetRect] = []) -> SystemSnapshot {
            let window = PetRect(x: x, y: y, width: 700, height: 340)
            return SystemSnapshot(obstacles: blocked, unknownAreas: [window],
                windows: [WindowRegion(id: windowID.windowID, pid: windowID.pid, bounds: window)],
                accessibilityAvailable: true,
                supports: supports ? [PerchSupport(id: windowID, bounds: window,
                    spans: [HorizontalSpan(minX: window.x, maxX: window.maxX)])] : [])
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
        @MainActor func finishMovement() async throws {
            let deadline = ContinuousClock.now + .seconds(4)
            while overlay.isMoving && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(!overlay.isMoving, "native perch session movement finishes within its bound")
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

        let oldEdgeChecks = state.edgeCrops
        _ = await refresh(scene(blocked: [PetRect(x: 10, y: 10, width: 8, height: 8)]))
        try check(overlay.isSitting && !overlay.isMoving && state.edgeCrops == oldEdgeChecks + 1,
                  "changed accessibility content forces a fresh crop at the same support")

        state.clock += 1
        _ = await refresh(scene(x: 140, y: 320))
        let followed = PetRect(x: first.x + 40, y: first.y + 20, width: 128, height: 156)
        try check(overlay.isSitting && overlay.lastPlacement == followed && !overlay.isMoving,
                  "support identity follows window movement after a fresh edge check")

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
    }
}

@MainActor
private final class CaptureFixtureState {
    var clock = 100.0
    var crops: [PetRect] = []
    var edgeCrops = 0
    var rejectEdges = 0
    var drawsSupportEdge = true
    var fresh = true
}

private enum PerchSessionCheckError: Error {
    case edgeOutsideCrop
    case noPlacement
}
