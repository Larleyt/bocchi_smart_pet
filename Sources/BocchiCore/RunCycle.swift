import Foundation

public struct RunArmPose: Sendable, Equatable {
    public let shoulder: PetPoint
    public let elbow: PetPoint
    public let wrist: PetPoint

    public init(shoulder: PetPoint, elbow: PetPoint, wrist: PetPoint) {
        self.shoulder = shoulder
        self.elbow = elbow
        self.wrist = wrist
    }
}

public struct RunLegPose: Sendable, Equatable {
    public let hip: PetPoint
    public let knee: PetPoint
    public let ankle: PetPoint

    public init(hip: PetPoint, knee: PetPoint, ankle: PetPoint) {
        self.hip = hip
        self.knee = knee
        self.ankle = ankle
    }
}

public struct RunPose: Sendable, Equatable {
    public let nearArm: RunArmPose
    public let farArm: RunArmPose
    public let nearLeg: RunLegPose
    public let farLeg: RunLegPose
    public let bodyBob: Double

    public init(nearArm: RunArmPose, farArm: RunArmPose,
                nearLeg: RunLegPose, farLeg: RunLegPose, bodyBob: Double) {
        self.nearArm = nearArm
        self.farArm = farArm
        self.nearLeg = nearLeg
        self.farLeg = farLeg
        self.bodyBob = bodyBob
    }
}

public enum RunCycle {
    public static let canvasSize = PetSize(width: 160, height: 208)
    public static let phaseCount = 8
    public static let thighLength = 28.0
    public static let calfLength = 30.0

    private static let rigOffsetX = 30.0
    private static let trajectoryAnkles = [
        PetPoint(x: 99, y: 198), PetPoint(x: 80, y: 198),
        PetPoint(x: 52, y: 195), PetPoint(x: 48, y: 174),
        PetPoint(x: 56, y: 173), PetPoint(x: 76, y: 179),
        PetPoint(x: 95, y: 181), PetPoint(x: 103, y: 188),
    ]
    private static let hipYs = [146.0, 148, 143, 140, 146, 148, 143, 140]

    public static func pose(index: Int, facingLeft: Bool = false) -> RunPose {
        let phase = ((index % phaseCount) + phaseCount) % phaseCount
        let hip = PetPoint(x: 75 + rigOffsetX, y: hipYs[phase])
        let bob = hip.y - 146
        let nearLeg = leg(hip: hip, ankle: worldAnkle(phase))
        let farLeg = leg(hip: hip, ankle: worldAnkle((phase + phaseCount / 2) % phaseCount))
        let nearSwing = -cos(Double(phase) * .pi / 4)
        let pose = RunPose(
            nearArm: arm(shoulder: PetPoint(x: 97, y: 84 + bob), swing: nearSwing),
            farArm: arm(shoulder: PetPoint(x: 113, y: 84 + bob), swing: -nearSwing),
            nearLeg: nearLeg,
            farLeg: farLeg,
            bodyBob: bob
        )
        return facingLeft ? mirrored(pose) : pose
    }

    private static func worldAnkle(_ phase: Int) -> PetPoint {
        let point = trajectoryAnkles[phase]
        return PetPoint(x: point.x + rigOffsetX, y: point.y)
    }

    private static func leg(hip: PetPoint, ankle: PetPoint) -> RunLegPose {
        let dx = ankle.x - hip.x
        let dy = ankle.y - hip.y
        let distance = hypot(dx, dy)
        let along = (thighLength * thighLength - calfLength * calfLength
                     + distance * distance) / (2 * distance)
        let height = sqrt(max(0, thighLength * thighLength - along * along))
        let base = PetPoint(x: hip.x + along * dx / distance,
                            y: hip.y + along * dy / distance)
        let perpendicular = PetPoint(x: -dy * height / distance,
                                     y: dx * height / distance)
        let first = PetPoint(x: base.x + perpendicular.x, y: base.y + perpendicular.y)
        let second = PetPoint(x: base.x - perpendicular.x, y: base.y - perpendicular.y)
        return RunLegPose(hip: hip, knee: first.x >= second.x ? first : second, ankle: ankle)
    }

    private static func arm(shoulder: PetPoint, swing: Double) -> RunArmPose {
        let upperLength = 24.0
        let forearmLength = 19.0
        let upperX = 16 * swing
        let elbow = PetPoint(x: shoulder.x + upperX,
                             y: shoulder.y + sqrt(upperLength * upperLength - upperX * upperX))
        let forearmX = 16 * swing
        let wrist = PetPoint(x: elbow.x + forearmX,
                             y: elbow.y - sqrt(forearmLength * forearmLength
                                              - forearmX * forearmX))
        return RunArmPose(shoulder: shoulder, elbow: elbow, wrist: wrist)
    }

    private static func mirrored(_ pose: RunPose) -> RunPose {
        func point(_ value: PetPoint) -> PetPoint {
            PetPoint(x: canvasSize.width - value.x, y: value.y)
        }
        func arm(_ value: RunArmPose) -> RunArmPose {
            RunArmPose(shoulder: point(value.shoulder), elbow: point(value.elbow),
                       wrist: point(value.wrist))
        }
        func leg(_ value: RunLegPose) -> RunLegPose {
            RunLegPose(hip: point(value.hip), knee: point(value.knee), ankle: point(value.ankle))
        }
        return RunPose(nearArm: arm(pose.nearArm), farArm: arm(pose.farArm),
                       nearLeg: leg(pose.nearLeg), farLeg: leg(pose.farLeg),
                       bodyBob: pose.bodyBob)
    }
}
