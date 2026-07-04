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
        monitor.start()
    }

    var body: some Scene {
        // Background-only app: no WindowGroup, so no window opens at launch.
        // Settings scene satisfies SwiftUI's "at least one scene" requirement
        // without showing anything.
        Settings {
            EmptyView()
        }
    }
}
