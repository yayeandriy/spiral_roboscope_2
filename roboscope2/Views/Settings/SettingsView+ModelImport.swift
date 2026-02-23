//
//  SettingsView+ModelImport.swift
//  roboscope2
//
//  Laser Guide model import logic + document picker
//  (extracted from SettingsView.swift to keep it under 500 lines)
//

import SwiftUI
import UniformTypeIdentifiers
import CoreML
import ZIPFoundation

// MARK: - Model Import Logic

extension SettingsView {

    func importLaserGuideModel(from pickedURL: URL) throws -> (compiledURL: URL, displayName: String) {
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
                userInfo: [NSLocalizedDescriptionKey: "That folder doesn't contain a compiled Core ML model (.mlmodelc). Please select a .mlmodelc package (folder) or a .mlmodel file."]
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
                userInfo: [NSLocalizedDescriptionKey: "That zip doesn't contain a .mlmodelc, .mlpackage, or .mlmodel. Please zip one of those and try again."]
            )
        }

        throw NSError(
            domain: "LaserGuideModel",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported item. Please choose a .mlmodel, a .mlmodelc, or a folder that contains a .mlmodelc."]
        )
    }

    func nearestCoreMLPackage(for url: URL) -> URL? {
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

    func findFirstMlmodelc(in folder: URL) -> URL? {
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

    func findFirstItem(in folder: URL, withExtension ext: String) -> URL? {
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
}

// MARK: - Document Picker

struct LaserGuideModelDocumentPicker: UIViewControllerRepresentable {
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
