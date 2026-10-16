import XCTest
@testable import BocchiCore

final class RunCycleTests: XCTestCase {
    private let rightRigOffsetX = 30.0
    private let trajectoryAnkles = [
        PetPoint(x: 99, y: 198), PetPoint(x: 80, y: 198),
        PetPoint(x: 52, y: 195), PetPoint(x: 48, y: 174),
        PetPoint(x: 56, y: 173), PetPoint(x: 76, y: 179),
        PetPoint(x: 95, y: 181), PetPoint(x: 103, y: 188),
    ]
    private let hipYs = [146.0, 148, 143, 140, 146, 148, 143, 140]

    func testEightPhasesUseTheAuthoredFootPlantsAndHalfCycleOffset() {
        for index in 0..<RunCycle.phaseCount {
            let pose = RunCycle.pose(index: index)
            XCTAssertEqual(pose.nearLeg.hip, PetPoint(x: 105, y: hipYs[index]))
            XCTAssertEqual(pose.nearLeg.ankle, worldAnkle(index))
            XCTAssertEqual(pose.farLeg.ankle, worldAnkle((index + 4) % 8))
            XCTAssertEqual(pose.nearArm.shoulder, PetPoint(x: 97, y: 84 + pose.bodyBob))
            XCTAssertEqual(pose.farArm.shoulder, PetPoint(x: 113, y: 84 + pose.bodyBob))
            XCTAssertEqual(pose.bodyBob, hipYs[index] - 146)
        }
    }

    func testOppositeLegsExchangeTheirFootPlantsAfterHalfACycle() {
        for index in 0..<4 {
            let first = RunCycle.pose(index: index)
            let second = RunCycle.pose(index: index + 4)
            XCTAssertEqual(first.nearLeg.ankle, second.farLeg.ankle)
            XCTAssertEqual(first.farLeg.ankle, second.nearLeg.ankle)
        }
        XCTAssertGreaterThan(RunCycle.pose(index: 0).nearLeg.ankle.x, 105)
        XCTAssertLessThan(RunCycle.pose(index: 4).nearLeg.ankle.x, 105)
    }

    func testArmsCounterTheNearLegAndKeepTheirLengths() {
        var correlation = 0.0
        for index in 0..<RunCycle.phaseCount {
            let pose = RunCycle.pose(index: index)
            correlation += (pose.nearLeg.ankle.x - pose.nearLeg.hip.x)
                * (pose.nearArm.wrist.x - pose.nearArm.shoulder.x)
            assertDistance(pose.nearArm.shoulder, pose.nearArm.elbow, equals: 24)
            assertDistance(pose.nearArm.elbow, pose.nearArm.wrist, equals: 19)
            assertDistance(pose.farArm.shoulder, pose.farArm.elbow, equals: 24)
            assertDistance(pose.farArm.elbow, pose.farArm.wrist, equals: 19)
            XCTAssertGreaterThan(pose.nearArm.wrist.y, pose.nearArm.shoulder.y)
            XCTAssertGreaterThan(pose.farArm.wrist.y, pose.farArm.shoulder.y)
        }
        XCTAssertLessThan(correlation, 0)
    }

    func testLegIKKeepsBothBonesFixedAndBendsKneesForward() {
        for index in 0..<RunCycle.phaseCount {
            let pose = RunCycle.pose(index: index)
            for leg in [pose.nearLeg, pose.farLeg] {
                assertDistance(leg.hip, leg.knee, equals: RunCycle.thighLength)
                assertDistance(leg.knee, leg.ankle, equals: RunCycle.calfLength)
                XCTAssertGreaterThanOrEqual(leg.knee.x, projectedKneeBaseX(leg))
            }
        }
    }

    func testFacingLeftMirrorsEveryJointInsideTheLogicalCanvas() {
        for index in 0..<RunCycle.phaseCount {
            let right = RunCycle.pose(index: index)
            let left = RunCycle.pose(index: index, facingLeft: true)
            XCTAssertEqual(left.bodyBob, right.bodyBob)
            for (rightPoint, leftPoint) in zip(points(right), points(left)) {
                XCTAssertEqual(leftPoint.x, RunCycle.canvasSize.width - rightPoint.x,
                               accuracy: 1e-10)
                XCTAssertEqual(leftPoint.y, rightPoint.y, accuracy: 1e-10)
            }
        }
    }

    func testPhaseIndexWrapsInBothDirections() {
        XCTAssertEqual(RunCycle.pose(index: 8), RunCycle.pose(index: 0))
        XCTAssertEqual(RunCycle.pose(index: -1), RunCycle.pose(index: 7))
        XCTAssertEqual(RunCycle.canvasSize, PetSize(width: 160, height: 208))
    }

    private func assertDistance(_ first: PetPoint, _ second: PetPoint, equals expected: Double,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(hypot(second.x - first.x, second.y - first.y), expected,
                       accuracy: 1e-10, file: file, line: line)
    }

    private func projectedKneeBaseX(_ leg: RunLegPose) -> Double {
        let dx = leg.ankle.x - leg.hip.x
        let dy = leg.ankle.y - leg.hip.y
        let distance = hypot(dx, dy)
        let along = (RunCycle.thighLength * RunCycle.thighLength
                     - RunCycle.calfLength * RunCycle.calfLength + distance * distance)
            / (2 * distance)
        return leg.hip.x + along * dx / distance
    }

    private func points(_ pose: RunPose) -> [PetPoint] {
        [
            pose.nearArm.shoulder, pose.nearArm.elbow, pose.nearArm.wrist,
            pose.farArm.shoulder, pose.farArm.elbow, pose.farArm.wrist,
            pose.nearLeg.hip, pose.nearLeg.knee, pose.nearLeg.ankle,
            pose.farLeg.hip, pose.farLeg.knee, pose.farLeg.ankle,
        ]
    }

    private func worldAnkle(_ index: Int) -> PetPoint {
        let point = trajectoryAnkles[index]
        return PetPoint(x: point.x + rightRigOffsetX, y: point.y)
    }
}
