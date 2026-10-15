import AppKit
import Foundation

@MainActor
enum LaunchCheck {
    static func run(_ delegate: AppDelegate) async -> Int32 {
        var failures = 0

        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if !condition { failures += 1 }
        }

        guard await wait(upTo: .seconds(2), for: { delegate.setup != nil }),
              let setup = delegate.setup else {
            check(false, "application lifecycle creates permission setup")
            print("LAUNCH-CHECK RESULT: FAIL (\(failures) failed)")
            return 1
        }
        check(true, "application lifecycle creates permission setup")
        defer { setup.dismiss() }

        let initiallyVisible = setup.window?.isVisible == true
        check(initiallyVisible, "initial launch shows setup with granted-Accessibility fixture")
        if !initiallyVisible { setup.show() }

        guard let expectedWindow = setup.window else {
            check(false, "permission setup creates its window")
            print("LAUNCH-CHECK RESULT: FAIL (\(failures) failed)")
            return 1
        }

        setup.dismiss()
        check(await reopen(setup: setup, expectedWindow: expectedWindow),
              "LaunchServices reopen restores the same active key setup window")

        setup.dismiss()
        let fixture = NSPanel(
            contentRect: NSRect(x: 80, y: 80, width: 80, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        fixture.isReleasedWhenClosed = false
        fixture.orderFrontRegardless()
        defer { fixture.orderOut(nil) }
        check(fixture.isVisible, "own NSPanel fixture is visible before reopen")
        check(await reopen(setup: setup, expectedWindow: expectedWindow),
              "LaunchServices reopen restores setup while another own panel is visible")

        let result = failures == 0 ? "PASS" : "FAIL"
        print("LAUNCH-CHECK RESULT: \(result) (\(failures) failed)")
        return failures == 0 ? 0 : 1
    }

    private static func reopen(setup: PermissionSetup, expectedWindow: NSWindow) async -> Bool {
        setup.dismiss()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            print("FAIL: /usr/bin/open could not start: \(error.localizedDescription)")
            return false
        }

        let deadline = ContinuousClock.now + .seconds(3)
        var reopened = false
        while ContinuousClock.now < deadline {
            reopened = reopened || (setup.window === expectedWindow
                && expectedWindow.isVisible
                && expectedWindow.isKeyWindow
                && NSApp.isActive)
            if !process.isRunning {
                guard process.terminationStatus == 0 else {
                    print("FAIL: /usr/bin/open exited with status \(process.terminationStatus)")
                    return false
                }
                if reopened { return true }
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                if process.isRunning { process.terminate() }
                return false
            }
        }
        reopened = reopened || (setup.window === expectedWindow
            && expectedWindow.isVisible
            && expectedWindow.isKeyWindow
            && NSApp.isActive)
        if process.isRunning {
            process.terminate()
            return false
        }
        guard process.terminationStatus == 0 else {
            print("FAIL: /usr/bin/open exited with status \(process.terminationStatus)")
            return false
        }
        return reopened
    }

    private static func wait(upTo timeout: Duration, for condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return condition()
    }
}
