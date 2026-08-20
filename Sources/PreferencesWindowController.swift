import AppKit

enum CommandID: String, CaseIterable {
    case globalToggle
    case open
    case quickLook
    case reveal
    case copyPath

    var title: String {
        switch self {
        case .globalToggle: return String(localized: "Show or hide FindAll")
        case .open: return String(localized: "Open selected items")
        case .quickLook: return String(localized: "Quick Look")
        case .reveal: return String(localized: "Reveal in Finder")
        case .copyPath: return String(localized: "Copy full paths")
        }
    }
}

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiersRawValue: UInt
    let characters: String

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
            .intersection(.deviceIndependentFlagsMask)
    }

    var keyEquivalent: String {
        switch keyCode {
        case 36, 76: return "\r"
        case 49: return " "
        case 51: return "\u{8}"
        case 53: return "\u{1b}"
        default: return characters.lowercased()
        }
    }

    var displayName: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        switch keyCode {
        case 36, 76: value += "↩"
        case 49: value += "Space"
        case 51: value += "⌫"
        case 53: value += "Esc"
        case 123: value += "←"
        case 124: value += "→"
        case 125: value += "↓"
        case 126: value += "↑"
        default: value += characters.uppercased()
        }
        return value
    }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode && modifiers == event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }
}

enum ShortcutSettings {
    private static let defaults: [CommandID: KeyboardShortcut] = [
        .globalToggle: KeyboardShortcut(keyCode: 49, modifiersRawValue: NSEvent.ModifierFlags.option.rawValue, characters: " "),
        .open: KeyboardShortcut(keyCode: 36, modifiersRawValue: 0, characters: "\r"),
        .quickLook: KeyboardShortcut(keyCode: 49, modifiersRawValue: 0, characters: " "),
        .reveal: KeyboardShortcut(keyCode: 36, modifiersRawValue: NSEvent.ModifierFlags.command.rawValue, characters: "\r"),
        .copyPath: KeyboardShortcut(keyCode: 8, modifiersRawValue: NSEvent.ModifierFlags.command.union(.shift).rawValue, characters: "c")
    ]

    static func shortcut(for command: CommandID) -> KeyboardShortcut {
        let key = "shortcut.\(command.rawValue)"
        if let data = UserDefaults.standard.data(forKey: key),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            return shortcut
        }
        return defaults[command]!
    }

    static func set(_ shortcut: KeyboardShortcut, for command: CommandID) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: "shortcut.\(command.rawValue)")
    }

    static func reset(_ command: CommandID) {
        UserDefaults.standard.removeObject(forKey: "shortcut.\(command.rawValue)")
    }

    static func resetAll() {
        CommandID.allCases.forEach(reset)
    }

    static func conflictingCommand(for shortcut: KeyboardShortcut, excluding command: CommandID) -> CommandID? {
        CommandID.allCases.first {
            $0 != command && self.shortcut(for: $0).hasSameKeys(as: shortcut)
        }
    }
}

private extension KeyboardShortcut {
    func hasSameKeys(as other: KeyboardShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

final class ShortcutRecorderButton: NSButton {
    let command: CommandID
    var onBeginRecording: (() -> Void)?
    var onShortcut: ((CommandID, KeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?

    private var eventMonitor: Any?
    private var previousTitle = ""

    init(command: CommandID) {
        self.command = command
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording(_:))
        widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        title = ShortcutSettings.shortcut(for: command).displayName
    }

    @objc private func beginRecording(_ sender: Any?) {
        onBeginRecording?()
        stopRecording(restoreTitle: false)
        previousTitle = title
        title = String(localized: "Press shortcut…")
        highlight(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.stopRecording(restoreTitle: true)
                self.onCancel?()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers ?? ""
            let isSpecialKey = [36, 49, 76, 123, 124, 125, 126].contains(Int(event.keyCode))
            guard !flags.isEmpty || isSpecialKey else {
                NSSound.beep()
                return nil
            }
            let shortcut = KeyboardShortcut(keyCode: event.keyCode, modifiersRawValue: flags.rawValue, characters: characters)
            self.stopRecording(restoreTitle: false)
            self.onShortcut?(self.command, shortcut)
            return nil
        }
    }

    private func stopRecording(restoreTitle: Bool) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        highlight(false)
        if restoreTitle { title = previousTitle }
    }

    func cancelRecording() {
        stopRecording(restoreTitle: true)
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let onChange: () -> Void
    private var recorderButtons: [ShortcutRecorderButton] = []
    private let messageLabel = NSTextField(labelWithString: "")

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "FindAll Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: String(localized: "Keyboard Shortcuts"))
        heading.font = .boldSystemFont(ofSize: 17)
        let help = NSTextField(wrappingLabelWithString: String(localized: "Click a shortcut, then press the new key combination. Escape cancels recording. Standard macOS shortcuts such as ⌘W, ⌘M, and ⌘Q remain reserved."))
        help.textColor = .secondaryLabelColor

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 10
        rows.alignment = .leading
        for (index, command) in CommandID.allCases.enumerated() {
            let label = NSTextField(labelWithString: command.title)
            let recorder = ShortcutRecorderButton(command: command)
            recorder.onBeginRecording = { [weak self, weak recorder] in
                self?.recorderButtons
                    .filter { $0 !== recorder }
                    .forEach { $0.cancelRecording() }
            }
            recorder.onShortcut = { [weak self] command, shortcut in self?.save(shortcut, for: command) }
            recorder.onCancel = { [weak self] in self?.showMessage("") }
            recorderButtons.append(recorder)

            let reset = NSButton(title: String(localized: "Reset"), target: self, action: #selector(resetOne(_:)))
            reset.tag = index
            reset.bezelStyle = .inline

            let row = NSGridView(views: [[label, recorder, reset]])
            row.column(at: 0).width = 260
            row.column(at: 1).width = 150
            row.column(at: 2).width = 70
            rows.addArrangedSubview(row)
        }

        messageLabel.textColor = .systemRed
        messageLabel.lineBreakMode = .byTruncatingTail
        let resetAll = NSButton(title: String(localized: "Restore All Defaults"), target: self, action: #selector(resetAllShortcuts(_:)))
        resetAll.bezelStyle = .rounded

        [heading, help, rows, messageLabel, resetAll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            help.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            help.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            rows.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 20),
            rows.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            messageLabel.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 16),
            messageLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            resetAll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            resetAll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
    }

    private func save(_ shortcut: KeyboardShortcut, for command: CommandID) {
        if command == .globalToggle && shortcut.modifiers.isEmpty {
            showMessage(String(localized: "The global shortcut must include Command, Option, Control, or Shift."))
            refreshButtons()
            NSSound.beep()
            return
        }
        if isReservedMacShortcut(shortcut) {
            showMessage(String(localized: "That shortcut is reserved by a standard macOS command."))
            refreshButtons()
            NSSound.beep()
            return
        }
        if let conflict = ShortcutSettings.conflictingCommand(for: shortcut, excluding: command) {
            showMessage(String(localized: "That shortcut is already assigned to “\(conflict.title)”."))
            refreshButtons()
            NSSound.beep()
            return
        }
        ShortcutSettings.set(shortcut, for: command)
        showMessage(String(localized: "Shortcut updated."), isError: false)
        refreshButtons()
        onChange()
    }

    private func isReservedMacShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        guard shortcut.modifiers == .command else { return false }
        return ["a", "c", "h", "m", "q", "v", "w", "x", "z", ","].contains(shortcut.characters.lowercased())
    }

    private func showMessage(_ message: String, isError: Bool = true) {
        messageLabel.stringValue = message
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func refreshButtons() {
        recorderButtons.forEach { $0.refresh() }
    }

    @objc private func resetOne(_ sender: NSButton) {
        guard CommandID.allCases.indices.contains(sender.tag) else { return }
        let command = CommandID.allCases[sender.tag]
        ShortcutSettings.reset(command)
        showMessage(String(localized: "Shortcut restored."), isError: false)
        refreshButtons()
        onChange()
    }

    @objc private func resetAllShortcuts(_ sender: Any?) {
        ShortcutSettings.resetAll()
        showMessage(String(localized: "All shortcuts restored."), isError: false)
        refreshButtons()
        onChange()
    }

    func windowWillClose(_ notification: Notification) {
        recorderButtons.forEach { $0.cancelRecording() }
    }
}
