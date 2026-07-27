import Foundation

enum ClipboardContentKind: String, Codable, CaseIterable, Sendable {
    case text
    case richText
    case image
    case files
    case url
}

struct ClipboardPayloadRepresentation: Codable, Equatable, Hashable, Sendable {
    let typeIdentifier: String
    let data: Data
}

struct ClipboardPayloadItem: Codable, Equatable, Hashable, Sendable {
    let representations: [ClipboardPayloadRepresentation]
}

struct ClipboardPayload: Codable, Equatable, Hashable, Sendable {
    let items: [ClipboardPayloadItem]
}

struct ClipboardHistoryCandidate: Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    let sourceApplicationName: String
    let sourceBundleIdentifier: String?
    let kind: ClipboardContentKind
    let summary: String
    let searchableText: String
    let fingerprint: String
    let payloadData: Data
    let thumbnailData: Data?
    let byteCount: Int
}

struct ClipboardHistoryRecord: Equatable, Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let lastCopiedAt: Date
    let sourceApplicationName: String
    let sourceBundleIdentifier: String?
    let kind: ClipboardContentKind
    let summary: String
    let searchableText: String
    let copyCount: Int
    let byteCount: Int
    let thumbnailData: Data?
}

struct ClipboardHistorySnapshot: Equatable, Sendable {
    let records: [ClipboardHistoryRecord]
    let warning: String?
    let revision: UInt64
}

struct ClipboardHistoryPreviewContent: Equatable, Sendable {
    let record: ClipboardHistoryRecord
    let text: String?
    let imageData: Data?
    let filePaths: [String]
}
