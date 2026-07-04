//
//  xcode_status_rpcApp.swift
//  xcode-status-rpc
//
//  Created by Fikrah Damar Huda on 05/07/26.
//

import SwiftUI

@main
struct xcode_status_rpcApp: App {
    private let monitor = XcodeMonitor()

    init() {
        XcodeMonitor.ensureAccessibilityPermission()
        monitor.start()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
