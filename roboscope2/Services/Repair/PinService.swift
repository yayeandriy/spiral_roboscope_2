//
//  PinService.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  API service for Pin create/list/delete. Bulk-create is the preferred flush path during
//  rapid auto-placement (02-contracts.md §2.2 / 05-ios-repair.md §5.5).
//

import Foundation
import Combine

final class PinService: ObservableObject {
    static let shared = PinService()

    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    private let http = RepairHTTP.shared

    private init() {}

    /// POST /v1/pins
    func createPin(_ body: CreatePin) async throws -> Pin {
        try await http.post("/pins", body: body)
    }

    /// POST /v1/pins/bulk — all entries must share one repair_session_id.
    /// Preferred flush path from the device to reduce chattiness during auto-placement.
    func createPinsBulk(_ pins: [CreatePin]) async throws -> [Pin] {
        guard !pins.isEmpty else { return [] }
        let body = CreatePinsBulk(pins: pins)
        return try await http.post("/pins/bulk", body: body)
    }

    /// GET /v1/pins?repair_session_id=
    func listPins(repairSessionId: UUID) async throws -> [Pin] {
        try await http.get("/pins", query: [URLQueryItem(name: "repair_session_id", value: repairSessionId.uuidString)])
    }

    /// DELETE /v1/pins/{id}
    func deletePin(_ id: UUID) async throws {
        try await http.delete("/pins/\(id.uuidString)")
    }

    /// POST /v1/pins/{id}/photo — the pin must already exist (created via createPin/
    /// createPinsBulk). Calling this again on the same pin replaces the photo server-side.
    func uploadPinPhoto(pinId: UUID, jpegData: Data) async throws -> Pin {
        try await http.postMultipart(
            "/pins/\(pinId.uuidString)/photo",
            fileParts: [RepairHTTP.MultipartFilePart(name: "photo", filename: "pin.jpg", mimeType: "image/jpeg", data: jpegData)]
        )
    }

    /// DELETE /v1/pins/{id}/photo — clears Pin.photoUrl back to null.
    func deletePinPhoto(pinId: UUID) async throws {
        try await http.delete("/pins/\(pinId.uuidString)/photo")
    }
}
