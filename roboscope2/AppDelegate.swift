//
//  AppDelegate.swift
//  roboscope2
//
//  Created by Andrii Ieroshevych on 14.10.2025.
//

import SwiftUI

@main
struct roboscope2App: App {
    
    init() {
        // Configure API environment based on build configuration
        #if DEBUG
        APIConfiguration.shared.useDevelopment()
        APIConfiguration.shared.enableLogging = true
        #else
        APIConfiguration.shared.useProduction()
        APIConfiguration.shared.enableLogging = false
        #endif
        
    // Background sync registration retained, but automatic polling disabled.
    // Users can trigger sync manually from UI if needed.
    SyncManager.shared.registerBackgroundTasks()
    }
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

