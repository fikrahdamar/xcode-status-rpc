//
//  XcodeMonitor.swift
//  xcode-status-rpc
//

import AppKit

/// Watches which app is frontmost and reports when Xcode gains/loses focus.
/// Uses NSWorkspace notifications (event-driven) instead of a polling timer,
/// so the app does zero work while the user stays in the same app.
final class XcodeMonitor {

    private static let xcodeBundleID = "com.apple.dt.Xcode"

    private var observer: NSObjectProtocol?
    private(set) var isXcodeFrontmost = false

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.frontmostChanged(to: app)
        }

        // The notification only fires on *changes*, so also check the app
        // that is already frontmost at launch (could be Xcode).
        if let app = NSWorkspace.shared.frontmostApplication {
            frontmostChanged(to: app)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    private func frontmostChanged(to app: NSRunningApplication) {
        let isXcode = app.bundleIdentifier == Self.xcodeBundleID

        if isXcode && !isXcodeFrontmost {
            print("[XcodeMonitor] Xcode is now frontmost")
        } else if !isXcode && isXcodeFrontmost {
            print("[XcodeMonitor] Xcode lost focus (now: \(app.localizedName ?? "unknown"))")
        }

        isXcodeFrontmost = isXcode
    }
}
