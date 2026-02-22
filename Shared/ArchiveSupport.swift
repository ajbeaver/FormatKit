import Foundation

enum ArchiveFormat: CaseIterable {
    case zip
    case tarGz
    case tarXz

    nonisolated var pickerDisplayName: String {
        switch self {
        case .zip: return "ZIP"
        case .tarGz: return "GZ"
        case .tarXz: return "XZ"
        }
    }

    nonisolated static func fromPickerDisplayName(_ name: String) -> ArchiveFormat? {
        allCases.first { $0.pickerDisplayName == name }
    }

    nonisolated var archiveSuffix: String {
        switch self {
        case .zip: return ".zip"
        case .tarGz: return ".tar.gz"
        case .tarXz: return ".tar.xz"
        }
    }

    nonisolated var executableURL: URL {
        switch self {
        case .zip:
            return URL(fileURLWithPath: "/usr/bin/zip")
        case .tarGz, .tarXz:
            return URL(fileURLWithPath: "/usr/bin/tar")
        }
    }

    nonisolated func processArguments(outputFileName: String, relativeItemNames: [String]) -> [String] {
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
    nonisolated private static let archivedSuffixes = [
        ".tar.gz", ".tar.xz", ".tgz", ".txz", ".zip", ".tar", ".gz", ".xz", ".bz2"
    ]

    nonisolated static func containsArchivedItem(urls: [URL]) -> Bool {
        urls.contains(where: isArchivedURL)
    }

    nonisolated static func isArchivedURL(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        return archivedSuffixes.contains { lowercasedName.hasSuffix($0) }
    }
}

enum ArchiveNamingError: Error {
    case emptySelection
    case mixedParentDirectories
}

enum ArchiveNameBuilder {
    nonisolated static func outputURL(for selection: [URL], format: ArchiveFormat, now: Date = Date(), fileManager: FileManager = .default) throws -> URL {
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

    nonisolated static func relativeItemNames(for selection: [URL]) throws -> [String] {
        guard !selection.isEmpty else { throw ArchiveNamingError.emptySelection }
        _ = try commonParentDirectory(for: selection)
        return selection.map(\.lastPathComponent)
    }

    nonisolated static func commonParentDirectory(for selection: [URL]) throws -> URL {
        guard let first = selection.first else { throw ArchiveNamingError.emptySelection }
        let firstParent = first.deletingLastPathComponent().standardizedFileURL
        let hasMixedParents = selection.dropFirst().contains {
            $0.deletingLastPathComponent().standardizedFileURL != firstParent
        }
        guard !hasMixedParents else { throw ArchiveNamingError.mixedParentDirectories }
        return firstParent
    }

    nonisolated static func singleSelectionBaseName(for item: URL, format: ArchiveFormat) -> String {
        switch format {
        case .zip:
            return item.lastPathComponent
        case .tarGz, .tarXz:
            let baseName = item.deletingPathExtension().lastPathComponent
            return baseName.isEmpty ? item.lastPathComponent : baseName
        }
    }

    nonisolated static func multiSelectionBaseName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "archive_\(formatter.string(from: now))"
    }

    nonisolated static func uniqueArchiveURL(directory: URL, baseName: String, format: ArchiveFormat, fileManager: FileManager = .default) -> URL {
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

enum AudioInputFormat: String, CaseIterable {
    case mp3
    case m4a
    case wav
    case aiff
    case flac

    nonisolated static func fromURL(_ url: URL) -> AudioInputFormat? {
        let ext = url.pathExtension.lowercased()
        return AudioInputFormat(rawValue: ext)
    }
}

enum AudioOutputFormat: String, CaseIterable {
    case mp3
    case m4a
    case wav
    case aiff

    nonisolated var displayName: String { rawValue.uppercased() }

    nonisolated var fileExtension: String { rawValue }
}

enum AudioSelectionGate {
    nonisolated static func allSupportedAudio(urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        return urls.allSatisfy { AudioInputFormat.fromURL($0) != nil }
    }

    nonisolated static func inputFormats(for urls: [URL]) -> [AudioInputFormat]? {
        let formats = urls.compactMap(AudioInputFormat.fromURL(_:))
        guard formats.count == urls.count else { return nil }
        return formats
    }
}

enum AudioConversionMatrix {
    nonisolated static func allowedOutputs(for input: AudioInputFormat) -> [AudioOutputFormat] {
        switch input {
        case .mp3:
            return [.m4a, .wav, .aiff]
        case .m4a:
            return [.mp3, .wav, .aiff]
        case .wav:
            return [.m4a, .mp3, .aiff]
        case .aiff:
            return [.m4a, .mp3, .wav]
        case .flac:
            return [.m4a, .mp3, .wav]
        }
    }

    nonisolated static func allowedOutputs(for inputs: [AudioInputFormat]) -> [AudioOutputFormat] {
        guard let first = inputs.first else { return [] }
        var allowed = Set(allowedOutputs(for: first))
        for input in inputs.dropFirst() {
            allowed.formIntersection(Set(allowedOutputs(for: input)))
        }
        return AudioOutputFormat.allCases.filter { allowed.contains($0) }
    }
}

enum ConvertNameBuilder {
    nonisolated static func outputURL(for sourceURL: URL, outputFormat: AudioOutputFormat, fileManager: FileManager = .default) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return uniqueOutputURL(directory: directory, baseName: stem, outputFormat: outputFormat, fileManager: fileManager)
    }

    nonisolated private static func uniqueOutputURL(
        directory: URL,
        baseName: String,
        outputFormat: AudioOutputFormat,
        fileManager: FileManager
    ) -> URL {
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : " \(attempt + 1)"
            let candidate = directory.appendingPathComponent("\(baseName)\(suffix).\(outputFormat.fileExtension)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }
}

enum VideoInputFormat: String, CaseIterable {
    case mp4
    case mov
    case m4v

    nonisolated static func fromURL(_ url: URL) -> VideoInputFormat? {
        VideoInputFormat(rawValue: url.pathExtension.lowercased())
    }
}

enum VideoSelectionGate {
    nonisolated static func isSingleSupportedVideo(urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first else { return false }
        return VideoInputFormat.fromURL(url) != nil
    }
}

enum VideoOutputFormat: String, CaseIterable {
    case mp4
    case mov
    case m4v

    nonisolated var displayName: String { rawValue.uppercased() }
    nonisolated var fileExtension: String { rawValue }

    nonisolated static func fromInputFormat(_ input: VideoInputFormat) -> VideoOutputFormat {
        switch input {
        case .mp4: return .mp4
        case .mov: return .mov
        case .m4v: return .m4v
        }
    }
}

enum VideoOutputOptionFilter {
    nonisolated static func alternativeOutputs(
        sourceInput: VideoInputFormat,
        supportedOutputs: [VideoOutputFormat]
    ) -> [VideoOutputFormat] {
        let sourceOutput = VideoOutputFormat.fromInputFormat(sourceInput)
        return supportedOutputs.filter { $0 != sourceOutput }
    }
}

enum VideoConvertNameBuilder {
    nonisolated static func outputURL(for sourceURL: URL, outputFormat: VideoOutputFormat, fileManager: FileManager = .default) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return uniqueOutputURL(directory: directory, baseName: stem, outputFormat: outputFormat, fileManager: fileManager)
    }

    nonisolated private static func uniqueOutputURL(
        directory: URL,
        baseName: String,
        outputFormat: VideoOutputFormat,
        fileManager: FileManager
    ) -> URL {
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : " \(attempt + 1)"
            let candidate = directory.appendingPathComponent("\(baseName)\(suffix).\(outputFormat.fileExtension)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }
}
