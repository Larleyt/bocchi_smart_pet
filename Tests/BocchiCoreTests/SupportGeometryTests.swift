import XCTest
@testable import BocchiCore

final class SupportGeometryTests: XCTestCase {
    private let screen = PetRect(x: 0, y: 0, width: 1200, height: 800)
    private let pet = PetSize(width: 128, height: 156)

    func testChoosesNearestClearSeatOnVisibleWindowTop() throws {
        let left = PerchSupport(
            id: SupportWindowID(windowID: 7, pid: 70),
            windowBounds: PetRect(x: 100, y: 400, width: 700, height: 300),
            spans: [HorizontalSpan(minX: 100, maxX: 800)]
        )
        let right = PerchSupport(
            id: SupportWindowID(windowID: 8, pid: 80),
            windowBounds: PetRect(x: 850, y: 350, width: 300, height: 350),
            spans: [HorizontalSpan(minX: 850, maxX: 1150)]
        )
        let previous = PetRect(x: 760, y: 260, width: 84, height: 156)

        let candidate = try XCTUnwrap(SupportGeometry.choose(
            in: screen, avoiding: [], size: pet, supports: [left, right], nearestTo: previous
        ))

        XCTAssertEqual(candidate.supportID, left.id)
        XCTAssertEqual(candidate.placement.y, 288)
        XCTAssertEqual(candidate.placement.x, 672)
    }

    func testBlockedSeatSlidesToNearestClearPointOnSameEdge() throws {
        let support = PerchSupport(
            id: SupportWindowID(windowID: 9, pid: 90),
            windowBounds: PetRect(x: 100, y: 400, width: 700, height: 300),
            spans: [HorizontalSpan(minX: 100, maxX: 800)]
        )
        let previous = PetRect(x: 370, y: 288, width: 84, height: 156)
        let blocked = PetRect(x: 340, y: 250, width: 120, height: 190)

        let candidate = try XCTUnwrap(SupportGeometry.choose(
            in: screen, avoiding: [blocked], size: pet,
            supports: [support], nearestTo: previous
        ))

        XCTAssertEqual(candidate.supportID, support.id)
        XCTAssertEqual(candidate.placement.y, 288)
        XCTAssertFalse(candidate.placement.intersects(blocked))
        XCTAssertEqual(candidate.placement.x, 460)
    }

    func testForegroundWindowAboveEdgeStillBlocksPetBody() throws {
        let foreground = PetRect(x: 350, y: 250, width: 150, height: 100)
        let support = PerchSupport(
            id: SupportWindowID(windowID: 9, pid: 90),
            windowBounds: PetRect(x: 100, y: 400, width: 700, height: 300),
            spans: [HorizontalSpan(minX: 100, maxX: 800)],
            foregroundOcclusions: [foreground]
        )
        let previous = PetRect(x: 450, y: 288, width: 84, height: 156)

        let candidate = try XCTUnwrap(SupportGeometry.choose(
            in: screen, avoiding: [], size: pet,
            supports: [support], nearestTo: previous
        ))

        XCTAssertFalse(candidate.placement.intersects(foreground))
        XCTAssertEqual(candidate.placement.x, 500)
    }

    func testRejectsClippedShortAndHeadroomStarvedSupports() {
        let identity = SupportWindowID(windowID: 10, pid: 100)
        let clipped = PerchSupport(
            id: identity,
            windowBounds: PetRect(x: 100, y: 400, width: 700, height: 300),
            spans: [HorizontalSpan(minX: 100, maxX: 170)]
        )
        let starved = PerchSupport(
            id: identity,
            windowBounds: PetRect(x: 100, y: 80, width: 700, height: 500),
            spans: [HorizontalSpan(minX: 100, maxX: 800)]
        )

        XCTAssertNil(SupportGeometry.choose(
            in: screen, avoiding: [], size: pet, supports: [clipped, starved], nearestTo: nil
        ))
    }

    func testRejectsSpanOutsideItsWindow() {
        let malformed = PerchSupport(
            id: SupportWindowID(windowID: 10, pid: 100),
            windowBounds: PetRect(x: 300, y: 400, width: 400, height: 300),
            spans: [HorizontalSpan(minX: 100, maxX: 700)]
        )

        XCTAssertNil(SupportGeometry.choose(
            in: screen, avoiding: [], size: pet, supports: [malformed], nearestTo: nil
        ))
    }

    func testSupportIdentityIncludesWindowAndProcess() {
        XCTAssertNotEqual(
            SupportWindowID(windowID: 11, pid: 101),
            SupportWindowID(windowID: 11, pid: 102)
        )
        XCTAssertNotEqual(
            SupportWindowID(windowID: 11, pid: 101),
            SupportWindowID(windowID: 12, pid: 101)
        )
    }
}
