import ApplicationServices
import BocchiCore
import CoreGraphics
import Foundation

struct WindowRegion: Sendable, Equatable {
    let id: UInt32
    let pid: Int32
    let bounds: PetRect
    let isOpaque: Bool

    init(id: UInt32, pid: Int32, bounds: PetRect, isOpaque: Bool = true) {
        self.id = id
        self.pid = pid
        self.bounds = bounds
        self.isOpaque = isOpaque
    }
}

struct SystemSnapshot: Sendable {
    let obstacles: [PetRect]
    let unknownAreas: [PetRect]
    let windows: [WindowRegion]
    let accessibilityAvailable: Bool
}

enum SystemInspectorError: Error, LocalizedError {
    case invalidGeometry
    case windowListUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            "Screen geometry must be finite and non-empty"
        case .windowListUnavailable:
            "The system window list is unavailable"
        }
    }
}

actor SystemInspector {
    private var lastTraceSummary: String?
    private static let maximumWindows = 128
    private static let maximumAXNodes = 600
    private static let maximumAXDuration = Duration.milliseconds(220)
    private static let axMessageTimeout: Float = 0.025

    nonisolated static func windows(in screen: PetRect, excludingPID: Int32) throws -> [WindowRegion] {
        try validate(screen)
        guard let information = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw SystemInspectorError.windowListUnavailable
        }

        return try decodeWindows(information, in: screen, excludingPID: excludingPID)
    }

    nonisolated static func decodeWindows(
        _ information: [[String: Any]],
        in screen: PetRect,
        excludingPID: Int32
    ) throws -> [WindowRegion] {
        try validate(screen)
        return information.compactMap { item in
            guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != excludingPID,
                  let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer >= 0,
                  let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha.isFinite, alpha > 0,
                  let boundsValue = item[kCGWindowBounds as String],
                  CFGetTypeID(boundsValue as CFTypeRef) == CFDictionaryGetTypeID(),
                  let dictionary = boundsValue as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  let clipped = intersection(petRect(bounds), screen)
            else { return nil }
            return WindowRegion(id: id, pid: pid, bounds: clipped, isOpaque: alpha >= 1)
        }
    }

    func inspect(screenBounds: PetRect, windows: [WindowRegion], trace: Bool = false) throws -> SystemSnapshot {
        var reasons: [String: Int] = [:]
        func report(_ reason: String, _ role: String? = nil) {
            let key = reason + (role.map { "/" + $0 } ?? "")
            reasons[key, default: 0] += 1
        }
        defer {
            if trace {
                let summary = reasons.keys.sorted().map { "\($0)=\(reasons[$0]!)" }.joined(separator: ",")
                if summary != lastTraceSummary {
                    NSLog("Bocchi AX reasons: %@", summary)
                    lastTraceSummary = summary
                }
            }
        }
        _ = Self.roleClassificationCheck
        try Self.validate(screenBounds)
        let clippedWindows = windows.compactMap { window -> WindowRegion? in
            guard let bounds = Self.intersection(window.bounds, screenBounds) else { return nil }
            return WindowRegion(
                id: window.id, pid: window.pid, bounds: bounds, isOpaque: window.isOpaque
            )
        }
        guard AXIsProcessTrusted() else {
            if trace { report("permission") }
            return SystemSnapshot(
                obstacles: [],
                unknownAreas: [screenBounds],
                windows: clippedWindows,
                accessibilityAvailable: false
            )
        }
        // shortcut: scenes above 128 windows stay unknown, replace rectangle splitting before raising the cap.
        guard clippedWindows.count <= Self.maximumWindows else {
            if trace { report("window-budget") }
            return SystemSnapshot(
                obstacles: [],
                unknownAreas: [screenBounds],
                windows: clippedWindows,
                accessibilityAvailable: true
            )
        }

        let visibility = Self.visibility(of: clippedWindows, in: screenBounds)
        let visibleRegions = visibility.windows
        var unknown = visibility.unknown
        if trace, !unknown.isEmpty { report("unrepresented-regions") }
        var obstacles: [PetRect] = []
        var remainingNodes = Self.maximumAXNodes
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.maximumAXDuration)
        var applicationWindows: [Int32: [(AXUIElement, PetRect)]] = [:]

        for (index, window) in clippedWindows.enumerated() where !visibleRegions[index].isEmpty {
            guard window.isOpaque else {
                continue
            }
            guard remainingNodes > 0, clock.now < deadline else {
                if trace { report(remainingNodes <= 0 ? "node-budget" : "time-budget") }
                unknown.append(contentsOf: visibleRegions[index])
                continue
            }

            var candidates = applicationWindows[window.pid] ?? Self.axWindows(
                pid: window.pid,
                remainingNodes: &remainingNodes,
                deadline: deadline,
                clock: clock,
                trace: trace ? report : nil
            )
            guard let match = Self.bestMatch(for: window.bounds, in: candidates) else {
                if trace { report("window-mismatch") }
                applicationWindows[window.pid] = candidates
                unknown.append(contentsOf: visibleRegions[index])
                continue
            }
            let element = candidates.remove(at: match)
            applicationWindows[window.pid] = candidates

            let result = Self.inspect(
                root: element.0,
                visibleRegions: visibleRegions[index],
                remainingNodes: &remainingNodes,
                deadline: deadline,
                clock: clock,
                trace: trace ? report : nil
            )
            obstacles.append(contentsOf: result.obstacles)
            unknown.append(contentsOf: result.unknown)
            if !result.complete {
                unknown.append(contentsOf: visibleRegions[index])
            }
        }

        return SystemSnapshot(
            obstacles: obstacles,
            unknownAreas: unknown,
            windows: clippedWindows,
            accessibilityAvailable: true
        )
    }

    nonisolated static func visibility(of windows: [WindowRegion], in screen: PetRect)
        -> (windows: [[PetRect]], unknown: [PetRect]) {
        var visible: [[PetRect]] = []
        var foreground: [PetRect] = []
        var unknown = subtract([screen], windows.map(\.bounds))
        for window in windows {
            let regions = subtract([window.bounds], foreground)
            visible.append(regions)
            if !window.isOpaque { unknown.append(contentsOf: regions) }
            foreground.append(window.bounds)
        }
        return (visible, unknown)
    }

    private static func axWindows(
        pid: Int32,
        remainingNodes: inout Int,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock,
        trace: ((String, String?) -> Void)? = nil
    ) -> [(AXUIElement, PetRect)] {
        let application = AXUIElementCreateApplication(pid_t(pid))
        guard AXUIElementSetMessagingTimeout(application, axMessageTimeout) == .success,
              clock.now < deadline,
              let elements = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement]
        else { trace?("application-windows", nil); return [] }
        var windows: [(AXUIElement, PetRect)] = []
        for element in elements {
            guard remainingNodes > 0, clock.now < deadline else { break }
            remainingNodes -= 1
            if case .visible(let frame) = frame(of: element, deadline: deadline, clock: clock) {
                windows.append((element, frame))
            }
        }
        return windows
    }

    private static func bestMatch(
        for bounds: PetRect,
        in candidates: [(AXUIElement, PetRect)]
    ) -> Int? {
        guard let index = candidates.indices.max(by: {
            overlapScore(candidates[$0].1, bounds) < overlapScore(candidates[$1].1, bounds)
        }), overlapScore(candidates[index].1, bounds) >= 0.5 else { return nil }
        return index
    }

    private static func inspect(
        root: AXUIElement,
        visibleRegions: [PetRect],
        remainingNodes: inout Int,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock,
        trace: ((String, String?) -> Void)? = nil
    ) -> (obstacles: [PetRect], unknown: [PetRect], complete: Bool) {
        inspectTree(
            root: root,
            visibleRegions: visibleRegions,
            remainingNodes: &remainingNodes,
            isExpired: { clock.now >= deadline },
            readRole: { attribute($0, kAXRoleAttribute as CFString) as? String },
            readVisibility: { visibility(of: $0) },
            readFrame: { frame(of: $0, deadline: deadline, clock: clock) },
            readChildren: { children(of: $0) },
            readActions: { actions(of: $0, trace: trace) },
            trace: trace
        )
    }

    nonisolated static func inspectTree<Element>(
        root: Element,
        visibleRegions: [PetRect],
        remainingNodes: inout Int,
        isExpired: () -> Bool,
        readRole: (Element) -> String?,
        readVisibility: (Element) -> Visibility,
        readFrame: (Element) -> AccessibilityFrame,
        readChildren: (Element) -> ChildrenResult<Element>,
        readActions: (Element) -> [String]?,
        trace: ((String, String?) -> Void)? = nil
    ) -> (obstacles: [PetRect], unknown: [PetRect], complete: Bool) {
        var queue = [root]
        var cursor = 0
        var obstacles: [PetRect] = []
        var unknown: [PetRect] = []

        func incomplete(_ reason: String, _ role: String? = nil)
            -> (obstacles: [PetRect], unknown: [PetRect], complete: Bool) {
            trace?(reason, role)
            return (obstacles, unknown, false)
        }
        while cursor < queue.count {
            guard remainingNodes > 0, !isExpired() else {
                return incomplete(remainingNodes <= 0 ? "node-budget" : "time-budget")
            }
            remainingNodes -= 1
            let element = queue[cursor]
            cursor += 1

            guard !isExpired(), let role = readRole(element) else {
                return incomplete(isExpired() ? "time-budget" : "role")
            }
            guard !isExpired() else { return incomplete("time-budget", role) }
            switch readVisibility(element) {
            case .hidden:
                continue
            case .failed:
                return incomplete("visibility", role)
            case .visible:
                break
            }
            let elementKind = kind(for: role)
            if elementKind != .obstacle {
                guard !isExpired(), let actions = readActions(element), !isExpired() else {
                    return incomplete(isExpired() ? "time-budget" : "actions", role)
                }
                if hasActivatingAction(actions) {
                    guard case .visible(let rect) = readFrame(element), !isExpired() else {
                        return incomplete(isExpired() ? "time-budget" : "action-frame", role)
                    }
                    obstacles.append(contentsOf: clip(rect, to: visibleRegions))
                    continue
                }
            }
            switch elementKind {
            case .obstacle:
                guard !isExpired(), case .visible(let rect) = readFrame(element) else {
                    return incomplete(isExpired() ? "time-budget" : "obstacle-frame", role)
                }
                obstacles.append(contentsOf: clip(rect, to: visibleRegions))
                continue
            case .unknown:
                guard !isExpired(), case .visible(let rect) = readFrame(element) else {
                    return incomplete(isExpired() ? "time-budget" : "unknown-frame", role)
                }
                trace?("unknown-role", role)
                unknown.append(contentsOf: clip(rect, to: visibleRegions))
                continue
            case .container:
                break
            }

            guard !isExpired() else { return incomplete("time-budget", role) }
            switch readChildren(element) {
            case .available(let children) where !children.isEmpty:
                if queue.count - cursor + children.count > remainingNodes {
                    return incomplete("queue-budget", role)
                }
                queue.append(contentsOf: children)
            case .available:
                guard !isExpired() else { return incomplete("time-budget", role) }
                switch readFrame(element) {
                case .empty:
                    continue
                case .visible(let rect):
                    trace?("empty-container", role)
                    unknown.append(contentsOf: clip(rect, to: visibleRegions))
                case .unavailable:
                    return incomplete("container-frame", role)
                }
            case .unsupported:
                guard !isExpired(), case .visible(let rect) = readFrame(element) else {
                    return incomplete(isExpired() ? "time-budget" : "unsupported-frame", role)
                }
                trace?("unsupported-children", role)
                unknown.append(contentsOf: clip(rect, to: visibleRegions))
            case .failed:
                return incomplete("children", role)
            }
        }
        return (obstacles, unknown, true)
    }

    enum ChildrenResult<Element> {
        case available([Element])
        case unsupported
        case failed
    }

    enum Visibility {
        case visible
        case hidden
        case failed
    }

    enum AccessibilityFrame {
        case visible(PetRect)
        case empty
        case unavailable
    }

    nonisolated static func accessibilityFrame(_ rect: PetRect) -> AccessibilityFrame {
        guard rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 0, rect.height >= 0 else { return .unavailable }
        return rect.width == 0 || rect.height == 0 ? .empty : .visible(rect)
    }

    private static func visibility(of element: AXUIElement) -> Visibility {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXHiddenAttribute as CFString, &value) {
        case .success:
            guard let hidden = value as? Bool else { return .failed }
            return hidden ? .hidden : .visible
        case .attributeUnsupported, .noValue:
            return .visible
        default:
            return .failed
        }
    }

    private static func children(of element: AXUIElement) -> ChildrenResult<AXUIElement> {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) {
        case .success:
            guard let children = value as? [AXUIElement] else { return .failed }
            return .available(children)
        case .attributeUnsupported, .noValue:
            return .unsupported
        default:
            return .failed
        }
    }

    private static func actions(
        of element: AXUIElement, trace: ((String, String?) -> Void)? = nil
    ) -> [String]? {
        var value: CFArray?
        let error = AXUIElementCopyActionNames(element, &value)
        if error != .success { trace?("actions-error-\(error.rawValue)", nil) }
        guard error == .success,
              let value, let actions = value as? [String]
        else { return nil }
        return actions
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private static func frame(
        of element: AXUIElement,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> AccessibilityFrame {
        guard clock.now < deadline else { return .unavailable }
        let position = attribute(element, kAXPositionAttribute as CFString)
        guard clock.now < deadline else { return .unavailable }
        let size = attribute(element, kAXSizeAttribute as CFString)
        guard clock.now < deadline, let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID()
        else { return .unavailable }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        else { return .unavailable }
        let rect = PetRect(
            x: Double(point.x), y: Double(point.y),
            width: Double(dimensions.width), height: Double(dimensions.height)
        )
        return accessibilityFrame(rect)
    }

    private static let obstacleRoles: Set<String> = [
        kAXButtonRole as String, kAXCheckBoxRole as String, kAXComboBoxRole as String,
        kAXDisclosureTriangleRole as String, kAXGrowAreaRole as String,
        kAXIncrementorRole as String, "AXLink", kAXMenuBarItemRole as String,
        kAXMenuButtonRole as String, kAXMenuItemRole as String, kAXPopUpButtonRole as String,
        kAXRadioButtonRole as String, "AXSearchField", kAXScrollBarRole as String,
        kAXSliderRole as String,
        kAXStaticTextRole as String, kAXTextAreaRole as String, kAXTextFieldRole as String,
        kAXValueIndicatorRole as String, kAXBusyIndicatorRole as String,
        kAXProgressIndicatorRole as String, kAXRelevanceIndicatorRole as String,
        kAXHeadingRole as String, kAXSplitterRole as String, kAXColorWellRole as String,
        kAXTimeFieldRole as String, kAXDateFieldRole as String, kAXHelpTagRole as String,
        kAXDockItemRole as String, kAXRulerRole as String, kAXRulerMarkerRole as String,
        kAXLevelIndicatorRole as String, kAXCellRole as String, kAXLayoutItemRole as String,
        kAXHandleRole as String,
    ]

    private static let containerRoles: Set<String> = [
        kAXApplicationRole as String, kAXWindowRole as String, kAXSheetRole as String,
        kAXDrawerRole as String, kAXGroupRole as String, kAXScrollAreaRole as String,
        kAXRadioGroupRole as String, kAXListRole as String, kAXTableRole as String,
        kAXOutlineRole as String, kAXBrowserRole as String, kAXColumnRole as String,
        kAXRowRole as String, kAXTabGroupRole as String, kAXSplitGroupRole as String,
        kAXToolbarRole as String, kAXMenuBarRole as String, kAXMenuRole as String,
        kAXGridRole as String, kAXLayoutAreaRole as String, kAXPopoverRole as String,
        "AXWebArea",
    ]

    private enum ElementKind {
        case obstacle
        case container
        case unknown
    }

    private static let activatingActions: Set<String> = [
        kAXPressAction as String, kAXPickAction as String,
        kAXConfirmAction as String, kAXCancelAction as String,
        kAXIncrementAction as String, kAXDecrementAction as String,
    ]

    nonisolated static func hasActivatingAction(_ actions: [String]) -> Bool {
        actions.contains { activatingActions.contains($0) }
    }

    private static func kind(for role: String) -> ElementKind {
        if obstacleRoles.contains(role) { return .obstacle }
        if containerRoles.contains(role) { return .container }
        return .unknown
    }

    private static let roleClassificationCheck: Void = {
        assert(kind(for: kAXGroupRole as String) == .container)
        assert(kind(for: kAXUnknownRole as String) == .unknown)
        assert(kind(for: kAXImageRole as String) == .unknown)
        assert(kind(for: kAXButtonRole as String) == .obstacle)
    }()

    private static func validate(_ rect: PetRect) throws {
        guard valid(rect) else { throw SystemInspectorError.invalidGeometry }
    }

    private static func valid(_ rect: PetRect) -> Bool {
        rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func petRect(_ rect: CGRect) -> PetRect {
        PetRect(x: Double(rect.minX), y: Double(rect.minY),
                width: Double(rect.width), height: Double(rect.height))
    }

    private static func intersection(_ lhs: PetRect, _ rhs: PetRect) -> PetRect? {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.maxX, rhs.maxX)
        let maxY = min(lhs.maxY, rhs.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return PetRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func overlapScore(_ lhs: PetRect, _ rhs: PetRect) -> Double {
        guard let overlap = intersection(lhs, rhs) else { return 0 }
        let intersectionArea = overlap.width * overlap.height
        return intersectionArea / (lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea)
    }

    private static func clip(_ rect: PetRect, to regions: [PetRect]) -> [PetRect] {
        regions.compactMap { intersection(rect, $0) }
    }

    private static func subtract(_ regions: [PetRect], _ cutters: [PetRect]) -> [PetRect] {
        cutters.reduce(regions) { pieces, cutter in pieces.flatMap { subtract($0, cutter) } }
    }

    private static func subtract(_ rect: PetRect, _ cutter: PetRect) -> [PetRect] {
        guard let overlap = intersection(rect, cutter) else { return [rect] }
        var result: [PetRect] = []
        if overlap.y > rect.y {
            result.append(PetRect(x: rect.x, y: rect.y, width: rect.width, height: overlap.y - rect.y))
        }
        if overlap.maxY < rect.maxY {
            result.append(PetRect(x: rect.x, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY))
        }
        if overlap.x > rect.x {
            result.append(PetRect(x: rect.x, y: overlap.y, width: overlap.x - rect.x, height: overlap.height))
        }
        if overlap.maxX < rect.maxX {
            result.append(PetRect(x: overlap.maxX, y: overlap.y, width: rect.maxX - overlap.maxX, height: overlap.height))
        }
        return result
    }
}

@MainActor
final class SystemChangeObserver {
    private static let maximumRegistrationDuration = Duration.milliseconds(180)

    private final class CallbackBox: @unchecked Sendable {
        let callback: @MainActor () -> Void

        init(callback: @escaping @MainActor () -> Void) {
            self.callback = callback
        }
    }

    private struct Registration: @unchecked Sendable {
        let observer: AXObserver
        let elements: [AXUIElement]
        let callback: UnsafeMutableRawPointer
    }

    private var registrations: [Registration] = []

    func observe(pids: [Int32], onChange: @escaping @MainActor () -> Void) {
        stop()
        guard AXIsProcessTrusted() else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.maximumRegistrationDuration)
        // shortcut: observe at most 32 applications, add registration diffing before raising the cap.
        for pid in Set(pids).filter({ $0 > 0 }).sorted().prefix(32) {
            guard clock.now < deadline else { break }
            var observer: AXObserver?
            guard AXObserverCreate(pid_t(pid), Self.changed, &observer) == .success,
                  let observer else { continue }
            let application = AXUIElementCreateApplication(pid_t(pid))
            guard AXUIElementSetMessagingTimeout(application, 0.025) == .success,
                  clock.now < deadline
            else { continue }
            let windows = Self.windows(of: application, deadline: deadline, clock: clock)
            let pointer = Unmanaged.passRetained(CallbackBox(callback: onChange)).toOpaque()
            let applicationNotifications = [
                kAXFocusedUIElementChangedNotification,
                kAXLayoutChangedNotification,
                kAXWindowCreatedNotification,
            ]
            var supported = false
            for notification in applicationNotifications {
                guard clock.now < deadline else { break }
                supported = AXObserverAddNotification(
                    observer, application, notification as CFString, pointer
                ) == .success || supported
            }
            for window in windows {
                guard clock.now < deadline else { break }
                for notification in [kAXMovedNotification, kAXResizedNotification,
                                     kAXLayoutChangedNotification,
                                     kAXUIElementDestroyedNotification] {
                    guard clock.now < deadline else { break }
                    supported = AXObserverAddNotification(
                        observer, window, notification as CFString, pointer
                    ) == .success || supported
                }
            }
            guard supported else {
                Unmanaged<CallbackBox>.fromOpaque(pointer).release()
                continue
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            registrations.append(Registration(
                observer: observer, elements: [application] + windows, callback: pointer
            ))
        }
    }

    func stop() {
        for registration in registrations {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes
            )
            Unmanaged<CallbackBox>.fromOpaque(registration.callback).release()
        }
        registrations.removeAll()
    }

    private nonisolated static let changed: AXObserverCallback = { _, _, _, context in
        guard let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in box.callback() }
    }

    private static func windows(
        of application: AXUIElement,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard clock.now < deadline,
              AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &value
        ) == .success,
              clock.now < deadline
        else { return [] }
        return Array((value as? [AXUIElement] ?? []).prefix(128))
    }

    deinit {
        for registration in registrations {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes
            )
            Unmanaged<CallbackBox>.fromOpaque(registration.callback).release()
        }
    }
}
