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

/// A manual session-photo capture still waiting to reach `POST /repair-sessions/{id}/photos`,
/// pointing at the already-saved-to-disk local files (see RepairPhotoStore) rather than holding
/// the image data itself.
struct PendingSessionPhotoUpload {
    let rawURL: URL
    let annotatedURL: URL?
    let capturedAt: Date
    var attempts: Int = 0
}

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

    /// Picks the highest-resolution camera format ARKit exposes on this device — ideally an
    /// exact 4K (3840x2160) format, for `captureSessionPhoto()`'s "always 4K" raw capture.
    /// Not every device exposes a true 4K ARKit format, so this falls back to whatever the
    /// highest-resolution option actually available is.
    static func preferredHighResVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        guard !formats.isEmpty else { return nil }
        if let uhd = formats.first(where: { $0.imageResolution.width == 3840 && $0.imageResolution.height == 2160 }) {
            return uhd
        }
        return formats.max { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }
    }

    func startARSession() {
        captureSession.start()

        // Upgrade the camera feed to the highest-resolution (ideally 4K) format available on
        // this device, so manual "take picture" captures and per-pin confirmation snapshots use
        // a full-resolution frame rather than ARKit's lower-res tracking default. Composed on
        // top of CaptureSession's own `.start()` (without editing that shared, reused-as-is
        // file) by re-running its ARSession with an upgraded configuration — the same pattern
        // CaptureSession.restart() itself uses to reconfigure a running session.
        if let videoFormat = Self.preferredHighResVideoFormat() {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical]
            config.worldAlignment = .gravity
            config.videoFormat = videoFormat
            captureSession.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }

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
            let url = try await RepairModelDownloadService.shared.ensureModel(for: activeModel)
            mlDetection.setModelURL(url, classLabels: activeModel.classLabels)
            pipeline.start()
        } catch {
            modelLoadError = error.localizedDescription
        }
        isLoadingModel = false
    }

    /// Swaps the live detector model mid-session (from RepairSessionSettingsView). Downloads/
    /// installs the new model if not already cached, reloads the Vision request, and resets
    /// only the in-flight tracking candidates — already-placed pins (and the 3D dedup set that
    /// protects them) are left untouched.
    @MainActor
    func swapActiveModel(to newModel: CoremlModel) async {
        guard newModel.id != activeModel.id else { return }
        isSwappingModel = true
        modelLoadError = nil
        do {
            let url = try await RepairModelDownloadService.shared.ensureModel(for: newModel)
            mlDetection.setModelURL(url, classLabels: newModel.classLabels)
            autoPlacer.resetCandidatesOnly()
            maturingCandidates = []
            activeModel = newModel
        } catch {
            errorMessage = "Failed to switch detector model: \(error.localizedDescription)"
        }
        isSwappingModel = false
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
        // `RepairARSessionView` is a struct, not a class — there's no retain-cycle risk here,
        // so this captures a plain (non-weak) copy, matching the existing Timer-closure
        // convention in LaserGuideARSessionView+ManualTwoPoints.swift (READ-ONLY reference).
        // `[weak self]` is a compile error on struct `self` ("weak" requires a class type).
        let placed = autoPlacer.ingest(rawDetections, raycast: { bbox in
            raycastBBoxCenter(bbox)
        })

        // Drives the always-visible "maturing" progress ring — updated every frame regardless
        // of whether a pin was placed this frame. Animated so rings fade in/out ("dissolve")
        // instead of abruptly popping when a candidate appears, decays, or matures into a pin.
        withAnimation(.easeOut(duration: 0.25)) {
            maturingCandidates = autoPlacer.maturingCandidates
        }

        guard !placed.isEmpty else { return }

        // Capture the current camera frame once for this batch of newly-confirmed pins, so a
        // photo of "what was actually there" travels with each pin record. Fire-and-forget /
        // best-effort — see RepairPhotoStore for where these land until a server destination
        // for pin images is decided.
        if let arView, let frame = arView.session.currentFrame {
            let interfaceOrientation = arView.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            let orientation = Self.cgImageOrientation(for: interfaceOrientation)
            if let snapshot = RepairPhotoStore.shared.image(from: frame.capturedImage, orientation: orientation) {
                for pin in placed {
                    RepairPhotoStore.shared.savePinSnapshotAsync(sessionId: session.id, pinId: pin.id, image: snapshot)
                }
            }
        }

        for pin in placed {
            pinRenderer.addPin(id: pin.id, at: pin.world)
            let body = CreatePin(
                repairSessionId: session.id,
                world: pin.world,
                detectionClass: pin.detectionClass,
                confidence: pin.confidence
            )
            pendingPinsBuffer.append((localId: pin.id, pin: body))
        }
        placedPinCount = autoPlacer.placedPins.count
    }

    // MARK: - Bulk flush (preferred flush path — 02-contracts.md §2.2)

    func startFlushTimer() {
        stopFlushTimer()
        let interval = max(1.0, settings.repairBulkFlushIntervalSeconds)
        // No `[weak self]` — `RepairARSessionView` is a struct, so `weak` doesn't apply (it's a
        // compile error on a non-class type). Matches the plain-capture Timer pattern already
        // used in LaserGuideARSessionView+ManualTwoPoints.swift (READ-ONLY reference).
        flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                await flushPendingPins()
                // Ordered after flushPendingPins: a pin's server id (needed for the photo
                // endpoint) is only known once its bulk-create flush above has succeeded.
                await flushPendingPinPhotoUploads()
                await flushPendingSessionPhotoUploads()
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
            let created = try await pinServiceObj.createPinsBulk(toFlush.map { $0.pin })
            // POST /pins/bulk returns created rows in submission order — correlate positionally
            // to learn each pin's server-assigned id (needed later for delete).
            for (index, serverPin) in created.enumerated() where index < toFlush.count {
                serverIdByLocalId[toFlush[index].localId] = serverPin.id
                pinsAwaitingPhotoUpload[serverPin.id] = toFlush[index].localId
            }
        } catch {
            // Put them back for the next attempt rather than dropping data silently.
            pendingPinsBuffer.append(contentsOf: toFlush)
            errorMessage = "Failed to sync pins: \(error.localizedDescription)"
        }
    }

    /// Uploads each newly-confirmed pin's locally-cached snapshot (captured at placement time in
    /// `processDetections`) to `POST /pins/{id}/photo`, now that the server id is known. Best-
    /// effort and silent on failure — a missing pin photo never blocks anything else, and the
    /// original frame stays safe on disk (RepairPhotoStore) regardless of upload outcome.
    @MainActor
    func flushPendingPinPhotoUploads() async {
        guard !pinsAwaitingPhotoUpload.isEmpty else { return }
        for (serverId, localId) in pinsAwaitingPhotoUpload {
            guard let url = RepairPhotoStore.shared.pinSnapshotURL(sessionId: session.id, pinId: localId) else {
                // Snapshot write (fire-and-forget, off-thread) may not have landed yet — retry a
                // few more ticks before giving up if it truly never appears.
                pinPhotoUploadAttempts[serverId, default: 0] += 1
                if pinPhotoUploadAttempts[serverId, default: 0] > 10 {
                    pinsAwaitingPhotoUpload.removeValue(forKey: serverId)
                    pinPhotoUploadAttempts.removeValue(forKey: serverId)
                }
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                pinsAwaitingPhotoUpload.removeValue(forKey: serverId)
                pinPhotoUploadAttempts.removeValue(forKey: serverId)
                continue
            }
            do {
                _ = try await pinServiceObj.uploadPinPhoto(pinId: serverId, jpegData: data)
                pinsAwaitingPhotoUpload.removeValue(forKey: serverId)
                pinPhotoUploadAttempts.removeValue(forKey: serverId)
            } catch {
                pinPhotoUploadAttempts[serverId, default: 0] += 1
                if pinPhotoUploadAttempts[serverId, default: 0] > 5 {
                    pinsAwaitingPhotoUpload.removeValue(forKey: serverId)
                    pinPhotoUploadAttempts.removeValue(forKey: serverId)
                }
            }
        }
    }

    /// Uploads any manual session-photo captures still pending (immediate upload attempts in
    /// `captureSessionPhoto` failed, or the app was briefly offline). Silent on failure, same
    /// reasoning as pin photos — the frames are already safe on disk either way.
    @MainActor
    func flushPendingSessionPhotoUploads() async {
        guard !pendingSessionPhotoUploads.isEmpty else { return }
        var stillPending: [PendingSessionPhotoUpload] = []
        for var upload in pendingSessionPhotoUploads {
            guard let rawData = try? Data(contentsOf: upload.rawURL) else { continue } // file gone — drop silently
            let annotatedData = upload.annotatedURL.flatMap { try? Data(contentsOf: $0) }
            do {
                _ = try await RepairSessionPhotoService.shared.upload(
                    sessionId: session.id, raw: rawData, annotated: annotatedData, capturedAt: upload.capturedAt
                )
            } catch {
                upload.attempts += 1
                if upload.attempts <= 8 {
                    stillPending.append(upload)
                }
            }
        }
        pendingSessionPhotoUploads = stillPending
    }

    // MARK: - Tap-to-select-then-delete (§5.7)
    //
    // Tapping a pin no longer deletes it immediately (too easy to trigger by accident while
    // walking around with the phone). First tap highlights the pin and shows a confirm bar;
    // a second tap on the SAME pin, or tapping empty space, deselects it without deleting.

    func handleTap(at point: CGPoint) {
        guard let arView else { return }

        guard let hitEntity = arView.entity(at: point),
              let pinId = pinRenderer.pinId(containingEntity: hitEntity) else {
            // Tapped empty space — deselect whatever was selected, if anything.
            if selectedPinId != nil { deselectPin() }
            return
        }

        if selectedPinId == pinId {
            deselectPin()
        } else {
            selectPin(pinId)
        }
    }

    func selectPin(_ pinId: UUID) {
        if let previous = selectedPinId, previous != pinId {
            pinRenderer.setSelected(id: previous, selected: false)
        }
        selectedPinId = pinId
        pinRenderer.setSelected(id: pinId, selected: true)
    }

    func deselectPin() {
        guard let pinId = selectedPinId else { return }
        pinRenderer.setSelected(id: pinId, selected: false)
        selectedPinId = nil
    }

    func confirmDeleteSelectedPin() {
        guard let pinId = selectedPinId else { return }
        selectedPinId = nil

        pinRenderer.removePin(id: pinId)
        autoPlacer.removePlacedPin(id: pinId)
        placedPinCount = autoPlacer.placedPins.count

        // Not flushed to the server yet — nothing to delete remotely, just drop it locally.
        pendingPinsBuffer.removeAll { $0.localId == pinId }

        guard let serverId = serverIdByLocalId.removeValue(forKey: pinId) else { return }
        pinsAwaitingPhotoUpload.removeValue(forKey: serverId)
        pinPhotoUploadAttempts.removeValue(forKey: serverId)
        Task {
            do {
                try await pinServiceObj.deletePin(serverId)
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to delete pin on server: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Clear scene

    /// Removes every pin in this session — rendered entities, local placement/dedup state, and
    /// (best-effort) their server-side records. Triggered from the settings sheet with its own
    /// confirmation alert, so no confirmation is repeated here.
    @MainActor
    func clearScene() async {
        // Snapshot before mutating so a slow network call can't race a second tap.
        let serverIdsToDelete = Array(serverIdByLocalId.values)

        pinRenderer.removeAll()
        autoPlacer.reset()
        pendingPinsBuffer.removeAll()
        serverIdByLocalId.removeAll()
        pinsAwaitingPhotoUpload.removeAll()
        pinPhotoUploadAttempts.removeAll()
        selectedPinId = nil
        placedPinCount = 0
        withAnimation(.easeOut(duration: 0.25)) {
            maturingCandidates = []
        }

        guard !serverIdsToDelete.isEmpty else { return }
        var deleteFailures = 0
        for id in serverIdsToDelete {
            do {
                try await pinServiceObj.deletePin(id)
            } catch {
                deleteFailures += 1
            }
        }
        if deleteFailures > 0 {
            errorMessage = "Cleared locally, but \(deleteFailures) pin(s) may not have been deleted from the server."
        }
    }

    // MARK: - Manual photo capture (session-level "take picture" button)

    /// Saves two images: the raw camera frame at (ideally) 4K — see `preferredHighResVideoFormat`
    /// — and a second image with the current pins baked in. The latter uses RealityKit's own
    /// live-rendered composite (`ARView.snapshotAsync`), which already includes the pin spheres
    /// as real scene entities, rather than re-projecting each pin's 3D position by hand; the
    /// trade-off is that this second image is captured at screen resolution, not the raw
    /// buffer's forced-4K resolution.
    @MainActor
    func captureSessionPhoto() async {
        guard !isCapturingPhoto, let arView, let frame = arView.session.currentFrame else { return }
        isCapturingPhoto = true
        defer { isCapturingPhoto = false }

        let interfaceOrientation = arView.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        let orientation = Self.cgImageOrientation(for: interfaceOrientation)

        guard let rawImage = RepairPhotoStore.shared.image(from: frame.capturedImage, orientation: orientation) else {
            errorMessage = "Failed to capture photo."
            return
        }

        let capturedAt = Date()
        let bakedImage = await arView.snapshotAsync(saveToHDR: false)

        do {
            // Save to local disk FIRST — this is the durable copy; the upload below is
            // best-effort and retried by flushPendingSessionPhotoUploads if it fails here.
            let saved = try await RepairPhotoStore.shared.saveManualCapture(sessionId: session.id, raw: rawImage, baked: bakedImage)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeOut(duration: 0.12)) { photoFlash = true }
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeOut(duration: 0.3)) { photoFlash = false }

            pendingSessionPhotoUploads.append(
                PendingSessionPhotoUpload(rawURL: saved.raw, annotatedURL: saved.baked, capturedAt: capturedAt)
            )
            // Try right away so the common case (network is fine) uploads immediately rather
            // than waiting for the next periodic flush tick.
            await flushPendingSessionPhotoUploads()
        } catch {
            errorMessage = "Failed to save photo: \(error.localizedDescription)"
        }
    }

    // MARK: - Close

    @MainActor
    func closeAndDismiss() async {
        guard !isClosing else { return }
        isClosing = true
        await flushPendingPins()
        await flushPendingPinPhotoUploads()
        await flushPendingSessionPhotoUploads()
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
