//
//  RepairARSessionView+Logic.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Frame update, transform, raycast, and the auto-placement driver (05-ios-repair.md §5.7).
//  The `arView.bounds` + `frame.displayTransform(for:viewportSize:)` lines and the raycast
//  existingPlaneGeometry -> estimatedPlane fallback chain are copied from
//  LaserGuideARSessionView+Logic.swift / +Scoping.swift (READ-ONLY references) per the
//  §5.2 copy map — this is the hard-won safe-area-correct transform; it is not paraphrased.
//

import SwiftUI
import RealityKit
import ARKit
import UIKit
import Combine
import QuartzCore

extension RepairARSessionView {

    static func cgImageOrientation(for interfaceOrientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        // Back camera (not mirrored). Keeps Vision's orientation consistent with
        // ARFrame.displayTransform(for: interfaceOrientation, ...). Copied verbatim from
        // LaserGuideARSessionView (READ-ONLY reference).
        switch interfaceOrientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .up
        case .landscapeRight:
            return .down
        default:
            return .right
        }
    }

    // MARK: - Session lifecycle

    func startARSession() {
        captureSession.start()
        isSessionActive = true
    }

    func endARSession() {
        captureSession.stop()
        isSessionActive = false
    }

    @MainActor
    func loadModelForSession() async {
        isLoadingModel = true
        modelLoadError = nil
        do {
            let url = try await RepairModelDownloadService.shared.ensureModel(for: model)
            mlDetection.setModelURL(url, classLabels: model.classLabels)
            pipeline.start()
        } catch {
            modelLoadError = error.localizedDescription
        }
        isLoadingModel = false
    }

    // MARK: - Per-frame update

    /// Called from the `SceneEvents.Update` subscription set up in RepairARSessionView.
    func processFrameUpdate() {
        guard let arView, let frame = arView.session.currentFrame else { return }

        let interfaceOrientation = arView.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        pipeline.processPixelBuffer(
            frame.capturedImage,
            orientation: Self.cgImageOrientation(for: interfaceOrientation)
        )

        // Map normalized image coordinates -> normalized view coordinates.
        // Use arView.bounds, NOT viewportSize, because the ARView fills the entire screen
        // (including behind safe areas), while GeometryReader's size excludes safe-area
        // insets. A mismatch here causes raycast screen points to be offset. (Copied verbatim
        // from LaserGuideARSessionView+Logic.processFrameUpdate — READ-ONLY reference.)
        let arSize = arView.bounds.size
        if arSize.width > 0, arSize.height > 0 {
            imageToViewTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: arSize)
        }
    }

    // MARK: - Raycast (existingPlaneGeometry -> estimatedPlane fallback)

    /// Raycasts a normalized-image-space bbox's center to a real ARKit-world point.
    /// Copied (fallback chain + worldTransform.columns.3 extraction) from
    /// LaserGuideARSessionView+Scoping.raycastDetection (READ-ONLY reference) per §5.2.
    func raycastBBoxCenter(_ bbox: CGRect) -> SIMD3<Float>? {
        guard let arView else { return nil }
        let vp = viewportSize.width > 0 ? viewportSize : arView.bounds.size
        guard vp.width > 0, vp.height > 0 else { return nil }

        let centerNormImg = CGPoint(x: bbox.midX, y: bbox.midY)
        let centerNormView = centerNormImg.applying(imageToViewTransform)
        let centerPx = CGPoint(x: centerNormView.x * vp.width, y: centerNormView.y * vp.height)

        var hit: ARRaycastResult?
        if let h = arView.raycast(from: centerPx, allowing: .existingPlaneGeometry, alignment: .any).first {
            hit = h
        } else if let h = arView.raycast(from: centerPx, allowing: .estimatedPlane, alignment: .any).first {
            hit = h
        }

        guard let hit else { return nil } // raycast miss -> no pin (05 §5.6)

        let world = hit.worldTransform.columns.3
        let pos = SIMD3<Float>(world.x, world.y, world.z)
        guard !pos.x.isNaN, !pos.y.isNaN, !pos.z.isNaN else { return nil }
        return pos
    }

    // MARK: - Auto-placement driver

    /// Feeds raw per-frame detections into RepairAutoPlacer, renders any newly-confirmed
    /// pins, and buffers their CreatePin bodies for the next flush.
    func processDetections(_ rawDetections: [RepairDetection]) {
        let placed = autoPlacer.ingest(rawDetections, raycast: { [weak self] bbox in
            self?.raycastBBoxCenter(bbox)
        })
        guard !placed.isEmpty else { return }

        for pin in placed {
            pinRenderer.addPin(id: pin.id, at: pin.world)
            pendingPinsBuffer.append(
                CreatePin(
                    repairSessionId: session.id,
                    world: pin.world,
                    detectionClass: pin.detectionClass,
                    confidence: pin.confidence
                )
            )
        }
        placedPinCount = autoPlacer.placedPins.count
    }

    // MARK: - Bulk flush (preferred flush path — 02-contracts.md §2.2)

    func startFlushTimer() {
        stopFlushTimer()
        let interval = max(1.0, settings.repairBulkFlushIntervalSeconds)
        flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.flushPendingPins()
            }
        }
    }

    func stopFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    @MainActor
    func flushPendingPins() async {
        guard !pendingPinsBuffer.isEmpty else { return }
        let toFlush = pendingPinsBuffer
        pendingPinsBuffer.removeAll()
        do {
            _ = try await pinServiceObj.createPinsBulk(toFlush)
        } catch {
            // Put them back for the next attempt rather than dropping data silently.
            pendingPinsBuffer.append(contentsOf: toFlush)
            errorMessage = "Failed to sync pins: \(error.localizedDescription)"
        }
    }

    // MARK: - Tap-to-delete (nice-to-have, §5.7)

    func handleTap(at point: CGPoint) {
        guard let arView else { return }
        let hits = arView.entity(at: point)
        guard let hitEntity = hits else { return }
        guard let pinId = pinRenderer.pinId(containingEntity: hitEntity) else { return }

        pinRenderer.removePin(id: pinId)
        autoPlacer.removePlacedPin(id: pinId)
        placedPinCount = autoPlacer.placedPins.count

        Task {
            do {
                try await pinServiceObj.deletePin(pinId)
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to delete pin on server: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Close

    @MainActor
    func closeAndDismiss() async {
        guard !isClosing else { return }
        isClosing = true
        await flushPendingPins()
        do {
            _ = try await sessionService.close(id: session.id)
        } catch {
            errorMessage = "Failed to close session: \(error.localizedDescription)"
        }
        endARSession()
        isClosing = false
        dismiss()
    }
}
