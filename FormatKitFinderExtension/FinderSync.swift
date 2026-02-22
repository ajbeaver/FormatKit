import AppKit
import FinderSync
import Foundation

final class FinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let payloadStore = HandoffPayloadStore()

    override init() {
        super.init()
        controller.directoryURLs = Set([URL(fileURLWithPath: "/")])
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }

        let urls = selectedFileURLs()
        guard !urls.isEmpty else { return nil }
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else { return nil }

        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Archive…", action: #selector(handleArchive(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func handleArchive(_ sender: Any?) {
        let urls = selectedFileURLs()
        guard !urls.isEmpty else { return }
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else { return }

        do {
            let token = try payloadStore.writePaths(urls.map(\.path))
            guard let components = archiveURLComponents(token: token), let url = components.url else {
                return
            }
            NSWorkspace.shared.open(url)
        } catch {
            NSLog("FormatKit Finder extension failed to handoff selection: %@", String(describing: error))
        }
    }

    private func selectedFileURLs() -> [URL] {
        (controller.selectedItemURLs() ?? []).filter(\.isFileURL)
    }

    private func archiveURLComponents(token: String) -> URLComponents? {
        var components = URLComponents()
        components.scheme = "formatkit"
        components.host = "archive"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components
    }
}
