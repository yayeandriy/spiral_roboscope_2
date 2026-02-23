//
//  SessionScanView+Actions.swift
//  roboscope2
//
//  Scan lifecycle actions: start/stop scanning and export to cloud.
//

import SwiftUI

extension SessionScanView {

    // MARK: - Scanning Actions

    func startScanning() {
        captureSession.startScanning()
        isScanning = true
        hasScanData = false
    }

    func stopScanning() {
        captureSession.stopScanning()
        isScanning = false
        hasScanData = true
    }

    /// Save the current scanned mesh to Spiral Storage and set it as the Space's scan model URL.
    func saveScanToSpace() {
        guard !isExporting && !isRegistering else { return }
        isExporting = true
        exportProgress = 0.0
        exportStatus = "Preparing export..."
        showSuccessMessage = false

        captureSession.exportAndUploadMeshData(
            sessionId: session.id,
            spaceId: session.spaceId,
            progress: { progress, status in
                DispatchQueue.main.async {
                    self.exportProgress = progress
                    self.exportStatus = status
                }
            },
            completion: { [spaceService] localURL, cloudURL in
                Task { @MainActor in
                    self.isExporting = false
                    if let cloudURL {
                        do {
                            let update = UpdateSpace(scanUrl: cloudURL)
                            _ = try await spaceService.updateSpace(id: self.session.spaceId, update: update)
                            self.showSuccessMessage = true
                        } catch {
                            self.exportStatus = "Failed to save scan URL"
                        }
                    } else {
                        self.exportStatus = "Upload failed"
                    }
                }
            }
        )
    }

    func findSpace() {
        isRegistering = true
        registrationProgress = "Fetching space data..."

        Task {
            await performSpaceRegistration()
        }
    }
}
