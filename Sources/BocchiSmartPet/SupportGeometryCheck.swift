import BocchiCore

@MainActor
enum SupportGeometryCheck {
    static func run(_ check: (Bool, String) throws -> Void) throws {
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
            support?.id == SupportWindowID(windowID: 21, pid: 3)
                && support?.spans == [
                    HorizontalSpan(minX: 100, maxX: 300),
                    HorizontalSpan(minX: 600, maxX: 1000),
                ],
            "foreground windows split a native top edge into truly visible spans"
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
    }
}
