import AppKit
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
                title: "Archive In Progress",
                message: "FormatKit is already archiving another selection."
            )
            return
        }

        guard
            url.scheme?.lowercased() == "formatkit",
            let action = url.host?.lowercased(),
            action == "archive",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let encodedPaths = components.queryItems?.first(where: { $0.name == "paths" })?.value,
            let data = Data(base64Encoded: encodedPaths),
            let rawPaths = try? JSONDecoder().decode([String].self, from: data)
        else {
            presentErrorAndMaybeTerminate(title: "Invalid Request", message: "The archive request URL was malformed.")
            return
        }

        let selection: [URL]
        do {
            selection = try validateSelection(paths: rawPaths)
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

    private func validateSelection(paths: [String]) throws -> [URL] {
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

        guard !ArchiveSelectionGate.containsArchivedItem(urls: urls) else {
            throw ValidationError.invalidSelection("Selection contains an item that is already an archive.")
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

    private func startArchiving(_ job: ArchiveJob) {
        isArchiving = true
        let progressWindowController = ArchivingProgressWindowController()
        self.progressWindowController = progressWindowController
        progressWindowController.show()

        compressionQueue.async { [job] in
            let result = Self.runArchive(job)
            DispatchQueue.main.async {
                self.progressWindowController?.close()
                self.progressWindowController = nil
                self.isArchiving = false
                self.presentCompletion(for: result, outputURL: job.outputURL)
            }
        }
    }

    private func presentCompletion(for result: ArchiveRunResult, outputURL: URL) {
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

        guard isValidArchiveOutput(at: job.outputURL) else {
            let snippet = diagnosticSnippet(from: stderr.isEmpty ? stdout : stderr)
            let message = snippet.isEmpty
                ? "Archive command finished, but the output file was missing or empty."
                : "Archive command finished, but the output file was missing or empty.\n\n\(snippet)"
            return .failure(ArchiveFailureDetails(userFacingMessage: message, diagnosticOutput: combinedDiagnostics))
        }

        return .success
    }

    private static func isValidArchiveOutput(at url: URL) -> Bool {
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

private enum ArchiveRunResult {
    case success
    case failure(ArchiveFailureDetails)
}

private struct ArchiveFailureDetails {
    let userFacingMessage: String
    let diagnosticOutput: String
}

private final class ArchivingProgressWindowController: NSWindowController {
    init() {
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

        let label = NSTextField(labelWithString: "Archiving…")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(spinner)
        contentView.addSubview(label)
        window.contentView = contentView

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
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
