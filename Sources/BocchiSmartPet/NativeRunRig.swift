import AppKit
import BocchiCore
import ImageIO

@MainActor
enum NativeRunRig {
    private struct Manifest: Decodable {
        let parts: [Part]
        let torsoHeight: Double
        let torsoRightHip: Anchor
        let torsoLeftHip: Anchor
        let shoeHeight: Double
        let shoeRightAnkle: Anchor
        let shoeLeftAnkle: Anchor
    }

    private struct Anchor: Decodable {
        let x: Double
        let y: Double

        var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
    }

    private struct Part: Decodable {
        let name: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    static func frames(asset: URL) throws -> (right: [NSImage], left: [NSImage]) {
        guard let source = CGImageSourceCreateWithURL(asset as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
              (256...4096).contains(atlas.width), (256...4096).contains(atlas.height) else {
            throw AtlasError.invalidAsset
        }
        let metadata = asset.deletingPathExtension().appendingPathExtension("json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: metadata))
        let names = ["torsoRight", "torsoLeft", "upperSleeve", "foreSleeve", "thigh", "calf", "shoeRight", "shoeLeft"]
        guard manifest.parts.map(\.name) == names,
              manifest.torsoHeight.isFinite, (1...208).contains(manifest.torsoHeight),
              manifest.shoeHeight.isFinite, (1...208).contains(manifest.shoeHeight),
              [manifest.torsoRightHip, manifest.torsoLeftHip, manifest.shoeRightAnkle,
               manifest.shoeLeftAnkle].allSatisfy(\.isValid) else { throw AtlasError.invalidAsset }
        let pieces = try manifest.parts.map { part -> CGImage in
            guard part.x >= 0, part.y >= 0, part.width > 0, part.height > 0,
                  part.width <= atlas.width, part.height <= atlas.height,
                  part.x <= atlas.width - part.width, part.y <= atlas.height - part.height,
                  let crop = atlas.cropping(to: CGRect(x: part.x, y: part.y,
                      width: part.width, height: part.height)) else { throw AtlasError.invalidAsset }
            let cleaned = try SpriteView.cleanedSpriteFrame(crop,
                size: NSSize(width: crop.width, height: crop.height))
            guard let image = cleaned.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw AtlasError.invalidAsset
            }
            return image
        }
        func direction(_ left: Bool) throws -> [NSImage] {
            try (0..<RunCycle.phaseCount).map { try render(pieces: pieces, manifest: manifest, phase: $0, left: left) }
        }
        return (try direction(false), try direction(true))
    }

    private static func render(pieces: [CGImage], manifest: Manifest, phase: Int, left: Bool) throws -> NSImage {
        let scale = 2.0
        let width = Int(RunCycle.canvasSize.width * scale)
        let height = Int(RunCycle.canvasSize.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AtlasError.invalidAsset }
        context.translateBy(x: 0, y: Double(height))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .high
        let pose = RunCycle.pose(index: phase, facingLeft: left)

        func image(_ image: CGImage, rect: CGRect, shadow: Bool = false) {
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            let local = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.draw(image, in: local)
            if shadow {
                context.setBlendMode(.sourceAtop)
                context.setFillColor(CGColor(gray: 0, alpha: 0.24))
                context.fill(local)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
        func bone(_ piece: Int, from: PetPoint, to: PetPoint, shadow: Bool) {
            let art = pieces[piece]
            let length = hypot(to.x - from.x, to.y - from.y)
            // Rounded painted ends overlap so elbows and knees stay joined while bending.
            let artHeight = length + 4
            let artWidth = artHeight * Double(art.width) / Double(art.height)
            context.saveGState()
            context.translateBy(x: from.x, y: from.y)
            context.rotate(by: atan2(to.y - from.y, to.x - from.x) - .pi / 2)
            if left { context.scaleBy(x: -1, y: 1) }
            // The source parts have painted cut ends; hide them inside the continuous joint.
            let end = piece == 3 ? length + 2 : length - 3
            context.clip(to: CGRect(x: -artWidth / 2, y: 3, width: artWidth, height: end - 3))
            image(art, rect: CGRect(x: -artWidth / 2, y: -2, width: artWidth, height: artHeight), shadow: shadow)
            context.restoreGState()
        }
        func jointPath(_ points: [PetPoint], width: Double, color: CGColor, shadow: Bool) {
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.beginPath()
            context.move(to: CGPoint(x: points[0].x, y: points[0].y))
            points.dropFirst().forEach { context.addLine(to: CGPoint(x: $0.x, y: $0.y)) }
            context.setStrokeColor(CGColor(gray: 0.05, alpha: 1))
            context.setLineWidth(width)
            context.strokePath()
            context.beginPath()
            context.move(to: CGPoint(x: points[0].x, y: points[0].y))
            points.dropFirst().forEach { context.addLine(to: CGPoint(x: $0.x, y: $0.y)) }
            context.setStrokeColor(color)
            context.setLineWidth(width - 1.4)
            context.strokePath()
            if shadow {
                context.setBlendMode(.sourceAtop)
                context.setFillColor(CGColor(gray: 0, alpha: 0.24))
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 208))
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
        func leg(_ leg: RunLegPose, phase: Int, shadow: Bool) {
            jointPath([leg.hip, leg.knee, leg.ankle], width: 12,
                color: CGColor(red: 0.95, green: 0.61, blue: 0.75, alpha: 1), shadow: shadow)
            bone(4, from: leg.hip, to: leg.knee, shadow: shadow)
            bone(5, from: leg.knee, to: leg.ankle, shadow: shadow)
            let angles = [0.0, 0, 0.6, 1.2, 1.1, 0.65, -0.3, -0.15]
            let art = pieces[left ? 7 : 6]
            let shoeHeight = manifest.shoeHeight
            let shoeWidth = shoeHeight * Double(art.width) / Double(art.height)
            let anchor = left ? manifest.shoeLeftAnkle : manifest.shoeRightAnkle
            context.saveGState()
            context.translateBy(x: leg.ankle.x, y: leg.ankle.y)
            context.rotate(by: angles[phase] * (left ? -1 : 1))
            image(art, rect: CGRect(x: -shoeWidth * anchor.x, y: -shoeHeight * anchor.y,
                width: shoeWidth, height: shoeHeight), shadow: shadow)
            context.restoreGState()
        }
        func arm(_ arm: RunArmPose, shadow: Bool) {
            jointPath([arm.shoulder, arm.elbow, arm.wrist], width: 9,
                color: CGColor(gray: 0.11, alpha: 1), shadow: shadow)
            bone(2, from: arm.shoulder, to: arm.elbow, shadow: shadow)
            bone(3, from: arm.elbow, to: arm.wrist, shadow: shadow)
        }

        leg(pose.farLeg, phase: (phase + 4) % 8, shadow: true)
        leg(pose.nearLeg, phase: phase, shadow: false)
        arm(pose.farArm, shadow: true)
        let torso = pieces[left ? 1 : 0]
        let torsoHeight = manifest.torsoHeight
        let torsoWidth = torsoHeight * Double(torso.width) / Double(torso.height)
        let torsoHip = left ? manifest.torsoLeftHip : manifest.torsoRightHip
        image(torso, rect: CGRect(x: pose.nearLeg.hip.x - torsoWidth * torsoHip.x,
            y: pose.nearLeg.hip.y - torsoHeight * torsoHip.y, width: torsoWidth, height: torsoHeight))
        arm(pose.nearArm, shadow: false)
        guard let frame = context.makeImage() else { throw AtlasError.invalidAsset }
        return NSImage(cgImage: frame,
            size: NSSize(width: RunCycle.canvasSize.width, height: RunCycle.canvasSize.height))
    }
}
