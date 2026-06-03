//
//  AppDelegate.swift
//  roboscope2
//
//  Created by Andrii Ieroshevych on 14.10.2025.
//

import SwiftUI
import Foundation

private extension ProcessInfo {
    static var isRunningUnitTests: Bool {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@main
struct roboscope2App: App {
    
    init() {
        // Skip heavy app initialization while running unit tests
        if ProcessInfo.isRunningUnitTests {
            return
        }

        // API environment is now persisted in AppSettings (defaults to dev in DEBUG, prod otherwise).
        // AppSettings.init reads the stored value; APIConfiguration reads it lazily.
        #if DEBUG
        APIConfiguration.shared.enableLogging = true
        #else
        APIConfiguration.shared.enableLogging = false
        #endif

        // Background sync registration retained, but automatic polling disabled.
        // Users can trigger sync manually from UI if needed.
        SyncManager.shared.registerBackgroundTasks()
    }
    
    var body: some Scene {
        // Use a single WindowGroup and choose content conditionally to keep
        // the underlying Scene type identical across branches.
        WindowGroup {
            if ProcessInfo.isRunningUnitTests {
                EmptyView()
            } else {
                MainTabView()
            }
        }
    }
}

