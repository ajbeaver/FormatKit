import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let compressionQueue = DispatchQueue(label: "FormatKit.CompressionQueue", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    static func openFinderExtensionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Extensions-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func handleIncomingURL(_ url: URL) {
        guard
            url.scheme?.lowercased() == "formatkit",
            let action = url.host?.lowercased(),
            action == "archive",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let encodedPaths = components.queryItems?.first(where: { $0.name == "paths" })?.value,
            let data = Data(base64Encoded: encodedPaths),
            let rawPaths = try? JSONDecoder().decode([String].self, from: data)
        else {
            return
        }

        let urls = rawPaths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)
        let format = presentCompressModal(selectionCount: urls.count)
        guard let format else { return }

        compressionQueue.async { [urls] in
            for url in urls {
                Self.compressItem(at: url, format: format)
            }
        }
    }

    private func presentCompressModal(selectionCount: Int) -> CompressionFormat? {
        let availableFormats = CompressionFormat.availableFormats(forSelectionCount: selectionCount)
        guard !availableFormats.isEmpty else { return nil }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28), pullsDown: false)
        popup.addItems(withTitles: availableFormats.map(\.displayName))
        popup.selectItem(at: 0)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Archive"
        alert.informativeText = ""
        alert.accessoryView = popup
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let selectedIndex = popup.indexOfSelectedItem
        guard availableFormats.indices.contains(selectedIndex) else { return .zip }
        return availableFormats[selectedIndex]
    }

    private static func compressItem(at url: URL, format: CompressionFormat) {
        let fileManager = FileManager.default
        let parentDirectory = url.deletingLastPathComponent()
        let itemName = url.lastPathComponent
        let process = Process()
        process.currentDirectoryURL = parentDirectory
        process.standardOutput = nil
        process.standardError = nil
        var rawPlan: RawCompressionPlan?

        switch format {
        case .zip:
            let outputURL = uniqueOutputURL(nextTo: url, format: format, fileManager: fileManager)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-r", outputURL.lastPathComponent, itemName]
        case .tarGz:
            let outputURL = uniqueOutputURL(nextTo: url, format: format, fileManager: fileManager)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-czf", outputURL.lastPathComponent, itemName]
        case .tarBz2:
            let outputURL = uniqueOutputURL(nextTo: url, format: format, fileManager: fileManager)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-cjf", outputURL.lastPathComponent, itemName]
        case .tarXz:
            let outputURL = uniqueOutputURL(nextTo: url, format: format, fileManager: fileManager)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-cJf", outputURL.lastPathComponent, itemName]
        case .gz, .bz2, .xz:
            rawPlan = configureRawCompressionProcess(
                process,
                sourceURL: url,
                format: format,
                fileManager: fileManager
            )
        }

        do {
            try process.run()
            process.waitUntilExit()
            cleanupRawCompressionTempLinkIfNeeded(rawPlan, fileManager: fileManager)
        } catch {
            cleanupRawCompressionTempLinkIfNeeded(rawPlan, fileManager: fileManager)
            // Minimal v1: fail silently and return.
        }
    }

    private static func uniqueOutputURL(nextTo url: URL, format: CompressionFormat, fileManager: FileManager) -> URL {
        let parentDirectory = url.deletingLastPathComponent()
        let stem: String
        if format.isTarContainer {
            let baseName = url.deletingPathExtension().lastPathComponent
            stem = baseName.isEmpty ? url.lastPathComponent : baseName
        } else {
            stem = url.lastPathComponent
        }
        let archiveSuffix = format.archiveSuffix

        var attempt = 0
        while true {
            let suffix: String
            if attempt == 0 {
                suffix = ""
            } else if format.isRawCompression {
                suffix = "_\(attempt)"
            } else {
                suffix = " \(attempt + 1)"
            }
            let filename = "\(stem)\(suffix)\(archiveSuffix)"
            let candidate = parentDirectory.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private static func configureRawCompressionProcess(
        _ process: Process,
        sourceURL: URL,
        format: CompressionFormat,
        fileManager: FileManager
    ) -> RawCompressionPlan {
        let outputURL = uniqueOutputURL(nextTo: sourceURL, format: format, fileManager: fileManager)
        let defaultOutputURL = sourceURL.appendingPathExtension(format.rawCompressionExtension)

        if outputURL.path == defaultOutputURL.path {
            process.executableURL = format.executableURL
            process.arguments = ["-k", sourceURL.lastPathComponent]
            return RawCompressionPlan(tempLinkURL: nil)
        }

        let tempLinkURL = outputURL.deletingPathExtension()
        try? fileManager.removeItem(at: tempLinkURL)
        do {
            try fileManager.linkItem(at: sourceURL, to: tempLinkURL)
            process.executableURL = format.executableURL
            process.arguments = ["-k", tempLinkURL.lastPathComponent]
            return RawCompressionPlan(tempLinkURL: tempLinkURL)
        } catch {
            do {
                try fileManager.copyItem(at: sourceURL, to: tempLinkURL)
                process.executableURL = format.executableURL
                process.arguments = ["-k", tempLinkURL.lastPathComponent]
                return RawCompressionPlan(tempLinkURL: tempLinkURL)
            } catch {
                process.executableURL = format.executableURL
                process.arguments = ["-k", sourceURL.lastPathComponent]
                return RawCompressionPlan(tempLinkURL: nil)
            }
        }
    }

    private static func cleanupRawCompressionTempLinkIfNeeded(
        _ plan: RawCompressionPlan?,
        fileManager: FileManager
    ) {
        guard let tempLinkURL = plan?.tempLinkURL else { return }
        try? fileManager.removeItem(at: tempLinkURL)
    }
}

private enum CompressionFormat: CaseIterable {
    case zip
    case tarGz
    case tarBz2
    case tarXz
    case gz
    case bz2
    case xz

    var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .tarGz: return "TAR.GZ"
        case .tarBz2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        case .gz: return "GZ"
        case .bz2: return "BZ2"
        case .xz: return "XZ"
        }
    }

    var archiveSuffix: String {
        switch self {
        case .zip: return ".zip"
        case .tarGz: return ".tar.gz"
        case .tarBz2: return ".tar.bz2"
        case .tarXz: return ".tar.xz"
        case .gz: return ".gz"
        case .bz2: return ".bz2"
        case .xz: return ".xz"
        }
    }

    var isTarContainer: Bool {
        switch self {
        case .tarGz, .tarBz2, .tarXz:
            return true
        default:
            return false
        }
    }

    var isRawCompression: Bool {
        switch self {
        case .gz, .bz2, .xz:
            return true
        default:
            return false
        }
    }

    var rawCompressionExtension: String {
        switch self {
        case .gz: return "gz"
        case .bz2: return "bz2"
        case .xz: return "xz"
        default: return ""
        }
    }

    var executableURL: URL {
        switch self {
        case .gz:
            return URL(fileURLWithPath: "/usr/bin/gzip")
        case .bz2:
            return URL(fileURLWithPath: "/usr/bin/bzip2")
        case .xz:
            return URL(fileURLWithPath: "/usr/bin/xz")
        case .zip:
            return URL(fileURLWithPath: "/usr/bin/zip")
        case .tarGz, .tarBz2, .tarXz:
            return URL(fileURLWithPath: "/usr/bin/tar")
        }
    }

    static func availableFormats(forSelectionCount count: Int) -> [CompressionFormat] {
        let multiFileFormats: [CompressionFormat] = [.zip, .tarGz, .tarBz2, .tarXz]
        if count == 1 {
            return multiFileFormats + [.gz, .bz2, .xz]
        }
        return multiFileFormats
    }
}

private struct RawCompressionPlan {
    let tempLinkURL: URL?
}
