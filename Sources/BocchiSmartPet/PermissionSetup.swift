import AppKit
@preconcurrency import ApplicationServices

struct PermissionState: Equatable {
    let accessibility: Bool
    let screenCapture: Bool

    static var current: Self {
        Self(
            accessibility: AXIsProcessTrusted(),
            screenCapture: CGPreflightScreenCaptureAccess()
        )
    }
}

@MainActor
final class PermissionSetup: NSObject {
    private let onVisualFallbackChanged: (Bool) -> Void
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let screenCaptureStatus = NSTextField(labelWithString: "")
    private let visualFallback = NSButton(
        checkboxWithTitle: "Включить визуальную проверку",
        target: nil,
        action: nil
    )
    private(set) var window: NSWindow?
    private var accessibilityRequestPendingUntil = 0.0
    private var observedAccessibilityWhileVisible: Bool?

    init(onVisualFallbackChanged: @escaping (Bool) -> Void) {
        self.onVisualFallbackChanged = onVisualFallbackChanged
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(state: PermissionState = .current) {
        if window == nil { window = makeWindow() }
        observedAccessibilityWhileVisible = nil
        update(state: state, visualFallbackEnabled: visualFallback.state == .on)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        observedAccessibilityWhileVisible = state.accessibility
    }

    func dismiss() {
        window?.orderOut(nil)
        observedAccessibilityWhileVisible = nil
    }

    func update(state: PermissionState, visualFallbackEnabled: Bool) {
        let accessibilityWasGranted = isVisible
            && observedAccessibilityWhileVisible == false
            && state.accessibility
        if state.accessibility { accessibilityRequestPendingUntil = 0 }
        let accessibilityRequestPending = ProcessInfo.processInfo.systemUptime < accessibilityRequestPendingUntil
        accessibilityStatus.stringValue = state.accessibility
            ? "Разрешено"
            : accessibilityRequestPending ? "Ожидаем решения macOS…" : "Не разрешено"
        accessibilityStatus.textColor = state.accessibility ? .systemGreen : .secondaryLabelColor
        screenCaptureStatus.stringValue = state.screenCapture ? "Разрешено" : "Не разрешено"
        screenCaptureStatus.textColor = state.screenCapture ? .systemGreen : .secondaryLabelColor
        visualFallback.state = visualFallbackEnabled ? .on : .off
        if isVisible { observedAccessibilityWhileVisible = state.accessibility }
        if accessibilityWasGranted { dismiss() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bocchi Smart Pet — доступ"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 660)

        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "Настройка доступа для Bocchi Smart Pet")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let intro = wrappingLabel(
            "Основной режим работает через Accessibility, без снимков и чтения текста."
        )
        let accessibility = permissionSection(
            title: "Accessibility — основной режим",
            detail: "Читает типы и границы элементов интерфейса.",
            status: accessibilityStatus,
            requestTitle: "Запросить Accessibility",
            requestAction: #selector(requestAccessibility),
            settingsTitle: "Открыть настройки Accessibility",
            settingsAction: #selector(openAccessibilitySettings)
        )

        visualFallback.target = self
        visualFallback.action = #selector(changeVisualFallback)
        visualFallback.toolTip = "По умолчанию выключен"
        let fallbackDetail = wrappingLabel(
            "Проверяет участок под питомцем. Полный кадр — только если место иначе не найти. Снимки не сохраняются и не отправляются в сеть."
        )
        let screenCapture = permissionSection(
            title: "Screen Recording — по желанию",
            detail: "Не требуется для основного режима. Разрешение macOS распространяется на экран целиком.",
            status: screenCaptureStatus,
            requestTitle: "Запросить Screen Recording",
            requestAction: #selector(requestScreenCapture),
            settingsTitle: "Открыть настройки Screen Recording",
            settingsAction: #selector(openScreenCaptureSettings)
        )

        let appPathTitle = NSTextField(labelWithString: "Какое приложение добавить")
        appPathTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let appPath = NSTextField(string: Bundle.main.bundlePath)
        appPath.isEditable = false
        appPath.isSelectable = true
        appPath.lineBreakMode = .byTruncatingMiddle
        appPath.toolTip = Bundle.main.bundlePath
        let reveal = NSButton(title: "Показать в Finder", target: self, action: #selector(revealApplication))
        let pathRow = NSStackView(views: [appPath, reveal])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8
        appPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pathHelp = wrappingLabel(
            "Если галочка уже включена, а статус — “Не разрешено”, удалите старую запись кнопкой “−”, добавьте эту .app через “+” и перезапустите Боччи."
        )
        pathHelp.textColor = .secondaryLabelColor

        let close = NSButton(title: "Закрыть и начать", target: self, action: #selector(closeSetup))
        let stack = NSStackView(views: [
            title, intro, separator(), accessibility,
            visualFallback, fallbackDetail, screenCapture,
            separator(), appPathTitle, pathRow, pathHelp, close
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22)
        ])
        return window
    }

    private func permissionSection(
        title: String,
        detail: String,
        status: NSTextField,
        requestTitle: String,
        requestAction: Selector,
        settingsTitle: String,
        settingsAction: Selector
    ) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        let headingRow = NSStackView(views: [heading, NSView(), status])
        headingRow.orientation = .horizontal
        headingRow.alignment = .firstBaseline

        let request = NSButton(title: requestTitle, target: self, action: requestAction)
        let settings = NSButton(title: settingsTitle, target: self, action: settingsAction)
        let buttons = NSStackView(views: [request, settings])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let section = NSStackView(views: [headingRow, wrappingLabel(detail), buttons])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        for view in section.arrangedSubviews { view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
        return section
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    @objc private func closeSetup() { dismiss() }

    @objc private func changeVisualFallback() {
        onVisualFallbackChanged(visualFallback.state == .on)
    }

    @objc private func requestAccessibility() {
        accessibilityRequestPendingUntil = ProcessInfo.processInfo.systemUptime + 2
        update(state: .current, visualFallbackEnabled: visualFallback.state == .on)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
        update(state: .current, visualFallbackEnabled: visualFallback.state == .on)
    }

    @objc private func openAccessibilitySettings() {
        openSettings("Privacy_Accessibility")
    }

    @objc private func openScreenCaptureSettings() {
        openSettings("Privacy_ScreenCapture")
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
