//
//  SpatialMarkerService+Tracking.swift
//  roboscope2
//
//  Tracking and selection logic for spatial markers.
//

import UIKit
import ARKit
import RealityKit

extension SpatialMarkerService {
    /// Continuously check which markers intersect the target rect and select closest.
    func updateMarkersInTarget(targetRect: CGRect) {
        if movingMarkerIndex != nil { return }
        guard let arView = arView, let frame = arView.session.currentFrame else { return }
        guard !markers.isEmpty else { return }

        var newMarkersInTarget = Set<UUID>()
        var newMarkerEdgesInTarget: [UUID: Set<Int>] = [:]
        let expandedRect = targetRect.insetBy(dx: -10, dy: -10)
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let edgeNodePairs = [(0, 1), (1, 2), (2, 3), (3, 0)]

        func edgeMidpointScreen(_ i: Int, _ j: Int, _ screenPositions: [CGPoint?]) -> CGPoint? {
            if let p1 = screenPositions[i], let p2 = screenPositions[j] {
                return CGPoint(x: (p1.x + p2.x)/2, y: (p1.y + p2.y)/2)
            }
            return nil
        }
        func segmentIntersectsRect(p1: CGPoint, p2: CGPoint, rect: CGRect) -> Bool {
            if rect.contains(p1) || rect.contains(p2) { return true }
            let rMinX = rect.minX, rMaxX = rect.maxX, rMinY = rect.minY, rMaxY = rect.maxY
            let rTL = CGPoint(x: rMinX, y: rMinY)
            let rTR = CGPoint(x: rMaxX, y: rMinY)
            let rBR = CGPoint(x: rMaxX, y: rMaxY)
            let rBL = CGPoint(x: rMinX, y: rMaxY)
            func ccw(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
                return (c.y - a.y) * (b.x - a.x) > (b.y - a.y) * (c.x - a.x)
            }
            func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
                return ccw(a,c,d) != ccw(b,c,d) && ccw(a,b,c) != ccw(a,b,d)
            }
            if segmentsIntersect(p1, p2, rTL, rTR) { return true }
            if segmentsIntersect(p1, p2, rTR, rBR) { return true }
            if segmentsIntersect(p1, p2, rBR, rBL) { return true }
            if segmentsIntersect(p1, p2, rBL, rTL) { return true }
            return false
        }

        for (markerIndex, marker) in markers.enumerated() {
            var screenPositions: [CGPoint?] = []
            for nodePos in marker.nodes {
                let screenPos = projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
                screenPositions.append(screenPos)
            }
            var edgesInTarget = Set<Int>()
            for (edgeIndex, (n1, n2)) in edgeNodePairs.enumerated() {
                if let p1 = screenPositions[n1], let p2 = screenPositions[n2] {
                    if segmentIntersectsRect(p1: p1, p2: p2, rect: expandedRect) {
                        edgesInTarget.insert(edgeIndex)
                    }
                }
            }
            if !edgesInTarget.isEmpty {
                let wasInTarget = markersInTarget.contains(marker.id)
                newMarkersInTarget.insert(marker.id)
                newMarkerEdgesInTarget[marker.id] = edgesInTarget
                if !wasInTarget || markerEdgesInTarget[marker.id] != edgesInTarget {
                    updateMarkerColorWithEdges(index: markerIndex, isSelected: false, isInTarget: true, edgesInTarget: edgesInTarget)
                }
            } else {
                if markersInTarget.contains(marker.id) {
                    updateMarkerColorWithEdges(index: markerIndex, isSelected: false, isInTarget: false, edgesInTarget: [])
                }
            }
        }

        markersInTarget = newMarkersInTarget
        markerEdgesInTarget = newMarkerEdgesInTarget

        if newMarkersInTarget.isEmpty {
            selectedMarkerID = nil
            selectedEdgeIndex = nil
            for idx in markers.indices {
                updateMarkerColorWithEdges(index: idx, isSelected: false, isInTarget: false, edgesInTarget: [])
            }
            return
        }

        var selectedIndex: Int?
        if let selID = selectedMarkerID, let idx = markers.firstIndex(where: { $0.id == selID }), newMarkersInTarget.contains(selID) {
            selectedIndex = idx
        } else {
            var bestIdx: Int?
            var bestDist: CGFloat = .infinity
            for (i, m) in markers.enumerated() where newMarkersInTarget.contains(m.id) {
                let worldCenter = m.nodes.reduce(SIMD3<Float>.zero, +) / Float(m.nodes.count)
                if let sp = projectWorldToScreen(worldPosition: worldCenter, frame: frame, arView: arView) {
                    let d = hypot(sp.x - targetCenter.x, sp.y - targetCenter.y)
                    if d < bestDist { bestDist = d; bestIdx = i }
                }
            }
            selectedIndex = bestIdx
            if let si = selectedIndex { selectedMarkerID = markers[si].id }
        }

        if let si = selectedIndex {
            let m = markers[si]
            var screenPositions: [CGPoint?] = []
            for nodePos in m.nodes {
                let sp = projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
                screenPositions.append(sp)
            }
            let edges = markerEdgesInTarget[m.id] ?? []
            var choice: Int?
            var bestDist: CGFloat = .infinity
            if !edges.isEmpty {
                for e in edges {
                    let pair = edgeNodePairs[e]
                    if let mid = edgeMidpointScreen(pair.0, pair.1, screenPositions) {
                        let d = hypot(mid.x - targetCenter.x, mid.y - targetCenter.y)
                        if d < bestDist { bestDist = d; choice = e }
                    }
                }
            } else {
                for e in 0..<4 {
                    let pair = edgeNodePairs[e]
                    if let mid = edgeMidpointScreen(pair.0, pair.1, screenPositions) {
                        let d = hypot(mid.x - targetCenter.x, mid.y - targetCenter.y)
                        if d < bestDist { bestDist = d; choice = e }
                    }
                }
            }
            selectedEdgeIndex = choice
        } else {
            selectedEdgeIndex = nil
        }

        for i in markers.indices {
            let isSel = (selectedMarkerID == markers[i].id)
            let inTarget = newMarkersInTarget.contains(markers[i].id)
            let edges = markerEdgesInTarget[markers[i].id] ?? []
            updateMarkerColorWithEdges(index: i, isSelected: isSel, isInTarget: inTarget, edgesInTarget: edges)
        }
    }

    func selectMarkerInTarget(targetRect: CGRect) {
        if movingMarkerIndex != nil { return }
        guard let arView = arView else { return }
        let markersInTargetArray = markers.filter { markersInTarget.contains($0.id) }
        if markersInTargetArray.isEmpty {
            var didDeselect = false
            for index in markers.indices {
                if markers[index].isSelected {
                    markers[index].isSelected = false
                    let isInTarget = markersInTarget.contains(markers[index].id)
                    let edgesInTarget = markerEdgesInTarget[markers[index].id] ?? []
                    updateMarkerColorWithEdges(index: index, isSelected: false, isInTarget: isInTarget, edgesInTarget: edgesInTarget)
                    didDeselect = true
                }
            }
            if didDeselect {
                selectedMarkerID = nil
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            return
        }
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        var closestMarker: SpatialMarker?
        var closestDistance: CGFloat = .infinity
        guard let frame = arView.session.currentFrame else { return }
        for marker in markersInTargetArray {
            let markerCenter = marker.nodes.reduce(SIMD3<Float>.zero, +) / Float(marker.nodes.count)
            if let screenPos = projectWorldToScreen(worldPosition: markerCenter, frame: frame, arView: arView) {
                let distance = hypot(screenPos.x - targetCenter.x, screenPos.y - targetCenter.y)
                if distance < closestDistance {
                    closestDistance = distance
                    closestMarker = marker
                }
            }
        }
        if let markerToSelect = closestMarker, let index = markers.firstIndex(where: { $0.id == markerToSelect.id }) {
            for idx in markers.indices {
                markers[idx].isSelected = false
                let isInTarget = markersInTarget.contains(markers[idx].id)
                let edgesInTarget = markerEdgesInTarget[markers[idx].id] ?? []
                updateMarkerColorWithEdges(index: idx, isSelected: false, isInTarget: isInTarget, edgesInTarget: edgesInTarget)
            }
            markers[index].isSelected = true
            selectedMarkerID = markerToSelect.id
            updateMarkerColorWithEdges(index: index, isSelected: true, isInTarget: true, edgesInTarget: [])
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func updateMarkerColor(index: Int, isSelected: Bool, isInTarget: Bool = false) {
        updateMarkerColorWithEdges(index: index, isSelected: isSelected, isInTarget: isInTarget, edgesInTarget: [])
    }

    private func updateMarkerColorWithEdges(index: Int, isSelected: Bool, isInTarget: Bool, edgesInTarget: Set<Int>) {
        guard index < markers.count, markers[index].nodes.count == 4 else { return }
        let marker = markers[index]
        let anchorEntity = marker.anchorEntity

        // Radius: thicker when selected
        let nodeRadius: Float = isSelected ? 0.015 : 0.01
        let edgeRadius: Float = isSelected ? 0.0008 : 0.0005
        let nodeColor: UIColor = isSelected || isInTarget
            ? .white
            : UIColor(white: 0.5, alpha: 1.0)

        for nodeIndex in 0..<4 {
            if let nodeEntity = anchorEntity.children.first(where: { $0.name == "node_\(nodeIndex)" }) as? ModelEntity {
                nodeEntity.model?.mesh = .generateSphere(radius: nodeRadius)
                nodeEntity.model?.materials = [UnlitMaterial(color: nodeColor)]
            }
        }
        let edgeNodePairs = [(0, 1), (1, 2), (2, 3), (3, 0)]
        let selEdge = (isSelected && markers[index].id == selectedMarkerID) ? selectedEdgeIndex : nil
        for (edgeIndex, (i, j)) in edgeNodePairs.enumerated() {
            if let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity {
                let edgeColor: UIColor
                let thisEdgeRadius: Float
                if selEdge == edgeIndex {
                    edgeColor = .white
                    thisEdgeRadius = edgeRadius * 2.5  // selected edge — thickest
                } else if isSelected || isInTarget || edgesInTarget.contains(edgeIndex) {
                    edgeColor = UIColor(white: 0.85, alpha: 1.0)
                    thisEdgeRadius = edgeRadius
                } else {
                    edgeColor = UIColor(white: 0.6, alpha: 1.0)
                    thisEdgeRadius = edgeRadius
                }
                // Rebuild edge mesh with correct radius
                let start = marker.nodes[i]
                let end = marker.nodes[j]
                let mid = (start + end) / 2
                let dir = end - start
                let len = simd_length(dir)
                edgeEntity.model?.mesh = .generateCylinder(height: len, radius: thisEdgeRadius)
                edgeEntity.position = mid
                let up = normalize(dir)
                let yAxis = SIMD3<Float>(0, 1, 0)
                let crossVal = cross(yAxis, up)
                if simd_length(crossVal) > 0.0001 {
                    edgeEntity.orientation = simd_quatf(angle: acos(dot(yAxis, up)), axis: normalize(crossVal))
                }
                edgeEntity.model?.materials = [UnlitMaterial(color: edgeColor)]
            }
        }

        // Edge selection handlers
        let handlerNames = ["handler_a", "handler_b"]
        let existingHandlers = anchorEntity.children.filter { handlerNames.contains($0.name) }

        if let edgeIdx = selEdge {
            let (i, j) = edgeNodePairs[edgeIdx]
            let pA = marker.nodes[i]
            let pB = marker.nodes[j]
            let mid = (pA + pB) / 2
            let dir = normalize(pB - pA)

            var perp = SIMD3<Float>(dir.z, 0, -dir.x)
            if simd_length(perp) < 0.0001 { perp = SIMD3<Float>(1, 0, 0) }
            perp = normalize(perp)

            let handleLen: Float = 0.025
            let handleRadius: Float = 0.001
            let gap: Float = 0.008
            let handleMat = UnlitMaterial(color: .white)

            for side in [-1, 1] {
                let offset = perp * gap * Float(side)
                let handlePos = mid + offset
                let handle = ModelEntity(
                    mesh: .generateCylinder(height: handleLen, radius: handleRadius),
                    materials: [handleMat]
                )
                handle.position = handlePos
                let yAxis = SIMD3<Float>(0, 1, 0)
                let crossVal = cross(yAxis, dir)
                if simd_length(crossVal) > 0.0001 {
                    handle.orientation = simd_quatf(angle: acos(dot(yAxis, dir)), axis: normalize(crossVal))
                }
                handle.name = handlerNames[side > 0 ? 1 : 0]
                if let old = existingHandlers.first(where: { $0.name == handle.name }) {
                    anchorEntity.removeChild(old)
                }
                anchorEntity.addChild(handle)
            }
        } else {
            for h in existingHandlers { anchorEntity.removeChild(h) }
        }
    }
}
