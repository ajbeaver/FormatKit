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

        _ = classifySelection(urls)

        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Compress…", action: #selector(handleCompress(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func handleCompress(_ sender: Any?) {
        let urls = selectedFileURLs()
        guard !urls.isEmpty else { return }

        let paths = urls.map(\.path)
        guard
            let jsonData = try? JSONEncoder().encode(paths),
            let components = compressURLComponents(withBase64Paths: jsonData.base64EncodedString()),
            let url = components.url
        else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func selectedFileURLs() -> [URL] {
        (controller.selectedItemURLs() ?? []).filter(\.isFileURL)
    }

    private func classifySelection(_ urls: [URL]) -> SelectionKind {
        let hasArchive = urls.contains { Self.isArchiveURL($0) }
        let hasNonArchive = urls.contains { !Self.isArchiveURL($0) }

        switch (hasArchive, hasNonArchive) {
        case (false, true): return .onlyNonArchives
        case (true, true): return .mixed
        case (true, false): return .onlyArchives
        default: return .empty
        }
    }

    private static func isArchiveURL(_ url: URL) -> Bool {
        let lowercased = url.lastPathComponent.lowercased()
        return lowercased.hasSuffix(".zip") || lowercased.hasSuffix(".tar.gz") || lowercased.hasSuffix(".tgz")
    }

    private func compressURLComponents(withBase64Paths encodedPaths: String) -> URLComponents? {
        var components = URLComponents()
        components.scheme = "formatkit"
        components.host = "compress"
        components.queryItems = [URLQueryItem(name: "paths", value: encodedPaths)]
        return components
    }
}

private enum SelectionKind {
    case empty
    case onlyNonArchives
    case mixed
    case onlyArchives
}
