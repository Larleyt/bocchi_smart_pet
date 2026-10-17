import ApplicationServices
import BocchiCore

@MainActor
enum SupportGeometryCheck {
    static func run(_ check: (Bool, String) throws -> Void) async throws {
        let screen = PetRect(x: 0, y: 0, width: 1200, height: 800)
        let foreground = WindowRegion(
            id: 20, pid: 2,
            bounds: PetRect(x: 300, y: 200, width: 300, height: 300)
        )
        let background = WindowRegion(
            id: 21, pid: 3,
            bounds: PetRect(x: 100, y: 300, width: 900, height: 400)
        )
        let visible = SystemInspector.visibility(of: [foreground, background], in: screen)
        let support = SystemInspector.perchSupport(
            for: background, visibleRegions: visible.windows[1], in: screen
        )
        try check(
            support?.id == SupportID(windowID: 21, pid: 3)
                && support?.spans == [
                    HorizontalSpan(minX: 100, maxX: 300),
                    HorizontalSpan(minX: 600, maxX: 1000),
                ],
            "foreground windows split a native top edge into truly visible spans"
        )

        let capturedScreen = PetRect(x: 0, y: 0, width: 2560, height: 1440)
        let recordingPID: Int32 = 20630
        let recordingID: UInt32 = 115775
        let hostPID: Int32 = 63297
        let hostID: UInt32 = 115659
        let menuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        let recorderIdentity = SystemInspector.ApplicationIdentity(
            bundleIdentifier: "com.apple.screencaptureui",
            bundlePath: "/System/Library/CoreServices/screencaptureui.app"
        )
        func metadata(_ id: UInt32, pid: Int32, layer: Int, alpha: Double,
                      bounds: PetRect) -> [String: Any] {
            [
                kCGWindowNumber as String: NSNumber(value: id),
                kCGWindowOwnerPID as String: NSNumber(value: pid),
                kCGWindowLayer as String: NSNumber(value: layer),
                kCGWindowAlpha as String: NSNumber(value: alpha),
                kCGWindowBounds as String: CGRect(
                    x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height
                ).dictionaryRepresentation,
            ]
        }
        let recordingOverlay = metadata(
            recordingID, pid: recordingPID, layer: menuLayer, alpha: 1,
            bounds: capturedScreen
        )
        let capturedHostBounds = PetRect(x: 830, y: 233, width: 900, height: 600)
        let capturedHost = metadata(
            hostID, pid: hostPID, layer: 0, alpha: 1, bounds: capturedHostBounds
        )
        func decode(
            _ items: [[String: Any]],
            identity: SystemInspector.ApplicationIdentity? = recorderIdentity
        ) throws -> [WindowRegion] {
            try SystemInspector.decodeWindows(
                items, in: capturedScreen, excludingPID: -1,
                identityForPID: { $0 == recordingPID ? identity : nil }
            )
        }

        let recordingDecoded = try decode([recordingOverlay, capturedHost])
        let recordingVisibility = SystemInspector.visibility(
            of: recordingDecoded, in: capturedScreen
        )
        let recordingSupport = recordingDecoded.first.flatMap {
            SystemInspector.perchSupport(
                for: $0, visibleRegions: recordingVisibility.windows[0], in: capturedScreen
            )
        }
        try check(
            recordingDecoded.map(\.id) == [hostID]
                && recordingVisibility.windows[0] == [capturedHostBounds]
                && recordingSupport?.id == SupportID(windowID: hostID, pid: hostPID),
            "verified full-display Screen Recording veil is removed before visibility and support"
        )

        let wrongBundle = SystemInspector.ApplicationIdentity(
            bundleIdentifier: "example.recorder", bundlePath: recorderIdentity.bundlePath
        )
        let wrongPath = SystemInspector.ApplicationIdentity(
            bundleIdentifier: recorderIdentity.bundleIdentifier,
            bundlePath: "/Applications/screencaptureui.app"
        )
        let wrongLayer = metadata(
            recordingID, pid: recordingPID, layer: 0, alpha: 1, bounds: capturedScreen
        )
        let translucent = metadata(
            recordingID, pid: recordingPID, layer: menuLayer, alpha: 0.75,
            bounds: capturedScreen
        )
        let partialBounds = PetRect(x: 0, y: 0, width: 2559, height: 1440)
        let partialOverlay = metadata(
            recordingID, pid: recordingPID, layer: menuLayer, alpha: 1,
            bounds: partialBounds
        )
        let toolbarBounds = PetRect(x: 920, y: 1160, width: 720, height: 92)
        let toolbar = metadata(
            recordingID, pid: recordingPID, layer: menuLayer, alpha: 1,
            bounds: toolbarBounds
        )
        let negativeControls = [
            try decode([recordingOverlay, capturedHost], identity: nil),
            try decode([recordingOverlay, capturedHost], identity: wrongBundle),
            try decode([recordingOverlay, capturedHost], identity: wrongPath),
            try decode([wrongLayer, capturedHost]),
            try decode([translucent, capturedHost]),
            try decode([partialOverlay, capturedHost]),
            try decode([toolbar, capturedHost]),
        ]
        try check(
            negativeControls.allSatisfy { $0.map(\.id) == [recordingID, hostID] },
            "missing or wrong identity, path, layer, alpha, bounds and toolbar geometry stay visible"
        )
        let opaqueOther = try decode([recordingOverlay, capturedHost], identity: wrongBundle)
        let translucentOther = try decode([translucent, capturedHost], identity: wrongBundle)
        try check(
            SystemInspector.visibility(of: opaqueOther, in: capturedScreen).windows[1].isEmpty
                && SystemInspector.visibility(
                    of: translucentOther, in: capturedScreen
                ).windows[1].isEmpty,
            "ordinary opaque and translucent foreground windows retain occlusion semantics"
        )

        guard let recordingSupport else {
            throw SupportGeometryCheckError.missingRecordingSupport
        }
        let runtimeOverlay = try PetOverlay()
        defer { runtimeOverlay.stop() }
        let runtimeSession = PlacementSession(overlay: runtimeOverlay)
        let fingerprint = try PixelFingerprint(rgb: [UInt8](repeating: 220, count: 64 * 3))
        let runtimeSnapshot = SystemSnapshot(
            obstacles: [], unknownAreas: recordingVisibility.unknown,
            windows: recordingDecoded, accessibilityAvailable: true,
            supports: [recordingSupport]
        )
        let runtimeOutcome = await runtimeSession.refresh(
            bounds: capturedScreen, screenBounds: capturedScreen, visualAllowed: true,
            inspect: { runtimeSnapshot },
            capture: {
                PixelSample(bounds: $0, obstacles: [], fingerprint: fingerprint)
            },
            capturePerch: { region, _ in
                PixelSample(
                    bounds: region, obstacles: [], fingerprint: fingerprint,
                    supportEdges: [HorizontalSpan(minX: region.x, maxX: region.maxX)]
                )
            },
            current: { true }, cursor: { PetPoint(x: -1000, y: -1000) }, now: { 100 }
        )
        let sittingDeadline = ContinuousClock.now + .seconds(2)
        while !runtimeOverlay.isSitting && ContinuousClock.now < sittingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let runtimePlacement = runtimeOverlay.lastPlacement
        try check(
            runtimeOutcome == .shown(visual: true) && runtimeOverlay.isPerched
                && runtimeOverlay.isSitting && runtimeOverlay.panel.isVisible
                && runtimePlacement?.y == capturedHostBounds.y - 112
                && runtimePlacement == ScreenCoordinates.quartz(runtimeOverlay.panel.frame),
            "decoded recording scene reaches PlacementSession and seats the actual NSPanel"
        )

        let clippedTop = WindowRegion(
            id: 22, pid: 4,
            bounds: PetRect(x: 0, y: 0, width: 1200, height: 700),
            rawBounds: PetRect(x: 0, y: -80, width: 1200, height: 780)
        )
        try check(
            SystemInspector.perchSupport(
                for: clippedTop, visibleRegions: [clippedTop.bounds], in: screen
            ) == nil,
            "screen-clipped and fullscreen top edges never become supports"
        )

        let headOcclusion = WindowRegion(
            id: 23, pid: 5,
            bounds: PetRect(x: 350, y: 250, width: 150, height: 100)
        )
        let behind = WindowRegion(
            id: 24, pid: 6,
            bounds: PetRect(x: 500, y: 250, width: 200, height: 100)
        )
        let stack = [headOcclusion, background, behind]
        let stackedVisibility = SystemInspector.visibility(of: stack, in: screen)
        let bodySupport = SystemInspector.perchSupport(
            for: background, visibleRegions: stackedVisibility.windows[1], in: screen,
            foregroundWindows: Array(stack.prefix(1))
        )
        let bodyCandidate = bodySupport.flatMap {
            SupportGeometry.choose(
                in: screen, avoiding: [], size: PetSize(width: 128, height: 156),
                supports: [$0],
                nearestTo: PetRect(x: 450, y: 288, width: 84, height: 156)
            )
        }
        try check(
            bodySupport?.foregroundOcclusions == [headOcclusion.bounds]
                && bodyCandidate?.placement.x == 500
                && bodyCandidate?.placement.intersects(headOcclusion.bounds) == false
                && bodyCandidate?.placement.intersects(behind.bounds) == true,
            "foreground body occlusion blocks a perch while background windows do not"
        )

        var remainingNodes = 32
        let panel = PetRect(x: 180, y: 360, width: 500, height: 260)
        let anonymousPanel = PetRect(x: 700, y: 360, width: 180, height: 260)
        let image = PetRect(x: 820, y: 220, width: 220, height: 100)
        let emptyGroup = PetRect(x: 180, y: 650, width: 400, height: 100)
        let actionable = PetRect(x: 200, y: 220, width: 300, height: 100)
        let text = PetRect(x: 560, y: 220, width: 180, height: 40)
        let roles = [
            0: kAXWindowRole as String,
            1: kAXGroupRole as String, 2: kAXStaticTextRole as String,
            3: kAXGroupRole as String, 4: kAXStaticTextRole as String,
            5: kAXGroupRole as String, 6: kAXGroupRole as String,
            7: kAXStaticTextRole as String, 8: kAXImageRole as String,
            9: kAXStaticTextRole as String,
        ]
        let frames = [
            1: panel, 2: PetRect(x: 200, y: 390, width: 60, height: 20),
            3: anonymousPanel, 4: PetRect(x: 720, y: 390, width: 40, height: 20),
            5: emptyGroup, 6: actionable,
            7: PetRect(x: 210, y: 230, width: 40, height: 20),
            8: image, 9: text,
        ]
        let children = [0: [1, 3, 5, 6, 8, 9], 1: [2], 3: [4], 6: [7]]
        let tree = SystemInspector.inspectTreeWithSupports(
            root: 0, visibleRegions: [screen], remainingNodes: &remainingNodes,
            isExpired: { false }, readRole: { roles[$0] }, readVisibility: { _ in .visible },
            readFrame: { frames[$0].map(SystemInspector.accessibilityFrame) ?? .unavailable },
            readChildren: { .available(children[$0] ?? []) },
            readActions: { $0 == 6 ? [kAXPressAction as String] : [] }
        )
        let host = WindowRegion(id: 30, pid: 7,
            bounds: PetRect(x: 100, y: 180, width: 1000, height: 600))
        let identified = tree.publishedSupports.enumerated().map {
            SystemInspector.IdentifiedPublishedSupport(
                token: UInt64($0.offset + 1), role: $0.element.role, bounds: $0.element.bounds
            )
        }
        let elementSupports = SystemInspector.elementSupports(
            identified, in: host, visibleRegions: [host.bounds], screen: screen
        )
        try check(
            tree.complete
                && tree.publishedSupports.map(\.element).sorted() == [1, 3, 8]
                && elementSupports.count == 3
                && elementSupports.first?.id == SupportID(windowID: 30, pid: 7, elementToken: 1)
                && elementSupports.first?.bounds == panel
                && tree.obstacles.contains(actionable) && tree.obstacles.contains(text)
                && tree.unknown.contains(emptyGroup) && tree.unknown.contains(image),
            "anonymous readable panels and images publish supports without weakening controls or text"
        )

        let moved = SystemInspector.elementSupports(
            [SystemInspector.IdentifiedPublishedSupport(token: 1,
                role: kAXGroupRole as String,
                bounds: PetRect(x: 220, y: 380, width: 500, height: 260))],
            in: host, visibleRegions: [host.bounds], screen: screen
        )
        try check(moved.first?.id == elementSupports.first?.id
                  && moved.first?.bounds != elementSupports.first?.bounds,
                  "published element identity survives movement while its edge follows the new frame")
        try check(SystemInspector.registrationIdentityCheck(),
                  "real AX element identity is stable across wrappers and distinct across processes")
    }
}

private enum SupportGeometryCheckError: Error {
    case missingRecordingSupport
}
