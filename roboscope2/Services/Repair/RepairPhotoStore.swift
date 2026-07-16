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

    // MARK: - Software overlay burn-in (Validation mode manual captures)

    /// Draws a "box + class + confidence" overlay onto `image`, matching what
    /// `RepairDetectionOverlay` shows live on screen — used because Validation mode's overlay is
    /// a flat SwiftUI layer, never part of the ARView's own Metal scene, so `ARView.snapshotAsync`
    /// alone can't capture it (see `captureSessionPhoto` in RepairARSessionView+Logic.swift).
    ///
    /// `detections` are in raw camera-buffer normalized space (top-left origin) — the same space
    /// `imageToViewTransform` maps into normalized *view* space; this then scales that into
    /// `image`'s own pixel dimensions, so no separate viewport size is needed.
    func renderDetectionOverlay(
        onto image: UIImage,
        detections: [RepairDetection],
        imageToViewTransform: CGAffineTransform,
        classStyles: [String: RepairClassStyle]?
    ) -> UIImage {
        guard !detections.isEmpty else { return image }

        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { ctx in
            image.draw(at: .zero)
            let cg = ctx.cgContext

            for detection in detections {
                let color = Self.resolvedColor(for: detection.label, classStyles: classStyles)
                let polygon = Self.mappedPolygon(detection.maskPolygon, imageToViewTransform: imageToViewTransform, targetSize: image.size)

                let labelAnchor: CGPoint
                if let polygon, polygon.count >= 3 {
                    let path = CGMutablePath()
                    path.addLines(between: polygon)
                    path.closeSubpath()

                    cg.saveGState()
                    cg.addPath(path)
                    cg.setFillColor(color.withAlphaComponent(0.28).cgColor)
                    cg.fillPath()
                    cg.restoreGState()

                    cg.addPath(path)
                    cg.setStrokeColor(color.cgColor)
                    cg.setLineWidth(max(2, image.size.width * 0.0025))
                    cg.strokePath()

                    labelAnchor = polygon.min(by: { $0.y < $1.y }) ?? polygon[0]
                } else {
                    let rect = Self.mappedRect(
                        detection.boundingBox,
                        imageToViewTransform: imageToViewTransform,
                        targetSize: image.size
                    )
                    cg.setStrokeColor(color.cgColor)
                    cg.setLineWidth(max(2, image.size.width * 0.0025))
                    cg.stroke(rect)
                    labelAnchor = CGPoint(x: rect.minX, y: rect.minY)
                }

                let labelText = "\(detection.label) \(String(format: "%.2f", detection.confidence))"
                let fontSize = max(12, image.size.width * 0.018)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: fontSize),
                    .foregroundColor: UIColor.white,
                    .backgroundColor: color.withAlphaComponent(0.85)
                ]
                let labelOrigin = CGPoint(x: labelAnchor.x, y: max(0, labelAnchor.y - fontSize - 4))
                (labelText as NSString).draw(at: labelOrigin, withAttributes: attrs)
            }
        }
    }

    /// Same per-point mapping as `mappedRect`'s corners, for `RepairDetection.maskPolygon`.
    private static func mappedPolygon(
        _ polygon: [CGPoint]?,
        imageToViewTransform: CGAffineTransform,
        targetSize: CGSize
    ) -> [CGPoint]? {
        guard let polygon, polygon.count >= 3 else { return nil }
        return polygon.map { p in
            let viewNorm = p.applying(imageToViewTransform)
            return CGPoint(x: viewNorm.x * targetSize.width, y: viewNorm.y * targetSize.height)
        }
    }

    /// Same corner-mapping math as `RepairDetectionOverlay.mappedRect` — kept independent (not
    /// shared) since one draws with SwiftUI and the other with Core Graphics, and duplicating
    /// ~10 lines here is simpler than threading a shared helper across a SwiftUI view file and
    /// this plain-class file.
    private static func mappedRect(
        _ rectNormImgTopLeft: CGRect,
        imageToViewTransform: CGAffineTransform,
        targetSize: CGSize
    ) -> CGRect {
        let p1 = CGPoint(x: rectNormImgTopLeft.minX, y: rectNormImgTopLeft.minY).applying(imageToViewTransform)
        let p2 = CGPoint(x: rectNormImgTopLeft.maxX, y: rectNormImgTopLeft.minY).applying(imageToViewTransform)
        let p3 = CGPoint(x: rectNormImgTopLeft.minX, y: rectNormImgTopLeft.maxY).applying(imageToViewTransform)
        let p4 = CGPoint(x: rectNormImgTopLeft.maxX, y: rectNormImgTopLeft.maxY).applying(imageToViewTransform)

        let xs = [p1.x, p2.x, p3.x, p4.x]
        let ys = [p1.y, p2.y, p3.y, p4.y]

        let minX = (xs.min() ?? 0) * targetSize.width
        let maxX = (xs.max() ?? 0) * targetSize.width
        let minY = (ys.min() ?? 0) * targetSize.height
        let maxY = (ys.max() ?? 0) * targetSize.height

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Only ever called for Validation-mode captures (see call site in
    /// RepairARSessionView+Logic.swift) — same auto-color-per-class fallback as the live
    /// `RepairDetectionOverlay`, so a baked snapshot matches what the operator saw on screen.
    private static func resolvedColor(for label: String, classStyles: [String: RepairClassStyle]?) -> UIColor {
        if let hex = classStyles?[label]?.color, let color = UIColor(hex: hex) {
            return color
        }
        return RepairClassStyle.autoColor(for: label)
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
