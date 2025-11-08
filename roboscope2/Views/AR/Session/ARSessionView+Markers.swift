//
//  ARSessionView+Markers.swift
//  roboscope2
//
//  Marker helpers and coordinate transforms
//

import SwiftUI
import RealityKit

extension ARSessionView {
    // MARK: - Coordinate System Transformation
    /// Transform points from AR world coordinates to FrameOrigin coordinates
    func transformPointsToFrameOrigin(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        // Get inverse of frame origin transform to convert world coords to frame coords
        let inverseTransform = frameOriginTransform.inverse
        
        return points.map { point in
            // Convert point to SIMD4
            let worldPoint = SIMD4<Float>(point.x, point.y, point.z, 1.0)
            
            // Transform to FrameOrigin space
            let framePoint = inverseTransform * worldPoint
            
            return SIMD3<Float>(framePoint.x, framePoint.y, framePoint.z)
        }
    }
    
    /// Transform points from FrameOrigin coordinates to AR world coordinates
    func transformPointsFromFrameOrigin(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        return points.map { point in
            // Convert point to SIMD4
            let framePoint = SIMD4<Float>(point.x, point.y, point.z, 1.0)
            
            // Transform to world space
            let worldPoint = frameOriginTransform * framePoint
            
            return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
        }
    }
    
    /// Update all markers' visual positions when FrameOrigin changes
    func updateMarkersForNewFrameOrigin() {
        // Reload markers from backend and transform them to the new world coordinates
        Task {
            do {
                let persisted = try await markerApi.getMarkersForSession(session.id)
                
                // Transform markers from FrameOrigin coordinates to new AR world coordinates
                let transformedMarkers = persisted.map { marker -> Marker in
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
                
                // Reload markers with new positions
                await MainActor.run {
                    markerService.loadPersistedMarkers(transformedMarkers)
                }
            } catch {
                // Silent
            }
        }
    }

    // MARK: - Marker helpers (aligned with Scan view)
    func placeMarker() {
        guard let arView = arView else { return }
        let screenSize = arView.bounds.size
        let centerX = screenSize.width / 2
        let targetSize: CGFloat = 150
        let targetY: CGFloat = 200
        let half = targetSize / 2
        let corners = [
            CGPoint(x: centerX - half, y: targetY - half),
            CGPoint(x: centerX + half, y: targetY - half),
            CGPoint(x: centerX + half, y: targetY + half),
            CGPoint(x: centerX - half, y: targetY + half)
        ]
        markerService.placeMarker(targetCorners: corners)
    }
    
    // Persisted create: place marker in AR and save to backend
    func createAndPersistMarker() {
        guard let arView = arView else { return }
        let screenSize = arView.bounds.size
        let centerX = screenSize.width / 2
        let targetSize: CGFloat = 150
        let targetY: CGFloat = 200
        let half = targetSize / 2
        let corners = [
            CGPoint(x: centerX - half, y: targetY - half),
            CGPoint(x: centerX + half, y: targetY - half),
            CGPoint(x: centerX + half, y: targetY + half),
            CGPoint(x: centerX - half, y: targetY + half)
        ]
        if let spatial = markerService.placeMarkerReturningSpatial(targetCorners: corners) {
            // Transform marker points to FrameOrigin coordinate system
            let frameOriginPoints = transformPointsToFrameOrigin(spatial.nodes)
            
            // Save to backend with FrameOrigin coordinates
            Task {
                do {
                    let created = try await markerApi.createMarker(
                        CreateMarker(
                            workSessionId: session.id,
                            points: frameOriginPoints,
                            customProps: nil
                        )
                    )
                    markerService.linkSpatialMarker(localId: spatial.id, backendId: created.id)
                    
                    // Immediately refresh marker details for the newly created marker
                    Task {
                        await markerService.refreshMarkerDetails(backendId: created.id)
                    }
                } catch {
                    // Silent
                }
            }
        }
    }
    
    func getTargetRect() -> CGRect {
        guard let arView = arView else { return .zero }
        let screenSize = arView.bounds.size
        let centerX = screenSize.width / 2
        let targetSize: CGFloat = 150
        let targetY: CGFloat = 200
        let expanded = targetSize * 1.1
        return CGRect(x: centerX - expanded/2, y: targetY - expanded/2, width: expanded, height: expanded)
    }
    
    func checkMarkersInTarget() {
        let rect = getTargetRect()
        markerService.updateMarkersInTarget(targetRect: rect)
    }
    
    func selectMarkerInTarget() {
        let rect = getTargetRect()
        markerService.selectMarkerInTarget(targetRect: rect)
    }
    
    // Legacy single-finger move helpers replaced by ViewModel-driven movement
    
    func clearAllMarkersPersisted() {
        // Remove visually
        markerService.clearMarkers()
        // Remove persisted markers for this session
        Task {
            do {
                try await markerApi.deleteAllMarkersForSession(session.id)
            } catch {
                // Silent
            }
        }
    }
}
