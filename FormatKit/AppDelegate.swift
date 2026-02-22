import AppKit
import AVFoundation
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let compressionQueue = DispatchQueue(label: "FormatKit.CompressionQueue", qos: .userInitiated)
    private var isArchiving = false
    private var progressWindowController: ArchivingProgressWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let firstURL = urls.first else { return }
        handleIncomingURL(firstURL)
    }

    static func openFinderExtensionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Extensions-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
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
            let action = url.host?.lowercased(),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let rawPaths = decodePaths(from: components)
        else {
            presentErrorAndMaybeTerminate(title: "Invalid Request", message: "The request URL was malformed.")
            return
        }

        switch action {
        case "archive":
            handleArchiveRequest(rawPaths: rawPaths)
        case "convert":
            handleConvertRequest(rawPaths: rawPaths)
        default:
            presentErrorAndMaybeTerminate(title: "Invalid Request", message: "Unsupported action: \(action)")
        }
    }

    private func decodePaths(from components: URLComponents) -> [String]? {
        guard
            let encodedPaths = components.queryItems?.first(where: { $0.name == "paths" })?.value,
            let data = Data(base64Encoded: encodedPaths),
            let rawPaths = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        return rawPaths
    }

    private func handleArchiveRequest(rawPaths: [String]) {
        let selection: [URL]
        do {
            selection = try validateArchiveSelection(paths: rawPaths)
        } catch {
            presentErrorAndMaybeTerminate(
                title: "Archive Request Failed",
                message: "Could not read the selected item paths. \(error.localizedDescription)"
            )
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let format = presentCompressModal() else {
            NSApp.terminate(nil)
            return
        }

        let job: ArchiveJob
        do {
            job = try ArchiveJob(selection: selection, format: format)
        } catch let error as ArchiveNamingError {
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
            presentErrorAndMaybeTerminate(title: "Invalid Selection", message: error.localizedDescription)
            return
        }

        startArchiving(job)
    }

    private func handleConvertRequest(rawPaths: [String]) {
        let selection: [URL]
        do {
            selection = try validateAudioSelection(paths: rawPaths)
        } catch {
            presentErrorAndMaybeTerminate(
                title: "Convert Request Failed",
                message: "Could not read the selected item paths. \(error.localizedDescription)"
            )
            return
        }

        guard let inputFormats = AudioSelectionGate.inputFormats(for: selection) else {
            presentErrorAndMaybeTerminate(title: "Invalid Selection", message: "All selected items must be supported audio files.")
            return
        }

        let allowedFormats = AudioConversionMatrix.allowedOutputs(for: inputFormats).filter { $0 != .mp3 }
        guard !allowedFormats.isEmpty else {
            presentErrorAndMaybeTerminate(
                title: "Invalid Selection",
                message: "The selected audio files do not share a common target format."
            )
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let outputFormat = presentConvertModal(allowedFormats: allowedFormats) else {
            NSApp.terminate(nil)
            return
        }

        let job = ConvertJob(selection: selection, outputFormat: outputFormat)
        startConverting(job)
    }

    private func validateCommonSelection(paths: [String]) throws -> [URL] {
        guard !paths.isEmpty else {
            throw ValidationError.emptySelection
        }

        let fileManager = FileManager.default
        let urls = paths.map { URL(fileURLWithPath: $0) }
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

    private func validateArchiveSelection(paths: [String]) throws -> [URL] {
        let urls = try validateCommonSelection(paths: paths)
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else {
            throw ValidationError.invalidSelection("Selection contains an item that is already an archive.")
        }
        return urls
    }

    private func validateAudioSelection(paths: [String]) throws -> [URL] {
        let urls = try validateCommonSelection(paths: paths)
        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else {
            throw ValidationError.invalidSelection("Selection contains an archived item.")
        }
        guard AudioSelectionGate.allSupportedAudio(urls: urls) else {
            throw ValidationError.invalidSelection("Selection must contain only supported audio files (mp3, m4a, wav, aiff, flac).")
        }
        return urls
    }

    private func presentCompressModal() -> ArchiveFormat? {
        let formats = ArchiveFormat.allCases
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28), pullsDown: false)
        popup.addItems(withTitles: formats.map(\.pickerDisplayName))
        popup.selectItem(at: 0)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Archive"
        alert.informativeText = "Choose a format."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let title = popup.titleOfSelectedItem ?? ""
        return ArchiveFormat.fromPickerDisplayName(title) ?? .zip
    }

    private func presentConvertModal(allowedFormats: [AudioOutputFormat]) -> AudioOutputFormat? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28), pullsDown: false)
        popup.addItems(withTitles: allowedFormats.map(\.displayName))
        popup.selectItem(at: 0)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Convert"
        alert.informativeText = "Choose a format."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let title = popup.titleOfSelectedItem ?? ""
        return allowedFormats.first(where: { $0.displayName == title })
    }

    private func startArchiving(_ job: ArchiveJob) {
        isArchiving = true
        let progressWindowController = ArchivingProgressWindowController(statusText: "Archiving…")
        self.progressWindowController = progressWindowController
        progressWindowController.show()

        compressionQueue.async { [job] in
            let result = Self.runArchive(job)
            DispatchQueue.main.async {
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

    private static func runArchive(_ job: ArchiveJob) -> ArchiveRunResult {
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

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(
                ArchiveFailureDetails(
                    userFacingMessage: "Failed to launch the archive tool: \(error.localizedDescription)",
                    diagnosticOutput: ""
                )
            )
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

    private static func runConversions(_ job: ConvertJob) -> ConvertRunResult {
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

    private static func runSingleConversion(_ task: ConvertTask) -> ConvertSingleResult {
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
                if let conversionError {
                    throw conversionError
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
                    throw ConvertEngineError.conversionFailedWithoutUnderlyingError
                @unknown default:
                    throw ConvertEngineError.unexpectedConverterStatus
                }
            }
        } catch {
            return .failure(
                ConvertFailureDetails(
                    userFacingMessage: "Failed to convert \(task.sourceURL.lastPathComponent).\n\n\(error.localizedDescription)",
                    diagnosticOutput: String(describing: error)
                )
            )
        }
    }

    private static func isValidOutputFile(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        guard let fileSize = attributes[.size] as? NSNumber else { return false }
        return fileManager.fileExists(atPath: url.path) && fileSize.int64Value > 0
    }

    private static func diagnosticSnippet(from text: String, maxLines: Int = 20) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .prefix(maxLines)
            .joined(separator: "\n")
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

private struct ArchiveJob {
    let selection: [URL]
    let format: ArchiveFormat
    let workingDirectory: URL
    let relativeItemNames: [String]
    let outputURL: URL

    init(selection: [URL], format: ArchiveFormat, now: Date = Date()) throws {
        self.selection = selection
        self.format = format
        workingDirectory = try ArchiveNameBuilder.commonParentDirectory(for: selection)
        relativeItemNames = try ArchiveNameBuilder.relativeItemNames(for: selection)
        outputURL = try ArchiveNameBuilder.outputURL(for: selection, format: format, now: now)
    }
}

private struct ConvertJob {
    let selection: [URL]
    let outputFormat: AudioOutputFormat
    let tasks: [ConvertTask]

    init(selection: [URL], outputFormat: AudioOutputFormat) {
        self.selection = selection
        self.outputFormat = outputFormat
        self.tasks = selection.map { ConvertTask(sourceURL: $0, outputURL: ConvertNameBuilder.outputURL(for: $0, outputFormat: outputFormat), outputFormat: outputFormat) }
    }
}

private struct ConvertTask {
    let sourceURL: URL
    let outputURL: URL
    let outputFormat: AudioOutputFormat
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

private struct ConvertOutputAudioConfiguration {
    let fileSettings: [String: Any]
    let clientCommonFormat: AVAudioCommonFormat
    let clientInterleaved: Bool
}

private enum ConvertEngineError: LocalizedError {
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

private func makeOutputAudioConfiguration(
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
