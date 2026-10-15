public enum PixelFingerprintError: Error {
    case invalidRGBCount
}

public struct PixelFingerprint: Sendable, Equatable {
    private static let maximumRGBCount = 64 * 96 * 3
    private let rgb: [UInt8]

    public init(rgb: [UInt8]) throws {
        guard !rgb.isEmpty,
              rgb.count.isMultiple(of: 3),
              rgb.count <= Self.maximumRGBCount
        else { throw PixelFingerprintError.invalidRGBCount }
        self.rgb = rgb
    }

    public func changedFraction(comparedTo other: Self, tolerance: UInt8 = 12) -> Double? {
        guard rgb.count == other.rgb.count else { return nil }
        var changed = 0
        for index in stride(from: 0, to: rgb.count, by: 3) {
            let delta = max(
                abs(Int(rgb[index]) - Int(other.rgb[index])),
                abs(Int(rgb[index + 1]) - Int(other.rgb[index + 1])),
                abs(Int(rgb[index + 2]) - Int(other.rgb[index + 2]))
            )
            changed += delta > Int(tolerance) ? 1 : 0
        }
        return Double(changed) / Double(rgb.count / 3)
    }
}
