//
//  XcodeMonitor.swift
//  xcode-status-rpc
//

import AppKit
import ApplicationServices

/// What the user is doing in Xcode right now, parsed from the window title.
struct XcodeActivity {
    let projectName: String?
    let fileName: String?
}

final class XcodeMonitor {

    private static let xcodeBundleID = "com.apple.dt.Xcode"

    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedXcodeElement: AXUIElement?
    private var lastReportedTitle: String?
    private(set) var isXcodeFrontmost = false

    // MARK: - Accessibility permission

    @discardableResult
    static func ensureAccessibilityPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Lifecycle

    func start() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.frontmostChanged(to: app)
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            frontmostChanged(to: app)
        }
    }

    func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        stopWatchingTitleChanges()
    }

    private func frontmostChanged(to app: NSRunningApplication) {
        let isXcode = app.bundleIdentifier == Self.xcodeBundleID

        if isXcode && !isXcodeFrontmost {
            print("[XcodeMonitor] Xcode is now frontmost")
            reportCurrentActivity(pid: app.processIdentifier)
            startWatchingTitleChanges(pid: app.processIdentifier)
        } else if !isXcode && isXcodeFrontmost {
            print("[XcodeMonitor] Xcode lost focus (now: \(app.localizedName ?? "unknown"))")
            stopWatchingTitleChanges()
        }

        isXcodeFrontmost = isXcode
    }

    // MARK: - Title change observation (fires when switching files in Xcode)

    private static let axCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<XcodeMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.xcodeWindowChanged()
    }

    private func startWatchingTitleChanges(pid: pid_t) {
        stopWatchingTitleChanges()

        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &observer) == .success, let observer else {
            print("[XcodeMonitor] Failed to create AXObserver")
            return
        }

        let xcodeElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        AXObserverAddNotification(observer, xcodeElement, kAXTitleChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, xcodeElement, kAXFocusedWindowChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        axObserver = observer
        observedXcodeElement = xcodeElement
    }

    private func stopWatchingTitleChanges() {
        if let axObserver {
            if let observedXcodeElement {
                AXObserverRemoveNotification(axObserver, observedXcodeElement, kAXTitleChangedNotification as CFString)
                AXObserverRemoveNotification(axObserver, observedXcodeElement, kAXFocusedWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        observedXcodeElement = nil
    }

    private func xcodeWindowChanged() {
        guard isXcodeFrontmost,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == Self.xcodeBundleID else {
            return
        }
        reportCurrentActivity(pid: app.processIdentifier)
    }

    // MARK: - Window title via Accessibility API

    private func reportCurrentActivity(pid: pid_t) {
        guard let title = Self.focusedWindowTitle(pid: pid) else {
            print("[XcodeMonitor] Could not read window title (no permission, or no window)")
            return
        }
        guard title != lastReportedTitle else { return }
        lastReportedTitle = title

        let activity = Self.parseWindowTitle(title)
        print("[XcodeMonitor] title=\"\(title)\" → project=\(activity.projectName ?? "?") file=\(activity.fileName ?? "?")")
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }

    static func parseWindowTitle(_ title: String) -> XcodeActivity {
        let separator = " — "  // em dash, not a hyphen
        var segments = title
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "Edited" }

        let fileIndex = segments.firstIndex { segment in
            let ext = (segment as NSString).pathExtension
            return !ext.isEmpty
        }

        var fileName: String?
        if let fileIndex {
            fileName = segments.remove(at: fileIndex)
        }

        return XcodeActivity(projectName: segments.first, fileName: fileName)
    }
}
