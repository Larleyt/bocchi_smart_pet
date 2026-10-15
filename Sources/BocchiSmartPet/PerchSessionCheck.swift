import AppKit
import BocchiCore

@MainActor
enum PerchSessionCheck {
    static func run(_ check: (Bool, String) throws -> Void) async throws {
        let bounds = PetRect(x: 0, y: 0, width: 900, height: 640)
        let windowID = SupportWindowID(windowID: 501, pid: 77)
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
                supports: supports ? [PerchSupport(id: windowID, windowBounds: window,
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
                    return PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint)
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
        try check(!overlay.isPerched && overlay.lastPlacement?.width == 84,
                  "lost or covered support returns to ordinary free placement")

        state.clock += 1
        _ = await refresh(scene())
        try await finishMovement()
        session.beginDragging()
        let manual = PetRect(x: 40, y: 80, width: 128, height: 156)
        session.drop(at: manual)
        _ = await refresh(scene())
        try await finishMovement()
        try check(!overlay.isPerched && overlay.lastPlacement ==
                  PetRect(x: 62, y: 80, width: 84, height: 156),
                  "manual drop detaches the perch and retains the requested center")

        state.clock += 1
        session.invalidate(preservingVerification: false)
        _ = await refresh(scene(), visual: false)
        try await finishMovement()
        try check(!overlay.isPerched,
                  "visual opt-out never seats dangling legs in an unknown window")

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
        state.fresh = true
        let stale = await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: true,
            inspect: { scene() }, capture: {
                PixelSample(bounds: $0, obstacles: [], fingerprint: fingerprint)
            }, capturePerch: { region, _ in
                state.fresh = false
                return PixelSample(bounds: region, obstacles: [], fingerprint: fingerprint)
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
    var fresh = true
}

private enum PerchSessionCheckError: Error {
    case edgeOutsideCrop
    case noPlacement
}
