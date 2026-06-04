//
//  LaserGuideARSessionView+Body.swift
//  roboscope2
//
//  View body for LaserGuideARSessionView.
//

import SwiftUI
import RealityKit
import ARKit
import UIKit
import SceneKit
import Combine
import QuartzCore

extension LaserGuideARSessionView {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // AR View
                ARViewContainer(
                    session: captureSession.session,
                    arView: $arView
                )
                .onAppear {
                    print("[LaserGuideSnap] ARViewContainer appeared, starting session")
                    startARSession()

                    // Restore ML detection tuning from last session.
                    if let mlSaved = SpaceMLDetectionSettingsStore.shared.load(spaceId: session.spaceId) {
                        applyMLDetectionSettings(mlSaved)
                    }

                    // Start the ML detection pipeline.
                    pipeline.start()

                    // Ensure the Space's ML model is downloaded and assign it.
                    Task {
                        await loadModelForSession()
                    }

                    Task {
                        print("[LaserGuideSnap] Launching fetchLaserGuideIfNeeded task")
                        await fetchLaserGuideIfNeeded()
                    }

                    // Place initial frame origin at AR session origin
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        placeFrameOriginGizmo(at: frameOriginTransform)
                        // Start auto-drop with retries so it lands as soon as a plane is available
                        startAutoDropFrameOrigin()
                    }

                    // Start tracking markers continuously via ViewModel
                    viewModel.startTracking(getTargetRect: { getTargetRect() }, onManualSelectionUpdate: {
                        // While holding to move a manual point, freeze selection to avoid drops
                        if !(viewModel.isHoldingScreen && manualPlacementState != .inactive) {
                            updateManualPointSelection()
                        }
                    })

                    // Load persisted markers for this session
                    Task {
                        do {
                            let persisted = try await markerApi.getMarkersForSession(session.id)
                            // Transform markers from FrameOrigin coordinates to AR world coordinates
                            let transformedMarkers = persisted.map { marker -> Marker in
                                // Create new marker with transformed points
                                let worldPoints = transformPointsFromFrameOrigin(marker.points)
                                return Marker(
                                    id: marker.id,
                                    workSessionId: marker.workSessionId,
                                    label: marker.label,
                                    p1: [Double(worldPoints[0].x), Double(worldPoints[0].y), Double(worldPoints[0].z)],
                                    p2: [Double(worldPoints[1].x), Double(worldPoints[1].y), Double(worldPoints[1].z)],
                                    p3: [Double(worldPoints[2].x), Double(worldPoints[2].y), Double(worldPoints[2].z)],
                                    p4: [Double(worldPoints[3].x), Double(worldPoints[3].y), Double(worldPoints[3].z)],
                                    calibratedData: marker.calibratedData,
                                    color: marker.color,
                                    version: marker.version,
                                    meta: marker.meta,
                                    customProps: marker.customProps,
                                    createdAt: marker.createdAt,
                                    updatedAt: marker.updatedAt,
                                    details: marker.details
                                )
                            }
                            // Pass both world and frame-origin coordinates
                            markerService.loadPersistedMarkers(transformedMarkers, originalFrameOriginMarkers: persisted)
                            // Calculate details for any markers that don't have them yet
                            for marker in transformedMarkers {
                                if marker.details == nil {
                                    Task {
                                        await markerService.refreshMarkerDetails(backendId: marker.id)
                                    }
                                }
                            }
                        } catch {
                            // Silent
                        }
                    }
                }
                .onChange(of: mlDetection.confidenceThreshold) { _, _ in
                    saveMLDetectionSettings()
                }
                .onDisappear {
                    pipeline.stop()
                    viewModel.cancelAllTimers()
                    autoDropTimer?.invalidate()
                    autoDropTimer = nil
                    autoDropAttempts = 0
                    endManualPointMove()
                    endARSession()
                    cancellables.removeAll()
                }
                .onChange(of: arView) { newValue in
                    markerService.arView = newValue
                    viewModel.bindARView(newValue)

                    // Keep marker visibility consistent with the current mode.
                    Task { @MainActor in
                        markerService.setMarkersVisible(hasAutoScoped)
                    }

                    // Hide origin + debug detections while locating.
                    frameOriginAnchor?.isEnabled = hasAutoScoped
                    debugDotAnchor?.isEnabled = hasAutoScoped
                    debugLineAnchor?.isEnabled = hasAutoScoped

                    // Set up frame callback for laser detection
                    if let arView = newValue {
                        arView.scene.subscribe(to: SceneEvents.Update.self) { _ in
                            if let frame = arView.session.currentFrame {
                                let interfaceOrientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait
                                // Route through the pipeline — works identically in Video Mode
                                // (replace frame.capturedImage with a CVPixelBuffer from video).
                                self.pipeline.processPixelBuffer(
                                    frame.capturedImage,
                                    orientation: Self.cgImageOrientation(for: interfaceOrientation)
                                )

                                // After auto-scope, monitor how far the user moves away from the scoped dot.
                                self.maybeReturnToDetectionIfUserMovedAway(frame)

                                // Keep Z-distance badges pinned to world positions as camera moves.
                                if self.hasAutoScoped {
                                    self.refreshBadgePositions()
                                }

                                // Map normalized image coordinates -> normalized view coordinates.
                                if self.viewportSize.width > 0 && self.viewportSize.height > 0 {
                                    self.imageToViewTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: self.viewportSize)
                                }

                                // Check if target crosses an object edge (throttled ~4x/sec)
                                if self.hasAutoScoped && self.manualPlacementState == .inactive {
                                    let now = CACurrentMediaTime()
                                    if now - self.lastEdgeCheckTime > 0.25 {
                                        self.lastEdgeCheckTime = now
                                        self.markerService.updateTargetEdgeState(targetCorners: self.getTargetRectCorners())
                                    }
                                }
                            }
                        }.store(in: &cancellables)
                    }
                }
                .onAppear {
                    // Initialize to the actual rendered size; UIScreen bounds can drift.
                    self.viewportSize = geometry.size
                }

                // Invisible two-finger overlay to detect two-finger contact immediately
                TwoFingerTouchOverlay(
                    onStart: {
                        if manualPlacementState != .inactive {
                            // Ignore two-finger in manual mode for now
                            return
                        }
                        viewModel.twoFingerStart(getTargetRect: { getTargetRect() })
                    },
                    onOneFingerStart: {
                        if manualPlacementState != .inactive {
                            // Begin moving selected manual point (if any)
                            if selectedManualPointIndex != nil {
                                viewModel.isHoldingScreen = true
                                startManualPointMove()
                            }
                            return
                        }
                        viewModel.oneFingerStart()
                    },
                    onOneFingerEnd: {
                        if manualPlacementState != .inactive {
                            // End moving manual point
                            viewModel.isHoldingScreen = false
                            endManualPointMove()
                            return
                        }
                        viewModel.oneFingerEnd(transformToFrameOrigin: { pts in transformPointsToFrameOrigin(pts) })
                    },
                    onChange: { translation, scale in
                        if manualPlacementState != .inactive { return }
                        viewModel.gestureChanged(translation: translation, scale: scale)
                    },
                    onEnd: {
                        if manualPlacementState != .inactive {
                            // Ignore two-finger end in manual mode
                        } else {
                            viewModel.twoFingerEnd(transformToFrameOrigin: { pts in transformPointsToFrameOrigin(pts) })
                        }
                    }
                )
                .allowsHitTesting(!showActionsDialog)
                .edgesIgnoringSafeArea(.all)

                // Target overlay — only in marker placement mode, red if crossing edge
                if hasAutoScoped {
                    TargetOverlayView(
                        style: manualPlacementState == .inactive ? .brackets : .cross,
                        color: markerService.targetCrossesEdge ? .red : .white
                    )
                        .padding(.top, 40)
                        .allowsHitTesting(false)
                        .zIndex(1)
                }

                // Top controls — simplified
                VStack {
                    HStack(spacing: 12) {
                        Spacer(minLength: 8)

                        // Marker count badge (only after origin placed) — tappable for delete all
                        if hasAutoScoped {
                            Menu {
                                Button(role: .destructive) {
                                    clearAllMarkersPersisted()
                                } label: {
                                    Label("Delete All Markers", systemImage: "trash")
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("\(markerService.markers.count)")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.ultraThinMaterial)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .strokeBorder(
                                                    LinearGradient(
                                                        colors: [.white.opacity(0.35), .white.opacity(0.1)],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    ),
                                                    lineWidth: 1
                                                )
                                        )
                                )
                            }
                        }

                        Spacer(minLength: 8)

                        if let spaceName = associatedSpaceName {
                            Text(spaceName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 8)

                        Menu {
                            Button(role: .destructive) {
                                dismiss()
                            } label: {
                                Label("Close Session", systemImage: "xmark")
                            }
                            Button {
                                enterDetectionMode()
                            } label: {
                                Label("Restart Placing", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: 66, height: 66)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .lgCircle(tint: .white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 56)
                    Spacer()
                }
                .zIndex(5)

                // Origin placement mode: full-width locating badge with Vision/Manual toggle
                if !hasAutoScoped {
                    VStack {
                        Spacer()
                        VStack(spacing: 10) {
                            // Status
                            HStack(spacing: 10) {
                                if originStabilityProgress > 0 {
                                    Circle()
                                        .trim(from: 0, to: originStabilityProgress)
                                        .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: 22, height: 22)
                                        .animation(.linear(duration: 0.1), value: originStabilityProgress)
                                }
                                Text(originStabilityProgress > 0 ? "Locking..." : "Locating Origin")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(originStabilityProgress > 0 ? .green : .white)
                            }

                            // Description and distance only in Vision mode
                            if manualPlacementState == .inactive {
                                Text("Point camera at the area you want to map.\nThe origin will lock automatically when detected.")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.white.opacity(0.75))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !locatingDistanceText.isEmpty {
                                    Text(locatingDistanceText)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.yellow)
                                }
                            }

                            // Vision / Manual toggle
                            HStack(spacing: 0) {
                                Button {
                                    if manualPlacementState != .inactive {
                                        cancelManualTwoPointsMode()
                                        enterDetectionMode()  // restart detection
                                    }
                                } label: {
                                    Text("Vision")
                                        .font(.system(size: 14, weight: manualPlacementState == .inactive ? .bold : .regular))
                                        .foregroundColor(manualPlacementState == .inactive ? .black : .white.opacity(0.7))
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity)
                                        .background(
                                            manualPlacementState == .inactive
                                                ? Color.white
                                                : Color.white.opacity(0.1)
                                        )
                                }
                                .buttonStyle(.plain)
                                Button {
                                    if manualPlacementState == .inactive { enterManualTwoPointsMode() }
                                } label: {
                                    Text("Manual")
                                        .font(.system(size: 14, weight: manualPlacementState != .inactive ? .bold : .regular))
                                        .foregroundColor(manualPlacementState != .inactive ? .black : .white.opacity(0.7))
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity)
                                        .background(
                                            manualPlacementState != .inactive
                                                ? Color.white
                                                : Color.white.opacity(0.1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(18)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [.white.opacity(0.3), .white.opacity(0.08)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 1
                                        )
                                )
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 50)
                    }
                    .zIndex(4)
                }

                // Removed detection settings / frame history panel

                if isRegistering {
                    registrationProgressOverlay
                        .zIndex(3)
                }
                // Measurement badge (screen-space)
                if let distText = measurementDistanceText, let screenPt = measurementBadgeScreenPoint {
                    measurementBadgeLabel(text: distText, position: screenPt)
                        .zIndex(5)
                }
                // Origin Z badge (green, at frame origin)
                if let zText = originZBadgeText, let screenPt = originZBadgeScreenPoint {
                    originZBadgeLabel(text: zText, position: screenPt)
                        .zIndex(5)
                }
                // Reference Z badge (red, at dot reference cross)
                if let zText = refZBadgeText, let screenPt = refZBadgeScreenPoint {
                    refZBadgeLabel(text: zText, position: screenPt)
                        .zIndex(5)
                }
                if isLoadingModel {
                    modelLoadingOverlay
                        .zIndex(3)
                }
                if isLoadingScan {
                    scanLoadingOverlay
                        .zIndex(3)
                }

                VStack {
                    Spacer()

                    if hasAutoScoped, let info = markerService.selectedMarkerInfo {
                        MarkerBadgeView(
                            info: info,
                            details: markerService.selectedMarkerDetails,
                            onDelete: {
                                if let backendId = markerService.selectedBackendId {
                                    Task {
                                        do {
                                            try await markerApi.deleteMarker(id: backendId)
                                            markerService.removeMarkerByBackendId(backendId)
                                        } catch {
                                            errorMessage = "Failed to delete marker: \(error.localizedDescription)"
                                        }
                                    }
                                } else {
                                    markerService.removeSelectedMarkerLocal()
                                }
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .transition(.opacity.combined(with: .scale))
                    }

                    HStack {
                        Spacer()
                        if manualPlacementState == .inactive {
                            HStack(spacing: 20) {
                                if hasAutoScoped {
                                    if markerService.targetCrossesEdge {
                                        // Edge detected — can't place marker here
                                        Text("Target crosses an edge.\nMove to a flat surface.")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.9))
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .fill(Color.red.opacity(0.4))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 14)
                                                            .stroke(Color.red.opacity(0.7), lineWidth: 1.5)
                                                    )
                                            )
                                    } else {
                                        // Add marker button (only after origin has auto-scoped)
                                        Button { createAndPersistMarker() } label: {
                                            Image(systemName: viewModel.isTwoFingers ? "hand.tap.fill" : (viewModel.isHoldingScreen ? "hand.point.up.fill" : "plus"))
                                                .font(.system(size: 36))
                                                .frame(width: 80, height: 80)
                                        }
                                        .buttonStyle(.plain)
                                        .lgCircle(tint: .white)
                                    }
                                }
                                // Old locating badge removed — now shown as full-width badge above
                            }
                        } else {
                            VStack(spacing: 10) {
                                Button {
                                    manualPlacementPrimaryAction()
                                } label: {
                                    Text(manualPlacementButtonTitle())
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(minWidth: 200, minHeight: 54)
                                }
                                .buttonStyle(.plain)
                                .lgCapsule(tint: .blue)

                                if manualFirstPoint != nil && manualSecondPoint != nil {
                                    Button(role: .destructive) {
                                        clearTwoPointPlacement()
                                    } label: {
                                        Text("Clear")
                                            .font(.system(size: 16, weight: .semibold))
                                            .frame(minWidth: 160, minHeight: 48)
                                    }
                                    .buttonStyle(.plain)
                                    .lgCapsule(tint: .red)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, manualPlacementState != .inactive ? 280 : 50)
                }
                .animation(.easeInOut(duration: 0.2), value: markerService.selectedMarkerID)

                if !hasAutoScoped && emptyDetectionFrames <= 2 * max(1, settings.videoModeAccumulatorFrames) {
                    LaserMLDetectionOverlay(
                        detections: filterLineOverDot(settings.showAccumulatedOverlay ? accumulatedDetections : mlDetection.detections),
                        viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                        imageToViewTransform: imageToViewTransform,
                        arView: arView,
                        maxDotLineYDeltaMeters: mlDetection.maxDotLineYDeltaMeters,
                        onDotLineMeasurement: { measurement in
                            latestLaserMeasurement = measurement
                            maybeAutoScope(measurement)
                        },
                        boxColor: settings.showAccumulatedOverlay ? .blue : .green
                    )
                    .onAppear { viewportSize = geometry.size }
                    .onChange(of: geometry.size) { _, newValue in viewportSize = newValue }
                    .zIndex(2)
                }

                // ML model loading / error HUD
                if isLoadingMLModel || mlModelLoadError != nil {
                    VStack(spacing: 12) {
                        if isLoadingMLModel {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                            Text("Loading ML model…")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        } else if let err = mlModelLoadError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.yellow)
                            Text(err)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 40)
                    .zIndex(6)
                }
            }
        }
        .ignoresSafeArea(.all)
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage = errorMessage { Text(errorMessage) }
        }
        .confirmationDialog("Actions", isPresented: $showActionsDialog, titleVisibility: .visible) {
            Button("Drop FrameOrigin", role: .none) {
                dropFrameOriginOnFloor()
            }

            if manualPlacementState == .inactive {
                Button("Manual Two Points") { enterManualTwoPointsMode() }
            } else {
                Button("Cancel Manual Placement", role: .destructive) { cancelManualTwoPointsMode() }
            }

            Button("Delete All Markers", role: .destructive) {
                clearAllMarkersPersisted()
            }
        }
        .sheet(isPresented: $showScanView) {
            SessionScanView(
                session: session,
                captureSession: captureSession,
                onRegistrationComplete: { transform in
                    frameOriginTransform = transform
                    updateMarkersForNewFrameOrigin()
                }
            )
        }
        .navigationBarBackButtonHidden()
        .onChange(of: mlDetection.detections) { _, rawDetections in
            // Apply "line over dot" filter before any calculations.
            let newDetections = filterLineOverDot(rawDetections)

            // --- Accumulator update ---
            let maxFrames = max(1, settings.videoModeAccumulatorFrames)
            var acc = frameAccumulator
            acc.append(newDetections)
            if acc.count > maxFrames { acc.removeFirst(acc.count - maxFrames) }
            frameAccumulator = acc
            let merged = laserDetectionMergeFrames(acc)
            // Track consecutive frames without a paired dot+line; clear stale boxes when exceeded.
            let mergedHasDot  = merged.contains { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
            let mergedHasLine = merged.contains { $0.classIndex == 1 || $0.label.lowercased().contains("line") }
            if mergedHasDot && mergedHasLine {
                emptyDetectionFrames = 0
                accumulatedDetections = merged
            } else {
                emptyDetectionFrames += 1
                if emptyDetectionFrames > 2 * maxFrames {
                    accumulatedDetections = []
                } else {
                    accumulatedDetections = merged
                }
            }

            // --- History record (only when this frame has detections) ---
            guard !newDetections.isEmpty else { return }
            let dotDetections  = newDetections.filter { $0.label == "dot"  || $0.classIndex == 0 }
            let lineDetections = newDetections.filter { $0.label == "line" || $0.classIndex == 1 }
            let bestDot  = dotDetections.max(by: { $0.confidence < $1.confidence })
            let bestLine = lineDetections.max(by: { $0.confidence < $1.confidence })
            let t = imageToViewTransform
            let vp = viewportSize.width > 0 ? viewportSize : CGSize(width: 390, height: 844)
            let lineToDotRatio: Float? = {
                guard let d = bestDot, let l = bestLine else { return nil }
                let dotLong  = laserDetectionLongestSidePixels(d.boundingBox, transform: t, viewport: vp)
                let lineLong = laserDetectionLongestSidePixels(l.boundingBox, transform: t, viewport: vp)
                guard dotLong > 0 else { return nil }
                return lineLong / dotLong
            }()
            let mergedDots  = merged.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }.count
            let mergedLines = merged.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") }.count
            let accumulatedRatio: Float? = {
                let mLine = merged.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") }
                    .max(by: { $0.confidence < $1.confidence })
                let mDot  = merged.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
                    .max(by: { $0.confidence < $1.confidence })
                let dot = bestDot ?? mDot
                guard let d = dot, let l = mLine else { return nil }
                let dotLong  = laserDetectionLongestSidePixels(d.boundingBox, transform: t, viewport: vp)
                let lineLong = laserDetectionLongestSidePixels(l.boundingBox, transform: t, viewport: vp)
                guard dotLong > 0 else { return nil }
                return lineLong / dotLong
            }()
            let record = DetectionFrameRecord(
                timestamp: Date(),
                dots: dotDetections.count,
                lines: lineDetections.count,
                otherCount: newDetections.filter { ($0.classIndex ?? -1) > 1 }.count,
                distanceMeters: latestLaserMeasurement?.distanceMeters,
                lineToDotSizeRatio: lineToDotRatio,
                accumulatedDots: mergedDots,
                accumulatedLines: mergedLines,
                accumulatorFramesUsed: acc.filter { !$0.isEmpty }.count,
                accumulatedLineToDotRatio: accumulatedRatio
            )
            detectionHistory.append(record)
            if detectionHistory.count > 50 { detectionHistory.removeFirst(detectionHistory.count - 50) }
        }
    }

    // MARK: - Detection helpers

    /// Removes line detections that overlap any dot detection when `lineOverDotFilter` is enabled.
    func filterLineOverDot(_ detections: [LaserMLDetection]) -> [LaserMLDetection] {
        guard settings.lineOverDotFilter else { return detections }
        let dots = detections.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
        guard !dots.isEmpty else { return detections }
        return detections.filter { det in
            let isLine = det.classIndex == 1 || det.label.lowercased().contains("line")
            guard isLine else { return true }
            return !dots.contains { dot in det.boundingBox.intersects(dot.boundingBox) }
        }
    }
}
