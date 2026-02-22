import Foundation

enum ArchiveFormat: CaseIterable {
    case zip
    case tarGz
    case tarXz

    var pickerDisplayName: String {
        switch self {
        case .zip: return "ZIP"
        case .tarGz: return "GZ"
        case .tarXz: return "XZ"
        }
    }

    static func fromPickerDisplayName(_ name: String) -> ArchiveFormat? {
        allCases.first { $0.pickerDisplayName == name }
    }

    var archiveSuffix: String {
        switch self {
        case .zip: return ".zip"
        case .tarGz: return ".tar.gz"
        case .tarXz: return ".tar.xz"
        }
    }

    var executableURL: URL {
        switch self {
        case .zip:
            return URL(fileURLWithPath: "/usr/bin/zip")
        case .tarGz, .tarXz:
            return URL(fileURLWithPath: "/usr/bin/tar")
        }
    }

    func processArguments(outputFileName: String, relativeItemNames: [String]) -> [String] {
        switch self {
        case .zip:
            return ["-r", outputFileName] + relativeItemNames
        case .tarGz:
            return ["-czf", outputFileName] + relativeItemNames
        case .tarXz:
            return ["-cJf", outputFileName] + relativeItemNames
        }
    }
}

enum ArchiveSelectionGate {
    private static let archivedSuffixes = [
        ".tar.gz", ".tar.xz", ".tgz", ".txz", ".zip", ".tar", ".gz", ".xz", ".bz2"
    ]

    static func containsArchivedItem(urls: [URL]) -> Bool {
        urls.contains(where: isArchivedURL)
    }

    static func isArchivedURL(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        return archivedSuffixes.contains { lowercasedName.hasSuffix($0) }
    }
}

enum ArchiveNamingError: Error {
    case emptySelection
    case mixedParentDirectories
}

enum ArchiveNameBuilder {
    static func outputURL(for selection: [URL], format: ArchiveFormat, now: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        guard !selection.isEmpty else { throw ArchiveNamingError.emptySelection }

        if selection.count == 1, let item = selection.first {
            let directory = item.deletingLastPathComponent()
            let baseName = singleSelectionBaseName(for: item, format: format)
            return uniqueArchiveURL(directory: directory, baseName: baseName, format: format, fileManager: fileManager)
        }

        let directory = try commonParentDirectory(for: selection)
        let baseName = multiSelectionBaseName(now: now)
        return uniqueArchiveURL(directory: directory, baseName: baseName, format: format, fileManager: fileManager)
    }

    static func relativeItemNames(for selection: [URL]) throws -> [String] {
        guard !selection.isEmpty else { throw ArchiveNamingError.emptySelection }
        _ = try commonParentDirectory(for: selection)
        return selection.map(\.lastPathComponent)
    }

    static func commonParentDirectory(for selection: [URL]) throws -> URL {
        guard let first = selection.first else { throw ArchiveNamingError.emptySelection }
        let firstParent = first.deletingLastPathComponent().standardizedFileURL
        let hasMixedParents = selection.dropFirst().contains {
            $0.deletingLastPathComponent().standardizedFileURL != firstParent
        }
        guard !hasMixedParents else { throw ArchiveNamingError.mixedParentDirectories }
        return firstParent
    }

    static func singleSelectionBaseName(for item: URL, format: ArchiveFormat) -> String {
        switch format {
        case .zip:
            return item.lastPathComponent
        case .tarGz, .tarXz:
            let baseName = item.deletingPathExtension().lastPathComponent
            return baseName.isEmpty ? item.lastPathComponent : baseName
        }
    }

    static func multiSelectionBaseName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "archive_\(formatter.string(from: now))"
    }

    static func uniqueArchiveURL(directory: URL, baseName: String, format: ArchiveFormat, fileManager: FileManager = .default) -> URL {
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : " \(attempt + 1)"
            let candidate = directory.appendingPathComponent(baseName + suffix + format.archiveSuffix)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }
}
