public struct SupportWindowID: Sendable, Hashable {
    public let windowID: UInt32
    public let pid: Int32

    public init(windowID: UInt32, pid: Int32) {
        self.windowID = windowID
        self.pid = pid
    }
}

public struct HorizontalSpan: Sendable, Equatable {
    public let minX: Double
    public let maxX: Double

    public init(minX: Double, maxX: Double) {
        self.minX = minX
        self.maxX = maxX
    }
}

public struct PerchSupport: Sendable, Equatable {
    public let id: SupportWindowID
    public let windowBounds: PetRect
    public let spans: [HorizontalSpan]
    public let foregroundOcclusions: [PetRect]

    public init(id: SupportWindowID, windowBounds: PetRect, spans: [HorizontalSpan],
                foregroundOcclusions: [PetRect] = []) {
        self.id = id
        self.windowBounds = windowBounds
        self.spans = spans
        self.foregroundOcclusions = foregroundOcclusions
    }
}

public struct PerchCandidate: Sendable, Equatable {
    public let supportID: SupportWindowID
    public let placement: PetRect

    public init(supportID: SupportWindowID, placement: PetRect) {
        self.supportID = supportID
        self.placement = placement
    }
}

public enum SupportGeometry {
    public static func choose(
        in screen: PetRect,
        avoiding blocked: [PetRect],
        size: PetSize,
        seatOffset: Double = 112,
        supports: [PerchSupport],
        nearestTo previous: PetRect?
    ) -> PerchCandidate? {
        guard valid(screen), valid(size), seatOffset.isFinite,
              seatOffset > 0, seatOffset <= size.height else { return nil }
        let origin: PetPoint
        if let previous, valid(previous) {
            origin = PetPoint(x: previous.x + previous.width / 2,
                              y: previous.y + previous.height / 2)
        } else {
            origin = PetPoint(x: screen.x + screen.width / 2,
                              y: screen.y + screen.height / 2)
        }
        var best: (distance: Double, candidate: PerchCandidate)?

        for support in supports where valid(support.windowBounds) {
            let y = support.windowBounds.y - seatOffset
            guard y.isFinite else { continue }
            let verticalPlacement = PetRect(x: 0, y: y, width: size.width, height: size.height)
            let forbidden = (blocked + support.foregroundOcclusions).compactMap {
                obstacle -> (Double, Double)? in
                guard valid(obstacle), verticalPlacement.y < obstacle.maxY,
                      verticalPlacement.maxY > obstacle.y else { return nil }
                return (obstacle.x - size.width, obstacle.maxX)
            }.sorted { $0.0 < $1.0 }
            for span in support.spans where span.minX.isFinite && span.maxX.isFinite {
                let minimum = span.minX
                let maximum = span.maxX - size.width
                guard minimum >= support.windowBounds.x,
                      span.maxX <= support.windowBounds.maxX,
                      minimum <= maximum else { continue }
                let targetX = min(max(origin.x - size.width / 2, minimum), maximum)
                var free: [(Double, Double)] = []
                var cursor = minimum
                for interval in forbidden where interval.1 >= minimum && interval.0 <= maximum {
                    if interval.0 >= cursor {
                        free.append((cursor, min(interval.0, maximum)))
                    }
                    cursor = max(cursor, interval.1)
                    if cursor > maximum { break }
                }
                if cursor <= maximum { free.append((cursor, maximum)) }
                for interval in free {
                    let x = min(max(targetX, interval.0), interval.1)
                    let placement = PetRect(x: x, y: y, width: size.width, height: size.height)
                    guard screen.contains(placement) else { continue }
                    let dx = x + size.width / 2 - origin.x
                    let dy = y + size.height / 2 - origin.y
                    let distance = dx * dx + dy * dy
                    if distance < (best?.distance ?? .infinity) {
                        best = (distance, PerchCandidate(
                            supportID: support.id, placement: placement
                        ))
                    }
                }
            }
        }
        return best?.candidate
    }

    private static func valid(_ rect: PetRect) -> Bool {
        rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func valid(_ size: PetSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
