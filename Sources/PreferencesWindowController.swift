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
        case .reveal: return String(localized: "Show in File Manager")
        case .copyPath: return String(localized: "Copy full paths")
        }
    }

    var scopeTitle: String {
        self == .globalToggle ? String(localized: "Global") : String(localized: "Result list")
    }
}

struct KeyboardShortcut: Codable, Equatable {
    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    let keyCode: UInt16
    let modifiersRawValue: UInt
    let characters: String

    init(keyCode: UInt16, modifiersRawValue: UInt, characters: String) {
        self.keyCode = keyCode
        self.modifiersRawValue = NSEvent.ModifierFlags(rawValue: modifiersRawValue)
            .intersection(Self.supportedModifiers).rawValue
        self.characters = characters
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
            .intersection(Self.supportedModifiers)
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
        Self.modifierDisplayName(modifiers) + keyDisplayName
    }

    private var keyDisplayName: String {
        switch keyCode {
        case 36, 76: return "↩"
        case 49: return String(localized: "Space")
        case 51: return "⌫"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return characters.uppercased()
        }
    }

    static func modifierDisplayName(_ modifiers: NSEvent.ModifierFlags) -> String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value
    }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode && modifiers == event.modifierFlags.intersection(Self.supportedModifiers)
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
            return KeyboardShortcut(
                keyCode: shortcut.keyCode,
                modifiersRawValue: shortcut.modifiers.rawValue,
                characters: shortcut.characters
            )
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

    static func resetAll() { CommandID.allCases.forEach(reset) }

    static func defaultShortcut(for command: CommandID) -> KeyboardShortcut { defaults[command]! }

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
    var onInvalid: ((String) -> Void)?

    private var eventMonitor: Any?
    private var previousTitle = ""
    private(set) var isRecording = false

    init(command: CommandID) {
        self.command = command
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording(_:))
        widthAnchor.constraint(greaterThanOrEqualToConstant: 175).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        guard !isRecording else { return }
        title = ShortcutSettings.shortcut(for: command).displayName
        toolTip = String.localizedStringWithFormat(String(localized: "Current shortcut: %@"), title)
    }

    @objc private func beginRecording(_ sender: Any?) {
        if isRecording {
            cancelRecording()
            return
        }
        onBeginRecording?()
        previousTitle = ShortcutSettings.shortcut(for: command).displayName
        isRecording = true
        title = String.localizedStringWithFormat(String(localized: "%@ → press new shortcut"), previousTitle)
        highlight(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                self.cancelRecording()
                return event
            case .flagsChanged:
                let flags = event.modifierFlags.intersection(KeyboardShortcut.supportedModifiers)
                let modifierText = KeyboardShortcut.modifierDisplayName(flags)
                self.title = modifierText.isEmpty
                    ? String.localizedStringWithFormat(String(localized: "%@ → press new shortcut"), self.previousTitle)
                    : modifierText
                return event
            case .keyDown:
                return self.record(event)
            default:
                return event
            }
        }
    }

    private func record(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            cancelRecording()
            return nil
        }
        let flags = event.modifierFlags.intersection(KeyboardShortcut.supportedModifiers)
        let characters = event.charactersIgnoringModifiers ?? ""
        let isSpecialKey = [36, 49, 51, 76, 123, 124, 125, 126].contains(Int(event.keyCode))
        guard !flags.isEmpty || isSpecialKey else {
            onInvalid?(String(localized: "Letter, number, and punctuation shortcuts must include Command, Option, Control, or Shift."))
            NSSound.beep()
            return nil
        }
        let shortcut = KeyboardShortcut(keyCode: event.keyCode, modifiersRawValue: flags.rawValue, characters: characters)
        stopRecording()
        onShortcut?(command, shortcut)
        return nil
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
        highlight(false)
    }

    func cancelRecording() {
        guard isRecording else { return }
        stopRecording()
        title = previousTitle
        onCancel?()
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let onShortcutChange: () -> Void
    private var recorderButtons: [ShortcutRecorderButton] = []
    private let shortcutMessageLabel = NSTextField(labelWithString: "")
    private let prioritizeFolderRulesButton = NSButton(checkboxWithTitle: String(localized: "Prioritize folder rules"), target: nil, action: nil)
    private let foldersFirstButton = NSButton(checkboxWithTitle: String(localized: "Keep folders above files within the same priority"), target: nil, action: nil)
    private let rulesTableView = NSTableView()
    private var folderRules: [FolderRule] = []

    init(onChange: @escaping () -> Void) {
        self.onShortcutChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "FindAll Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        refreshSearchSettings()
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let searchTab = NSTabViewItem(identifier: "search")
        searchTab.label = String(localized: "Search & Ranking")
        searchTab.view = makeSearchSettingsView()
        tabView.addTabViewItem(searchTab)

        let shortcutsTab = NSTabViewItem(identifier: "shortcuts")
        shortcutsTab.label = String(localized: "Keyboard Shortcuts")
        shortcutsTab.view = makeShortcutsView()
        tabView.addTabViewItem(shortcutsTab)

        content.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    private func makeSearchSettingsView() -> NSView {
        let view = NSView()
        let accessHeading = NSTextField(labelWithString: String(localized: "Full Disk Access"))
        accessHeading.font = .boldSystemFont(ofSize: 14)
        let accessHelp = NSTextField(wrappingLabelWithString: String(localized: "Full Disk Access is required for Spotlight searches. Without it, searches return no results. Enable FindAll in System Settings, then restart the app."))
        accessHelp.textColor = .secondaryLabelColor
        let openAccessSettings = NSButton(
            title: String(localized: "Open Full Disk Access Settings"),
            target: self,
            action: #selector(openFullDiskAccessSettings(_:))
        )

        let heading = NSTextField(labelWithString: String(localized: "Result Ordering"))
        heading.font = .boldSystemFont(ofSize: 17)
        let help = NSTextField(wrappingLabelWithString: String(localized: "Click a result-table header to choose the ordering. Folder priority and folders-first are independent options."))
        help.textColor = .secondaryLabelColor

        prioritizeFolderRulesButton.target = self
        prioritizeFolderRulesButton.action = #selector(prioritizeFolderRulesChanged(_:))
        foldersFirstButton.target = self
        foldersFirstButton.action = #selector(foldersFirstChanged(_:))

        let folderHeading = NSTextField(labelWithString: String(localized: "Saved Folders and Ranking"))
        folderHeading.font = .boldSystemFont(ofSize: 14)
        let folderHelp = NSTextField(wrappingLabelWithString: String(localized: "Saved folders appear in the Scope menu only when you add them explicitly. Pinned folders rank above Preferred folders; Normal folders receive no ranking boost."))
        folderHelp.textColor = .secondaryLabelColor

        configureRulesTable()
        let scrollView = NSScrollView()
        scrollView.documentView = rulesTableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let add = NSButton(title: String(localized: "Add…"), target: self, action: #selector(addFolderRule(_:)))
        let remove = NSButton(title: String(localized: "Remove"), target: self, action: #selector(removeFolderRule(_:)))
        let up = NSButton(title: String(localized: "Move Up"), target: self, action: #selector(moveFolderRuleUp(_:)))
        let down = NSButton(title: String(localized: "Move Down"), target: self, action: #selector(moveFolderRuleDown(_:)))
        let buttons = NSStackView(views: [add, remove, up, down])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        [accessHeading, accessHelp, openAccessSettings, heading, help, prioritizeFolderRulesButton, foldersFirstButton, folderHeading, folderHelp, scrollView, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            accessHeading.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            accessHeading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            accessHelp.topAnchor.constraint(equalTo: accessHeading.bottomAnchor, constant: 6),
            accessHelp.leadingAnchor.constraint(equalTo: accessHeading.leadingAnchor),
            accessHelp.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            openAccessSettings.topAnchor.constraint(equalTo: accessHelp.bottomAnchor, constant: 8),
            openAccessSettings.leadingAnchor.constraint(equalTo: accessHeading.leadingAnchor),
            heading.topAnchor.constraint(equalTo: openAccessSettings.bottomAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            help.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            help.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            prioritizeFolderRulesButton.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 14),
            prioritizeFolderRulesButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            foldersFirstButton.topAnchor.constraint(equalTo: prioritizeFolderRulesButton.bottomAnchor, constant: 8),
            foldersFirstButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            folderHeading.topAnchor.constraint(equalTo: foldersFirstButton.bottomAnchor, constant: 22),
            folderHeading.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            folderHelp.topAnchor.constraint(equalTo: folderHeading.bottomAnchor, constant: 6),
            folderHelp.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            folderHelp.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: folderHelp.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(equalToConstant: 185),
            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
        return view
    }

    private func configureRulesTable() {
        rulesTableView.delegate = self
        rulesTableView.dataSource = self
        rulesTableView.allowsMultipleSelection = false
        rulesTableView.usesAlternatingRowBackgroundColors = true
        rulesTableView.rowHeight = 28
        let folderColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        folderColumn.title = String(localized: "Folder")
        folderColumn.minWidth = 300
        folderColumn.width = 430
        let priorityColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("priority"))
        priorityColumn.title = String(localized: "Priority")
        priorityColumn.minWidth = 130
        priorityColumn.width = 150
        rulesTableView.addTableColumn(folderColumn)
        rulesTableView.addTableColumn(priorityColumn)
    }

    private func makeShortcutsView() -> NSView {
        let view = NSView()
        let heading = NSTextField(labelWithString: String(localized: "Keyboard Shortcuts"))
        heading.font = .boldSystemFont(ofSize: 17)
        let help = NSTextField(wrappingLabelWithString: String(localized: "Every button shows its saved shortcut. Click one and press a new combination; modifiers are shown live. Click elsewhere or press Escape to cancel."))
        help.textColor = .secondaryLabelColor

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 10
        rows.alignment = .leading
        for (index, command) in CommandID.allCases.enumerated() {
            let label = NSTextField(labelWithString: "\(command.title) · \(command.scopeTitle)")
            let recorder = ShortcutRecorderButton(command: command)
            recorder.onBeginRecording = { [weak self, weak recorder] in
                self?.recorderButtons
                    .filter { $0 !== recorder && $0.isRecording }
                    .forEach { $0.cancelRecording() }
                self?.showShortcutMessage(String(localized: "Recording shortcut…"), isError: false)
            }
            recorder.onShortcut = { [weak self] command, shortcut in self?.save(shortcut, for: command) }
            recorder.onCancel = { [weak self] in self?.showShortcutMessage("") }
            recorder.onInvalid = { [weak self] message in self?.showShortcutMessage(message) }
            recorderButtons.append(recorder)

            let reset = NSButton(title: String(localized: "Reset"), target: self, action: #selector(resetOne(_:)))
            reset.tag = index
            reset.bezelStyle = .inline

            let row = NSGridView(views: [[label, recorder, reset]])
            row.column(at: 0).width = 280
            row.column(at: 1).width = 200
            row.column(at: 2).width = 70
            rows.addArrangedSubview(row)
        }

        shortcutMessageLabel.textColor = .systemRed
        shortcutMessageLabel.lineBreakMode = .byTruncatingTail
        let resetAll = NSButton(title: String(localized: "Restore All Defaults"), target: self, action: #selector(resetAllShortcuts(_:)))
        resetAll.bezelStyle = .rounded

        [heading, help, rows, shortcutMessageLabel, resetAll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            help.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            help.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 20),
            rows.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            shortcutMessageLabel.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 16),
            shortcutMessageLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            shortcutMessageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            resetAll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            resetAll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        return view
    }

    func numberOfRows(in tableView: NSTableView) -> Int { folderRules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === rulesTableView, let tableColumn, folderRules.indices.contains(row) else { return nil }
        let rule = folderRules[row]
        if tableColumn.identifier.rawValue == "priority" {
            let popup = NSPopUpButton()
            popup.identifier = tableColumn.identifier
            popup.controlSize = .small
            popup.tag = row
            popup.target = self
            popup.action = #selector(folderPriorityChanged(_:))
            for priority in FolderPriority.allCases {
                let item = NSMenuItem(title: priority.title, action: nil, keyEquivalent: "")
                item.tag = priority.rawValue
                popup.menu?.addItem(item)
            }
            popup.selectItem(withTag: rule.priority.rawValue)
            return popup
        }
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = rule.path
        cell.textField?.toolTip = rule.path
        return cell
    }

    private func refreshSearchSettings() {
        folderRules = SearchPreferences.folderRules
        prioritizeFolderRulesButton.state = SearchPreferences.prioritizeFolderRules ? .on : .off
        foldersFirstButton.state = SearchPreferences.foldersFirst ? .on : .off
        rulesTableView.reloadData()
    }

    @objc private func prioritizeFolderRulesChanged(_ sender: NSButton) {
        SearchPreferences.prioritizeFolderRules = sender.state == .on
    }

    @objc private func foldersFirstChanged(_ sender: NSButton) {
        SearchPreferences.foldersFirst = sender.state == .on
    }

    @objc private func openFullDiskAccessSettings(_ sender: Any?) {
        FullDiskAccessSupport.openSystemSettings()
    }

    @objc private func addFolderRule(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls where !self.folderRules.contains(where: { $0.path == url.path }) {
                self.folderRules.append(FolderRule(path: url.path, priority: .normal))
            }
            self.persistFolderRules()
        }
    }

    @objc private func removeFolderRule(_ sender: Any?) {
        let row = rulesTableView.selectedRow
        guard folderRules.indices.contains(row) else { return }
        folderRules.remove(at: row)
        persistFolderRules()
    }

    @objc private func moveFolderRuleUp(_ sender: Any?) {
        let row = rulesTableView.selectedRow
        guard row > 0, folderRules.indices.contains(row) else { return }
        folderRules.swapAt(row, row - 1)
        persistFolderRules(selecting: row - 1)
    }

    @objc private func moveFolderRuleDown(_ sender: Any?) {
        let row = rulesTableView.selectedRow
        guard row >= 0, row + 1 < folderRules.count else { return }
        folderRules.swapAt(row, row + 1)
        persistFolderRules(selecting: row + 1)
    }

    @objc private func folderPriorityChanged(_ sender: NSPopUpButton) {
        guard folderRules.indices.contains(sender.tag),
              let priority = FolderPriority(rawValue: sender.selectedTag()) else { return }
        folderRules[sender.tag].priority = priority
        persistFolderRules(selecting: sender.tag)
    }

    private func persistFolderRules(selecting row: Int? = nil) {
        SearchPreferences.folderRules = folderRules
        rulesTableView.reloadData()
        if let row, folderRules.indices.contains(row) {
            rulesTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func save(_ shortcut: KeyboardShortcut, for command: CommandID) {
        if command == .globalToggle && shortcut.modifiers.isEmpty {
            showShortcutMessage(String(localized: "The global shortcut must include Command, Option, Control, or Shift."))
            refreshButtons()
            NSSound.beep()
            return
        }
        if isReservedMacShortcut(shortcut) {
            showShortcutMessage(String(localized: "That shortcut is reserved by a standard macOS command."))
            refreshButtons()
            NSSound.beep()
            return
        }
        if let conflict = ShortcutSettings.conflictingCommand(for: shortcut, excluding: command) {
            let message = String.localizedStringWithFormat(String(localized: "That shortcut is already assigned to “%@”."), conflict.title)
            showShortcutMessage(message)
            refreshButtons()
            NSSound.beep()
            return
        }
        if command == .globalToggle, let registrationError = validateGlobalShortcut(shortcut) {
            showShortcutMessage(registrationError)
            refreshButtons()
            NSSound.beep()
            return
        }
        ShortcutSettings.set(shortcut, for: command)
        showShortcutMessage(String(localized: "Shortcut updated."), isError: false)
        refreshButtons()
        onShortcutChange()
    }

    private func isReservedMacShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        guard shortcut.modifiers == .command else { return false }
        return ["a", "c", "h", "m", "q", "v", "w", "x", "z", ","].contains(shortcut.characters.lowercased())
    }

    private func showShortcutMessage(_ message: String, isError: Bool = true) {
        shortcutMessageLabel.stringValue = message
        shortcutMessageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func refreshButtons() { recorderButtons.forEach { $0.refresh() } }

    private func validateGlobalShortcut(_ shortcut: KeyboardShortcut) -> String? {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            return String(localized: "The global shortcut could not be registered because the application is not ready.")
        }
        let status = delegate.validateGlobalShortcut(shortcut)
        guard status != noErr else { return nil }
        return String.localizedStringWithFormat(
            String(localized: "The global shortcut could not be registered (error %lld). It may already be used by macOS or another application."),
            Int64(status)
        )
    }

    @objc private func resetOne(_ sender: NSButton) {
        guard CommandID.allCases.indices.contains(sender.tag) else { return }
        let command = CommandID.allCases[sender.tag]
        if command == .globalToggle,
           let error = validateGlobalShortcut(ShortcutSettings.defaultShortcut(for: command)) {
            showShortcutMessage(error)
            NSSound.beep()
            return
        }
        ShortcutSettings.reset(command)
        showShortcutMessage(String(localized: "Shortcut restored."), isError: false)
        refreshButtons()
        onShortcutChange()
    }

    @objc private func resetAllShortcuts(_ sender: Any?) {
        if let error = validateGlobalShortcut(ShortcutSettings.defaultShortcut(for: .globalToggle)) {
            showShortcutMessage(error)
            NSSound.beep()
            return
        }
        ShortcutSettings.resetAll()
        showShortcutMessage(String(localized: "All shortcuts restored."), isError: false)
        refreshButtons()
        onShortcutChange()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshButtons()
        refreshSearchSettings()
    }

    func windowDidResignKey(_ notification: Notification) {
        recorderButtons.filter(\.isRecording).forEach { $0.cancelRecording() }
    }

    func windowWillClose(_ notification: Notification) {
        recorderButtons.filter(\.isRecording).forEach { $0.cancelRecording() }
    }
}
