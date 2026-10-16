import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum PaintedRunFrames {
    static let frameCount = 4
    static let cellSize = 627
    static let atlasSize = cellSize * 2
    static let commonCrop = CGRect(x: 86, y: 8, width: 455, height: 614)
    private static var cache: [URL: [NSImage]] = [:]

    static func frames(leftAsset: URL, rightAsset: URL) throws
        -> (right: [NSImage], left: [NSImage]) {
        (right: try load(rightAsset), left: try load(leftAsset))
    }

    private static func load(_ asset: URL) throws -> [NSImage] {
        let cacheKey = asset.standardizedFileURL
        if let cached = cache[cacheKey] { return cached }
        guard let source = CGImageSourceCreateWithURL(asset as CFURL, nil),
              let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String) == .png,
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
              atlas.width == atlasSize, atlas.height == atlasSize else {
            throw AtlasError.invalidAsset
        }

        let frames = try (0..<frameCount).map { index in
            let cellRect = CGRect(x: (index % 2) * cellSize,
                                  y: (index / 2) * cellSize,
                                  width: cellSize, height: cellSize)
            guard let cell = atlas.cropping(to: cellRect),
                  let frame = cell.cropping(to: commonCrop) else {
                throw AtlasError.invalidAsset
            }
            return try SpriteView.cleanedSpriteFrame(frame, size: commonCrop.size)
        }
        cache[cacheKey] = frames
        return frames
    }
}
