import AppKit
import FinderSync
import Foundation

final class FinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()

    override init() {
        super.init()
        controller.directoryURLs = Set([URL(fileURLWithPath: "/")])
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }

        let urls = selectedFileURLs()
        guard !urls.isEmpty else { return nil }
        let containsArchived = ArchiveSelectionGate.containsArchivedItem(urls: urls)
        guard !containsArchived else { return nil }

        let menu = NSMenu(title: "")
        let archiveItem = NSMenuItem(title: "Archive", action: #selector(handleArchive(_:)), keyEquivalent: "")
        archiveItem.target = self
        menu.addItem(archiveItem)

        if VideoSelectionGate.isSingleSupportedVideo(urls: urls) {
            let convertItem = NSMenuItem(title: "Convert", action: #selector(handleConvert(_:)), keyEquivalent: "")
            convertItem.target = self
            menu.addItem(convertItem)
        }

        return menu
    }

    @objc private func handleArchive(_ sender: Any?) {
        let urls = selectedFileURLs()
        guard !urls.isEmpty else { return }
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else { return }

        let paths = urls.map(\.path)
        guard
            let jsonData = try? JSONEncoder().encode(paths),
            let components = archiveURLComponents(withBase64Paths: jsonData.base64EncodedString()),
            let url = components.url
        else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    @objc private func handleConvert(_ sender: Any?) {
        let urls = selectedFileURLs()
        guard !urls.isEmpty else { return }
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else { return }
        guard VideoSelectionGate.isSingleSupportedVideo(urls: urls) else { return }

        let paths = urls.map(\.path)
        guard
            let jsonData = try? JSONEncoder().encode(paths),
            let components = urlComponents(action: "convert", withBase64Paths: jsonData.base64EncodedString()),
            let url = components.url
        else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func selectedFileURLs() -> [URL] {
        (controller.selectedItemURLs() ?? []).filter(\.isFileURL)
    }

    private func archiveURLComponents(withBase64Paths encodedPaths: String) -> URLComponents? {
        urlComponents(action: "archive", withBase64Paths: encodedPaths)
    }

    private func urlComponents(action: String, withBase64Paths encodedPaths: String) -> URLComponents? {
        var components = URLComponents()
        components.scheme = "formatkit"
        components.host = action
        components.queryItems = [URLQueryItem(name: "paths", value: encodedPaths)]
        return components
    }
}
