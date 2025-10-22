//
//  SettingsView.swift
//  roboscope2
//
//  App settings interface
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @State private var showResetConfirmation = false
    
    var body: some View {
        NavigationView {
            Form {
                // Preset Section
                Section {
                    Picker("Registration Preset", selection: $settings.currentPreset) {
                        ForEach(AppSettings.RegistrationPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .onChange(of: settings.currentPreset) { newPreset in
                        if newPreset != .custom {
                            settings.applyPreset(newPreset)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(presetDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Registration Preset")
                } footer: {
                    Text("Choose a preset or customize individual settings")
                }
                
                // Point Cloud Settings
                Section {
                    Stepper(value: $settings.modelPointsSampleCount, in: 1000...20000, step: 1000) {
                        VStack(alignment: .leading) {
                            Text("Model Points")
                            Text("\(settings.modelPointsSampleCount) points")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: settings.modelPointsSampleCount) { _ in
                        markAsCustom()
                    }
                    
                    Stepper(value: $settings.scanPointsSampleCount, in: 1000...30000, step: 1000) {
                        VStack(alignment: .leading) {
                            Text("Scan Points")
                            Text("\(settings.scanPointsSampleCount) points")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: settings.scanPointsSampleCount) { _ in
                        markAsCustom()
                    }
                } header: {
                    Text("Point Cloud Sampling")
                } footer: {
                    Text("Higher values improve accuracy but slow down registration")
                }
                
                // ICP Algorithm Settings
                Section {
                    Stepper(value: $settings.maxICPIterations, in: 10...100, step: 5) {
                        VStack(alignment: .leading) {
                            Text("Max Iterations")
                            Text("\(settings.maxICPIterations) iterations")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: settings.maxICPIterations) { _ in
                        markAsCustom()
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Convergence Threshold")
                        
                        Picker("Threshold", selection: $settings.icpConvergenceThreshold) {
                            Text("0.0001 (Very Precise)").tag(0.0001)
                            Text("0.0005 (Precise)").tag(0.0005)
                            Text("0.001 (Normal)").tag(0.001)
                            Text("0.002 (Fast)").tag(0.002)
                            Text("0.005 (Very Fast)").tag(0.005)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: settings.icpConvergenceThreshold) { _ in
                            markAsCustom()
                        }
                        
                        Text("Current: \(String(format: "%.4f", settings.icpConvergenceThreshold))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("ICP Algorithm")
                } footer: {
                    Text("Lower threshold = higher accuracy but longer processing time")
                }
                
                // Performance Settings
                Section {
                    Toggle(isOn: $settings.pauseARDuringRegistration) {
                        VStack(alignment: .leading) {
                            Text("Pause AR During Registration")
                            Text("Frees 30-40% CPU/GPU resources")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: settings.pauseARDuringRegistration) { _ in
                        markAsCustom()
                    }
                    
                    Toggle(isOn: $settings.useBackgroundLoading) {
                        VStack(alignment: .leading) {
                            Text("Background Model Loading")
                            Text("Keeps UI responsive during load")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: settings.useBackgroundLoading) { _ in
                        markAsCustom()
                    }
                    
                    Toggle(isOn: $settings.skipModelConsistencyChecks) {
                        VStack(alignment: .leading) {
                            Text("Skip Consistency Checks")
                            Text("Faster loading, less validation")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: settings.skipModelConsistencyChecks) { _ in
                        markAsCustom()
                    }
                } header: {
                    Text("Performance Optimizations")
                } footer: {
                    Text("Recommended settings for best performance")
                }
                
                // Debug Settings
                Section {
                    Toggle(isOn: $settings.showPerformanceLogs) {
                        VStack(alignment: .leading) {
                            Text("Show Performance Logs")
                            Text("Displays timing information in console")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Debug")
                }
                
                // Reset Section
                Section {
                    Button(action: {
                        showResetConfirmation = true
                    }) {
                        HStack {
                            Spacer()
                            Text("Reset to Defaults")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
                
                // Info Section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        estimatedTimeRow
                        
                        Divider()
                        
                        Text("Expected Results")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        HStack {
                            Text("RMSE:")
                            Spacer()
                            Text(expectedRMSE)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        
                        HStack {
                            Text("Accuracy:")
                            Spacer()
                            Text(expectedAccuracy)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                    }
                } header: {
                    Text("Performance Estimate")
                }
            }
            .navigationTitle("Settings")
            .alert("Reset Settings", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    settings.resetToDefaults()
                }
            } message: {
                Text("Reset all settings to default balanced values?")
            }
        }
    }
    
    // MARK: - Helper Views
    
    private var estimatedTimeRow: some View {
        HStack {
            Text("Estimated Time:")
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
            Text(estimatedTime)
                .font(.subheadline)
                .foregroundColor(.blue)
        }
    }
    
    // MARK: - Computed Properties
    
    private var presetDescription: String {
        switch settings.currentPreset {
        case .fast:
            return "⚡ Optimized for speed (~10-15s). Good for quick alignment checks."
        case .balanced:
            return "⚖️ Best balance of speed and accuracy (~15-20s). Recommended for most users."
        case .accurate:
            return "🎯 Maximum accuracy (~30-40s). Best for critical measurements."
        case .custom:
            return "🔧 Custom settings. Modify individual parameters below."
        }
    }
    
    private var estimatedTime: String {
        let pointsTime = Double(settings.modelPointsSampleCount + settings.scanPointsSampleCount) / 2000.0
        let iterationsTime = Double(settings.maxICPIterations) * 0.2
        let baseTime: Double = 8.0 // Download + export + load
        
        let total = baseTime + pointsTime + iterationsTime
        
        if total < 15 {
            return "~10-15s"
        } else if total < 25 {
            return "~15-25s"
        } else if total < 35 {
            return "~25-35s"
        } else {
            return "~35-45s"
        }
    }
    
    private var expectedRMSE: String {
        if settings.icpConvergenceThreshold <= 0.0001 {
            return "< 0.05m (Excellent)"
        } else if settings.icpConvergenceThreshold <= 0.001 {
            return "< 0.10m (Good)"
        } else {
            return "< 0.15m (Acceptable)"
        }
    }
    
    private var expectedAccuracy: String {
        let points = settings.modelPointsSampleCount + settings.scanPointsSampleCount
        if points >= 20000 {
            return "Very High"
        } else if points >= 12000 {
            return "High"
        } else {
            return "Medium"
        }
    }
    
    // MARK: - Actions
    
    private func markAsCustom() {
        if settings.currentPreset != .custom {
            settings.currentPreset = .custom
        }
    }
}

#Preview {
    SettingsView()
}
