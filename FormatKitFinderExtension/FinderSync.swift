import AppKit
import FinderSync
import Foundation

final class FinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let requestStore: RequestStore?
    private let requestStoreInitError: String?

    override init() {
        do {
            requestStore = try AppGroupTransferRequestStore()
            requestStoreInitError = nil
            NSLog("FormatKitFinderExtension request store initialized.")
        } catch {
            requestStore = nil
            requestStoreInitError = error.localizedDescription
            NSLog("FormatKitFinderExtension request store init failed: %@", error.localizedDescription)
        }
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

        if AudioSelectionGate.allSupportedAudio(urls: urls) || VideoSelectionGate.isSingleSupportedVideo(urls: urls) || ImageSelectionGate.allSupportedImages(urls: urls) {
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
        submitRequest(action: .archive, urls: urls)
    }

    @objc private func handleConvert(_ sender: Any?) {
        let urls = selectedFileURLs()
        guard !urls.isEmpty else { return }
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else { return }
        guard AudioSelectionGate.allSupportedAudio(urls: urls) || VideoSelectionGate.isSingleSupportedVideo(urls: urls) || ImageSelectionGate.allSupportedImages(urls: urls) else { return }
        submitRequest(action: .convert, urls: urls)
    }

    private func selectedFileURLs() -> [URL] {
        (controller.selectedItemURLs() ?? []).filter(\.isFileURL)
    }

    private func submitRequest(action: TransferAction, urls: [URL]) {
        NSLog("FormatKitFinderExtension submitting %@ request for %ld item(s).", action.rawValue, urls.count)
        guard let requestStore else {
            notifyFailure(
                action: action,
                message: requestStoreInitError ?? "Secure request store unavailable in Finder extension."
            )
            return
        }

        let requestId: UUID
        do {
            requestId = try persistTransferRequest(action: action, urls: urls, requestStore: requestStore)
            NSLog("FormatKitFinderExtension request %@ persisted as %@", action.rawValue, requestId.uuidString)
        } catch {
            NSLog("FormatKitFinderExtension request %@ persist failed: %@", action.rawValue, error.localizedDescription)
            notifyFailure(action: action, message: error.localizedDescription)
            return
        }

        guard
            let components = requestURLComponents(action: action, requestId: requestId),
            let url = components.url
        else {
            NSLog("FormatKitFinderExtension request %@ URL build failed.", action.rawValue)
            notifyFailure(action: action, message: "Could not build app request URL.")
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func persistTransferRequest(action: TransferAction, urls: [URL], requestStore: RequestStore) throws -> UUID {
        var seen = Set<String>()
        var selectedPaths: [String] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            let key = standardized.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            selectedPaths.append(key)
        }
        guard !selectedPaths.isEmpty else {
            throw TransferRequestStoreError.ioFailure("No selectable file paths were available.")
        }
        NSLog("FormatKitFinderExtension prepared %ld selected path(s).", selectedPaths.count)

        let request = TransferRequest(
            version: TransferRequestDefaults.schemaVersion,
            requestId: UUID(),
            action: action,
            createdAt: Date(),
            selectedItemPaths: selectedPaths
        )
        try requestStore.cleanupExpiredRequests(now: Date(), maxAge: TransferRequestDefaults.maxAge)
        try requestStore.save(request)
        NSLog("FormatKitFinderExtension request saved to app group store.")
        return request.requestId
    }

    private func requestURLComponents(action: TransferAction, requestId: UUID) -> URLComponents? {
        var components = URLComponents()
        components.scheme = "formatkit"
        components.host = action.rawValue
        components.queryItems = [URLQueryItem(name: "requestId", value: requestId.uuidString)]
        return components
    }

    private func notifyFailure(action: TransferAction, message: String) {
        NSLog("FormatKitFinderExtension %@ request failure: %@", action.rawValue, message)
        var components = URLComponents()
        components.scheme = "formatkit"
        components.host = "error"
        components.queryItems = [
            URLQueryItem(name: "action", value: action.rawValue),
            URLQueryItem(name: "message", value: message)
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}
