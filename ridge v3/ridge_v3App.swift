//
//  ridge_v3App.swift
//  ridge v3
//
//  Created by Matthew Bilella on 13/09/2026.
//

import SwiftUI

@main
struct ridge_v3App: App {
    init() {
        UserDefaults.standard.register(defaults: [
            "ridge.mapSourceMode": WorldLibrary.defaultMode,
            "ridge.localMapServer": WorldLibrary.defaultLocalServer
        ])
        #if DEBUG
        // An explicit development launch can select a different LAN library.
        if let address = ProcessInfo.processInfo.environment["RIDGE_LOCAL_TEST_SERVER"],
           let root = try? WorldLibrary.root(mode: "local", local: address) {
            UserDefaults.standard.set(root.absoluteString, forKey: "ridge.localMapServer")
            UserDefaults.standard.set("local", forKey: "ridge.mapSourceMode")
        }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
