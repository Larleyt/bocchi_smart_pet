import BocchiCore
import XCTest

final class PixelFingerprintTests: XCTestCase {
    func testChangedFractionReportsTenPercent() throws {
        let baseline = try PixelFingerprint(rgb: [UInt8](repeating: 0, count: 30))
        var changedRGB = [UInt8](repeating: 0, count: 30)
        changedRGB[12] = 13

        XCTAssertEqual(try PixelFingerprint(rgb: changedRGB).changedFraction(comparedTo: baseline), 0.1)
    }

    func testColorNoiseAtToleranceIsUnchanged() throws {
        let baseline = try PixelFingerprint(rgb: [10, 20, 30, 100, 110, 120])
        let noise = try PixelFingerprint(rgb: [22, 8, 42, 88, 122, 108])

        XCTAssertEqual(noise.changedFraction(comparedTo: baseline), 0)
    }

    func testIdenticalStaticFingerprintIsUnchanged() throws {
        let fingerprint = try PixelFingerprint(rgb: [1, 2, 3, 4, 5, 6])

        XCTAssertEqual(fingerprint.changedFraction(comparedTo: fingerprint), 0)
    }

    func testInvalidRGBCountsAreRejected() {
        XCTAssertThrowsError(try PixelFingerprint(rgb: []))
        XCTAssertThrowsError(try PixelFingerprint(rgb: [1, 2]))
        XCTAssertThrowsError(try PixelFingerprint(rgb: [UInt8](repeating: 0, count: 64 * 96 * 3 + 3)))
    }

    func testMismatchedFingerprintsCannotBeCompared() throws {
        let short = try PixelFingerprint(rgb: [0, 0, 0])
        let long = try PixelFingerprint(rgb: [0, 0, 0, 0, 0, 0])

        XCTAssertNil(short.changedFraction(comparedTo: long))
    }
}
