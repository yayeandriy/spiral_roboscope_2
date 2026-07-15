//
//  RepairSessionPhotoService.swift
//  roboscope2
//
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  API service for the manual "take picture" session-photo endpoints (0007_session_photos.sql).
//  Each capture event uploads a required `raw` frame plus a best-effort `annotated` frame — not
//  tied to any specific pin (see PinService.uploadPinPhoto for the separate per-pin flow).
//

import Foundation

/// Not an ObservableObject — it has no observable state, just stateless request methods
/// (unlike PinService, which exposes @Published isLoading/lastError for its callers).
final class RepairSessionPhotoService {
    static let shared = RepairSessionPhotoService()

    private let http = RepairHTTP.shared

    private init() {}

    /// Matches the contract's example format exactly (no fractional seconds), e.g.
    /// "2026-07-15T11:20:00Z".
    private static let capturedAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// POST /v1/repair-sessions/{id}/photos
    /// `annotated` is optional — omit the part entirely (not just pass nil data) when the
    /// pins-baked-in render failed on-device; the raw upload must never be blocked by it.
    func upload(sessionId: UUID, raw: Data, annotated: Data?, capturedAt: Date) async throws -> RepairSessionPhoto {
        var fileParts: [RepairHTTP.MultipartFilePart] = [
            RepairHTTP.MultipartFilePart(name: "raw", filename: "raw.jpg", mimeType: "image/jpeg", data: raw)
        ]
        if let annotated {
            fileParts.append(
                RepairHTTP.MultipartFilePart(name: "annotated", filename: "annotated.jpg", mimeType: "image/jpeg", data: annotated)
            )
        }
        return try await http.postMultipart(
            "/repair-sessions/\(sessionId.uuidString)/photos",
            fileParts: fileParts,
            textFields: ["captured_at": Self.capturedAtFormatter.string(from: capturedAt)]
        )
    }

    /// GET /v1/repair-sessions/{id}/photos — not required for the capture flow itself; kept for
    /// any future on-device gallery.
    func list(sessionId: UUID) async throws -> [RepairSessionPhoto] {
        let response: RepairSessionPhotosResponse = try await http.get("/repair-sessions/\(sessionId.uuidString)/photos")
        return response.photos
    }

    /// DELETE /v1/repair-sessions/{id}/photos/{photoId} — not required for the capture flow itself.
    func delete(sessionId: UUID, photoId: UUID) async throws {
        try await http.delete("/repair-sessions/\(sessionId.uuidString)/photos/\(photoId.uuidString)")
    }
}
