//
//  SettingsView.swift
//  roboscope2
//
//  App settings interface
//

import SwiftUI
import UniformTypeIdentifiers
import CoreML
import ZIPFoundation

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @State private var showResetConfirmation = false
    @State private var isApplyingPreset = false
    @State private var showLaserGuideModelPicker = false
    @State private var laserGuideModelError: String? = nil
    
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
                        // Apply preset settings when user selects it (except Custom)
                        if newPreset != .custom {
                            isApplyingPreset = true
                            settings.applyPreset(newPreset, updateCurrentPreset: false)
                            // Delay to allow settings to propagate before re-enabling markAsCustom
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isApplyingPreset = false
                            }
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

                // Laser Guide ML Model (Files/Google Drive)
                Section {
                    HStack {
                        Text("Current Model")
                        Spacer()
                        Text(settings.laserGuideMLModelDisplayName ?? "Bundled (laser-pens)")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Button("Select Model from Files / Google Drive") {
                        showLaserGuideModelPicker = true
                    }

                    if settings.laserGuideMLModelLocalPath != nil {
                        Button("Use Bundled Model", role: .destructive) {
                            settings.laserGuideMLModelLocalPath = nil
                            settings.laserGuideMLModelDisplayName = nil
                        }
                    }
                } header: {
                    Text("Laser Guide ML")
                } footer: {
                    Text("Pick a .mlmodel or .mlmodelc from Files (Google Drive supported). The model is compiled/cached locally.")
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
            .alert("Laser Guide Model", isPresented: .constant(laserGuideModelError != nil)) {
                Button("OK") { laserGuideModelError = nil }
            } message: {
                if let laserGuideModelError {
                    Text(laserGuideModelError)
                }
            }
            .sheet(isPresented: $showLaserGuideModelPicker) {
                LaserGuideModelDocumentPicker(
                    onPick: { url in
                        Task { @MainActor in
                            do {
                                let (compiledURL, displayName) = try importLaserGuideModel(from: url)
                                settings.laserGuideMLModelLocalPath = compiledURL.path
                                settings.laserGuideMLModelDisplayName = displayName
                                showLaserGuideModelPicker = false
                            } catch {
                                laserGuideModelError = error.localizedDescription
                                showLaserGuideModelPicker = false
                            }
                        }
                    },
                    onCancel: {
                        showLaserGuideModelPicker = false
                    }
                )
            }
        }
    }

    private func importLaserGuideModel(from pickedURL: URL) throws -> (compiledURL: URL, displayName: String) {
        let fm = FileManager.default

        // If the user picked a file *inside* a CoreML package (common when .mlmodelc/.mlpackage appear as folders),
        // walk up to the nearest containing package.
        let resolvedURL = nearestCoreMLPackage(for: pickedURL) ?? pickedURL

        let displayName = resolvedURL.deletingPathExtension().lastPathComponent
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let modelsDir = appSupport
            .appendingPathComponent("MLModels", isDirectory: true)
            .appendingPathComponent("LaserGuide", isDirectory: true)
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let dest = modelsDir.appendingPathComponent("laser_guide_custom.mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }

        let needsSecurity = resolvedURL.isFileURL
        let didStart = needsSecurity ? resolvedURL.startAccessingSecurityScopedResource() : false
        defer {
            if didStart { resolvedURL.stopAccessingSecurityScopedResource() }
        }

        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: resolvedURL.path, isDirectory: &isDir)

        // Many providers (Google Drive/iCloud) show .mlmodelc as a folder/package.
        // Also, users may select a containing folder (e.g. "laser-pens").
        if isDir.boolValue {
            let ext = resolvedURL.pathExtension.lowercased()
            if ext == "mlmodelc" {
                try fm.copyItem(at: resolvedURL, to: dest)
                return (dest, displayName)
            }

            if ext == "mlpackage" {
                let compiledTemp = try MLModel.compileModel(at: resolvedURL)
                try fm.copyItem(at: compiledTemp, to: dest)
                return (dest, displayName)
            }

            if let embedded = findFirstMlmodelc(in: resolvedURL) {
                let embeddedName = embedded.deletingPathExtension().lastPathComponent
                try fm.copyItem(at: embedded, to: dest)
                return (dest, embeddedName)
            }

            throw NSError(
                domain: "LaserGuideModel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "That folder doesn’t contain a compiled Core ML model (.mlmodelc). Please select a .mlmodelc package (folder) or a .mlmodel file."]
            )
        }

        let ext = resolvedURL.pathExtension.lowercased()
        if ext == "mlmodelc" {
            // Some providers may hand back a file URL even for packages.
            try fm.copyItem(at: resolvedURL, to: dest)
            return (dest, displayName)
        }

        if ext == "mlmodel" {
            let compiledTemp = try MLModel.compileModel(at: resolvedURL)
            try fm.copyItem(at: compiledTemp, to: dest)
            return (dest, displayName)
        }

        if ext == "zip" {
            let tempRoot = fm.temporaryDirectory
                .appendingPathComponent("laser_guide_model_unzip_\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempRoot) }

            do {
                try fm.unzipItem(at: resolvedURL, to: tempRoot)
            } catch {
                throw NSError(
                    domain: "LaserGuideModel",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to unzip archive: \(error.localizedDescription)"]
                )
            }

            if let embeddedModelc = findFirstMlmodelc(in: tempRoot) {
                let embeddedName = embeddedModelc.deletingPathExtension().lastPathComponent
                try fm.copyItem(at: embeddedModelc, to: dest)
                return (dest, embeddedName)
            }

            if let embeddedPackage = findFirstItem(in: tempRoot, withExtension: "mlpackage") {
                let embeddedName = embeddedPackage.deletingPathExtension().lastPathComponent
                let compiledTemp = try MLModel.compileModel(at: embeddedPackage)
                try fm.copyItem(at: compiledTemp, to: dest)
                return (dest, embeddedName)
            }

            if let embeddedModel = findFirstItem(in: tempRoot, withExtension: "mlmodel") {
                let embeddedName = embeddedModel.deletingPathExtension().lastPathComponent
                let compiledTemp = try MLModel.compileModel(at: embeddedModel)
                try fm.copyItem(at: compiledTemp, to: dest)
                return (dest, embeddedName)
            }

            throw NSError(
                domain: "LaserGuideModel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "That zip doesn’t contain a .mlmodelc, .mlpackage, or .mlmodel. Please zip one of those and try again."]
            )
        }

        throw NSError(
            domain: "LaserGuideModel",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported item. Please choose a .mlmodel, a .mlmodelc, or a folder that contains a .mlmodelc."]
        )
    }

    private func nearestCoreMLPackage(for url: URL) -> URL? {
        let fm = FileManager.default

        // If `url` is inside a package, walk up to the nearest parent that ends with .mlmodelc or .mlpackage.
        var candidate = url
        while candidate.pathComponents.count > 1 {
            let ext = candidate.pathExtension.lowercased()
            if ext == "mlmodelc" || ext == "mlpackage" {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    return candidate
                }
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }

    private func findFirstMlmodelc(in folder: URL) -> URL? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "mlmodelc" {
                return url
            }
        }
        return nil
    }

    private func findFirstItem(in folder: URL, withExtension ext: String) -> URL? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == ext.lowercased() {
                return url
            }
        }
        return nil
    }
    

private struct LaserGuideModelDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Use a broad type so providers like Google Drive don't hide CoreML packages.
        // We'll validate the selection ourselves.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let first = urls.first else {
                onCancel()
                return
            }
            onPick(first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
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
        case .instant:
            return "🚀 Blazing fast (~5-8s). Minimal points for instant rough alignment."
        case .ultraFast:
            return "⚡⚡ Ultra speed (~7-12s). Very quick with acceptable quality."
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
        
        if total < 10 {
            return "~5-8s"
        } else if total < 13 {
            return "~8-12s"
        } else if total < 16 {
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
        // Don't mark as custom if we're currently applying a preset
        if !isApplyingPreset && settings.currentPreset != .custom {
            settings.currentPreset = .custom
        }
    }
}

#Preview {
    SettingsView()
}
