import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationCenter = DistributedNotificationCenter.default()
    private let compressionQueue = DispatchQueue(label: "FormatKit.CompressionQueue", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationCenter.addObserver(
            self,
            selector: #selector(handleFinderActionNotification(_:)),
            name: .formatKitFinderAction,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        notificationCenter.removeObserver(self)
    }

    @objc private func handleFinderActionNotification(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let action = userInfo["action"] as? String,
            action == "compress",
            let rawPaths = userInfo["paths"] as? [String]
        else {
            return
        }

        let urls = rawPaths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)
        let format = presentCompressModal()
        guard let format else { return }

        compressionQueue.async { [urls] in
            for url in urls {
                Self.compressItem(at: url, format: format)
            }
        }
    }

    private func presentCompressModal() -> CompressionFormat? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28), pullsDown: false)
        popup.addItems(withTitles: CompressionFormat.allCases.map(\.displayName))
        popup.selectItem(at: 0)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Compress"
        alert.informativeText = ""
        alert.accessoryView = popup
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let selectedIndex = popup.indexOfSelectedItem
        let formats = CompressionFormat.allCases
        guard formats.indices.contains(selectedIndex) else { return .zip }
        return formats[selectedIndex]
    }

    private static func compressItem(at url: URL, format: CompressionFormat) {
        let fileManager = FileManager.default
        let parentDirectory = url.deletingLastPathComponent()
        let itemName = url.lastPathComponent
        let outputURL = uniqueOutputURL(nextTo: url, format: format, fileManager: fileManager)

        let process = Process()
        process.currentDirectoryURL = parentDirectory
        process.standardOutput = nil
        process.standardError = nil

        switch format {
        case .zip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-r", outputURL.lastPathComponent, itemName]
        case .tarGz:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-czf", outputURL.lastPathComponent, itemName]
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Minimal v1: fail silently and return.
        }
    }

    private static func uniqueOutputURL(nextTo url: URL, format: CompressionFormat, fileManager: FileManager) -> URL {
        let parentDirectory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let stem = baseName.isEmpty ? url.lastPathComponent : baseName
        let archiveSuffix = format.archiveSuffix

        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : " \(attempt + 1)"
            let filename = "\(stem)\(suffix)\(archiveSuffix)"
            let candidate = parentDirectory.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }
}

private enum CompressionFormat: CaseIterable {
    case zip
    case tarGz

    var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .tarGz: return "TAR.GZ"
        }
    }

    var archiveSuffix: String {
        switch self {
        case .zip: return ".zip"
        case .tarGz: return ".tar.gz"
        }
    }
}

private extension Notification.Name {
    static let formatKitFinderAction = Notification.Name("com.ajbeaver.FormatKit.finderAction")
}
