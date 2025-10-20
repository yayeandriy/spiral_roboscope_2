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
        // Configure API environment
        APIConfiguration.shared.useDevelopment()
        
        // Start background sync
        SyncManager.shared.registerBackgroundTasks()
        SyncManager.shared.startAutoSync()
    }
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

