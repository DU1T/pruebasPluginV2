//
//  Main.swift
//  UWBTestApp
//
//  Created by Gustavo Gonzalez on 7/20/25.
//
import SwiftUI

/// Mirrors the plugin's module-wide flag (declared in `UWBplugin/Main.swift`), so the
/// mirrored pipeline files compile unchanged here. Toggleable from the Diagnóstico
/// section; leave it off unless debugging — these paths run tens of times per second
/// and synchronous print() is what caused stutter on the Unity side.
var uwbVerboseLogging = false

@main
struct Main: App {
    @State private var viewModel = ViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .task {
                    // Deferred startup: first frame renders immediately showing
                    // the loading state, then UWB + Bluetooth initialization begins.
                    viewModel.startIfNeeded()
                }
        }
    }
}
