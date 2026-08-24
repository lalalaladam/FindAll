import AppKit
import ServiceManagement
import UniformTypeIdentifiers

enum CommandID: String, CaseIterable {
    case globalToggle
    case open
    case showFolderContents
    case quickLook
    case reveal
    case copyFiles
    case copyPath
    case share
    case getInfo

    static let resultListCommands: [CommandID] = [
        .open, .showFolderContents, .quickLook, .reveal, .copyFiles, .copyPath, .share, .getInfo
    ]

    var title: String {
        switch self {
        case .globalToggle: return L10n.string("Show or hide FindAll")
        case .open: return L10n.string("Open selected items")
        case .showFolderContents: return L10n.string("Show Folder Contents in New Window")
        case .quickLook: return L10n.string("Quick Look")
        case .reveal: return L10n.string("Show in File Manager")
        case .copyFiles: return L10n.string("Copy Files")
        case .copyPath: return L10n.string("Copy full paths")
        case .share: return L10n.string("Share")
        case .getInfo: return L10n.string("Get Info")
        }
    }

    var scopeTitle: String {
        self == .globalToggle ? L10n.string("Global") : L10n.string("Result list")
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
        case 123: return "\u{F702}"
        case 124: return "\u{F703}"
        case 125: return "\u{F701}"
        case 126: return "\u{F700}"
        default: return characters.lowercased()
        }
    }

    var displayName: String {
        Self.modifierDisplayName(modifiers) + keyDisplayName
    }

    private var keyDisplayName: String {
        switch keyCode {
        case 36, 76: return "↩"
        case 49: return L10n.string("Space")
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
        .showFolderContents: KeyboardShortcut(keyCode: 125, modifiersRawValue: NSEvent.ModifierFlags.command.rawValue, characters: "\u{F701}"),
        .quickLook: KeyboardShortcut(keyCode: 49, modifiersRawValue: 0, characters: " "),
        .reveal: KeyboardShortcut(keyCode: 36, modifiersRawValue: NSEvent.ModifierFlags.command.rawValue, characters: "\r"),
        .copyFiles: KeyboardShortcut(keyCode: 8, modifiersRawValue: NSEvent.ModifierFlags.command.rawValue, characters: "c"),
        .copyPath: KeyboardShortcut(keyCode: 8, modifiersRawValue: NSEvent.ModifierFlags.command.union(.shift).rawValue, characters: "c"),
        .share: KeyboardShortcut(keyCode: 1, modifiersRawValue: NSEvent.ModifierFlags.command.union(.option).union(.control).rawValue, characters: "s"),
        .getInfo: KeyboardShortcut(keyCode: 34, modifiersRawValue: NSEvent.ModifierFlags.command.rawValue, characters: "i")
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
        toolTip = String.localizedStringWithFormat(L10n.string("Current shortcut: %@"), title)
    }

    @objc private func beginRecording(_ sender: Any?) {
        if isRecording {
            cancelRecording()
            return
        }
        onBeginRecording?()
        previousTitle = ShortcutSettings.shortcut(for: command).displayName
        isRecording = true
        title = String.localizedStringWithFormat(L10n.string("%@ → press new shortcut"), previousTitle)
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
                    ? String.localizedStringWithFormat(L10n.string("%@ → press new shortcut"), self.previousTitle)
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
            onInvalid?(L10n.string("Letter, number, and punctuation shortcuts must include Command, Option, Control, or Shift."))
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
    private let prioritizeFolderRulesButton = NSButton(checkboxWithTitle: L10n.string("Prioritize folder rules"), target: nil, action: nil)
    private let foldersFirstButton = NSButton(checkboxWithTitle: L10n.string("Keep folders above files within the same priority"), target: nil, action: nil)
    private let sortModePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let fullDiskAccessStatusLabel = NSTextField(labelWithString: "")
    private lazy var openFullDiskAccessSettingsButton = NSButton(
        title: L10n.string("Open Full Disk Access Settings"),
        target: self,
        action: #selector(openFullDiskAccessSettings(_:))
    )
    private let rulesTableView = NSTableView()
    private var folderRules: [FolderRule] = []
    private var windowPreferencesObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var isWindowSettingsRefreshScheduled = false
    private let centerPlacementButton = NSButton(radioButtonWithTitle: WindowPlacement.center.title, target: nil, action: nil)
    private let rememberPlacementButton = NSButton(radioButtonWithTitle: WindowPlacement.remember.title, target: nil, action: nil)
    private let startupSizePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let columnSizingPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let settingsKeepOnTopButton = NSButton(checkboxWithTitle: L10n.string("Keep on top in current Space"), target: nil, action: nil)
    private let settingsAllSpacesButton = NSButton(checkboxWithTitle: L10n.string("Show on all Spaces"), target: nil, action: nil)
    private let settingsLaunchAtLoginButton = NSButton(checkboxWithTitle: L10n.string("Launch FindAll at login"), target: nil, action: nil)
    private let settingsShowDockIconButton = NSButton(checkboxWithTitle: L10n.string("Show FindAll in the Dock"), target: nil, action: nil)
    private let fileManagerPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: true)

    init(onChange: @escaping () -> Void) {
        self.onShortcutChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("FindAll Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        refreshSearchSettings()
        refreshWindowSettings()
        windowPreferencesObserver = NotificationCenter.default.addObserver(
            forName: WindowPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleWindowSettingsRefresh()
        }
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.refreshFullDiskAccessStatus()
            self?.refreshLaunchAtLoginStatus()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let windowPreferencesObserver { NotificationCenter.default.removeObserver(windowPreferencesObserver) }
        if let applicationActivationObserver { NotificationCenter.default.removeObserver(applicationActivationObserver) }
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let searchTab = NSTabViewItem(identifier: "search")
        searchTab.label = L10n.string("Search & Ranking")
        searchTab.view = makeSearchSettingsView()
        tabView.addTabViewItem(searchTab)

        let shortcutsTab = NSTabViewItem(identifier: "shortcuts")
        shortcutsTab.label = L10n.string("Keyboard Shortcuts")
        shortcutsTab.view = makeShortcutsView()
        tabView.addTabViewItem(shortcutsTab)

        let windowTab = NSTabViewItem(identifier: "window")
        windowTab.label = L10n.string("Window & Layout")
        windowTab.view = makeWindowSettingsView()
        tabView.addTabViewItem(windowTab)

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
        let accessHeading = NSTextField(labelWithString: L10n.string("Full Disk Access"))
        accessHeading.font = .boldSystemFont(ofSize: 14)
        let accessHelp = NSTextField(wrappingLabelWithString: L10n.string("Full Disk Access lets FindAll include more protected locations in Spotlight results. You can manage it in System Settings."))
        accessHelp.textColor = .secondaryLabelColor
        fullDiskAccessStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let heading = NSTextField(labelWithString: L10n.string("Result Ordering"))
        heading.font = .boldSystemFont(ofSize: 17)
        let help = NSTextField(wrappingLabelWithString: L10n.string("This is the default ordering used when each search first appears. Clicking a result-table header changes only the current results; the next search returns to this default. Folder priority and folders-first remain independent."))
        help.textColor = .secondaryLabelColor

        let sortLabel = NSTextField(labelWithString: L10n.string("Default ordering:"))
        sortModePopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let sortRow = NSStackView(views: [sortLabel, sortModePopup])
        sortRow.orientation = .horizontal
        sortRow.alignment = .centerY
        sortRow.spacing = 12

        prioritizeFolderRulesButton.target = self
        prioritizeFolderRulesButton.action = #selector(prioritizeFolderRulesChanged(_:))
        foldersFirstButton.target = self
        foldersFirstButton.action = #selector(foldersFirstChanged(_:))

        let folderHeading = NSTextField(labelWithString: L10n.string("Saved Folders and Ranking"))
        folderHeading.font = .boldSystemFont(ofSize: 14)
        let folderHelp = NSTextField(wrappingLabelWithString: L10n.string("Saved folders appear in the Scope menu only when you add them explicitly. Pinned folders rank above Preferred folders; Normal folders receive no ranking boost."))
        folderHelp.textColor = .secondaryLabelColor

        configureRulesTable()
        let scrollView = NSScrollView()
        scrollView.documentView = rulesTableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let add = NSButton(title: L10n.string("Add…"), target: self, action: #selector(addFolderRule(_:)))
        let remove = NSButton(title: L10n.string("Remove"), target: self, action: #selector(removeFolderRule(_:)))
        let up = NSButton(title: L10n.string("Move Up"), target: self, action: #selector(moveFolderRuleUp(_:)))
        let down = NSButton(title: L10n.string("Move Down"), target: self, action: #selector(moveFolderRuleDown(_:)))
        let buttons = NSStackView(views: [add, remove, up, down])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        [accessHeading, accessHelp, fullDiskAccessStatusLabel, openFullDiskAccessSettingsButton, heading, help, sortRow, prioritizeFolderRulesButton, foldersFirstButton, folderHeading, folderHelp, scrollView, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            accessHeading.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            accessHeading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            accessHelp.topAnchor.constraint(equalTo: accessHeading.bottomAnchor, constant: 6),
            accessHelp.leadingAnchor.constraint(equalTo: accessHeading.leadingAnchor),
            accessHelp.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            fullDiskAccessStatusLabel.topAnchor.constraint(equalTo: accessHelp.bottomAnchor, constant: 8),
            fullDiskAccessStatusLabel.leadingAnchor.constraint(equalTo: accessHeading.leadingAnchor),
            openFullDiskAccessSettingsButton.topAnchor.constraint(equalTo: fullDiskAccessStatusLabel.bottomAnchor, constant: 8),
            openFullDiskAccessSettingsButton.leadingAnchor.constraint(equalTo: accessHeading.leadingAnchor),
            heading.topAnchor.constraint(equalTo: openFullDiskAccessSettingsButton.bottomAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            help.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            help.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            sortRow.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 12),
            sortRow.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            prioritizeFolderRulesButton.topAnchor.constraint(equalTo: sortRow.bottomAnchor, constant: 12),
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
            scrollView.heightAnchor.constraint(equalToConstant: 155),
            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
        return view
    }

    private func makeWindowSettingsView() -> NSView {
        let view = NSView()
        let languageHeading = NSTextField(labelWithString: L10n.string("Language"))
        languageHeading.font = .boldSystemFont(ofSize: 17)
        let languageLabel = NSTextField(labelWithString: L10n.string("Application language:"))
        languagePopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let languageRow = NSStackView(views: [languageLabel, languagePopup])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 12

        let startupHeading = NSTextField(labelWithString: L10n.string("Startup & Presence"))
        startupHeading.font = .boldSystemFont(ofSize: 17)
        settingsLaunchAtLoginButton.target = self
        settingsLaunchAtLoginButton.action = #selector(launchAtLoginChanged(_:))
        settingsShowDockIconButton.target = self
        settingsShowDockIconButton.action = #selector(showDockIconChanged(_:))
        let startupOptions = NSStackView(views: [settingsLaunchAtLoginButton, settingsShowDockIconButton])
        startupOptions.orientation = .horizontal
        startupOptions.alignment = .centerY
        startupOptions.spacing = 28

        let windowHeading = NSTextField(labelWithString: L10n.string("Window Presentation"))
        windowHeading.font = .boldSystemFont(ofSize: 17)
        let placementLabel = NSTextField(labelWithString: L10n.string("When showing FindAll:"))

        centerPlacementButton.target = self
        centerPlacementButton.action = #selector(windowPlacementChanged(_:))
        rememberPlacementButton.target = self
        rememberPlacementButton.action = #selector(windowPlacementChanged(_:))
        let placementOptions = NSStackView(views: [centerPlacementButton, rememberPlacementButton])
        placementOptions.orientation = .vertical
        placementOptions.alignment = .leading
        placementOptions.spacing = 5
        placementOptions.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let startupSizeLabel = NSTextField(labelWithString: L10n.string("At app launch:"))
        startupSizePopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let resetWindowSize = NSButton(title: L10n.string("Restore Default Window Size Now"), target: self, action: #selector(resetWindowSize(_:)))
        settingsKeepOnTopButton.target = self
        settingsKeepOnTopButton.action = #selector(settingsWindowBehaviorChanged(_:))
        settingsAllSpacesButton.target = self
        settingsAllSpacesButton.action = #selector(settingsWindowBehaviorChanged(_:))

        let layoutHeading = NSTextField(labelWithString: L10n.string("Result List Layout"))
        layoutHeading.font = .boldSystemFont(ofSize: 17)
        let layoutHelp = NSTextField(wrappingLabelWithString: L10n.string("Fitted columns can still be adjusted: other columns compensate to avoid horizontal scrolling. Name and Modified shrink last; Path shrinks first. Manual column widths change only when you drag a divider; resizing the window does not redistribute them, and overflow uses horizontal scrolling."))
        layoutHelp.textColor = .secondaryLabelColor
        let sizingLabel = NSTextField(labelWithString: L10n.string("Column widths:"))
        columnSizingPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let resetLayout = NSButton(title: L10n.string("Restore Default Column Layout"), target: self, action: #selector(resetColumnLayout(_:)))

        let fileManagerHeading = NSTextField(labelWithString: L10n.string("File Manager"))
        fileManagerHeading.font = .boldSystemFont(ofSize: 17)
        let fileManagerHelp = NSTextField(wrappingLabelWithString: L10n.string("Double-clicking a folder opens it in the selected file manager. Showing an item opens its parent and selects it in Finder or QSpace; unsupported file managers open the parent folder."))
        fileManagerHelp.textColor = .secondaryLabelColor
        let fileManagerLabel = NSTextField(labelWithString: L10n.string("Default file manager:"))
        fileManagerPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let placementRow = NSStackView(views: [placementLabel, placementOptions])
        placementRow.orientation = .horizontal
        placementRow.alignment = .top
        placementRow.spacing = 12
        let startupSizeRow = NSStackView(views: [startupSizeLabel, startupSizePopup])
        startupSizeRow.orientation = .horizontal
        startupSizeRow.alignment = .centerY
        startupSizeRow.spacing = 12
        let sizingRow = NSStackView(views: [sizingLabel, columnSizingPopup, resetLayout])
        sizingRow.orientation = .horizontal
        sizingRow.alignment = .centerY
        sizingRow.spacing = 12
        let fileManagerRow = NSStackView(views: [fileManagerLabel, fileManagerPopup])
        fileManagerRow.orientation = .horizontal
        fileManagerRow.alignment = .centerY
        fileManagerRow.spacing = 12

        let stack = NSStackView(views: [
            languageHeading,
            languageRow,
            startupHeading,
            startupOptions,
            windowHeading,
            placementRow,
            startupSizeRow,
            resetWindowSize,
            settingsKeepOnTopButton,
            settingsAllSpacesButton,
            layoutHeading,
            layoutHelp,
            sizingRow,
            fileManagerHeading,
            fileManagerHelp,
            fileManagerRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: languageRow)
        stack.setCustomSpacing(18, after: startupOptions)
        stack.setCustomSpacing(18, after: settingsAllSpacesButton)
        stack.setCustomSpacing(18, after: sizingRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            layoutHelp.widthAnchor.constraint(equalToConstant: 600),
            fileManagerHelp.widthAnchor.constraint(equalToConstant: 600)
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
        folderColumn.title = L10n.string("Folder")
        folderColumn.minWidth = 300
        folderColumn.width = 430
        let priorityColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("priority"))
        priorityColumn.title = L10n.string("Priority")
        priorityColumn.minWidth = 130
        priorityColumn.width = 150
        rulesTableView.addTableColumn(folderColumn)
        rulesTableView.addTableColumn(priorityColumn)
    }

    private func makeShortcutsView() -> NSView {
        let view = NSView()
        let heading = NSTextField(labelWithString: L10n.string("Keyboard Shortcuts"))
        heading.font = .boldSystemFont(ofSize: 17)
        let help = NSTextField(wrappingLabelWithString: L10n.string("Every button shows its saved shortcut. Click one and press a new combination; modifiers are shown live. Click elsewhere or press Escape to cancel."))
        help.textColor = .secondaryLabelColor

        let globalHeading = NSTextField(labelWithString: L10n.string("Available in Any Application"))
        globalHeading.font = .boldSystemFont(ofSize: 14)
        let globalRows = makeShortcutRows(commands: [.globalToggle])
        let resultsHeading = NSTextField(labelWithString: L10n.string("FindAll File Lists"))
        resultsHeading.font = .boldSystemFont(ofSize: 14)
        let resultsHelp = NSTextField(wrappingLabelWithString: L10n.string("These shortcuts work when a FindAll file list has keyboard focus and an item is selected."))
        resultsHelp.textColor = .secondaryLabelColor
        let resultRows = makeShortcutRows(commands: CommandID.resultListCommands)

        shortcutMessageLabel.textColor = .systemRed
        shortcutMessageLabel.lineBreakMode = .byTruncatingTail
        let resetAll = NSButton(title: L10n.string("Restore All Defaults"), target: self, action: #selector(resetAllShortcuts(_:)))
        resetAll.bezelStyle = .rounded

        [heading, help, globalHeading, globalRows, resultsHeading, resultsHelp, resultRows, shortcutMessageLabel, resetAll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            help.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            help.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            globalHeading.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 20),
            globalHeading.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            globalRows.topAnchor.constraint(equalTo: globalHeading.bottomAnchor, constant: 8),
            globalRows.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            resultsHeading.topAnchor.constraint(equalTo: globalRows.bottomAnchor, constant: 18),
            resultsHeading.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            resultsHelp.topAnchor.constraint(equalTo: resultsHeading.bottomAnchor, constant: 5),
            resultsHelp.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            resultsHelp.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            resultRows.topAnchor.constraint(equalTo: resultsHelp.bottomAnchor, constant: 9),
            resultRows.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            shortcutMessageLabel.topAnchor.constraint(equalTo: resultRows.bottomAnchor, constant: 14),
            shortcutMessageLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            shortcutMessageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            resetAll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            resetAll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        return view
    }

    private func makeShortcutRows(commands: [CommandID]) -> NSStackView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 8
        rows.alignment = .leading
        for command in commands {
            let label = NSTextField(labelWithString: command.title)
            let recorder = ShortcutRecorderButton(command: command)
            recorder.onBeginRecording = { [weak self, weak recorder] in
                self?.recorderButtons
                    .filter { $0 !== recorder && $0.isRecording }
                    .forEach { $0.cancelRecording() }
                self?.showShortcutMessage(L10n.string("Recording shortcut…"), isError: false)
            }
            recorder.onShortcut = { [weak self] command, shortcut in self?.save(shortcut, for: command) }
            recorder.onCancel = { [weak self] in self?.showShortcutMessage("") }
            recorder.onInvalid = { [weak self] message in self?.showShortcutMessage(message) }
            recorderButtons.append(recorder)

            let reset = NSButton(title: L10n.string("Reset"), target: self, action: #selector(resetOne(_:)))
            reset.tag = CommandID.allCases.firstIndex(of: command) ?? 0
            reset.bezelStyle = .inline

            let row = NSGridView(views: [[label, recorder, reset]])
            row.column(at: 0).width = 280
            row.column(at: 1).width = 200
            row.column(at: 2).width = 70
            rows.addArrangedSubview(row)
        }
        return rows
    }

    func numberOfRows(in tableView: NSTableView) -> Int { folderRules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === rulesTableView, let tableColumn, folderRules.indices.contains(row) else { return nil }
        let rule = folderRules[row]
        if tableColumn.identifier.rawValue == "priority" {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.identifier = tableColumn.identifier
            popup.controlSize = .small
            popup.preferredEdge = .minY
            popup.addItem(withTitle: rule.priority.title)
            for priority in FolderPriority.allCases {
                let item = NSMenuItem(title: priority.title, action: #selector(folderPriorityMenuItemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = priority.rawValue
                item.representedObject = row
                item.state = priority == rule.priority ? .on : .off
                popup.menu?.addItem(item)
            }
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
        rebuildSortModeMenu()
        prioritizeFolderRulesButton.state = SearchPreferences.prioritizeFolderRules ? .on : .off
        foldersFirstButton.state = SearchPreferences.foldersFirst ? .on : .off
        refreshFullDiskAccessStatus()
        rulesTableView.reloadData()
    }

    private func refreshWindowSettings() {
        rebuildLanguageMenu()
        refreshLaunchAtLoginStatus()
        let placement = WindowPreferences.placement
        centerPlacementButton.state = placement == .center ? .on : .off
        rememberPlacementButton.state = placement == .remember ? .on : .off
        rebuildStartupSizeMenu()
        rebuildColumnSizingMenu()
        settingsKeepOnTopButton.state = WindowPreferences.keepOnTop ? .on : .off
        settingsAllSpacesButton.state = WindowPreferences.showOnAllSpaces ? .on : .off
        settingsShowDockIconButton.state = WindowPreferences.showDockIcon ? .on : .off

        rebuildFileManagerMenu()
    }

    private func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            settingsLaunchAtLoginButton.state = .on
            settingsLaunchAtLoginButton.toolTip = nil
        case .requiresApproval:
            settingsLaunchAtLoginButton.state = .off
            settingsLaunchAtLoginButton.toolTip = L10n.string("Enable FindAll in System Settings > General > Login Items.")
        case .notRegistered, .notFound:
            settingsLaunchAtLoginButton.state = .off
            settingsLaunchAtLoginButton.toolTip = nil
        @unknown default:
            settingsLaunchAtLoginButton.state = .off
            settingsLaunchAtLoginButton.toolTip = nil
        }
    }

    private func rebuildLanguageMenu() {
        let selectedLanguage = AppLanguagePreferences.currentLanguage
        rebuildPullDown(
            languagePopup,
            selectedTitle: selectedLanguage.displayName,
            choices: AppLanguage.allCases.map { ($0.displayName, $0.rawValue, $0 == selectedLanguage) },
            action: #selector(languageChanged(_:))
        )
    }

    private func rebuildStartupSizeMenu() {
        let selectedMode = WindowPreferences.startupSize
        rebuildPullDown(
            startupSizePopup,
            selectedTitle: selectedMode.title,
            choices: WindowStartupSize.allCases.map { ($0.title, $0.rawValue, $0 == selectedMode) },
            action: #selector(startupWindowSizeChanged(_:))
        )
    }

    private func rebuildSortModeMenu() {
        let selectedMode = SearchPreferences.sortMode
        rebuildPullDown(
            sortModePopup,
            selectedTitle: selectedMode.title,
            choices: ResultSortMode.allCases.map { ($0.title, $0.rawValue, $0 == selectedMode) },
            action: #selector(sortModeChanged(_:))
        )
    }

    private func rebuildColumnSizingMenu() {
        let selectedMode = WindowPreferences.columnSizingMode
        rebuildPullDown(
            columnSizingPopup,
            selectedTitle: selectedMode.title,
            choices: ColumnSizingMode.allCases.map { ($0.title, $0.rawValue, $0 == selectedMode) },
            action: #selector(columnSizingChanged(_:))
        )
    }

    private func rebuildFileManagerMenu() {
        let selectedChoice = WindowPreferences.fileManagerChoice
        let customURL = WindowPreferences.customFileManagerURL
        let customName = customURL.map { FileManager.default.displayName(atPath: $0.path) }
        let selectedTitle: String
        switch selectedChoice {
        case .systemDefault: selectedTitle = L10n.string("System Default")
        case .finder: selectedTitle = "Finder"
        case .custom: selectedTitle = customName ?? L10n.string("System Default")
        }

        fileManagerPopup.removeAllItems()
        fileManagerPopup.addItem(withTitle: selectedTitle)
        let choices: [(String, FileManagerChoice)] = [
            (L10n.string("System Default"), .systemDefault),
            ("Finder", .finder)
        ]
        for (title, choice) in choices {
            addPullDownItem(
                to: fileManagerPopup,
                title: title,
                representedObject: choice.rawValue,
                selected: choice == selectedChoice,
                action: #selector(fileManagerChanged(_:))
            )
        }
        if let customName {
            addPullDownItem(
                to: fileManagerPopup,
                title: customName,
                representedObject: FileManagerChoice.custom.rawValue,
                selected: selectedChoice == .custom,
                action: #selector(fileManagerChanged(_:))
            )
        }
        fileManagerPopup.menu?.addItem(.separator())
        let choose = NSMenuItem(
            title: L10n.string("Choose Other Application…"),
            action: #selector(fileManagerChanged(_:)),
            keyEquivalent: ""
        )
        choose.target = self
        choose.representedObject = "__choose__"
        fileManagerPopup.menu?.addItem(choose)
    }

    private func rebuildPullDown(
        _ popup: NSPopUpButton,
        selectedTitle: String,
        choices: [(title: String, representedObject: String, selected: Bool)],
        action: Selector
    ) {
        popup.removeAllItems()
        popup.addItem(withTitle: selectedTitle)
        for choice in choices {
            addPullDownItem(
                to: popup,
                title: choice.title,
                representedObject: choice.representedObject,
                selected: choice.selected,
                action: action
            )
        }
    }

    private func addPullDownItem(
        to popup: NSPopUpButton,
        title: String,
        representedObject: String,
        selected: Bool,
        action: Selector
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.state = selected ? .on : .off
        popup.menu?.addItem(item)
    }

    private func scheduleWindowSettingsRefresh() {
        guard !isWindowSettingsRefreshScheduled else { return }
        isWindowSettingsRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isWindowSettingsRefreshScheduled = false
            self.refreshWindowSettings()
        }
    }

    private func selectItem(in popup: NSPopUpButton, representedObject: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == representedObject }) {
            popup.select(item)
        }
    }

    @objc private func windowPlacementChanged(_ sender: NSButton) {
        let placement: WindowPlacement
        if sender === centerPlacementButton {
            placement = .center
        } else if sender === rememberPlacementButton {
            placement = .remember
        } else {
            return
        }
        WindowPreferences.placement = placement
    }

    @objc private func languageChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue) else { return }
        let currentLanguage = AppLanguagePreferences.currentLanguage
        guard language != currentLanguage, let window else {
            rebuildLanguageMenu()
            return
        }

        let failureTitle = L10n.string("Could Not Restart FindAll")
        let failureMessage = L10n.string("The language change will apply the next time you open FindAll.")
        let failureButtonTitle = L10n.string("OK")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("Change Language?")
        alert.informativeText = String.localizedStringWithFormat(
            L10n.string("FindAll needs to restart to use %@."),
            language.displayName
        )
        alert.addButton(withTitle: L10n.string("Restart and Apply"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.rebuildLanguageMenu()
                return
            }

            AppLanguagePreferences.select(language)
            self.rebuildLanguageMenu()
            guard let delegate = NSApp.delegate as? AppDelegate else {
                self.showRestartFailure(
                    title: failureTitle,
                    message: failureMessage,
                    buttonTitle: failureButtonTitle
                )
                return
            }
            delegate.relaunchApplication { [weak self] _ in
                self?.showRestartFailure(
                    title: failureTitle,
                    message: failureMessage,
                    buttonTitle: failureButtonTitle
                )
            }
        }
    }

    private func showRestartFailure(title: String, message: String, buttonTitle: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: buttonTitle)
        alert.beginSheetModal(for: window)
    }

    @objc private func startupWindowSizeChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = WindowStartupSize(rawValue: rawValue) else { return }
        WindowPreferences.startupSize = mode
    }

    @objc private func resetWindowSize(_ sender: Any?) {
        WindowPreferences.resetWindowSize()
    }

    @objc private func settingsWindowBehaviorChanged(_ sender: NSButton) {
        if sender === settingsKeepOnTopButton {
            WindowPreferences.keepOnTop = sender.state == .on
        } else if sender === settingsAllSpacesButton {
            WindowPreferences.showOnAllSpaces = sender.state == .on
        }
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let service = SMAppService.mainApp
        let shouldLaunchAtLogin = sender.state == .on
        do {
            if shouldLaunchAtLogin {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            guard let window else {
                refreshLaunchAtLoginStatus()
                return
            }
            let alert = NSAlert(error: error)
            alert.messageText = L10n.string("Could Not Change Login Item")
            alert.informativeText = L10n.string("FindAll could not update its login item. You can manage it in System Settings > General > Login Items.")
            alert.beginSheetModal(for: window)
        }
        refreshLaunchAtLoginStatus()
    }

    @objc private func showDockIconChanged(_ sender: NSButton) {
        let shouldShowDockIcon = sender.state == .on
        let currentValue = WindowPreferences.showDockIcon
        guard shouldShowDockIcon != currentValue, let window else {
            settingsShowDockIconButton.state = currentValue ? .on : .off
            return
        }

        let failureTitle = L10n.string("Could Not Restart FindAll")
        let failureMessage = L10n.string("The Dock icon change will apply the next time you open FindAll.")
        let failureButtonTitle = L10n.string("OK")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("Change Dock Icon Visibility?")
        alert.informativeText = L10n.string("FindAll needs to restart to change its Dock icon visibility. When hidden, use the global keyboard shortcut to show FindAll.")
        alert.addButton(withTitle: L10n.string("Restart and Apply"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.settingsShowDockIconButton.state = currentValue ? .on : .off
                return
            }

            WindowPreferences.showDockIcon = shouldShowDockIcon
            self.settingsShowDockIconButton.state = shouldShowDockIcon ? .on : .off
            guard let delegate = NSApp.delegate as? AppDelegate else {
                self.showRestartFailure(
                    title: failureTitle,
                    message: failureMessage,
                    buttonTitle: failureButtonTitle
                )
                return
            }
            delegate.relaunchApplication { [weak self] _ in
                self?.showRestartFailure(
                    title: failureTitle,
                    message: failureMessage,
                    buttonTitle: failureButtonTitle
                )
            }
        }
    }

    @objc private func columnSizingChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = ColumnSizingMode(rawValue: rawValue) else { return }
        WindowPreferences.columnSizingMode = mode
    }

    @objc private func resetColumnLayout(_ sender: Any?) {
        WindowPreferences.resetColumnLayout()
    }

    @objc private func fileManagerChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        if rawValue == "__choose__" {
            chooseCustomFileManager()
            return
        }
        guard let choice = FileManagerChoice(rawValue: rawValue) else { return }
        WindowPreferences.fileManagerChoice = choice
    }

    private func chooseCustomFileManager() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = L10n.string("Choose")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.refreshWindowSettings()
                return
            }
            WindowPreferences.customFileManagerURL = url
            WindowPreferences.fileManagerChoice = .custom
        }
    }

    private func refreshFullDiskAccessStatus() {
        switch FullDiskAccessSupport.currentStatus() {
        case .granted:
            fullDiskAccessStatusLabel.stringValue = L10n.string("Full Disk Access is available.")
            fullDiskAccessStatusLabel.textColor = .systemGreen
            openFullDiskAccessSettingsButton.title = L10n.string("Manage Full Disk Access…")
        case .denied:
            fullDiskAccessStatusLabel.stringValue = L10n.string("Full Disk Access is not available.")
            fullDiskAccessStatusLabel.textColor = .systemOrange
            openFullDiskAccessSettingsButton.title = L10n.string("Open Full Disk Access Settings")
        case .unknown:
            fullDiskAccessStatusLabel.stringValue = L10n.string("Full Disk Access could not be confirmed.")
            fullDiskAccessStatusLabel.textColor = .secondaryLabelColor
            openFullDiskAccessSettingsButton.title = L10n.string("Open Full Disk Access Settings")
        }
    }

    @objc private func prioritizeFolderRulesChanged(_ sender: NSButton) {
        SearchPreferences.prioritizeFolderRules = sender.state == .on
    }

    @objc private func sortModeChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = ResultSortMode(rawValue: rawValue) else { return }
        SearchPreferences.sortMode = mode
        refreshSearchSettings()
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
        panel.prompt = L10n.string("Add")
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

    @objc private func folderPriorityMenuItemSelected(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int,
              folderRules.indices.contains(row),
              let priority = FolderPriority(rawValue: sender.tag) else { return }
        folderRules[row].priority = priority
        SearchPreferences.folderRules = folderRules

        let priorityColumn = rulesTableView.column(withIdentifier: NSUserInterfaceItemIdentifier("priority"))
        if priorityColumn >= 0,
           let popup = rulesTableView.view(atColumn: priorityColumn, row: row, makeIfNecessary: false) as? NSPopUpButton {
            popup.item(at: 0)?.title = priority.title
            for item in popup.itemArray.dropFirst() {
                item.state = item.tag == priority.rawValue ? .on : .off
            }
            popup.synchronizeTitleAndSelectedItem()
        }
        rulesTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
            showShortcutMessage(L10n.string("The global shortcut must include Command, Option, Control, or Shift."))
            refreshButtons()
            NSSound.beep()
            return
        }
        if isReservedMacShortcut(shortcut, for: command) {
            showShortcutMessage(L10n.string("That shortcut is reserved by a standard macOS command."))
            refreshButtons()
            NSSound.beep()
            return
        }
        if let conflict = ShortcutSettings.conflictingCommand(for: shortcut, excluding: command) {
            let message = String.localizedStringWithFormat(L10n.string("That shortcut is already assigned to “%@”."), conflict.title)
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
        showShortcutMessage(L10n.string("Shortcut updated."), isError: false)
        refreshButtons()
        onShortcutChange()
    }

    private func isReservedMacShortcut(_ shortcut: KeyboardShortcut, for command: CommandID) -> Bool {
        guard shortcut.modifiers == .command else { return false }
        if command == .copyFiles, shortcut.characters.lowercased() == "c" { return false }
        return ["a", "c", "h", "m", "q", "v", "w", "x", "z", ","].contains(shortcut.characters.lowercased())
    }

    private func showShortcutMessage(_ message: String, isError: Bool = true) {
        shortcutMessageLabel.stringValue = message
        shortcutMessageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func refreshButtons() { recorderButtons.forEach { $0.refresh() } }

    private func validateGlobalShortcut(_ shortcut: KeyboardShortcut) -> String? {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            return L10n.string("The global shortcut could not be registered because the application is not ready.")
        }
        let status = delegate.validateGlobalShortcut(shortcut)
        guard status != noErr else { return nil }
        return String.localizedStringWithFormat(
            L10n.string("The global shortcut could not be registered (error %lld). It may already be used by macOS or another application."),
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
        showShortcutMessage(L10n.string("Shortcut restored."), isError: false)
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
        showShortcutMessage(L10n.string("All shortcuts restored."), isError: false)
        refreshButtons()
        onShortcutChange()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshButtons()
        refreshSearchSettings()
        refreshWindowSettings()
    }

    func windowDidResignKey(_ notification: Notification) {
        recorderButtons.filter(\.isRecording).forEach { $0.cancelRecording() }
    }

    func windowWillClose(_ notification: Notification) {
        recorderButtons.filter(\.isRecording).forEach { $0.cancelRecording() }
    }
}
