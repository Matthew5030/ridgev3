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
        // Explicit device diagnostics exercise the app's real network permission
        // and DNS route without changing its source or downloading terrain.
        if let addresses = ProcessInfo.processInfo.environment["RIDGE_CHECK_SERVERS"] {
            Task {
                var results: [String:String] = [:]
                for address in addresses.split(separator:",").map(String.init) {
                    do {
                        let root = try WorldLibrary.root(mode:"local",local:address)
                        let count = try await WorldLibrary.checkConnection(root:root)
                        results[address]="Connected: \(count) sections"
                    } catch { results[address]=String(describing:error) }
                }
                let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                if let data=try? JSONEncoder().encode(results) {
                    try? data.write(to:directory.appendingPathComponent("connection-check.json"),options:.atomic)
                }
            }
        }
        if let sourceID=ProcessInfo.processInfo.environment["RIDGE_BENCHMARK_PACK"] {
            Task { await WorldPackDiagnostics.run(sourceID:sourceID) }
        }
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
