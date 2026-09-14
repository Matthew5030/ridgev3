//
//  ridge_v3App.swift
//  ridge v3
//
//  Created by Matthew Bilella on 13/09/2026.
//

import SwiftUI

@main
struct ridge_v3App: App {
    @State private var showStressTest = ProcessInfo.processInfo.arguments.contains("--eryri-stress-test")
    var body: some Scene {
        WindowGroup {
            if showStressTest {
                AdaptiveParkTestView(onClose: { showStressTest = false })
            } else {
                ContentView()
            }
        }
    }
}
