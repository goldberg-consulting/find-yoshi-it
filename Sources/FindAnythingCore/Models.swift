import Foundation

public enum SourceKind: String, Codable, Sendable, CaseIterable { case local, external, network }
public enum SourceAvailability: String, Codable, Sendable { case online, offline, scanning, paused, error }
public enum ContentStatus: String, Codable, Sendable { case queued, indexed, needsOCR, unsupported, locked, failed, partial, denied }
public enum SearchMode: String, Codable, Sendable, CaseIterable { case names, hybrid, exact, semantic }

public struct SourceRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var kind: SourceKind
    public var availability: SourceAvailability
    public var lastScan: Date?
    public var lastError: String?
    public var exclusions: [String]
    public var allowsOfflineContent: Bool
    public var ocrEnabled: Bool
    public var fileCount: Int
    public var indexedCount: Int
    public var pendingCount: Int
    public var failedCount: Int
    public var unsupportedCount: Int
    public init(id: String = UUID().uuidString, name: String, path: String, kind: SourceKind = .local, availability: SourceAvailability = .online, lastScan: Date? = nil, lastError: String? = nil, exclusions: [String] = [".git", ".build", ".DS_Store"], allowsOfflineContent: Bool = true, ocrEnabled: Bool = true, fileCount: Int = 0, indexedCount: Int = 0, pendingCount: Int = 0, failedCount: Int = 0, unsupportedCount: Int = 0) {
        self.id = id; self.name = name; self.path = path; self.kind = kind; self.availability = availability
        self.lastScan = lastScan; self.lastError = lastError; self.exclusions = exclusions
        self.allowsOfflineContent = allowsOfflineContent; self.ocrEnabled = ocrEnabled
        self.fileCount = fileCount; self.indexedCount = indexedCount; self.pendingCount = pendingCount
        self.failedCount = failedCount; self.unsupportedCount = unsupportedCount
    }
}

public struct Passage: Identifiable, Codable, Sendable, Equatable {
    public var id: Int64
    public var text: String
    public var location: String
    public var page: Int?
    public var line: Int?
    public var sheet: String?
    public var cell: String?
    public init(id: Int64 = 0, text: String, location: String, page: Int? = nil, line: Int? = nil, sheet: String? = nil, cell: String? = nil) {
        self.id = id; self.text = text; self.location = location; self.page = page; self.line = line; self.sheet = sheet; self.cell = cell
    }
}

public struct ExtractionResult: Sendable {
    public var passages: [Passage]
    public var status: ContentStatus
    public var detail: String?
    public init(passages: [Passage], status: ContentStatus = .indexed, detail: String? = nil) {
        self.passages = passages; self.status = status; self.detail = detail
    }
}

public struct SearchRequest: Sendable {
    public var namesOnly = false
    public var query: String
    public var mode: SearchMode
    public var sourceID: String?
    public var fileExtension: String?
    public var modifiedAfter: Date?
    public var limit: Int
    public var category: FileSearchCategory
    var candidateFileIDs: [Int64]? = nil
    public init(query: String, mode: SearchMode = .hybrid, sourceID: String? = nil, fileExtension: String? = nil, modifiedAfter: Date? = nil, limit: Int = 60, category: FileSearchCategory = .all) {
        self.query = query; self.mode = mode; self.sourceID = sourceID; self.fileExtension = fileExtension; self.modifiedAfter = modifiedAfter; self.limit = limit; self.category = category
    }
}

public struct SearchResult: Identifiable, Sendable, Equatable {
    public var id: Int64 { fileID }
    public var fileID: Int64
    public var sourceID: String
    public var sourceName: String
    public var filename: String
    public var path: String
    public var fileExtension: String
    public var modifiedAt: Date
    public var indexedAt: Date?
    public var availability: SourceAvailability
    public var status: ContentStatus
    public var detail: String?
    public var passages: [Passage]
    public var score: Double
    public var nameMatched: Bool = false
    public var matchKind: String
    public var isStale: Bool
    public var offlineContentAllowed: Bool
    public init(fileID: Int64, sourceID: String, sourceName: String, filename: String, path: String, fileExtension: String, modifiedAt: Date, indexedAt: Date? = nil, availability: SourceAvailability = .online, status: ContentStatus = .indexed, detail: String? = nil, passages: [Passage] = [], score: Double = 0, matchKind: String = "Text match", isStale: Bool = false, offlineContentAllowed: Bool = true) {
        self.fileID = fileID; self.sourceID = sourceID; self.sourceName = sourceName; self.filename = filename; self.path = path
        self.fileExtension = fileExtension; self.modifiedAt = modifiedAt; self.indexedAt = indexedAt; self.availability = availability
        self.status = status; self.detail = detail; self.passages = passages; self.score = score; self.matchKind = matchKind; self.isStale = isStale; self.offlineContentAllowed = offlineContentAllowed
    }
}

public struct IndexProgress: Sendable {
    public var sourceID: String
    public var phase: String
    public var discovered: Int
    public var processed: Int
    public var currentPath: String
    public init(sourceID: String, phase: String, discovered: Int = 0, processed: Int = 0, currentPath: String = "") {
        self.sourceID = sourceID; self.phase = phase; self.discovered = discovered; self.processed = processed; self.currentPath = currentPath
    }
}

public struct IndexStatistics: Sendable {
    public var files: Int
    public var passages: Int
    public var vectors: Int
    public var databaseBytes: Int64
    public var semanticAvailable: Bool
    public var modelDescription: String
    public init(files: Int = 0, passages: Int = 0, vectors: Int = 0, databaseBytes: Int64 = 0, semanticAvailable: Bool = false, modelDescription: String = "") {
        self.files = files; self.passages = passages; self.vectors = vectors; self.databaseBytes = databaseBytes; self.semanticAvailable = semanticAvailable; self.modelDescription = modelDescription
    }
}
