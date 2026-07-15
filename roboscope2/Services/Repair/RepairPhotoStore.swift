//
//  RepairPhotoStore.swift
//  roboscope2
//
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Local-disk persistence for Repair photos: a snapshot captured the moment each pin is
//  confirmed, plus manual "take picture" session captures (raw + pins-baked-in). The server-side
//  storage destination for these isn't decided yet — SpiralStorageService.FileCategory.image /
//  generatePath(for: .image, ...) is the likely eventual home once that lands. Until then,
//  everything is written to Application Support/RepairPhotos/<sessionId>/ so nothing is lost;
//  wiring in a real upload later just means adding a call after each `save...` below.
//

import Foundation
import UIKit
import CoreImage
import ImageIO
import RealityKit

final class RepairPhotoStore {
    static let shared = RepairPhotoStore()
    private init() {}

    private let ciContext = CIContext()
    private let ioQueue = DispatchQueue(label: "repair.photostore.io", qos: .utility)

    // MARK: - Pixel buffer -> UIImage

    /// Converts a raw ARKit camera pixel buffer to an upright UIImage, using the same
    /// orientation convention Vision uses elsewhere in this module (see cgImageOrientation(for:)
    /// in RepairARSessionView+Logic.swift).
    func image(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Pin snapshots (captured the moment a pin is confirmed)

    /// Fire-and-forget: encodes + writes off the main thread. Best-effort — a failed snapshot
    /// write never blocks or fails pin placement itself.
    func savePinSnapshotAsync(sessionId: UUID, pinId: UUID, image: UIImage) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let dir = try self.directory(subpath: "RepairPhotos/\(sessionId.uuidString)/pins")
                let url = dir.appendingPathComponent("pin_\(pinId.uuidString).jpg")
                try self.write(image, to: url)
            } catch {
                print("[RepairPhotoStore] Failed to save pin snapshot for \(pinId): \(error)")
            }
        }
    }

    func pinSnapshotURL(sessionId: UUID, pinId: UUID) -> URL? {
        guard let dir = try? directory(subpath: "RepairPhotos/\(sessionId.uuidString)/pins", create: false) else { return nil }
        let url = dir.appendingPathComponent("pin_\(pinId.uuidString).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Manual session-level captures ("take picture" button)

    /// Saves a manually-triggered capture: the raw camera frame, plus (best-effort) a second
    /// image with pins baked in. This is a once-in-a-while, user-initiated action (not a hot
    /// per-frame path), so it's fine to `await` the disk write.
    @discardableResult
    func saveManualCapture(sessionId: UUID, raw: UIImage, baked: UIImage?) async throws -> (raw: URL, baked: URL?) {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let dir = try self.directory(subpath: "RepairPhotos/\(sessionId.uuidString)/captures")
                    let stamp = Self.filenameTimestamp()

                    let rawURL = dir.appendingPathComponent("\(stamp)_raw.jpg")
                    try self.write(raw, to: rawURL)

                    var bakedURL: URL? = nil
                    if let baked {
                        let url = dir.appendingPathComponent("\(stamp)_annotated.jpg")
                        try self.write(baked, to: url)
                        bakedURL = url
                    }
                    continuation.resume(returning: (rawURL, bakedURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Directories

    private func directory(subpath: String, create: Bool = true) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let url = base.appendingPathComponent(subpath, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private func write(_ image: UIImage, to url: URL) throws {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw NSError(domain: "RepairPhotoStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JPEG"])
        }
        try data.write(to: url, options: .atomic)
    }

    private static func filenameTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return fmt.string(from: Date())
    }
}

// MARK: - ARView snapshot async bridge

extension ARView {
    /// Async wrapper over RealityKit's completion-based `snapshot(saveToHDR:completion:)`.
    /// Captures the ARView's own live-rendered composite — camera passthrough plus whatever
    /// RealityKit entities (e.g. Repair's pin spheres) are currently in the scene — at the
    /// view's on-screen resolution (not the raw camera buffer's).
    func snapshotAsync(saveToHDR: Bool = false) async -> UIImage? {
        await withCheckedContinuation { continuation in
            self.snapshot(saveToHDR: saveToHDR) { image in
                continuation.resume(returning: image)
            }
        }
    }
}
