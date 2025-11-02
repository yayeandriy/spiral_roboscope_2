//
//  ARSessionViewModel.swift
//  roboscope2
//
//  Extracted orchestration for ARSessionView: timers, gesture side-effects, and persistence.
//

import Foundation
import SwiftUI
import Combine
import ARKit
import RealityKit

final class ARSessionViewModel: ObservableObject {
    // Inputs
    let sessionId: UUID
    let markerService: SpatialMarkerService
    let markerApi: MarkerAPI

    // AR binding
    weak var arView: ARView? {
        didSet { markerService.arView = arView }
    }

    // Gesture state
    @Published var isHoldingScreen = false
    @Published var isTwoFingers = false
    @Published var currentDrag: CGSize = .zero
    @Published var currentScale: CGFloat = 1.0

    // Timers
    private var moveUpdateTimer: Timer?
    private var markerTrackingTimer: Timer?

    init(sessionId: UUID, markerService: SpatialMarkerService, markerApi: MarkerAPI) {
        self.sessionId = sessionId
        self.markerService = markerService
        self.markerApi = markerApi
    }

    // MARK: - AR session bridging
    func bindARView(_ view: ARView?) {
        self.arView = view
    }

    // MARK: - Marker tracking
    func startTracking(getTargetRect: @escaping () -> CGRect, onManualSelectionUpdate: (() -> Void)? = nil) {
        stopTracking()
        let tracking = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let rect = getTargetRect()
            self.markerService.updateMarkersInTarget(targetRect: rect)
            if !self.isHoldingScreen {
                onManualSelectionUpdate?()
            }
        }
        RunLoop.main.add(tracking, forMode: .common)
        markerTrackingTimer = tracking
    }

    func stopTracking() {
        markerTrackingTimer?.invalidate()
        markerTrackingTimer = nil
    }

    // MARK: - Gesture handling (two-finger whole-marker transform)
    func twoFingerStart(getTargetRect: @escaping () -> CGRect) {
        // Ignore if already active
        guard !isTwoFingers else { return }
        isTwoFingers = true
        isHoldingScreen = true
        // Cancel any active one-finger edge move
        if moveUpdateTimer != nil {
            _ = markerService.endMoveSelectedEdge()
            moveUpdateTimer?.invalidate()
            moveUpdateTimer = nil
        }
        guard markerService.selectedMarkerID != nil else { return }
        let rect = getTargetRect()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if markerService.startTransformSelectedMarker(referenceCenter: center) {
            let timer = Timer(timeInterval: 0.033, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.markerService.updateTransform(dragTranslation: self.currentDrag, pinchScale: self.currentScale)
            }
            RunLoop.main.add(timer, forMode: .common)
            moveUpdateTimer = timer
        }
    }

    func twoFingerEnd(transformToFrameOrigin: @escaping ([SIMD3<Float>]) -> [SIMD3<Float>]) {
        guard isTwoFingers else { return }
        isTwoFingers = false
        isHoldingScreen = false
        if let (backendId, version, updatedNodes) = markerService.endTransform() {
            let frameOriginPoints = transformToFrameOrigin(updatedNodes)
            Task { [sessionId, markerApi] in
                do {
                    _ = try await markerApi.updateMarkerPosition(
                        id: backendId,
                        workSessionId: sessionId,
                        points: frameOriginPoints,
                        version: version,
                        customProps: nil
                    )
                    await markerService.updateDetailsAfterTransform(backendId: backendId)
                } catch {
                    // Silently ignore for now
                }
            }
        }
        moveUpdateTimer?.invalidate()
        moveUpdateTimer = nil
        currentScale = 1.0
        currentDrag = .zero
    }

    // MARK: - Gesture handling (one-finger edge move)
    func oneFingerStart(startManualPointMoveIfNeeded: (() -> Void)? = nil) {
        // If provided, caller may start manual point move instead
        if let startManualPointMoveIfNeeded {
            startManualPointMoveIfNeeded()
        }
        // Skip if two-finger is active or already moving
        if isTwoFingers || moveUpdateTimer != nil { return }
        isHoldingScreen = true
        if markerService.startMoveSelectedEdge() {
            let timer = Timer(timeInterval: 0.033, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.markerService.updateMoveSelectedEdge(withDrag: self.currentDrag)
            }
            RunLoop.main.add(timer, forMode: .common)
            moveUpdateTimer = timer
        }
    }

    func oneFingerEnd(transformToFrameOrigin: @escaping ([SIMD3<Float>]) -> [SIMD3<Float>]) {
        guard !isTwoFingers else { return }
        isHoldingScreen = false
        if let (backendId, version, updatedNodes) = markerService.endMoveSelectedEdge() {
            let frameOriginPoints = transformToFrameOrigin(updatedNodes)
            Task { [sessionId, markerApi] in
                do {
                    _ = try await markerApi.updateMarkerPosition(
                        id: backendId,
                        workSessionId: sessionId,
                        points: frameOriginPoints,
                        version: version,
                        customProps: nil
                    )
                    await markerService.updateDetailsAfterTransform(backendId: backendId)
                } catch {
                    // Silently ignore for now
                }
            }
        }
        moveUpdateTimer?.invalidate()
        moveUpdateTimer = nil
        currentDrag = .zero
        currentScale = 1.0
    }

    // MARK: - Gesture streaming
    func gestureChanged(translation: CGSize, scale: CGFloat) {
        currentDrag = translation
        currentScale = scale
    }

    // MARK: - Cleanup
    func cancelAllTimers() {
        stopTracking()
        moveUpdateTimer?.invalidate()
        moveUpdateTimer = nil
    }
}
