//
//  PersistenceService.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import Foundation
import ARKit

/// Save/load pose, metrics, world map
final class PersistenceService {
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    
    func save(result: AlignmentResult) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(result)
        
        let fileURL = documentsDirectory.appendingPathComponent("alignment_result.json")
        try data.write(to: fileURL)
    }
    
    func loadLastAlignment() throws -> AlignmentResult? {
        let fileURL = documentsDirectory.appendingPathComponent("alignment_result.json")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(AlignmentResult.self, from: data)
    }
    
    func saveWorldMap(_ worldMap: ARWorldMap) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
        let fileURL = documentsDirectory.appendingPathComponent("ar_world_map.data")
        try data.write(to: fileURL)
    }
    
    func loadWorldMap() throws -> ARWorldMap? {
        let fileURL = documentsDirectory.appendingPathComponent("ar_world_map.data")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        let data = try Data(contentsOf: fileURL)
        guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            return nil
        }
        return worldMap
    }
}
