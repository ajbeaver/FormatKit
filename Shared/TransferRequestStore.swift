import Foundation

enum TransferAction: String, Codable {
    case archive
    case convert
}

struct TransferRequest: Codable {
    let version: Int
    let requestId: UUID
    let action: TransferAction
    let createdAt: Date
    let selectedItemBookmarks: [Data]
    let parentDirectoryBookmarks: [Data]
}

enum TransferRequestDefaults {
    static let schemaVersion = 2
    static let appGroupIdentifier = "group.com.ajbeaver.FormatKit"
    static let maxAge: TimeInterval = 5 * 60
}

enum TransferRequestStoreError: LocalizedError {
    case appGroupContainerUnavailable(String)
    case requestNotFound(UUID)
    case schemaMismatch(expected: Int, actual: Int)
    case actionMismatch(expected: TransferAction, actual: TransferAction)
    case malformedRequest
    case staleRequest
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable(let identifier):
            return "App Group container unavailable for \(identifier)."
        case .requestNotFound(let requestId):
            return "Request not found: \(requestId.uuidString)."
        case .schemaMismatch(let expected, let actual):
            return "Request version mismatch. Expected \(expected), got \(actual)."
        case .actionMismatch(let expected, let actual):
            return "Request action mismatch. Expected \(expected.rawValue), got \(actual.rawValue)."
        case .malformedRequest:
            return "Request payload was malformed."
        case .staleRequest:
            return "Request has expired."
        case .ioFailure(let message):
            return message
        }
    }
}

extension TransferRequest {
    func validate(expectedAction: TransferAction, now: Date, schemaVersion: Int = TransferRequestDefaults.schemaVersion, maxAge: TimeInterval = TransferRequestDefaults.maxAge) throws {
        guard version == schemaVersion else {
            throw TransferRequestStoreError.schemaMismatch(expected: schemaVersion, actual: version)
        }
        guard action == expectedAction else {
            throw TransferRequestStoreError.actionMismatch(expected: expectedAction, actual: action)
        }
        guard now.timeIntervalSince(createdAt) <= maxAge else {
            throw TransferRequestStoreError.staleRequest
        }
    }
}

protocol RequestStore {
    func save(_ request: TransferRequest) throws
    func take(requestId: UUID) throws -> TransferRequest
    func cleanupExpiredRequests(now: Date, maxAge: TimeInterval) throws
}

struct AppGroupTransferRequestStore: RequestStore {
    private let baseDirectoryURL: URL
    private let fileManager: FileManager

    init(appGroupIdentifier: String = TransferRequestDefaults.appGroupIdentifier, fileManager: FileManager = .default) throws {
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw TransferRequestStoreError.appGroupContainerUnavailable(appGroupIdentifier)
        }
        self.fileManager = fileManager
        self.baseDirectoryURL = containerURL.appendingPathComponent("TransferRequests", isDirectory: true)
    }

    init(baseDirectoryURL: URL, fileManager: FileManager = .default) {
        self.baseDirectoryURL = baseDirectoryURL
        self.fileManager = fileManager
    }

    func save(_ request: TransferRequest) throws {
        try ensureDirectoryExists()
        let data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            throw TransferRequestStoreError.ioFailure("Failed to encode request.")
        }
        do {
            try data.write(to: fileURL(for: request.requestId), options: [.atomic])
        } catch {
            throw TransferRequestStoreError.ioFailure("Failed to save request.")
        }
    }

    func take(requestId: UUID) throws -> TransferRequest {
        let requestURL = fileURL(for: requestId)
        guard fileManager.fileExists(atPath: requestURL.path) else {
            throw TransferRequestStoreError.requestNotFound(requestId)
        }

        let data: Data
        do {
            data = try Data(contentsOf: requestURL)
        } catch {
            throw TransferRequestStoreError.ioFailure("Failed to read request.")
        }

        do {
            try fileManager.removeItem(at: requestURL)
        } catch {
            throw TransferRequestStoreError.ioFailure("Failed to consume request.")
        }

        do {
            return try JSONDecoder().decode(TransferRequest.self, from: data)
        } catch {
            throw TransferRequestStoreError.malformedRequest
        }
    }

    func cleanupExpiredRequests(now: Date, maxAge: TimeInterval) throws {
        guard fileManager.fileExists(atPath: baseDirectoryURL.path) else { return }
        let requestFiles: [URL]
        do {
            requestFiles = try fileManager.contentsOfDirectory(at: baseDirectoryURL, includingPropertiesForKeys: nil)
        } catch {
            throw TransferRequestStoreError.ioFailure("Failed to inspect request store.")
        }

        for requestFile in requestFiles where requestFile.pathExtension == "json" {
            let shouldRemove: Bool
            do {
                let data = try Data(contentsOf: requestFile)
                let request = try JSONDecoder().decode(TransferRequest.self, from: data)
                shouldRemove = now.timeIntervalSince(request.createdAt) > maxAge
            } catch {
                shouldRemove = true
            }

            if shouldRemove {
                try? fileManager.removeItem(at: requestFile)
            }
        }
    }

    private func ensureDirectoryExists() throws {
        if fileManager.fileExists(atPath: baseDirectoryURL.path) { return }
        do {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw TransferRequestStoreError.ioFailure("Failed to initialize request store directory.")
        }
    }

    private func fileURL(for requestId: UUID) -> URL {
        baseDirectoryURL.appendingPathComponent(requestId.uuidString).appendingPathExtension("json")
    }
}
