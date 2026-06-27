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
            sessionContent(geometry: geometry)
        }
    }

    @ViewBuilder
    private func sessionContent(geometry: GeometryProxy) -> some View {
        ZStack {
                // AR View
                arViewLayer(geometry: geometry)

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
                topBarControls
                    .zIndex(5)

                // Hold-to-place origin button — always visible at bottom-right (hidden during manual mode)
                if manualPlacementState == .inactive {
                    VStack {
                        Spacer()
                        HStack(alignment: .center) {
                            // Instruction block at bottom-left when no origin placed yet
                            if !hasAutoScoped && !isPlacementButtonHeld {
                                instructionInfoBlock
                                    .padding(.leading, 20)
                                    .allowsHitTesting(false)
                            }
                            Spacer()
                            placementButton
                                .padding(.trailing, 30)
                        }
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
                // TIP badge (at Z-arrow tip of red cross)
                if let tipText = refTipBadgeText, let screenPt = refTipBadgeScreenPoint {
                    refZBadgeLabel(text: tipText, position: screenPt)
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
                        bottomControls
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
                            if !settings.usePerFrame3DPlacement, let measurement {
                                placeOriginImmediately(measurement)
                            }
                        },
                        onDotWorldDetected: { dotWorld in
                            // Cone placed immediately when the dot is raycasted, before line is found.
                            placeDotCone(at: dotWorld)
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

                // Space Info overlay
                if showSpaceInfo {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .zIndex(8)
                        .onTapGesture { showSpaceInfo = false }

                    spaceInfoContent
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
        .sheet(isPresented: $showMinimap) {
            MinimapView(
                spaceId: session.spaceId.uuidString,
                sessionId: session.id
            )
        }
        .navigationBarBackButtonHidden()
        .onChange(of: mlDetection.detections) { _, rawDetections in
            processDetections(rawDetections)
        }
    }

    // MARK: - Detection helpers

    /// Removes line detections that overlap any dot detection when `lineOverDotFilter` is enabled.
    func filterLineOverDot(_ detections: [LaserMLDetection]) -> [LaserMLDetection] {
        LaserMLDetectionService.filterLineOverDot(detections, enabled: settings.lineOverDotFilter)
    }

    // MARK: - Bottom controls

    @ViewBuilder
    private func arViewLayer(geometry: GeometryProxy) -> some View {
        ARViewContainer(
            session: captureSession.session,
            arView: $arView
        )
        .onAppear {
            print("[LaserGuideSnap] ARViewContainer appeared, starting session")
            startARSession()
            if let mlSaved = SpaceMLDetectionSettingsStore.shared.load(spaceId: session.spaceId) {
                applyMLDetectionSettings(mlSaved)
            }
            Task { await loadModelForSession() }
            Task { await fetchLaserGuideIfNeeded() }
            Task { await initCurrentRun() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                placeFrameOriginGizmo(at: frameOriginTransform)
                startAutoDropFrameOrigin()
            }
            viewModel.startTracking(getTargetRect: { getTargetRect() }, onManualSelectionUpdate: {
                if !(viewModel.isHoldingScreen && manualPlacementState != .inactive) {
                    updateManualPointSelection()
                }
            })
            Task { await loadPersistedMarkers() }
        }
        .onChange(of: mlDetection.confidenceThreshold) { _, _ in saveMLDetectionSettings() }
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
        .onChange(of: arView) { _, newValue in
            markerService.arView = newValue
            viewModel.bindARView(newValue)
            Task { @MainActor in markerService.setMarkersVisible(hasAutoScoped) }
            frameOriginAnchor?.isEnabled = hasAutoScoped
            debugDotAnchor?.isEnabled = hasAutoScoped
            debugLineAnchor?.isEnabled = hasAutoScoped
            if let arView = newValue {
                arView.scene.subscribe(to: SceneEvents.Update.self) { _ in
                    self.processFrameUpdate()
                }.store(in: &cancellables)
            }
        }
        .onAppear { self.viewportSize = geometry.size }
    }

    private func loadPersistedMarkers() async {
        do {
            let persisted = try await markerApi.getMarkersForSession(session.id)
            let transformedMarkers = persisted.map { marker -> Marker in
                let worldPoints = transformPointsFromFrameOrigin(marker.points)
                return Marker(
                    id: marker.id, workSessionId: marker.workSessionId,
                    label: marker.label,
                    p1: [Double(worldPoints[0].x), Double(worldPoints[0].y), Double(worldPoints[0].z)],
                    p2: [Double(worldPoints[1].x), Double(worldPoints[1].y), Double(worldPoints[1].z)],
                    p3: [Double(worldPoints[2].x), Double(worldPoints[2].y), Double(worldPoints[2].z)],
                    p4: [Double(worldPoints[3].x), Double(worldPoints[3].y), Double(worldPoints[3].z)],
                    calibratedData: marker.calibratedData, color: marker.color,
                    version: marker.version, meta: marker.meta, customProps: marker.customProps,
                    createdAt: marker.createdAt, updatedAt: marker.updatedAt, details: marker.details
                )
            }
            markerService.loadPersistedMarkers(transformedMarkers, originalFrameOriginMarkers: persisted)
            for marker in transformedMarkers where marker.details == nil {
                Task { await markerService.refreshMarkerDetails(backendId: marker.id) }
            }
        } catch { /* silent */ }
    }

    @ViewBuilder
    var topBarControls: some View {
        VStack {
            HStack(spacing: 12) {
                Spacer(minLength: 8)
                if hasAutoScoped { markerCountBadge }
                Spacer(minLength: 8)
                if let spaceName = associatedSpaceName {
                    Text(spaceName)
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Menu {
                    Button { showMinimap = true } label: {
                        Label("Minimap", systemImage: "map")
                    }
                    Button { showSpaceInfo = true } label: {
                        Label("Space Info", systemImage: "info.circle")
                    }
                    Divider()
                    if manualPlacementState == .inactive {
                        Button { enterManualTwoPointsMode() } label: {
                            Label("Manual Two Points", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                    } else {
                        Button(role: .destructive) { cancelManualTwoPointsMode() } label: {
                            Label("Cancel Manual Placement", systemImage: "xmark")
                        }
                    }
                    Button(role: .destructive) { dismiss() } label: {
                        Label("Close Session", systemImage: "xmark")
                    }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold)).frame(width: 66, height: 66)
                }
                .menuStyle(.button).buttonStyle(.plain).lgCircle(tint: .white)
            }
            .padding(.horizontal, 16).padding(.top, 56)
            Spacer()
        }
    }

    @ViewBuilder
    var markerCountBadge: some View {
        Menu {
            Button(role: .destructive) { clearAllMarkersPersisted() } label: {
                Label("Delete All Markers", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Text("\(markerService.markers.count)")
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.35), .white.opacity(0.1)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ), lineWidth: 1
                            )
                    )
            )
        }
    }

    @ViewBuilder
    var bottomControls: some View {
        if manualPlacementState == .inactive {
            HStack(spacing: 20) {
                if hasAutoScoped && !isPlacementButtonHeld {
                    if markerService.targetCrossesEdge {
                        edgeWarningLabel
                    } else {
                        markerPlaceButton
                    }
                }
            }
        } else {
            twoPointControls
        }
    }

    @ViewBuilder
    var edgeWarningLabel: some View {
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
    }

    @ViewBuilder
    var markerPlaceButton: some View {
        Button { createAndPersistMarker() } label: {
            Image(systemName: viewModel.isTwoFingers ? "hand.tap.fill" : (viewModel.isHoldingScreen ? "hand.point.up.fill" : "plus"))
                .font(.system(size: 36))
                .frame(width: 80, height: 80)
        }
        .buttonStyle(.plain)
        .lgCircle(tint: .white)
    }

    @ViewBuilder
    var twoPointControls: some View {
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
}
