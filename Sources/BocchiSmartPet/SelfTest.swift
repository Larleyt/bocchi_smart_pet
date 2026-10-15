import AppKit
import BocchiCore

private enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): message }
    }
}

@MainActor
private final class FixtureView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
    }
}

@MainActor
enum RuntimeSelfTest {
    static func run() async -> Int32 {
        var passed = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SelfTestFailure.failed(message) }
            passed += 1
            print("PASS: \(message)")
        }
        var overlay: PetOverlay?
        do {
            let panel = try PetOverlay()
            let session = PlacementSession(overlay: panel)
            overlay = panel
            defer { panel.stop() }
            try check(panel.panel.ignoresMouseEvents && !panel.panel.canBecomeKey && !panel.panel.canBecomeMain,
                      "overlay does not intercept clicks or focus")
            let original = NSRect(x: -1200, y: 1100, width: 900, height: 640)
            let converted = ScreenCoordinates.quartz(original, primaryHeight: 1000)
            try check(converted == PetRect(x: -1200, y: -740, width: 900, height: 640),
                      "Quartz transform supports displays above and left")
            try check(ScreenCoordinates.appKit(converted, primaryHeight: 1000) == original,
                      "display coordinate round trip")
            let setup = PermissionSetup { _ in }
            setup.show()
            setup.update(state: PermissionState(accessibility: true, screenCapture: false), visualFallbackEnabled: false)
            guard let setupWindow = setup.window, let setupContent = setupWindow.contentView,
                  let setupStack = setupContent.subviews.first as? NSStackView else {
                throw SelfTestFailure.failed("permission setup view missing")
            }
            setupContent.layoutSubtreeIfNeeded()
            try check(setupStack.fittingSize.height + 44 <= setupContent.bounds.height + 1,
                      "permission setup fits without clipping at initial size")
            setupWindow.setFrame(NSRect(x: setupWindow.frame.minX, y: setupWindow.frame.minY,
                                       width: 620, height: 660), display: true)
            setupContent.layoutSubtreeIfNeeded()
            try check(setupStack.fittingSize.height + 44 <= setupContent.bounds.height + 1,
                      "permission setup fits at minimum window size")
            func descendants(_ view: NSView) -> [NSView] {
                view.subviews.flatMap { [$0] + descendants($0) }
            }
            let setupViews = descendants(setupContent)
            let labels = setupViews.compactMap { ($0 as? NSTextField)?.stringValue }
            try check(labels.contains("Разрешено") && labels.contains("Не разрешено"),
                      "Accessibility and screen permissions display separate actual states")
            let fallback = setupViews.compactMap { $0 as? NSButton }
                .first { $0.title == "Включить визуальную проверку" }
            try check(fallback?.state == .off, "visual fallback is explicitly off in initial setup")
            setup.dismiss()

            // External capture and AX are explicit fixtures; native rendering, Vision and placement stay real.
            let size = NSSize(width: 900, height: 640)
            let fixture = FixtureView(frame: NSRect(origin: .zero, size: size))
            let text = NSTextField(labelWithString: "Bocchi Smart Pet\nKeep this text readable")
            text.font = .systemFont(ofSize: 26)
            text.textColor = .black
            text.frame = NSRect(x: 40, y: 490, width: 600, height: 100)
            fixture.addSubview(text)
            let button = NSButton(title: "Keep this button free", target: nil, action: nil)
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 635, y: 16, width: 250, height: 60)
            fixture.addSubview(button)
            let fixtureWindow = NSWindow(contentRect: fixture.frame, styleMask: [.borderless],
                                         backing: .buffered, defer: false)
            fixtureWindow.isReleasedWhenClosed = false
            fixtureWindow.contentView = fixture
            fixtureWindow.appearance = NSAppearance(named: .aqua)
            fixture.appearance = NSAppearance(named: .aqua)
            fixtureWindow.center()
            fixtureWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(300))
            fixture.layoutSubtreeIfNeeded()
            fixtureWindow.displayIfNeeded()
            guard let background = fixture.bitmapImageRepForCachingDisplay(in: fixture.bounds),
                  let control = button.bitmapImageRepForCachingDisplay(in: button.bounds),
                  let graphics = CGContext(data: nil, width: 900, height: 640,
                      bitsPerComponent: 8, bytesPerRow: 900 * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw SelfTestFailure.failed("native fixture rendering context") }
            fixture.cacheDisplay(in: fixture.bounds, to: background)
            // On macOS 26 the container cache omits NSButton's layer; render that native control directly.
            button.cacheDisplay(in: button.bounds, to: control)
            guard let backgroundImage = background.cgImage, let buttonImage = control.cgImage else {
                throw SelfTestFailure.failed("native fixture component image")
            }
            graphics.draw(backgroundImage, in: fixture.bounds)
            graphics.draw(buttonImage, in: button.frame)
            guard let image = graphics.makeImage() else { throw SelfTestFailure.failed("native fixture image") }
            fixtureWindow.orderOut(nil)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("artifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            guard let fixturePNG = bitmap.representation(using: .png, properties: [:]) else {
                throw SelfTestFailure.failed("native fixture PNG encoding")
            }
            try fixturePNG.write(to: artifacts.appendingPathComponent("runtime-fixture.png"))

            let bounds = PetRect(x: 0, y: 0, width: 900, height: 640)
            func windowInfo(_ id: UInt32, pid: Int32 = 1, alpha: Double = 1) -> [String: Any] {
                [kCGWindowNumber as String: NSNumber(value: id),
                 kCGWindowOwnerPID as String: NSNumber(value: pid),
                 kCGWindowLayer as String: NSNumber(value: 0),
                 kCGWindowAlpha as String: NSNumber(value: alpha),
                 kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 900, height: 640).dictionaryRepresentation]
            }
            let decoded = try SystemInspector.decodeWindows([
                windowInfo(1, alpha: 0), windowInfo(2, alpha: 0.5), windowInfo(3),
                windowInfo(4, pid: 99), [:]
            ], in: bounds, excludingPID: 99)
            try check(decoded.map(\.id) == [2, 3] && !decoded[0].isOpaque && decoded[1].isOpaque,
                      "actual metadata decoder filters own and invisible windows and preserves translucency")
            let translucent = SystemInspector.visibility(of: decoded, in: bounds)
            try check(translucent.unknown == [bounds] && translucent.windows[1].isEmpty,
                      "translucent foreground remains unknown rather than exposing a trusted background")
            let foreground = WindowRegion(id: 5, pid: 1, bounds: PetRect(x: 0, y: 0, width: 450, height: 640))
            let layers = SystemInspector.visibility(of: [foreground, decoded[0]], in: bounds)
            try check(layers.windows[1] == [PetRect(x: 450, y: 0, width: 450, height: 640)]
                      && layers.unknown == layers.windows[1],
                      "occlusion removes unknown background only where foreground actually covers it")
            let noWindows = SystemInspector.visibility(of: [], in: bounds)
            try check(noWindows.unknown == [bounds], "undescribed desktop is unknown, never assumed empty")
            let realInspector = SystemInspector()
            let emptySystem = try await realInspector.inspect(screenBounds: bounds, windows: [])
            try check(emptySystem.unknownAreas == [bounds] && emptySystem.obstacles.isEmpty,
                      "real system inspector keeps an unrepresented scene unknown without pixel access")
            let knownText = PetRect(x: 40, y: 50, width: 600, height: 100)
            let fakeAXButton = PetRect(x: 635, y: 564, width: 250, height: 60)
            let analyzer = ScreenAnalyzer()
            let visualOnly = try await analyzer.analyze(image: image, screenBounds: bounds)
            try check(visualOnly.pixelWidth > 0 && visualOnly.pixelHeight > 0, "real AppKit fixture analyzed")
            try check(visualOnly.obstacles.contains { $0.intersects(knownText) },
                      "Vision or image mask detects native text without AX fixture")
            try check(visualOnly.obstacles.contains { $0.intersects(fakeAXButton) },
                      "Vision or image mask detects native button without AX fixture")
            let snapshot = try await analyzer.analyze(image: image, screenBounds: bounds, controls: [fakeAXButton])
            try check(snapshot.obstacles.contains(fakeAXButton), "external AX fixture reaches obstacle map")
            let outsideCursor = PetPoint(x: -1000, y: -1000)
            let knownSystem = SystemSnapshot(obstacles: [knownText, fakeAXButton], unknownAreas: [],
                windows: [WindowRegion(id: 1, pid: 1, bounds: bounds)], accessibilityAvailable: true)
            var capturedRegions: [PetRect] = []
            var clock = 100.0
            func runSession(_ system: SystemSnapshot, visual: Bool = false,
                current: () -> Bool = { true },
                pixels: ((PetRect) async throws -> PixelSample)? = nil
            ) async -> CaptureOutcome {
                await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: visual,
                    inspect: { system }, capture: { region in
                        capturedRegions.append(region)
                        guard let pixels else { throw SelfTestFailure.failed("unexpected pixel capture") }
                        return try await pixels(region)
                    }, current: current, cursor: { outsideCursor }, now: { clock })
            }
            func unknownScene(_ id: UInt32) -> SystemSnapshot {
                SystemSnapshot(obstacles: [], unknownAreas: [bounds],
                    windows: [WindowRegion(id: id, pid: 1, bounds: bounds)], accessibilityAvailable: false)
            }
            let outcome = await runSession(knownSystem)
            try check(outcome == .shown(visual: false) && capturedRegions.isEmpty,
                      "AX-only runtime publishes without permission or any pixel capture")
            guard let placement = panel.lastPlacement else {
                throw SelfTestFailure.failed("sparse native fixture has a visible placement")
            }
            try check(panel.panel.isVisible, "real NSPanel becomes visible")
            try check(bounds.contains(placement), "panel remains inside usable screen")
            let protected = [knownText, fakeAXButton].map {
                PetRect(x: $0.x - 12, y: $0.y - 12, width: $0.width + 24, height: $0.height + 24)
            }
            try check(!protected.contains { $0.intersects(placement) },
                      "runtime placement avoids known text and bottom-right button with padding")
            try check(ScreenCoordinates.quartz(panel.panel.frame) == placement, "actual NSPanel frame matches placement")
            _ = await runSession(knownSystem)
            try check(panel.lastPlacement == placement && capturedRegions.isEmpty,
                      "unchanged AX screen preserves placement without pixels")
            let away = PetPoint(x: placement.maxX + 53, y: placement.y + placement.height / 2)
            try check(!session.input(moved: true, cursor: away) && panel.panel.isVisible,
                      "cursor outside clearance keeps panel stable")
            try check(session.input(moved: true, cursor: PetPoint(x: placement.maxX + 40, y: away.y))
                      && !panel.panel.isVisible, "cursor movement inside full clearance hides panel")

            let delayed = Task { @MainActor in
                await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: false,
                    inspect: {
                        try await Task.sleep(for: .milliseconds(120))
                        return knownSystem
                    }, capture: { _ in throw SelfTestFailure.failed("unexpected pixel capture") },
                    current: { true }, cursor: { outsideCursor })
            }
            await Task.yield()
            try check(session.busy, "production session marks in-flight metadata work")
            let duplicate = await runSession(knownSystem)
            try check(duplicate == .discarded, "concurrent refresh does not start a second inspection")
            try check(session.input(moved: false, cursor: outsideCursor) && !panel.panel.isVisible,
                      "input invalidates in-flight work")
            let stale = await delayed.value
            try check(stale == .discarded && !panel.panel.isVisible && !session.busy,
                      "delayed completion cannot publish after input")
            _ = await runSession(knownSystem)
            let changedContext = await runSession(knownSystem, current: { false })
            try check(changedContext == .discarded && !panel.panel.isVisible,
                      "changed app or permission context rejects and hides result")
            session.setEnabled(false)
            let paused = await runSession(knownSystem)
            try check(paused == .discarded && !panel.panel.isVisible, "pause blocks publication")
            session.setEnabled(true)
            let dense = SystemSnapshot(obstacles: [bounds], unknownAreas: [], windows: [], accessibilityAvailable: true)
            let denseResult = await runSession(dense, visual: true)
            try check(denseResult == .noSpace && !panel.panel.isVisible && capturedRegions.isEmpty,
                      "known dense AX scene hides without pointless visual fallback")
            let unknown = await runSession(unknownScene(10))
            try check(unknown == .needsVisualAccess && capturedRegions.isEmpty && !panel.panel.isVisible,
                      "unknown scene with visual access off never captures pixels")

            let localResult = await runSession(unknownScene(10), visual: true, pixels: { region in
                guard let crop = image.cropping(to: CGRect(x: region.x, y: region.y,
                    width: region.width, height: region.height)) else {
                    throw SelfTestFailure.failed("explicit external crop fixture failed")
                }
                return try await analyzer.sample(image: crop, bounds: region)
            })
            try check(localResult == .shown(visual: true), "real local OCR finds a free region in unknown scene")
            try check(capturedRegions.count >= 2 && capturedRegions.count <= 5
                      && capturedRegions.filter { $0 == bounds }.count <= 1,
                      "static native button rejects occupied crops; full map remains bounded")
            guard let localPlacement = panel.lastPlacement else { throw SelfTestFailure.failed("local placement missing") }
            try check(!protected.contains { $0.intersects(localPlacement) },
                      "zero activity does not permit placement over static native text or button")
            let partialSystem = SystemSnapshot(obstacles: [fakeAXButton], unknownAreas: [bounds],
                windows: [WindowRegion(id: 15, pid: 1, bounds: bounds)], accessibilityAvailable: true)
            capturedRegions = []
            let partialResult = await runSession(partialSystem, visual: true, pixels: { region in
                guard let crop = image.cropping(to: CGRect(x: region.x, y: region.y,
                    width: region.width, height: region.height)) else {
                    throw SelfTestFailure.failed("explicit external crop fixture failed")
                }
                return try await analyzer.sample(image: crop, bounds: region)
            })
            try check(partialResult == .shown(visual: true) && capturedRegions.count <= 3
                      && !capturedRegions.contains(bounds), "partial AX map avoids full display and verifies only local candidate")
            let previousCaptureCount = capturedRegions.count
            clock += 4
            _ = await runSession(partialSystem, visual: true)
            try check(capturedRegions.count == previousCaptureCount, "local watcher waits five seconds between pixel samples")
            clock += 1
            _ = await runSession(partialSystem, visual: true, pixels: { region in
                guard let crop = image.cropping(to: CGRect(x: region.x, y: region.y,
                    width: region.width, height: region.height)) else {
                    throw SelfTestFailure.failed("explicit external crop fixture failed")
                }
                return try await analyzer.sample(image: crop, bounds: region)
            })
            try check(capturedRegions.count == previousCaptureCount + 1 && capturedRegions.last != bounds,
                      "five-second watcher samples only occupied region")

            let white = try PixelFingerprint(rgb: [UInt8](repeating: 255, count: 300))
            var changedRGB = [UInt8](repeating: 255, count: 300)
            for index in 0..<45 { changedRGB[index] = 0 }
            let changed = try PixelFingerprint(rgb: changedRGB)
            capturedRegions = []
            _ = await runSession(unknownScene(11), visual: true, pixels: {
                PixelSample(bounds: $0, obstacles: [], fingerprint: white)
            })
            guard let old = panel.lastPlacement, let oldRegion = capturedRegions.first else {
                throw SelfTestFailure.failed("activity baseline placement missing")
            }
            clock += 5
            _ = await runSession(unknownScene(11), visual: true, pixels: {
                PixelSample(bounds: $0, obstacles: [], fingerprint: $0 == oldRegion ? changed : white)
            })
            try check(panel.lastPlacement != old && !capturedRegions.contains(bounds),
                      "15-percent activity moves pet using only local crops")

            capturedRegions = []
            _ = await runSession(unknownScene(12), visual: true, pixels: {
                PixelSample(bounds: $0, obstacles: [], fingerprint: white)
            })
            guard let staticOld = panel.lastPlacement, let staticRegion = capturedRegions.first else {
                throw SelfTestFailure.failed("small text baseline missing")
            }
            clock += 5
            _ = await runSession(unknownScene(12), visual: true, pixels: { region in
                let newText = PetRect(x: staticOld.x + 5, y: staticOld.y + 5, width: 10, height: 8)
                return PixelSample(bounds: region, obstacles: region == staticRegion ? [newText] : [], fingerprint: white)
            })
            try check(panel.lastPlacement != staticOld, "new small text forbids placement even below activity threshold")

            clock += 20
            capturedRegions = []
            let exhausted = await runSession(unknownScene(13), visual: true, pixels: {
                PixelSample(bounds: $0, obstacles: [$0], fingerprint: white)
            })
            try check(exhausted == .noSpace && capturedRegions.count == 4
                      && capturedRegions.filter { $0 == bounds }.count == 1,
                      "full map is captured once only after three rejected local candidates")
            let exhaustedCount = capturedRegions.count
            clock += 20
            _ = await runSession(unknownScene(13), visual: true)
            try check(capturedRegions.count == exhaustedCount && !panel.panel.isVisible,
                      "timer never repeats exhausted local or full-screen search")
            _ = await runSession(unknownScene(16), visual: true, pixels: {
                PixelSample(bounds: $0, obstacles: [$0], fingerprint: white)
            })
            capturedRegions = []
            clock += 1
            let limited = await runSession(unknownScene(17), visual: true, pixels: {
                PixelSample(bounds: $0, obstacles: [$0], fingerprint: white)
            })
            try check(limited == .noSpace && capturedRegions.count == 3 && !capturedRegions.contains(bounds),
                      "new scenes respect one-full-map-per-ten-second limit and remain hidden")

            let delayedPixel = Task { @MainActor in
                await runSession(unknownScene(18), visual: true, pixels: {
                    try await Task.sleep(for: .milliseconds(120))
                    return PixelSample(bounds: $0, obstacles: [], fingerprint: white)
                })
            }
            await Task.yield()
            _ = session.input(moved: false, cursor: outsideCursor)
            let stalePixel = await delayedPixel.value
            try check(stalePixel == .discarded && !panel.panel.isVisible && !session.busy,
                      "delayed local pixel result cannot publish after input")

            _ = await runSession(knownSystem)
            let staleFailure = await session.refresh(bounds: bounds, screenBounds: bounds, visualAllowed: false,
                inspect: { throw SelfTestFailure.failed("explicit stale metadata failure fixture") },
                capture: { _ in throw SelfTestFailure.failed("unexpected pixel capture") },
                current: { false }, cursor: { outsideCursor })
            try check(staleFailure == .discarded && !panel.panel.isVisible && !session.busy,
                      "metadata failure after context change still hides panel")
            let failed = await runSession(unknownScene(14), visual: true, pixels: { _ in
                throw SelfTestFailure.failed("explicit external capture failure fixture")
            })
            if case .failed = failed {
                try check(!panel.panel.isVisible && !session.busy, "pixel failure hides panel and clears in-flight state")
            } else { throw SelfTestFailure.failed("pixel failure not reported") }

            let negative = PetRect(x: -1600, y: -900, width: 900, height: 640)
            let offset = try await analyzer.analyze(image: image, screenBounds: negative)
            try check(offset.obstacles.allSatisfy { negative.contains($0) },
                      "OCR and detail mask map to negative monitor coordinates")
            var rejected = false
            do {
                _ = try await analyzer.analyze(image: image,
                    screenBounds: PetRect(x: 0, y: 0, width: .nan, height: 100))
            } catch { rejected = true }
            try check(rejected, "invalid capture geometry fails instead of reporting empty success")
            fixtureWindow.close()
            print("SELF-TEST RESULT: \(passed) passed, 0 failed")
            return 0
        } catch {
            overlay?.stop()
            print("FAIL: \(error)")
            print("SELF-TEST RESULT: \(passed) passed, 1 failed")
            return 1
        }
    }
}
