//
//  MainTabView.swift
//  roboscope2
//
//  Main navigation structure for the app
//

import SwiftUI

struct MainTabView: View {
    // Default to Sessions tab
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Sessions Tab
            SessionsView()
                .tabItem {
                    Label("Sessions", systemImage: "list.clipboard")
                }
                .tag(0)

            // Repair Tab — independent AR inspection workflow (own space picker + session list),
            // does not share state with the Sessions/Laser Guide flow above.
            RepairView()
                .tabItem {
                    Label("Repair", systemImage: "wrench.and.screwdriver")
                }
                .tag(1)

            // Record Tab
            NavigationView {
                RecordView()
            }
            .navigationViewStyle(.stack)
                .tabItem {
                    Label("Record", systemImage: "video.fill")
                }
                .tag(2)

            // Settings Tab
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
    }
}

// MARK: - Placeholder Views

struct SpacesPlaceholderView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "cube")
                    .font(.system(size: 64))
                    .foregroundColor(.gray)
                
                Text("Spaces")
                    .font(.title)
                    .fontWeight(.semibold)
                
                Text("Manage your 3D spaces")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Spaces")
        }
    }
}

// MARK: - Preview

#Preview {
    MainTabView()
}