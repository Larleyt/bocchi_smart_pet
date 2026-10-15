import XCTest
@testable import BocchiCore

final class PlacementEngineTests: XCTestCase {
    private let petSize = PetSize(width: 40, height: 30)

    func testGeometryUsesHalfOpenIntersectionAndInclusiveContainment() {
        let rect = PetRect(x: -10, y: 5, width: 20, height: 10)
        XCTAssertEqual(rect.maxX, 10)
        XCTAssertEqual(rect.maxY, 15)
        XCTAssertTrue(rect.contains(PetPoint(x: 10, y: 15)))
        XCTAssertFalse(rect.contains(PetPoint(x: 10.01, y: 15)))
        XCTAssertTrue(rect.contains(PetRect(x: -10, y: 5, width: 20, height: 10)))
        XCTAssertFalse(rect.intersects(PetRect(x: 10, y: 5, width: 3, height: 3)))
        XCTAssertTrue(rect.intersects(PetRect(x: 9, y: 14, width: 3, height: 3)))
    }

    func testEmptyScreenChoosesSideAtMiddleHeight() throws {
        let screen = PetRect(x: 100, y: 50, width: 300, height: 200)
        let result = PlacementEngine.choose(
            in: screen,
            avoiding: [], size: petSize, previous: nil
        )
        let placed = try XCTUnwrap(result)
        XCTAssertTrue(abs(placed.x - (screen.x + 24)) <= 2
            || abs(placed.maxX - (screen.maxX - 24)) <= 2)
        XCTAssertEqual(placed.y + placed.height / 2, screen.y + screen.height / 2, accuracy: 2)
    }

    func testNarrowScreenClampsSideInsetInsideAvailableTravel() throws {
        let screen = PetRect(x: -30, y: 10, width: 60, height: 100)
        let placed = try XCTUnwrap(PlacementEngine.choose(
            in: screen, avoiding: [], size: petSize, previous: nil
        ))
        XCTAssertEqual(placed.x, -20, accuracy: 2)
        XCTAssertEqual(placed.y + placed.height / 2, screen.y + screen.height / 2, accuracy: 2)
    }

    func testChoosesSideBackgroundInsteadOfSmallBottomRightPocket() throws {
        let result = PlacementEngine.choose(
            in: PetRect(x: 0, y: 0, width: 400, height: 240),
            avoiding: [PetRect(x: 250, y: 0, width: 90, height: 240)],
            size: petSize, previous: nil
        )
        let placed = try XCTUnwrap(result)
        XCTAssertLessThan(placed.maxX, 238)
        XCTAssertEqual(placed.y + placed.height / 2, 120, accuracy: 2)
    }

    func testSafePreviousPositionIsPreserved() {
        let previous = PetRect(x: 25, y: 35, width: 40, height: 30)
        XCTAssertEqual(PlacementEngine.choose(
            in: PetRect(x: 0, y: 0, width: 300, height: 200),
            avoiding: [PetRect(x: 180, y: 100, width: 20, height: 20)],
            size: petSize, previous: previous,
            nearestTo: PetRect(x: 240, y: 150, width: 40, height: 30)
        ), previous)
    }

    func testPreviousAtExactlyTwelvePointClearanceIsSafe() {
        let previous = PetRect(x: 0, y: 0, width: 40, height: 30)
        XCTAssertEqual(PlacementEngine.choose(
            in: PetRect(x: 0, y: 0, width: 200, height: 100),
            avoiding: [PetRect(x: 52, y: 0, width: 20, height: 20)],
            size: petSize, previous: previous
        ), previous)
    }

    func testUnsafePreviousMovesToSafePosition() throws {
        let screen = PetRect(x: 0, y: 0, width: 300, height: 180)
        let previous = PetRect(x: 20, y: 20, width: 40, height: 30)
        let result = PlacementEngine.choose(
            in: screen,
            avoiding: [PetRect(x: 10, y: 10, width: 80, height: 60)],
            size: petSize, previous: previous
        )
        let placed = try XCTUnwrap(result)
        XCTAssertNotEqual(placed, previous)
        XCTAssertTrue(screen.contains(placed))
        XCTAssertFalse(placed.intersects(PetRect(x: -2, y: -2, width: 104, height: 84)))
    }

    func testUnsafePreviousMovesToNearestSafePosition() throws {
        let origin = PetRect(x: 450, y: 285, width: 40, height: 30)
        let placed = try XCTUnwrap(PlacementEngine.choose(
            in: PetRect(x: 0, y: 0, width: 1_000, height: 600),
            avoiding: [PetRect(x: 440, y: 270, width: 40, height: 60)],
            size: petSize, previous: nil, nearestTo: origin
        ))
        let dx = (placed.x + placed.width / 2) - (origin.x + origin.width / 2)
        let dy = (placed.y + placed.height / 2) - (origin.y + origin.height / 2)
        XCTAssertLessThanOrEqual(dx * dx + dy * dy, 2_500)
    }

    func testOccupiedSideFallsBackToAnotherActuallyFreePosition() throws {
        let screen = PetRect(x: 0, y: 0, width: 400, height: 240)
        let obstacles = [
            PetRect(x: 0, y: 70, width: 80, height: 100),
            PetRect(x: 320, y: 70, width: 80, height: 100)
        ]
        let placed = try XCTUnwrap(PlacementEngine.choose(
            in: screen, avoiding: obstacles, size: petSize, previous: nil
        ))
        XCTAssertTrue(screen.contains(placed))
        for obstacle in obstacles {
            XCTAssertFalse(placed.intersects(PetRect(
                x: obstacle.x - 12, y: obstacle.y - 12,
                width: obstacle.width + 24, height: obstacle.height + 24
            )))
        }
        XCTAssertEqual(placed.y + placed.height / 2, screen.y + screen.height / 2, accuracy: 2)
    }

    func testInitialPlacementPrefersFreeCenterOverTopCorner() throws {
        let screen = PetRect(x: 0, y: 0, width: 2_000, height: 700)
        let placed = try XCTUnwrap(PlacementEngine.choose(
            in: screen,
            avoiding: [
                PetRect(x: 0, y: 100, width: 800, height: 500),
                PetRect(x: 1_200, y: 100, width: 800, height: 500)
            ],
            size: petSize, previous: nil
        ))
        XCTAssertGreaterThanOrEqual(placed.x, 812)
        XCTAssertLessThanOrEqual(placed.maxX, 1_188)
        XCTAssertGreaterThanOrEqual(placed.y, 72)
        XCTAssertLessThanOrEqual(placed.maxY, 580)
    }

    func testQuartzTopBandUsesSeventyTwoPointReserve() throws {
        let placed = try XCTUnwrap(PlacementEngine.choose(
            in: PetRect(x: 0, y: 0, width: 400, height: 300),
            avoiding: [PetRect(x: 0, y: 114, width: 400, height: 64)],
            size: petSize, previous: nil
        ))
        XCTAssertEqual(placed.y, 72, accuracy: 2)
        XCTAssertLessThanOrEqual(placed.maxY, 180)
    }

    func testInitialPlacementFallsBackWhenReservedMiddleIsFull() throws {
        let screen = PetRect(x: 0, y: 0, width: 400, height: 300)
        let placed = try XCTUnwrap(PlacementEngine.choose(
            in: screen,
            avoiding: [PetRect(x: 0, y: 102, width: 400, height: 86)],
            size: petSize, previous: nil
        ))
        XCTAssertTrue(placed.y < 72 || placed.maxY > 180)
    }

    func testDenseSceneReturnsNil() {
        XCTAssertNil(PlacementEngine.choose(
            in: PetRect(x: 0, y: 0, width: 200, height: 120),
            avoiding: [PetRect(x: 0, y: 0, width: 200, height: 120)],
            size: petSize, previous: nil
        ))
    }

    func testExactPetHeightCorridorRemainsUsable() {
        let result = PlacementEngine.choose(
            in: PetRect(x: 0, y: 0, width: 300, height: 120),
            avoiding: [
                PetRect(x: 0, y: 0, width: 300, height: 32),
                PetRect(x: 0, y: 86, width: 300, height: 34)
            ],
            size: petSize, previous: nil
        )
        XCTAssertEqual(result?.y, 44)
        XCTAssertEqual(result?.x ?? .nan, 24, accuracy: 2)
    }

    func testNegativeMonitorOriginAndOffscreenObstacle() {
        let result = PlacementEngine.choose(
            in: PetRect(x: -1_920, y: -100, width: 1_920, height: 1_080),
            avoiding: [PetRect(x: 100, y: 100, width: 500, height: 500)],
            size: PetSize(width: 100, height: 80), previous: nil
        )
        XCTAssertEqual(result?.x ?? .nan, -1_896, accuracy: 2)
        XCTAssertEqual((result?.y ?? 0) + 40, 440, accuracy: 2)
    }

    func testInvalidOrOversizedGeometryReturnsNil() {
        XCTAssertNil(PlacementEngine.choose(
            in: PetRect(x: 0, y: 0, width: 30, height: 20),
            avoiding: [], size: petSize, previous: nil
        ))
        XCTAssertNil(PlacementEngine.choose(
            in: PetRect(x: 0, y: 0, width: .nan, height: 100),
            avoiding: [], size: petSize, previous: nil
        ))
    }

    func testRandomizedResultsAlwaysRespectBoundsAndPadding() {
        var random = LCG(state: 0xB0CC_1)
        let screen = PetRect(x: -640, y: -200, width: 960, height: 700)

        for _ in 0..<100 {
            let obstacles = (0..<30).map { _ in
                PetRect(
                    x: -700 + random.next(1_100), y: -250 + random.next(850),
                    width: 5 + random.next(120), height: 5 + random.next(90)
                )
            }
            guard let result = PlacementEngine.choose(
                in: screen, avoiding: obstacles, size: petSize, previous: nil
            ) else { continue }

            XCTAssertTrue(screen.contains(result))
            for obstacle in obstacles {
                XCTAssertFalse(result.intersects(PetRect(
                    x: obstacle.x - 12, y: obstacle.y - 12,
                    width: obstacle.width + 24, height: obstacle.height + 24
                )))
            }
        }
    }
}

private struct LCG {
    var state: UInt64

    mutating func next(_ upperBound: Double) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return Double(state >> 11) / Double(UInt64.max >> 11) * upperBound
    }
}
