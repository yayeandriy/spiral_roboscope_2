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
        guard index < markers.count else { return }
        let marker = markers[index]
        let anchorEntity = marker.anchorEntity
        let nodeColor: UIColor = (isSelected || isInTarget) ? .systemBlue : .black
        for nodeIndex in 0..<4 {
            if let nodeEntity = anchorEntity.children.first(where: { $0.name == "node_\(nodeIndex)" }) as? ModelEntity {
                nodeEntity.model?.materials = [UnlitMaterial(color: nodeColor)]
            }
        }
        let edgeNodePairs = [(0, 1), (1, 2), (2, 3), (3, 0)]
        for (edgeIndex, (i, j)) in edgeNodePairs.enumerated() {
            if let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity {
                let edgeColor: UIColor
                if isSelected, let selEdge = selectedEdgeIndex, markers[index].id == selectedMarkerID, edgeIndex == selEdge {
                    edgeColor = .systemRed
                } else if isSelected || isInTarget || edgesInTarget.contains(edgeIndex) {
                    edgeColor = .systemBlue
                } else {
                    edgeColor = UIColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)
                }
                let edgeMaterial = UnlitMaterial(color: edgeColor)
                edgeEntity.model?.materials = [edgeMaterial]
            }
        }
    }
}
