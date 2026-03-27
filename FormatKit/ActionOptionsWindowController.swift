import AppKit
import Foundation

private final class OptionSelectionWindowController: NSWindowController, NSWindowDelegate {
    private let popup: NSPopUpButton
    private let actionButtonTitle: String
    private var modalResponse: NSApplication.ModalResponse = .abort

    init(
        title: String,
        rowLabel: String,
        options: [String],
        actionButtonTitle: String
    ) {
        self.popup = NSPopUpButton(frame: .zero, pullsDown: false)
        self.actionButtonTitle = actionButtonTitle
        super.init(window: nil)

        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: options)
        popup.selectItem(at: 0)

        let label = NSTextField(labelWithString: rowLabel)
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.alignment = .right

        let grid = NSGridView(views: [[label, popup]])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.row(at: 0).yPlacement = .center

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(handleCancel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        let actionButton = NSButton(title: actionButtonTitle, target: self, action: #selector(handleConfirm))
        actionButton.keyEquivalent = "\r"
        actionButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancelButton, actionButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        buttons.distribution = .gravityAreas
        buttons.setHuggingPriority(.required, for: .horizontal)

        let buttonContainer = NSView()
        buttonContainer.translatesAutoresizingMaskIntoConstraints = false
        buttonContainer.addSubview(buttons)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(grid)
        contentView.addSubview(divider)
        contentView.addSubview(buttonContainer)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),

            divider.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            buttonContainer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            buttonContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            buttonContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttonContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            buttons.trailingAnchor.constraint(equalTo: buttonContainer.trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: buttonContainer.centerYAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 182),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.delegate = self
        self.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() -> Int? {
        guard let window else { return nil }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        showWindow(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        guard modalResponse == .OK else { return nil }
        return popup.indexOfSelectedItem
    }

    @objc private func handleConfirm() {
        modalResponse = .OK
        closeModal(response: .OK)
    }

    @objc private func handleCancel() {
        modalResponse = .cancel
        closeModal(response: .cancel)
    }

    private func closeModal(response: NSApplication.ModalResponse) {
        guard let window else { return }
        NSApp.stopModal(withCode: response)
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard modalResponse == .abort else { return }
        NSApp.stopModal(withCode: .cancel)
    }
}

enum ArchiveOptionsPanel {
    @MainActor
    static func present() -> ArchiveFormat? {
        let formats = ArchiveFormat.allCases
        let controller = OptionSelectionWindowController(
            title: "Archive",
            rowLabel: "Format:",
            options: formats.map(\.pickerDisplayName),
            actionButtonTitle: "Archive"
        )
        guard let selected = controller.present(), formats.indices.contains(selected) else {
            return nil
        }
        return formats[selected]
    }
}

enum ConvertOptionsPanel {
    @MainActor
    static func presentAudio(allowedFormats: [AudioOutputFormat]) -> AudioOutputFormat? {
        let controller = OptionSelectionWindowController(
            title: "Convert",
            rowLabel: "Format:",
            options: allowedFormats.map(\.displayName),
            actionButtonTitle: "Convert"
        )
        guard let selected = controller.present(), allowedFormats.indices.contains(selected) else {
            return nil
        }
        return allowedFormats[selected]
    }

    @MainActor
    static func presentVideo(allowedFormats: [VideoOutputFormat]) -> VideoOutputFormat? {
        let controller = OptionSelectionWindowController(
            title: "Convert",
            rowLabel: "Format:",
            options: allowedFormats.map(\.displayName),
            actionButtonTitle: "Convert"
        )
        guard let selected = controller.present(), allowedFormats.indices.contains(selected) else {
            return nil
        }
        return allowedFormats[selected]
    }

    @MainActor
    static func presentImage(allowedFormats: [ImageOutputFormat]) -> ImageOutputFormat? {
        let controller = OptionSelectionWindowController(
            title: "Convert",
            rowLabel: "Format:",
            options: allowedFormats.map(\.displayName),
            actionButtonTitle: "Convert"
        )
        guard let selected = controller.present(), allowedFormats.indices.contains(selected) else {
            return nil
        }
        return allowedFormats[selected]
    }
}
