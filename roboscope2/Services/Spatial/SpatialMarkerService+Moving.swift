//
//  SpatialMarkerService+Moving.swift
//  roboscope2
//
//  Whole-marker and edge moving helpers.
//

import Foundation
import ARKit
import RealityKit

extension SpatialMarkerService {
    /// Start moving the currently selected marker
    func startMovingSelectedMarker() -> Bool {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let selectedID = selectedMarkerID,
              let markerIndex = markers.firstIndex(where: { $0.id == selectedID }) else {
            print("Cannot start moving: no selected marker or no AR frame. SelectedID: \(selectedMarkerID?.uuidString ?? "nil")")
            return false
        }
        let marker = markers[markerIndex]
        nodeScreenPositions = marker.nodes.compactMap { nodePos in
            projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
        }
        if nodeScreenPositions.count == 4 {
            updateCounter = 0
            movingMarkerIndex = markerIndex
            return true
        } else {
            return false
        }
    }

    /// Check if any marker is near the target and prepare to move it
    func startMovingMarkerInTarget(targetCorners: [CGPoint]) -> Bool {
        guard let arView = arView,
              let frame = arView.session.currentFrame else {
            return false
        }
        let targetCenter = CGPoint(
            x: (targetCorners[0].x + targetCorners[2].x) / 2,
            y: (targetCorners[0].y + targetCorners[2].y) / 2
        )
        for (index, marker) in markers.enumerated() {
            let markerCenter = marker.nodes.reduce(SIMD3<Float>.zero, +) / Float(marker.nodes.count)
            if let screenPos = projectWorldToScreen(worldPosition: markerCenter, frame: frame, arView: arView) {
                let distance = hypot(screenPos.x - targetCenter.x, screenPos.y - targetCenter.y)
                if distance < 75 {
                    movingMarkerIndex = index
                    nodeScreenPositions = marker.nodes.compactMap { nodePos in
                        projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
                    }
                    if nodeScreenPositions.count == 4 {
                        print("Started moving marker \(index)")
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Update the moving marker by raycasting stored screen points
    func updateMovingMarker() {
        guard let arView = arView,
              let markerIndex = movingMarkerIndex,
              markerIndex < markers.count,
              nodeScreenPositions.count == 4 else {
            return
        }
        var newNodePositions: [SIMD3<Float>] = []
        for screenPos in nodeScreenPositions {
            let results = arView.raycast(from: screenPos, allowing: .estimatedPlane, alignment: .any)
            if let firstResult = results.first {
                let worldPosition = SIMD3<Float>(
                    firstResult.worldTransform.columns.3.x,
                    firstResult.worldTransform.columns.3.y,
                    firstResult.worldTransform.columns.3.z
                )
                newNodePositions.append(worldPosition)
            } else {
                return
            }
        }
        guard newNodePositions.count == 4 else { return }
        applyNodePositions(markerIndex: markerIndex, newNodePositions: newNodePositions)
    }

    /// Stop moving the marker and return data for persistence
    func stopMovingMarker() -> (UUID, Int64, [SIMD3<Float>])? {
        defer {
            movingMarkerIndex = nil
            nodeScreenPositions.removeAll()
            originalNodeScreenPositions.removeAll()
            lastWorldNodePositions.removeAll()
            movingEdgeIndices = nil
            updateCounter = 0
        }
        guard let idx = movingMarkerIndex, idx < markers.count else { return nil }
        let marker = markers[idx]
        guard let backendId = marker.backendId else { return nil }
        markers[idx].version += 1
        return (backendId, marker.version, marker.nodes)
    }
}
