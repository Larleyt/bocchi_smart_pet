import AppKit
import BocchiCore

private struct DisplayContext: Equatable, Sendable {
    let id: UInt32
    let bounds: PetRect
    let usable: PetRect
    let frontmostPID: Int32?
    let windows: [WindowRegion]
}

private struct WindowIdentity: Hashable {
    let id: UInt32
    let pid: Int32
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var session: PlacementSession?
    private let startPaused: Bool
    private let diagnosePlacement: Bool
    private let inspector = SystemInspector()
    private let analyzer = ScreenAnalyzer()
    private let changes = SystemChangeObserver()
    private(set) var setup: PermissionSetup?
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "Боччи запускается", action: nil, keyEquivalent: "")
    private var pauseItem: NSMenuItem?
    private var heartbeat: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var menuOpen = false
    private var pending = true
    private var context: DisplayContext?
    private var observedWindows: Set<WindowIdentity>?
    private var observedAccessibility: Bool?
    private var lastInput = 0.0
    private var lastAttempt = -10.0
    private var lastSuccess = -10.0
    private var permissions: PermissionState
    private var visualEnabled = UserDefaults.standard.bool(forKey: "visualFallbackEnabled")
    private var refreshTask: Task<Void, Never>?
    private var loggedOutcome: CaptureOutcome?
    private var diagnosticMap = ""

    init(startPaused: Bool = false, initialPermissions: PermissionState = .current,
         diagnosePlacement: Bool = false) {
        self.startPaused = startPaused
        self.diagnosePlacement = diagnosePlacement
        self.permissions = initialPermissions
        super.init()
        if diagnosePlacement { visualEnabled = false }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { session = PlacementSession(overlay: try PetOverlay()) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось запустить Боччи"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        if startPaused { session?.setEnabled(false) }
        setup = PermissionSetup { [weak self] enabled in
            guard let self else { return }
            visualEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "visualFallbackEnabled")
            invalidate()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "♪"
        item.button?.toolTip = "Боччи — умный питомец"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(statusLine)
        menu.addItem(.separator())
        pauseItem = addItem("Приостановить", action: #selector(toggle), to: menu)
        _ = addItem("Настройка доступа…", action: #selector(showSetup), to: menu)
        menu.addItem(.separator())
        _ = addItem("Завершить Боччи", action: #selector(quit), to: menu)
        item.menu = menu
        statusItem = item

        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown,
            .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseMoved]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            let moved = event.type == .mouseMoved
            let contentMoved = Self.isContentMovement(event.type)
            Task { @MainActor in self?.input(moved: moved, contentMoved: contentMoved) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.input(moved: event.type == .mouseMoved, contentMoved: Self.isContentMovement(event.type))
            return event
        }
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } })
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if !diagnosePlacement { showSetup() }
        tick()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSetup()
        return false
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func currentContext() throws -> DisplayContext? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let bounds = ScreenCoordinates.quartz(screen.frame)
        return DisplayContext(id: number.uint32Value, bounds: bounds,
            usable: ScreenCoordinates.quartz(screen.visibleFrame),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            windows: try SystemInspector.windows(in: bounds, excludingPID: ProcessInfo.processInfo.processIdentifier))
    }

    private func invalidate() {
        session?.invalidate()
        pending = true
    }

    nonisolated static func isContentMovement(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: true
        default: false
        }
    }

    private func input(moved: Bool, contentMoved: Bool) {
        if session?.input(moved: moved, contentMoved: contentMoved, cursor: ScreenCoordinates.cursor) == true {
            pending = true
            lastInput = ProcessInfo.processInfo.systemUptime
        }
    }

    private func tick() {
        let state = PermissionState.current
        if state != permissions { permissions = state; invalidate() }
        setup?.update(state: state, visualFallbackEnabled: visualEnabled)
        guard let session, session.enabled else { return }
        guard !menuOpen, setup?.isVisible != true else {
            session.overlay.panel.orderOut(nil)
            return
        }
        let nextContext: DisplayContext
        do {
            guard let value = try currentContext() else { invalidate(); return }
            nextContext = value
        } catch {
            invalidate()
            statusLine.title = "Не удалось прочитать геометрию окон"
            NSLog("Bocchi window metadata failed: %@", error.localizedDescription)
            return
        }
        if context != nextContext { context = nextContext; invalidate() }
        let identities = Set(nextContext.windows.map { WindowIdentity(id: $0.id, pid: $0.pid) })
        if observedWindows != identities || observedAccessibility != state.accessibility {
            changes.observe(pids: nextContext.windows.map(\.pid)) { [weak self] in self?.invalidate() }
            observedWindows = identities
            observedAccessibility = state.accessibility
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSuccess > 2.5 { session.overlay.panel.orderOut(nil) }
        guard !session.busy, now - lastInput >= 0.25,
              now - lastAttempt >= (pending ? 0.5 : 1.0) else { return }
        pending = false
        lastAttempt = now
        let visualPreference = visualEnabled
        let visualAllowed = !diagnosePlacement && visualPreference && state.screenCapture
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await session.refresh(
                bounds: nextContext.usable, screenBounds: nextContext.bounds, visualAllowed: visualAllowed,
                inspect: {
                    let snapshot = try await self.inspector.inspect(
                        screenBounds: nextContext.bounds, windows: nextContext.windows)
                    if self.diagnosePlacement {
                        self.diagnosticMap = "AX=\(snapshot.accessibilityAvailable) windows=\(snapshot.windows.count) obstacles=\(snapshot.obstacles.count) unknown=\(snapshot.unknownAreas.count)"
                    }
                    return snapshot
                },
                capture: { region in
                    try await self.analyzer.capture(displayID: nextContext.id, screenBounds: nextContext.bounds,
                        region: region, ownBundleID: Bundle.main.bundleIdentifier ?? "local.bocchi.smartpet")
                },
                current: {
                    PermissionState.current == state && self.visualEnabled == visualPreference
                        && (try? self.currentContext()) == nextContext
                },
                cursor: { ScreenCoordinates.cursor })
            if diagnosePlacement, outcome != loggedOutcome {
                NSLog("Bocchi placement diagnostic: %@ %@", String(describing: outcome), diagnosticMap)
                loggedOutcome = outcome
            }
            switch outcome {
            case .shown(let visual):
                lastSuccess = ProcessInfo.processInfo.systemUptime
                statusLine.title = visual ? "Боччи проверяет только свой участок" : "Боччи использует системные данные"
            case .noSpace:
                lastSuccess = ProcessInfo.processInfo.systemUptime
                statusLine.title = "Место не найдено — Боччи скрыта"
            case .needsVisualAccess:
                lastSuccess = ProcessInfo.processInfo.systemUptime
                statusLine.title = state.accessibility
                    ? "Неизвестная область — Боччи скрыта" : "Нужен Accessibility или визуальная проверка"
            case .discarded:
                pending = true
            case .failed(let detail):
                statusLine.title = "Ошибка анализа — Боччи скрыта"
                NSLog("Bocchi analysis failed: %@", detail)
            }
        }
    }

    @objc private func toggle() {
        guard let session else { return }
        session.setEnabled(!session.enabled)
        invalidate()
        pauseItem?.title = session.enabled ? "Приостановить" : "Продолжить"
        statusLine.title = session.enabled ? "Боччи ищет место" : "На паузе"
    }

    @objc private func showSetup() {
        invalidate()
        setup?.update(state: PermissionState.current, visualFallbackEnabled: visualEnabled)
        setup?.show()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; invalidate() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; invalidate() }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeat?.invalidate()
        refreshTask?.cancel()
        session?.overlay.stop()
        changes.stop()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@main
enum BocchiSmartPet {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in Darwin.exit(await RuntimeSelfTest.run()) }
            app.run()
        } else {
            let launchCheck = CommandLine.arguments.contains("--launch-check")
            let grantedAccessibilityFixture = PermissionState(accessibility: true, screenCapture: false)
            let delegate = AppDelegate(startPaused: launchCheck,
                initialPermissions: launchCheck ? grantedAccessibilityFixture : .current,
                diagnosePlacement: CommandLine.arguments.contains("--diagnose-placement"))
            app.delegate = delegate
            if launchCheck {
                Task { @MainActor in
                    let code = await LaunchCheck.run(delegate)
                    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    Darwin.exit(code)
                }
            }
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
