public struct PetPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PetSize: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct PetRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func intersects(_ other: PetRect) -> Bool {
        x < other.maxX && maxX > other.x && y < other.maxY && maxY > other.y
    }

    public func contains(_ point: PetPoint) -> Bool {
        x <= point.x && point.x <= maxX && y <= point.y && point.y <= maxY
    }

    public func contains(_ other: PetRect) -> Bool {
        x <= other.x && y <= other.y && maxX >= other.maxX && maxY >= other.maxY
    }
}
