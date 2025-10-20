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
            // Sessions Tab (first)
            SessionsView()
                .tabItem {
                    Label("Sessions", systemImage: "list.clipboard")
                }
                .tag(0)

            // Spaces Tab (second)
            SpacesView()
                .tabItem {
                    Label("Spaces", systemImage: "cube")
                }
                .tag(1)

            // Scanner Tab (just before settings)
            ContentView()
                .tabItem {
                    Label("Scanner", systemImage: "viewfinder")
                }
                .tag(2)

            // Settings Tab
            SettingsPlaceholderView()
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

struct SettingsPlaceholderView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "gear")
                    .font(.system(size: 64))
                    .foregroundColor(.gray)
                
                Text("Settings")
                    .font(.title)
                    .fontWeight(.semibold)
                
                Text("Configure your preferences")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Preview

#Preview {
    MainTabView()
}