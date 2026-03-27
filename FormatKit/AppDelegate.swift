import AppKit
@preconcurrency import AVFoundation
import FinderSync
import Foundation
import ImageIO
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let compressionQueue = DispatchQueue(label: "FormatKit.CompressionQueue", qos: .userInitiated)
    private let requestStore: RequestStore? = try? AppGroupTransferRequestStore()
    private let directoryAccessStore = DirectoryAccessStore()
    private var pendingIdleTerminationWorkItem: DispatchWorkItem?
    private var isArchiving = false
    private var progressWindowController: ArchivingProgressWindowController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let requestStore {
            do {
                try requestStore.cleanupExpiredRequests(now: Date(), maxAge: TransferRequestDefaults.maxAge)
            } catch {
                NSLog("FormatKit preflight cleanup failed: %@", error.localizedDescription)
            }
        } else {
            NSLog("FormatKit preflight failed: App Group request store unavailable.")
        }
        if Self.isFinderExtensionEnabled {
            if requestStore == nil {
                presentErrorAndMaybeTerminate(
                    title: "Finder Integration Unavailable",
                    message: "App Group request store is unavailable. Check app group entitlements/provisioning."
                )
                return
            }
            let workItem = DispatchWorkItem {
                NSApp.terminate(nil)
            }
            pendingIdleTerminationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
            return
        }

        presentSettingsWindow()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingIdleTerminationWorkItem?.cancel()
        pendingIdleTerminationWorkItem = nil
        guard let firstURL = urls.first else { return }
        handleIncomingURL(firstURL)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, !Self.isFinderExtensionEnabled else { return false }
        presentSettingsWindow()
        return false
    }

    func presentSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    static func openFinderExtensionSettings() {
        if #available(macOS 10.14, *) {
            FIFinderSyncController.showExtensionManagementInterface()
            return
        }

        guard let url = URL(string: "x-apple.systempreferences:com.apple.Extensions-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static var isFinderExtensionEnabled: Bool {
        if #available(macOS 10.14, *) {
            return FIFinderSyncController.isExtensionEnabled
        }
        return false
    }

    private func handleIncomingURL(_ url: URL) {
        guard !isArchiving else {
            presentErrorAndMaybeTerminate(
                title: "Operation In Progress",
                message: "FormatKit is already processing another selection."
            )
            return
        }

        guard
            url.scheme?.lowercased() == "formatkit",
            let rawAction = url.host?.lowercased(),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            presentErrorAndMaybeTerminate(title: "Invalid Request", message: "The request URL was malformed.")
            return
        }

        if rawAction == "error" {
            let actionName = components.queryItems?.first(where: { $0.name == "action" })?.value?.uppercased() ?? "OPERATION"
            let message = components.queryItems?.first(where: { $0.name == "message" })?.value ?? "Unknown error."
            presentErrorAndMaybeTerminate(title: "\(actionName) Request Failed", message: message)
            return
        }

        guard let action = TransferAction(rawValue: rawAction) else {
            presentErrorAndMaybeTerminate(title: "Invalid Request", message: "Unsupported action: \(rawAction)")
            return
        }

        switch action {
        case .archive:
            handleArchiveRequest(components: components)
        case .convert:
            handleConvertRequest(components: components)
        }
    }

    private func handleArchiveRequest(components: URLComponents) {
        let archiveRequest: ResolvedTransferRequest
        do {
            NSLog("FormatKit decoding archive transfer request.")
            archiveRequest = try decodeTransferRequest(from: components, expectedAction: .archive)
        } catch {
            presentErrorAndMaybeTerminate(
                title: "Archive Request Failed",
                message: requestFailureMessage(for: .archive, error: error)
            )
            return
        }

        let selection: [URL]
        do {
            selection = try validateArchiveSelection(urls: archiveRequest.selection)
        } catch {
            archiveRequest.securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(
                title: "Archive Request Failed",
                message: error.localizedDescription
            )
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let format = presentCompressModal() else {
            archiveRequest.securityScope?.stopAccessing()
            NSApp.terminate(nil)
            return
        }

        let job: ArchiveJob
        do {
            job = try ArchiveJob(selection: selection, format: format, securityScope: archiveRequest.securityScope)
        } catch let error as ArchiveNamingError {
            archiveRequest.securityScope?.stopAccessing()
            let message: String
            switch error {
            case .emptySelection:
                message = "No items were selected to archive."
            case .mixedParentDirectories:
                message = "All selected items must be in the same folder for a single archive."
            }
            presentErrorAndMaybeTerminate(title: "Invalid Selection", message: message)
            return
        } catch {
            archiveRequest.securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(title: "Invalid Selection", message: error.localizedDescription)
            return
        }

        startArchiving(job)
    }

    private func handleConvertRequest(components: URLComponents) {
        let request: ResolvedTransferRequest
        do {
            NSLog("FormatKit decoding convert transfer request.")
            request = try decodeTransferRequest(from: components, expectedAction: .convert)
        } catch {
            presentErrorAndMaybeTerminate(title: "Convert Request Failed", message: requestFailureMessage(for: .convert, error: error))
            return
        }

        if handleVideoConvertRequestIfNeeded(urls: request.selection, securityScope: request.securityScope) {
            return
        }
        if handleImageConvertRequestIfNeeded(urls: request.selection, securityScope: request.securityScope) {
            return
        }

        let selection = request.selection
        do {
            _ = try validateAudioSelection(urls: selection)
        } catch {
            request.securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(
                title: "Convert Request Failed",
                message: error.localizedDescription
            )
            return
        }

        guard let inputFormats = AudioSelectionGate.inputFormats(for: selection) else {
            request.securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(title: "Invalid Selection", message: "All selected items must be supported audio files.")
            return
        }

        let allowedFormats = AudioConversionMatrix.allowedOutputs(for: inputFormats).filter { $0 != .mp3 }
        guard !allowedFormats.isEmpty else {
            request.securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(
                title: "Invalid Selection",
                message: "The selected audio files do not share a common target format."
            )
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let outputFormat = presentConvertModal(allowedFormats: allowedFormats) else {
            request.securityScope?.stopAccessing()
            NSApp.terminate(nil)
            return
        }

        let job = ConvertJob(selection: selection, outputFormat: outputFormat, securityScope: request.securityScope)
        startConverting(job)
    }

    private func handleVideoConvertRequestIfNeeded(urls: [URL], securityScope: SecurityScopedAccessSession?) -> Bool {
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else {
            return false
        }
        guard VideoSelectionGate.isSingleSupportedVideo(urls: urls) else {
            return false
        }

        guard let sourceURL = urls.first else { return false }
        do {
            try validateVideoAssetPreflight(sourceURL: sourceURL)
        } catch {
            securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(title: "Convert Failed", message: error.localizedDescription)
            return true
        }

        guard let sourceInputFormat = VideoInputFormat.fromURL(sourceURL) else {
            return false
        }

        let supportedOutputs = Self.availableVideoOutputFormats(for: sourceURL)
        let allowedOutputs = VideoOutputOptionFilter.alternativeOutputs(
            sourceInput: sourceInputFormat,
            supportedOutputs: supportedOutputs
        )
        guard !allowedOutputs.isEmpty else {
            securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(
                title: "Convert not available for this file.",
                message: "No alternative output formats available."
            )
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let outputFormat = presentVideoConvertModal(allowedFormats: allowedOutputs) else {
            securityScope?.stopAccessing()
            NSApp.terminate(nil)
            return true
        }

        let job = VideoConvertJob(sourceURL: sourceURL, outputFormat: outputFormat, securityScope: securityScope)
        startVideoConverting(job)
        return true
    }

    private func handleImageConvertRequestIfNeeded(urls: [URL], securityScope: SecurityScopedAccessSession?) -> Bool {
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else {
            return false
        }
        guard ImageSelectionGate.allSupportedImages(urls: urls) else {
            return false
        }

        do {
            _ = try validateImageSelection(urls: urls)
        } catch {
            securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(title: "Convert Failed", message: error.localizedDescription)
            return true
        }

        guard let inputFormats = ImageSelectionGate.inputFormats(for: urls) else {
            securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(title: "Invalid Selection", message: "All selected items must be supported image files (JPEG, PNG, HEIC, TIFF).")
            return true
        }

        let allowedOutputs = ImageConversionMatrix.allowedOutputs(
            for: inputFormats,
            supportedBySystem: Self.availableImageOutputFormats()
        )
        guard !allowedOutputs.isEmpty else {
            securityScope?.stopAccessing()
            presentErrorAndMaybeTerminate(
                title: "Convert not available for this selection.",
                message: "No available output formats for the selected image files on this system."
            )
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let outputFormat = presentImageConvertModal(allowedFormats: allowedOutputs) else {
            securityScope?.stopAccessing()
            NSApp.terminate(nil)
            return true
        }

        let job = ImageConvertJob(selection: urls, outputFormat: outputFormat, securityScope: securityScope)
        startImageConverting(job)
        return true
    }

    private func validateCommonSelection(urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else {
            throw ValidationError.emptySelection
        }

        let fileManager = FileManager.default
        for url in urls {
            guard url.isFileURL else {
                throw ValidationError.invalidSelection("Selection contained a non-file URL.")
            }
            guard fileManager.fileExists(atPath: url.path) else {
                throw ValidationError.invalidSelection("Selected item no longer exists: \(url.lastPathComponent)")
            }
        }
        return urls
    }

    private func validateArchiveSelection(urls: [URL]) throws -> [URL] {
        _ = try validateCommonSelection(urls: urls)
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else {
            throw ValidationError.invalidSelection("Selection contains an item that is already an archive.")
        }
        return urls
    }

    private func decodeTransferRequest(from components: URLComponents, expectedAction: TransferAction) throws -> ResolvedTransferRequest {
        let requestId = try parseRequestID(from: components)
        guard let requestStore else {
            throw ValidationError.invalidSelection("Secure request store is unavailable.")
        }

        try requestStore.cleanupExpiredRequests(now: Date(), maxAge: TransferRequestDefaults.maxAge)
        let request = try requestStore.take(requestId: requestId)
        try request.validate(expectedAction: expectedAction, now: Date())

        let resolvedItems = request.selectedItemPaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard !resolvedItems.isEmpty else {
            throw ValidationError.invalidSelection("The request did not contain any selected items.")
        }
        let securityScope = try buildDirectoryScope(for: resolvedItems)
        NSLog("FormatKit resolved transfer request %@ with %ld selected item(s).", requestId.uuidString, resolvedItems.count)
        guard securityScope.startAccessing() else {
            securityScope.stopAccessing()
            throw ValidationError.invalidSelection("Could not access the selected files in the sandbox.")
        }
        NSLog("FormatKit started security scope for request %@.", requestId.uuidString)
        return ResolvedTransferRequest(selection: resolvedItems, securityScope: securityScope)
    }

    private func parseRequestID(from components: URLComponents) throws -> UUID {
        guard
            let requestIdString = components.queryItems?.first(where: { $0.name == "requestId" })?.value,
            let requestId = UUID(uuidString: requestIdString)
        else {
            throw ValidationError.invalidSelection("The request URL was malformed.")
        }
        return requestId
    }

    private func buildDirectoryScope(for selection: [URL]) throws -> SecurityScopedAccessSession {
        let requiredDirectories = Set(selection.map { $0.deletingLastPathComponent().standardizedFileURL })
        var scopeDirectories: [URL] = []
        for requiredDirectory in requiredDirectories {
            let grantedDirectory: URL
            if let existing = try directoryAccessStore.lookupCoveringDirectory(for: requiredDirectory) {
                grantedDirectory = existing
            } else {
                let chosenDirectory = try requestDirectoryAccess(for: requiredDirectory)
                try directoryAccessStore.store(directoryURL: chosenDirectory)
                guard let resolved = try directoryAccessStore.lookupCoveringDirectory(for: requiredDirectory) else {
                    throw ValidationError.invalidSelection("Could not restore granted folder access for \(requiredDirectory.path).")
                }
                grantedDirectory = resolved
            }
            scopeDirectories.append(grantedDirectory)
        }

        guard !scopeDirectories.isEmpty else {
            throw ValidationError.invalidSelection("No accessible directories were granted for this request.")
        }

        return SecurityScopedAccessSession(urls: scopeDirectories)
    }

    private func requestDirectoryAccess(for requiredDirectory: URL) throws -> URL {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = requiredDirectory
        panel.message = "FormatKit needs folder access to create output next to the selected file. Choose this folder or a parent folder to reduce future prompts."
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let chosenDirectory = panel.url?.standardizedFileURL else {
            throw ValidationError.invalidSelection("Folder access was not granted.")
        }

        guard Self.directory(chosenDirectory, covers: requiredDirectory) else {
            throw ValidationError.invalidSelection("The selected folder does not include \(requiredDirectory.path).")
        }

        return chosenDirectory
    }

    fileprivate static func directory(_ grantedDirectory: URL, covers requiredDirectory: URL) -> Bool {
        let grantedPath = grantedDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let requiredPath = requiredDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if grantedPath == "/" {
            return requiredPath.hasPrefix("/")
        }
        if requiredPath == grantedPath {
            return true
        }
        return requiredPath.hasPrefix(grantedPath + "/")
    }

    private func requestFailureMessage(for action: TransferAction, error: Error) -> String {
        switch error {
        case TransferRequestStoreError.malformedRequest:
            return "The \(action.rawValue) request payload was malformed."
        case TransferRequestStoreError.staleRequest:
            return "The \(action.rawValue) request expired. Try again from Finder."
        case TransferRequestStoreError.actionMismatch:
            return "The request type did not match the requested action."
        case TransferRequestStoreError.schemaMismatch:
            return "The request version is incompatible with this app build."
        case TransferRequestStoreError.requestNotFound:
            return "The request was not found. Try again from Finder."
        default:
            return error.localizedDescription
        }
    }

    private func validateAudioSelection(urls: [URL]) throws -> [URL] {
        let validatedURLs = try validateCommonSelection(urls: urls)
        guard !ArchiveSelectionGate.containsArchivedItem(urls: validatedURLs) else {
            throw ValidationError.invalidSelection("Selection contains an archived item.")
        }
        guard AudioSelectionGate.allSupportedAudio(urls: validatedURLs) else {
            throw ValidationError.invalidSelection("Selection must contain only supported audio files (mp3, m4a, wav, aiff, flac).")
        }
        return validatedURLs
    }

    private func validateImageSelection(urls: [URL]) throws -> [URL] {
        let validatedURLs = try validateCommonSelection(urls: urls)
        guard !ArchiveSelectionGate.containsArchivedItem(urls: validatedURLs) else {
            throw ValidationError.invalidSelection("Selection contains an archived item.")
        }
        guard ImageSelectionGate.allSupportedImages(urls: validatedURLs) else {
            throw ValidationError.invalidSelection("All selected items must be supported image files (JPEG, PNG, HEIC, TIFF).")
        }
        return validatedURLs
    }

    private func validateVideoAssetPreflight(sourceURL: URL) throws {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = loadVideoTracksSync(from: asset)
        guard !videoTracks.isEmpty else {
            throw VideoPreflightError.noVideoTrack
        }
    }

    private func presentCompressModal() -> ArchiveFormat? {
        ArchiveOptionsPanel.present()
    }

    private func presentConvertModal(allowedFormats: [AudioOutputFormat]) -> AudioOutputFormat? {
        ConvertOptionsPanel.presentAudio(allowedFormats: allowedFormats)
    }

    private func presentVideoConvertModal(allowedFormats options: [VideoOutputFormat]) -> VideoOutputFormat? {
        ConvertOptionsPanel.presentVideo(allowedFormats: options)
    }

    private func presentImageConvertModal(allowedFormats options: [ImageOutputFormat]) -> ImageOutputFormat? {
        ConvertOptionsPanel.presentImage(allowedFormats: options)
    }

    private func startArchiving(_ job: ArchiveJob) {
        isArchiving = true
        let progressWindowController = ArchivingProgressWindowController(statusText: "Archiving…")
        self.progressWindowController = progressWindowController
        progressWindowController.show()

        compressionQueue.async { [job] in
            let result = Self.runArchive(job)
            DispatchQueue.main.async {
                job.securityScope?.stopAccessing()
                self.progressWindowController?.close()
                self.progressWindowController = nil
                self.isArchiving = false
                self.presentArchiveCompletion(for: result, outputURL: job.outputURL)
            }
        }
    }

    private func startConverting(_ job: ConvertJob) {
        isArchiving = true
        let progressWindowController = ArchivingProgressWindowController(statusText: "Converting")
        self.progressWindowController = progressWindowController
        progressWindowController.show()

        compressionQueue.async { [job] in
            let result = Self.runConversions(job)
            DispatchQueue.main.async {
                job.securityScope?.stopAccessing()
                self.progressWindowController?.close()
                self.progressWindowController = nil
                self.isArchiving = false
                self.presentConvertCompletion(for: result)
            }
        }
    }

    private func startVideoConverting(_ job: VideoConvertJob) {
        isArchiving = true
        let progressWindowController = ArchivingProgressWindowController(statusText: "Converting")
        self.progressWindowController = progressWindowController
        progressWindowController.show()

        compressionQueue.async { [job] in
            let result = Self.runVideoConversion(job)
            DispatchQueue.main.async {
                job.securityScope?.stopAccessing()
                self.progressWindowController?.close()
                self.progressWindowController = nil
                self.isArchiving = false
                self.presentConvertCompletion(for: result)
            }
        }
    }

    private func startImageConverting(_ job: ImageConvertJob) {
        isArchiving = true
        let progressWindowController = ArchivingProgressWindowController(statusText: "Converting")
        self.progressWindowController = progressWindowController
        progressWindowController.show()

        compressionQueue.async { [job] in
            let result = Self.runImageConversions(job)
            DispatchQueue.main.async {
                job.securityScope?.stopAccessing()
                self.progressWindowController?.close()
                self.progressWindowController = nil
                self.isArchiving = false
                self.presentConvertCompletion(for: result)
            }
        }
    }

    private func presentArchiveCompletion(for result: ArchiveRunResult, outputURL: URL) {
        switch result {
        case .success:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Archive Complete"
            alert.informativeText = outputURL.path
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failure(let details):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Archive Failed"
            alert.informativeText = details.userFacingMessage
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            if !details.diagnosticOutput.isEmpty {
                NSLog("FormatKit archive error output:\n%@", details.diagnosticOutput)
            }
        }

        NSApp.terminate(nil)
    }

    private func presentConvertCompletion(for result: ConvertRunResult) {
        switch result {
        case .success(let outputURLs):
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Convert Complete"
            if outputURLs.count == 1, let outputURL = outputURLs.first {
                alert.informativeText = outputURL.path
            } else {
                alert.informativeText = "Converted \(outputURLs.count) files."
            }
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
        case .failure(let details):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Convert Failed"
            alert.informativeText = details.userFacingMessage
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            if !details.diagnosticOutput.isEmpty {
                NSLog("FormatKit convert error output:\n%@", details.diagnosticOutput)
            }
        }

        NSApp.terminate(nil)
    }

    private func presentErrorAndMaybeTerminate(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
        if !isArchiving {
            NSApp.terminate(nil)
        }
    }

    nonisolated private static func runArchive(_ job: ArchiveJob) -> ArchiveRunResult {
        let process = Process()
        process.executableURL = job.format.executableURL
        process.currentDirectoryURL = job.workingDirectory
        process.arguments = job.format.processArguments(
            outputFileName: job.outputURL.lastPathComponent,
            relativeItemNames: job.relativeItemNames
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let diagnosticsLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            diagnosticsLock.lock()
            stdoutData.append(chunk)
            diagnosticsLock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            diagnosticsLock.lock()
            stderrData.append(chunk)
            diagnosticsLock.unlock()
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(
                ArchiveFailureDetails(
                    userFacingMessage: "Failed to launch the archive tool: \(error.localizedDescription)",
                    diagnosticOutput: ""
                )
            )
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        diagnosticsLock.lock()
        stdoutData.append(remainingStdout)
        stderrData.append(remainingStderr)
        let finalStdoutData = stdoutData
        let finalStderrData = stderrData
        diagnosticsLock.unlock()
        let stdout = decodedDiagnosticOutput(from: finalStdoutData)
        let stderr = decodedDiagnosticOutput(from: finalStderrData)
        let combinedDiagnostics = [stderr, stdout]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")

        guard process.terminationStatus == 0 else {
            let snippet = diagnosticSnippet(from: stderr.isEmpty ? stdout : stderr)
            let message = snippet.isEmpty
                ? "The archive tool exited with status \(process.terminationStatus)."
                : "The archive tool exited with status \(process.terminationStatus).\n\n\(snippet)"
            return .failure(ArchiveFailureDetails(userFacingMessage: message, diagnosticOutput: combinedDiagnostics))
        }

        guard isValidOutputFile(at: job.outputURL) else {
            let snippet = diagnosticSnippet(from: stderr.isEmpty ? stdout : stderr)
            let message = snippet.isEmpty
                ? "Archive command finished, but the output file was missing or empty."
                : "Archive command finished, but the output file was missing or empty.\n\n\(snippet)"
            return .failure(ArchiveFailureDetails(userFacingMessage: message, diagnosticOutput: combinedDiagnostics))
        }

        return .success
    }

    nonisolated private static func runConversions(_ job: ConvertJob) -> ConvertRunResult {
        var outputURLs: [URL] = []
        for task in job.tasks {
            let singleResult = runSingleConversion(task)
            switch singleResult {
            case .success(let outputURL):
                outputURLs.append(outputURL)
            case .failure(let details):
                return .failure(details)
            }
        }
        return .success(outputURLs)
    }

    nonisolated private static func runVideoConversion(_ job: VideoConvertJob) -> ConvertRunResult {
        switch runSingleVideoConversion(job) {
        case .success(let outputURL):
            return .success([outputURL])
        case .failure(let details):
            return .failure(details)
        }
    }

    nonisolated private static func runImageConversions(_ job: ImageConvertJob) -> ConvertRunResult {
        var outputURLs: [URL] = []
        for task in job.tasks {
            let singleResult = runSingleImageConversion(task)
            switch singleResult {
            case .success(let outputURL):
                outputURLs.append(outputURL)
            case .failure(let details):
                return .failure(details)
            }
        }
        return .success(outputURLs)
    }

    nonisolated private static func runSingleVideoConversion(_ job: VideoConvertJob) -> ConvertSingleResult {
        if job.outputFormat == .gif {
            return runSingleVideoToGIFConversion(job)
        }

        let asset = AVURLAsset(url: job.sourceURL)
        let presetName = videoExportPresetName(sourceURL: job.sourceURL, outputFormat: job.outputFormat)

        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to create a video export session.",
                    diagnosticOutput: "AVAssetExportSession init returned nil for preset \(presetName)"
                )
            )
        }

        let outputFileType = job.outputFormat.avFileType
        guard session.supportedFileTypes.contains(outputFileType) else {
            let supportedTypesDescription = session.supportedFileTypes.map(\.rawValue).joined(separator: ", ")
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "The selected output format is not supported for this file.",
                    diagnosticOutput: "Unsupported file type \(outputFileType.rawValue); supported: \(supportedTypesDescription)"
                )
            )
        }

        session.shouldOptimizeForNetworkUse = false

        do {
            try exportVideoSync(session: session, to: job.outputURL, as: outputFileType)
            guard isValidOutputFile(at: job.outputURL) else {
                return .failure(
                    ConvertFailureDetails(
                        userFacingMessage: "Convert finished, but the output file was missing or empty.",
                        diagnosticOutput: job.outputURL.path
                    )
                )
            }
            guard outputContainerMatchesSelection(outputURL: job.outputURL, expectedFormat: job.outputFormat) else {
                return .failure(
                    ConvertFailureDetails(
                        userFacingMessage: "Convert finished, but the output file format did not match the selected container.",
                        diagnosticOutput: "Expected \(job.outputFormat.fileExtension), got \(job.outputURL.pathExtension.lowercased())"
                    )
                )
            }
            return .success(job.outputURL)
        } catch {
            let message = (error as NSError).localizedDescription
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to convert \(job.sourceURL.lastPathComponent).\n\n\(message)",
                    diagnosticOutput: String(describing: error)
                )
            )
        }
    }

    nonisolated private static func runSingleVideoToGIFConversion(_ job: VideoConvertJob) -> ConvertSingleResult {
        let asset = AVURLAsset(url: job.sourceURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        guard VideoGIFConstraints.isSupportedDuration(durationSeconds) else {
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "GIF conversion supports videos up to 10 seconds. Please trim the video and try again.",
                    diagnosticOutput: "GIF duration check failed: \(durationSeconds)s"
                )
            )
        }

        let startedAt = Date()
        let frameTimes = gifFrameTimes(durationSeconds: durationSeconds)
        var lastOversizedBytes: Int64 = 0
        for maxDimension in VideoGIFConstraints.fallbackPixelDimensions {
            switch encodeVideoToGIF(
                asset: asset,
                outputURL: job.outputURL,
                frameTimes: frameTimes,
                maxDimension: maxDimension,
                startedAt: startedAt
            ) {
            case .success:
                return .success(job.outputURL)
            case .oversized(let bytes):
                lastOversizedBytes = bytes
                continue
            case .timedOut:
                return .failure(
                    ConvertFailureDetails(
                        userFacingMessage: "GIF conversion took too long and was stopped. Please try a shorter or smaller video.",
                        diagnosticOutput: "GIF conversion timed out after \(VideoGIFConstraints.timeoutSeconds)s."
                    )
                )
            case .failure(let details):
                return .failure(details)
            }
        }

        try? FileManager.default.removeItem(at: job.outputURL)
        return .failure(
            ConvertFailureDetails(
                userFacingMessage: "The GIF would be too large to be practical. Please use a shorter or smaller video and try again.",
                diagnosticOutput: "GIF output size \(lastOversizedBytes) exceeded limit \(VideoGIFConstraints.maxOutputBytes)."
            )
        )
    }

    nonisolated private static func runSingleConversion(_ task: ConvertTask) -> ConvertSingleResult {
        do {
            let inputFile = try AVAudioFile(forReading: task.sourceURL)
            let outputConfig = try makeOutputAudioConfiguration(for: task.outputFormat, sourceFile: inputFile)

            let outputFile = try AVAudioFile(
                forWriting: task.outputURL,
                settings: outputConfig.fileSettings,
                commonFormat: outputConfig.clientCommonFormat,
                interleaved: outputConfig.clientInterleaved
            )

            guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFile.processingFormat) else {
                throw ConvertEngineError.converterInitializationFailed
            }

            let inputFrameCapacity: AVAudioFrameCount = 4096
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFile.processingFormat,
                frameCapacity: inputFrameCapacity
            ) else {
                throw ConvertEngineError.inputBufferAllocationFailed
            }

            let sampleRateRatio: Double
            if inputFile.processingFormat.sampleRate > 0 {
                sampleRateRatio = outputFile.processingFormat.sampleRate / inputFile.processingFormat.sampleRate
            } else {
                sampleRateRatio = 1
            }
            let estimatedOutputCapacity = max(
                Int(inputFrameCapacity),
                Int((Double(inputFrameCapacity) * max(sampleRateRatio, 1)) + 1024)
            )

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFile.processingFormat,
                frameCapacity: AVAudioFrameCount(estimatedOutputCapacity)
            ) else {
                throw ConvertEngineError.outputBufferAllocationFailed
            }

            var reachedEOF = false
            var pendingReadError: Error?

            while true {
                outputBuffer.frameLength = 0
                var inputProvidedForThisCall = false
                var conversionError: NSError?

                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                    if let _ = pendingReadError {
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    if reachedEOF {
                        outStatus.pointee = .endOfStream
                        return nil
                    }

                    if inputProvidedForThisCall {
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    do {
                        inputBuffer.frameLength = 0
                        try inputFile.read(into: inputBuffer, frameCount: inputFrameCapacity)
                    } catch {
                        pendingReadError = error
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    if inputBuffer.frameLength == 0 {
                        reachedEOF = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }

                    inputProvidedForThisCall = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                }

                if let pendingReadError {
                    throw pendingReadError
                }

                if outputBuffer.frameLength > 0 {
                    try outputFile.write(from: outputBuffer)
                }

                switch status {
                case .haveData, .inputRanDry:
                    continue
                case .endOfStream:
                    guard isValidOutputFile(at: task.outputURL) else {
                        return .failure(
                            ConvertFailureDetails(
                                userFacingMessage: "Convert finished, but the output file was missing or empty.",
                                diagnosticOutput: task.outputURL.path
                            )
                        )
                    }
                    return .success(task.outputURL)
                case .error:
                    if let conversionError {
                        throw conversionError
                    }
                    throw ConvertEngineError.conversionFailedWithoutUnderlyingError
                @unknown default:
                    if let conversionError {
                        throw conversionError
                    }
                    throw ConvertEngineError.unexpectedConverterStatus
                }
            }
        } catch {
            // AVAudioConverter may surface a terminal bridged NSError after writing valid output.
            // Prefer the observable result (a non-empty output file) over the terminal status in that case.
            if isValidOutputFile(at: task.outputURL) {
                return .success(task.outputURL)
            }
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to convert \(task.sourceURL.lastPathComponent).\n\n\(error.localizedDescription)",
                    diagnosticOutput: String(describing: error)
                )
            )
        }
    }

    nonisolated private static func runSingleImageConversion(_ task: ImageConvertTask) -> ConvertSingleResult {
        let sourcePath = task.sourceURL.path as CFString
        guard let source = CGImageSourceCreateWithURL(task.sourceURL as CFURL, nil) else {
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to convert \(task.sourceURL.lastPathComponent).\n\nThe source image could not be opened.",
                    diagnosticOutput: "CGImageSourceCreateWithURL returned nil for \(task.sourceURL.path)"
                )
            )
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to convert \(task.sourceURL.lastPathComponent).\n\nThe source image data is invalid.",
                    diagnosticOutput: "CGImageSourceCreateImageAtIndex returned nil for \(sourcePath)"
                )
            )
        }

        guard let destination = CGImageDestinationCreateWithURL(
            task.outputURL as CFURL,
            task.outputFormat.destinationUTTypeIdentifier as CFString,
            1,
            nil
        ) else {
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to convert \(task.sourceURL.lastPathComponent).\n\nThe selected output format is not available on this system.",
                    diagnosticOutput: "CGImageDestinationCreateWithURL returned nil for UTI \(task.outputFormat.destinationUTTypeIdentifier)"
                )
            )
        }

        let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        CGImageDestinationAddImage(destination, image, metadata)
        guard CGImageDestinationFinalize(destination) else {
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to convert \(task.sourceURL.lastPathComponent).\n\nImage export did not complete successfully.",
                    diagnosticOutput: "CGImageDestinationFinalize returned false for \(task.outputURL.path)"
                )
            )
        }

        guard isValidOutputFile(at: task.outputURL) else {
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Convert finished, but the output file was missing or empty.",
                    diagnosticOutput: task.outputURL.path
                )
            )
        }
        return .success(task.outputURL)
    }

    nonisolated private static func isValidOutputFile(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        guard let fileSize = attributes[.size] as? NSNumber else { return false }
        return fileManager.fileExists(atPath: url.path) && fileSize.int64Value > 0
    }

    nonisolated private static func videoExportPresetName(sourceURL: URL, outputFormat: VideoOutputFormat) -> String {
        let sourceContainer = videoContainerKind(for: sourceURL)
        let targetContainer = outputFormat.containerKind
        if sourceContainer == targetContainer {
            return AVAssetExportPresetPassthrough
        }
        return AVAssetExportPresetHighestQuality
    }

    nonisolated private static func videoContainerKind(for url: URL) -> VideoContainerKind? {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v":
            return .mp4Family
        case "mov":
            return .mov
        default:
            return nil
        }
    }

    nonisolated private static func outputContainerMatchesSelection(outputURL: URL, expectedFormat: VideoOutputFormat) -> Bool {
        outputURL.pathExtension.lowercased() == expectedFormat.fileExtension
    }

    nonisolated private static func availableVideoOutputFormats(for sourceURL: URL) -> [VideoOutputFormat] {
        let asset = AVURLAsset(url: sourceURL)
        return VideoOutputFormat.allCases.filter { outputFormat in
            if outputFormat == .gif {
                return supportsGIFOutput()
            }
            let presetName = videoExportPresetName(sourceURL: sourceURL, outputFormat: outputFormat)
            guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
                return false
            }
            return session.supportedFileTypes.contains(outputFormat.avFileType)
        }
    }

    nonisolated private static func supportsGIFOutput() -> Bool {
        let availableTypeIdentifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return availableTypeIdentifiers.contains("com.compuserve.gif")
    }

    nonisolated private static func gifFrameTimes(durationSeconds: Double) -> [CMTime] {
        let interval = VideoGIFConstraints.frameDelaySeconds
        let frameCount = max(1, Int(floor(durationSeconds / interval)))
        return (0..<frameCount).map { index in
            let seconds = min(Double(index) * interval, max(durationSeconds - 0.001, 0))
            return CMTime(seconds: seconds, preferredTimescale: 600)
        }
    }

    nonisolated private static func encodeVideoToGIF(
        asset: AVAsset,
        outputURL: URL,
        frameTimes: [CMTime],
        maxDimension: CGFloat,
        startedAt: Date
    ) -> GIFEncodeAttemptResult {
        try? FileManager.default.removeItem(at: outputURL)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            "com.compuserve.gif" as CFString,
            0,
            nil
        ) else {
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to convert video to GIF.\n\nGIF export is not available on this system.",
                    diagnosticOutput: "CGImageDestinationCreateWithURL returned nil for GIF destination."
                )
            )
        }

        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: VideoGIFConstraints.frameDelaySeconds
            ]
        ]

        for frameTime in frameTimes {
            if Date().timeIntervalSince(startedAt) > VideoGIFConstraints.timeoutSeconds {
                try? FileManager.default.removeItem(at: outputURL)
                return .timedOut
            }

            do {
                let image = try generator.copyCGImage(at: frameTime, actualTime: nil)
                CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                return .failure(
                    ConvertFailureDetails(
                        userFacingMessage: "Failed to convert video to GIF.\n\nThe video frames could not be processed.",
                        diagnosticOutput: String(describing: error)
                    )
                )
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to convert video to GIF.\n\nGIF export did not complete successfully.",
                    diagnosticOutput: "CGImageDestinationFinalize returned false for \(outputURL.path)"
                )
            )
        }

        guard isValidOutputFile(at: outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Convert finished, but the output file was missing or empty.",
                    diagnosticOutput: outputURL.path
                )
            )
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > VideoGIFConstraints.maxOutputBytes {
            try? FileManager.default.removeItem(at: outputURL)
            return .oversized(fileSize)
        }

        return .success
    }

    nonisolated private static func availableImageOutputFormats() -> [ImageOutputFormat] {
        let availableTypeIdentifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let availableSet = Set(availableTypeIdentifiers)
        return ImageOutputFormat.allCases.filter { availableSet.contains($0.destinationUTTypeIdentifier) }
    }

    nonisolated private static func diagnosticSnippet(from text: String, maxLines: Int = 20) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .prefix(maxLines)
            .joined(separator: "\n")
    }

    nonisolated private static func decodedDiagnosticOutput(from data: Data, byteLimit: Int = 16_384) -> String {
        let truncated = data.count > byteLimit ? data.prefix(byteLimit) : data[...]
        return String(data: Data(truncated), encoding: .utf8) ?? ""
    }

    private func loadVideoTracksSync(from asset: AVURLAsset) -> [AVAssetTrack] {
        if #available(macOS 15.0, *) {
            let resultBox = SyncResultBox<Result<[AVAssetTrack], Error>?>(nil)
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    resultBox.value = .success(tracks)
                } catch {
                    resultBox.value = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()
            switch resultBox.value {
            case .success(let tracks):
                return tracks
            case .failure:
                return []
            case .none:
                return []
            }
        } else {
            return loadVideoTracksSyncLegacy(from: asset)
        }
    }

    nonisolated private static func exportVideoSync(
        session: AVAssetExportSession,
        to outputURL: URL,
        as outputFileType: AVFileType
    ) throws {
        if #available(macOS 15.0, *) {
            let resultBox = SyncResultBox<Result<Void, Error>?>(nil)
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    try await session.export(to: outputURL, as: outputFileType)
                    resultBox.value = .success(())
                } catch {
                    resultBox.value = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()
            switch resultBox.value {
            case .success:
                return
            case .failure(let error):
                throw error
            case .none:
                throw VideoExportError.noResult
            }
        } else {
            try exportVideoSyncLegacy(session: session, to: outputURL, as: outputFileType)
        }
    }

    @available(macOS, introduced: 11.0, deprecated: 15.0)
    nonisolated private static func exportVideoSyncLegacy(
        session: AVAssetExportSession,
        to outputURL: URL,
        as outputFileType: AVFileType
    ) throws {
        session.outputURL = outputURL
        session.outputFileType = outputFileType
        session.shouldOptimizeForNetworkUse = false

        let semaphore = DispatchSemaphore(value: 0)
        session.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()

        switch session.status {
        case .completed:
            return
        case .failed:
            throw session.error ?? VideoExportError.unknownFailure
        case .cancelled:
            throw VideoExportError.cancelled
        default:
            throw VideoExportError.unexpectedStatus(rawValue: session.status.rawValue, underlying: session.error)
        }
    }

    @available(macOS, introduced: 11.0, deprecated: 15.0)
    private func loadVideoTracksSyncLegacy(from asset: AVURLAsset) -> [AVAssetTrack] {
        asset.tracks(withMediaType: .video)
    }
}

private struct AppBundleMetadata {
    let appName: String
    let shortVersion: String

    static var current: AppBundleMetadata {
        let bundle = Bundle.main
        let appName =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ProcessInfo.processInfo.processName

        let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"

        return AppBundleMetadata(
            appName: appName.isEmpty ? "FormatKit" : appName,
            shortVersion: shortVersion
        )
    }
}

private struct SettingsActivationView: View {
    private let metadata = AppBundleMetadata.current
    private let privacyPolicyURL = URL(string: "https://github.com/ajbeaver/FormatKit#readme")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(metadata.appName)
                .font(.system(size: 26, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Right-click files in Finder to archive or convert them.")
                Text("Enable the Finder extension to use FormatKit in Finder.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Enable Finder Extension") {
                    AppDelegate.openFinderExtensionSettings()
                }
                .keyboardShortcut(.defaultAction)

                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Text("\(metadata.appName) v\(metadata.shortVersion)")
                Link("Privacy Policy", destination: privacyPolicyURL)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520, height: 220, alignment: .topLeading)
    }
}

private final class SettingsWindowController: NSWindowController {
    init() {
        let hostingController = NSHostingController(rootView: SettingsActivationView())
        let window = NSWindow(
            contentViewController: hostingController
        )
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 220))
        window.center()

        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class DirectoryAccessStore {
    private let defaults: UserDefaults
    static let storageKey = "FinderGrantedDirectoryBookmarks"

    init(defaults: UserDefaults = UserDefaults(suiteName: TransferRequestDefaults.appGroupIdentifier) ?? .standard) {
        self.defaults = defaults
    }

    func lookupCoveringDirectory(for requiredDirectory: URL) throws -> URL? {
        let required = canonicalize(requiredDirectory)
        var bookmarkMap = rawBookmarkMap()
        var changed = false
        var resolvedPairs: [(path: String, url: URL)] = []

        for (key, bookmarkData) in bookmarkMap {
            do {
                let resolved = try resolveBookmark(bookmarkData)
                let resolvedPath = canonicalize(resolved).path
                guard resolvedPath == key else {
                    bookmarkMap.removeValue(forKey: key)
                    changed = true
                    continue
                }
                resolvedPairs.append((key, canonicalize(resolved)))
            } catch {
                bookmarkMap.removeValue(forKey: key)
                changed = true
            }
        }

        if changed {
            defaults.set(bookmarkMap, forKey: Self.storageKey)
        }

        return resolvedPairs
            .filter { AppDelegate.directory($0.url, covers: required) }
            .max { $0.path.count < $1.path.count }?
            .url
    }

    func store(directoryURL: URL) throws {
        let canonical = canonicalize(directoryURL)
        let bookmarkData = try canonical.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarkMap = rawBookmarkMap()
        bookmarkMap[canonical.path] = bookmarkData
        defaults.set(bookmarkMap, forKey: Self.storageKey)
    }

    private func rawBookmarkMap() -> [String: Data] {
        defaults.dictionary(forKey: Self.storageKey) as? [String: Data] ?? [:]
    }

    private func resolveBookmark(_ bookmarkData: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL
        if isStale {
            throw TransferRequestStoreError.staleRequest
        }
        return url
    }

    private func canonicalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private enum ValidationError: LocalizedError {
    case emptySelection
    case invalidSelection(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No items were selected."
        case .invalidSelection(let message):
            return message
        }
    }
}

private enum VideoPreflightError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The selected file does not contain a video track."
        }
    }
}

private nonisolated enum VideoExportError: LocalizedError {
    case cancelled
    case unknownFailure
    case noResult
    case unexpectedStatus(rawValue: Int, underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The operation was cancelled."
        case .unknownFailure:
            return "Unknown AVFoundation export error."
        case .noResult:
            return "The video export did not return a result."
        case .unexpectedStatus:
            return "Video export did not complete successfully."
        }
    }
}

// Narrow sync bridge for `Task.detached` results used only with a semaphore handoff.
nonisolated private final class SyncResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    nonisolated init(_ initialValue: T) {
        storage = initialValue
    }

    nonisolated(unsafe) var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private struct ResolvedTransferRequest {
    let selection: [URL]
    let securityScope: SecurityScopedAccessSession?
}

private final class SecurityScopedAccessSession {
    private let urls: [URL]
    private let lock = NSLock()
    private var activeURLs: [URL] = []
    private var isStopped = false

    init(urls: [URL]) {
        var seen = Set<String>()
        self.urls = urls.compactMap { url in
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return url.standardizedFileURL
        }
    }

    func startAccessing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeURLs.isEmpty else { return true }

        var didStartAll = true
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                activeURLs.append(url)
            } else {
                didStartAll = false
            }
        }
        return didStartAll
    }

    func stopAccessing() {
        lock.lock()
        if isStopped {
            lock.unlock()
            return
        }
        isStopped = true
        let urlsToStop = activeURLs
        activeURLs.removeAll()
        lock.unlock()

        for url in urlsToStop {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

private struct ArchiveJob {
    let selection: [URL]
    let format: ArchiveFormat
    let workingDirectory: URL
    let relativeItemNames: [String]
    let outputURL: URL
    let securityScope: SecurityScopedAccessSession?

    init(selection: [URL], format: ArchiveFormat, securityScope: SecurityScopedAccessSession?, now: Date = Date()) throws {
        self.selection = selection
        self.format = format
        self.securityScope = securityScope
        workingDirectory = try ArchiveNameBuilder.commonParentDirectory(for: selection)
        relativeItemNames = try ArchiveNameBuilder.relativeItemNames(for: selection)
        outputURL = try ArchiveNameBuilder.outputURL(for: selection, format: format, now: now)
    }
}

private struct ConvertJob {
    let selection: [URL]
    let outputFormat: AudioOutputFormat
    let tasks: [ConvertTask]
    let securityScope: SecurityScopedAccessSession?

    init(selection: [URL], outputFormat: AudioOutputFormat, securityScope: SecurityScopedAccessSession?) {
        self.selection = selection
        self.outputFormat = outputFormat
        self.securityScope = securityScope
        self.tasks = selection.map { ConvertTask(sourceURL: $0, outputURL: ConvertNameBuilder.outputURL(for: $0, outputFormat: outputFormat), outputFormat: outputFormat) }
    }
}

private struct ConvertTask {
    let sourceURL: URL
    let outputURL: URL
    let outputFormat: AudioOutputFormat
}

private struct ImageConvertJob {
    let selection: [URL]
    let outputFormat: ImageOutputFormat
    let tasks: [ImageConvertTask]
    let securityScope: SecurityScopedAccessSession?

    init(selection: [URL], outputFormat: ImageOutputFormat, securityScope: SecurityScopedAccessSession?) {
        self.selection = selection
        self.outputFormat = outputFormat
        self.securityScope = securityScope
        self.tasks = selection.map {
            ImageConvertTask(
                sourceURL: $0,
                outputURL: ImageConvertNameBuilder.outputURL(for: $0, outputFormat: outputFormat),
                outputFormat: outputFormat
            )
        }
    }
}

private struct ImageConvertTask {
    let sourceURL: URL
    let outputURL: URL
    let outputFormat: ImageOutputFormat
}

private struct VideoConvertJob {
    let sourceURL: URL
    let outputFormat: VideoOutputFormat
    let outputURL: URL
    let securityScope: SecurityScopedAccessSession?

    init(sourceURL: URL, outputFormat: VideoOutputFormat, securityScope: SecurityScopedAccessSession?) {
        self.sourceURL = sourceURL
        self.outputFormat = outputFormat
        self.securityScope = securityScope
        self.outputURL = VideoConvertNameBuilder.outputURL(for: sourceURL, outputFormat: outputFormat)
    }
}

private enum ArchiveRunResult {
    case success
    case failure(ArchiveFailureDetails)
}

private struct ArchiveFailureDetails {
    let userFacingMessage: String
    let diagnosticOutput: String
}

private enum ConvertRunResult {
    case success([URL])
    case failure(ConvertFailureDetails)
}

private enum ConvertSingleResult {
    case success(URL)
    case failure(ConvertFailureDetails)
}

private struct ConvertFailureDetails {
    let userFacingMessage: String
    let diagnosticOutput: String
}

private enum GIFEncodeAttemptResult {
    case success
    case oversized(Int64)
    case timedOut
    case failure(ConvertFailureDetails)
}

private nonisolated struct ConvertOutputAudioConfiguration {
    let fileSettings: [String: Any]
    let clientCommonFormat: AVAudioCommonFormat
    let clientInterleaved: Bool
}

private nonisolated enum ConvertEngineError: LocalizedError {
    case unsupportedOutputFormat
    case invalidOutputConfiguration
    case converterInitializationFailed
    case inputBufferAllocationFailed
    case outputBufferAllocationFailed
    case conversionFailedWithoutUnderlyingError
    case unexpectedConverterStatus

    var errorDescription: String? {
        switch self {
        case .unsupportedOutputFormat:
            return "The selected output format is not supported."
        case .invalidOutputConfiguration:
            return "Could not build audio output settings."
        case .converterInitializationFailed:
            return "Could not initialize the audio converter."
        case .inputBufferAllocationFailed:
            return "Could not allocate the input audio buffer."
        case .outputBufferAllocationFailed:
            return "Could not allocate the output audio buffer."
        case .conversionFailedWithoutUnderlyingError:
            return "Audio conversion failed."
        case .unexpectedConverterStatus:
            return "Audio conversion returned an unexpected status."
        }
    }
}

private nonisolated enum VideoContainerKind {
    case mp4Family
    case mov
}

private final class ArchivingProgressWindowController: NSWindowController {
    private let statusLabel: NSTextField

    init(statusText: String = "Archiving…") {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "FormatKit"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.standardWindowButton(.closeButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: statusText)
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(spinner)
        contentView.addSubview(statusLabel)
        window.contentView = contentView

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])

        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private nonisolated func makeOutputAudioConfiguration(
    for format: AudioOutputFormat,
    sourceFile: AVAudioFile
) throws -> ConvertOutputAudioConfiguration {
    let sourceFormat = sourceFile.processingFormat
    let sourceChannelCount = max(1, Int(sourceFormat.channelCount))
    let sourceSampleRate = sourceFormat.sampleRate > 0 ? sourceFormat.sampleRate : 44_100

    switch format {
    case .m4a:
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceSampleRate,
            AVNumberOfChannelsKey: sourceChannelCount,
            AVEncoderBitRateKey: 192_000
        ]
        guard AVAudioFormat(settings: fileSettings) != nil else {
            throw ConvertEngineError.invalidOutputConfiguration
        }
        return ConvertOutputAudioConfiguration(
            fileSettings: fileSettings,
            clientCommonFormat: .pcmFormatFloat32,
            clientInterleaved: false
        )
    case .wav:
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sourceSampleRate,
            AVNumberOfChannelsKey: sourceChannelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard AVAudioFormat(settings: fileSettings) != nil else {
            throw ConvertEngineError.invalidOutputConfiguration
        }
        return ConvertOutputAudioConfiguration(
            fileSettings: fileSettings,
            clientCommonFormat: .pcmFormatInt16,
            clientInterleaved: true
        )
    case .aiff:
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sourceSampleRate,
            AVNumberOfChannelsKey: sourceChannelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard AVAudioFormat(settings: fileSettings) != nil else {
            throw ConvertEngineError.invalidOutputConfiguration
        }
        return ConvertOutputAudioConfiguration(
            fileSettings: fileSettings,
            clientCommonFormat: .pcmFormatInt16,
            clientInterleaved: true
        )
    case .mp3:
        throw ConvertEngineError.unsupportedOutputFormat
    }
}

private extension VideoOutputFormat {
    nonisolated var avFileType: AVFileType {
        switch self {
        case .mp4:
            return .mp4
        case .mov:
            return .mov
        case .m4v:
            return .m4v
        case .gif:
            return .mov
        }
    }

    nonisolated var containerKind: VideoContainerKind {
        switch self {
        case .mp4:
            return .mp4Family
        case .mov:
            return .mov
        case .m4v:
            return .mp4Family
        case .gif:
            return .mp4Family
        }
    }
}
