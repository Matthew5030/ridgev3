//
//  ridge_v3App.swift
//  ridge v3
//
//  Created by Matthew Bilella on 13/09/2026.
//

import SwiftUI

@main
struct ridge_v3App: App {
    @AppStorage(RidgeWalkthrough.completedVersionKey) private var walkthroughVersion = 0
    @State private var pendingOpenURL: URL?
    @State private var forceWalkthrough = ProcessInfo.processInfo.arguments.contains("--ridge-show-walkthrough")
    private var needsWalkthrough: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return forceWalkthrough || (walkthroughVersion < RidgeWalkthrough.version
            && !arguments.contains("--ridge-skip-walkthrough") && !arguments.contains("--verify-preinstalled-atlas"))
    }

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
        if let regionID=ProcessInfo.processInfo.environment["RIDGE_BENCHMARK_REGION"] {
            Task { await WorldPackDiagnostics.runRegion(id:regionID) }
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
            Group {
                if needsWalkthrough {
                    RidgeWalkthroughView {
                        walkthroughVersion = RidgeWalkthrough.version
                        forceWalkthrough = false
                    }
                } else {
                    ContentView(initialOpenURL: pendingOpenURL)
                }
            }
            .onOpenURL { url in
                // Keep files opened from Files until the first-run guide ends.
                if needsWalkthrough { pendingOpenURL = url }
            }
        }
    }
}
