import AppKit
import FinderSync
import Foundation

final class FinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let requestStore: RequestStore? = try? AppGroupTransferRequestStore()

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

        if AudioSelectionGate.allSupportedAudio(urls: urls) || VideoSelectionGate.isSingleSupportedVideo(urls: urls) {
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

        guard
            let requestStore,
            let requestId = persistTransferRequest(action: .archive, urls: urls, requestStore: requestStore),
            let components = requestURLComponents(action: .archive, requestId: requestId),
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
        guard AudioSelectionGate.allSupportedAudio(urls: urls) || VideoSelectionGate.isSingleSupportedVideo(urls: urls) else { return }

        guard
            let requestStore,
            let requestId = persistTransferRequest(action: .convert, urls: urls, requestStore: requestStore),
            let components = requestURLComponents(action: .convert, requestId: requestId),
            let url = components.url
        else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func selectedFileURLs() -> [URL] {
        (controller.selectedItemURLs() ?? []).filter(\.isFileURL)
    }

    private func persistTransferRequest(action: TransferAction, urls: [URL], requestStore: RequestStore) -> UUID? {
        let itemBookmarks = urls.compactMap {
            try? $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        guard itemBookmarks.count == urls.count else { return nil }

        let request = TransferRequest(
            version: TransferRequestDefaults.schemaVersion,
            requestId: UUID(),
            action: action,
            createdAt: Date(),
            selectedItemBookmarks: itemBookmarks
        )
        do {
            try requestStore.cleanupExpiredRequests(now: Date(), maxAge: TransferRequestDefaults.maxAge)
            try requestStore.save(request)
            return request.requestId
        } catch {
            return nil
        }
    }

    private func requestURLComponents(action: TransferAction, requestId: UUID) -> URLComponents? {
        var components = URLComponents()
        components.scheme = "formatkit"
        components.host = action.rawValue
        components.queryItems = [URLQueryItem(name: "requestId", value: requestId.uuidString)]
        return components
    }
}
