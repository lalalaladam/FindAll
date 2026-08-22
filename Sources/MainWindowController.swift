import AppKit
import QuickLookUI

final class MainWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let searchField = NSSearchField()
    private let pathInputScrollView = NSScrollView()
    private let pathInputTextView = PathInputTextView()
    private let matchModeControl = NSSegmentedControl(
        labels: SearchMatchMode.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let categoryPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let prioritizeFoldersButton = NSButton(checkboxWithTitle: L10n.string("Prioritize folder rules"), target: nil, action: nil)
    private let foldersFirstButton = NSButton(checkboxWithTitle: L10n.string("Folders first"), target: nil, action: nil)
    private let settingsButton = NSButton()
    private let scrollView = NSScrollView()
    private let tableView = ActionTableView()
    private let statusLabel = WindowDragTextField(labelWithString: L10n.string("Type a query and press Return"))
    private let spinner = NSProgressIndicator()
    private let keepOnTopSwitch = NSSwitch()
    private let allSpacesSwitch = NSSwitch()
    private let searchService = FileSearchService()
    private var candidates: [SearchResult] = []
    private var results: [SearchResult] = []
    private var lastSearchRequest: SearchRequest?
    private var isChangingMatchMode = false
    private var filterBarSearchTopConstraint: NSLayoutConstraint?
    private var filterBarPathTopConstraint: NSLayoutConstraint?
    private var matchModeSearchCenterConstraint: NSLayoutConstraint?
    private var matchModePathCenterConstraint: NSLayoutConstraint?
    private var matchModeSearchTrailingConstraint: NSLayoutConstraint?
    private var matchModePathTrailingConstraint: NSLayoutConstraint?
    private var pathIgnoredFilterViews: [NSView] = []
    private var preferencesObserver: NSObjectProtocol?
    private var windowPreferencesObserver: NSObjectProtocol?
    private var resetColumnLayoutObserver: NSObjectProtocol?
    private var resetWindowSizeObserver: NSObjectProtocol?
    private var scrollerStyleObserver: NSObjectProtocol?
    private var volumeObservers: [NSObjectProtocol] = []
    private var sharingServicePicker: NSSharingServicePicker?
    private var isOpenConfirmationPresented = false
    private var isAdjustingColumns = false
    private var hasRestoredFittedColumnLayout = false
    private var isSynchronizingSort = false
    private var isFilterRefreshScheduled = false
    private var saveWindowOriginWorkItem: DispatchWorkItem?
    private var windowUsesAllSpacesPresentation = WindowPreferences.showOnAllSpaces
    private var activeColumnSizingMode = WindowPreferences.columnSizingMode
    private var activeSortMode = SearchPreferences.sortMode
    private var observedDefaultSortMode = SearchPreferences.sortMode

    private static let fullDiskAccessNoticeKey = "privacy.fullDiskAccessNoticeShown.v2"
    private static let displayedResultLimit = 5_000
    private static let defaultColumnOrder = ["name", "path", "kind", "size", "modified"]
    private static let defaultColumnWidths: [String: CGFloat] = [
        "name": 260,
        "path": 360,
        "kind": 120,
        "size": 85,
        "modified": 145
    ]

    init() {
        let window = Self.makeWindow(showOnAllSpaces: WindowPreferences.showOnAllSpaces)
        super.init(window: window)
        restoreWindowFrame()
        window.delegate = self
        buildInterface()
        restoreWindowBehavior()
        bindSearch()
        updateIdleStatus()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: SearchPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.preferencesDidChange()
        }
        windowPreferencesObserver = NotificationCenter.default.addObserver(
            forName: WindowPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.windowPreferencesDidChange()
        }
        resetColumnLayoutObserver = NotificationCenter.default.addObserver(
            forName: WindowPreferences.resetColumnLayoutNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetColumnLayout()
        }
        resetWindowSizeObserver = NotificationCenter.default.addObserver(
            forName: WindowPreferences.resetWindowSizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetWindowSize()
        }
        scrollerStyleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layoutColumns()
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification].map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleFilterControlsRefresh()
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    private static func makeWindow(showOnAllSpaces: Bool) -> NSWindow {
        let contentRect = NSRect(x: 0, y: 0, width: 980, height: 620)
        let baseStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window: NSWindow
        if showOnAllSpaces {
            let panel = NSPanel(
                contentRect: contentRect,
                styleMask: baseStyle.union(.nonactivatingPanel),
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            window = panel
        } else {
            window = NSWindow(
                contentRect: contentRect,
                styleMask: baseStyle,
                backing: .buffered,
                defer: false
            )
        }
        window.title = "FindAll"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        return window
    }

    deinit {
        saveWindowOriginWorkItem?.cancel()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let windowPreferencesObserver { NotificationCenter.default.removeObserver(windowPreferencesObserver) }
        if let resetColumnLayoutObserver { NotificationCenter.default.removeObserver(resetColumnLayoutObserver) }
        if let resetWindowSizeObserver { NotificationCenter.default.removeObserver(resetWindowSizeObserver) }
        if let scrollerStyleObserver { NotificationCenter.default.removeObserver(scrollerStyleObserver) }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        volumeObservers.forEach(workspaceCenter.removeObserver)
    }

    func showAndFocusSearch() {
        refreshFilterControls()
        if window?.isVisible == false { positionWindowForPresentation() }
        if windowUsesAllSpacesPresentation {
            window?.orderFrontRegardless()
            window?.makeKey()
        } else {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
        focusActiveSearchInput()
        showFullDiskAccessNoticeIfNeeded()
    }

    var showsOnAllSpaces: Bool { windowUsesAllSpacesPresentation }

    var shouldHideForGlobalToggle: Bool {
        guard let window, window.isVisible else { return false }
        return windowUsesAllSpacesPresentation ? window.isKeyWindow : NSApp.isActive
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        searchField.placeholderString = L10n.string("Search files, folders, and applications")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(executeSearch(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        configurePathInput()

        matchModeControl.controlSize = .regular
        matchModeControl.segmentStyle = .rounded
        matchModeControl.target = self
        matchModeControl.action = #selector(matchModeChanged(_:))
        for (index, mode) in SearchMatchMode.allCases.enumerated() {
            matchModeControl.setToolTip(mode.toolTip, forSegment: index)
        }
        matchModeControl.setAccessibilityLabel(L10n.string("Search mode"))
        matchModeControl.translatesAutoresizingMaskIntoConstraints = false

        configureFilterControls()

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = WindowPreferences.columnSizingMode == .manual
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder

        configureTable()
        scrollView.documentView = tableView

        let scopeLabel = filterLabel(L10n.string("Scope:"))
        let categoryLabel = filterLabel(L10n.string("Type:"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let filterBar = NSStackView(views: [scopeLabel, scopePopup, categoryLabel, categoryPopup, spacer, prioritizeFoldersButton, foldersFirstButton, settingsButton])
        filterBar.orientation = .horizontal
        filterBar.alignment = .centerY
        filterBar.spacing = 7
        filterBar.detachesHiddenViews = true
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        pathIgnoredFilterViews = [scopeLabel, scopePopup, categoryLabel, categoryPopup, prioritizeFoldersButton, foldersFirstButton]

        let statusSpacer = WindowDragView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keepOnTopControl = labeledSwitch(
            title: L10n.string("Keep on top in current Space"),
            control: keepOnTopSwitch
        )
        let allSpacesControl = labeledSwitch(
            title: L10n.string("Show on all Spaces"),
            control: allSpacesSwitch
        )
        let statusBar = WindowDragStackView(views: [spinner, statusLabel, statusSpacer, keepOnTopControl, allSpacesControl])
        statusBar.orientation = .horizontal
        statusBar.alignment = .centerY
        statusBar.spacing = 8
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        let statusSeparator = NSBox()
        statusSeparator.boxType = .separator
        statusSeparator.translatesAutoresizingMaskIntoConstraints = false

        [searchField, pathInputScrollView, filterBar, matchModeControl, scrollView, statusSeparator, statusBar].forEach(content.addSubview)

        let filterBarSearchTopConstraint = filterBar.topAnchor.constraint(
            equalTo: searchField.bottomAnchor,
            constant: 5
        )
        let filterBarPathTopConstraint = filterBar.topAnchor.constraint(
            equalTo: pathInputScrollView.bottomAnchor,
            constant: 5
        )
        self.filterBarSearchTopConstraint = filterBarSearchTopConstraint
        self.filterBarPathTopConstraint = filterBarPathTopConstraint
        filterBarPathTopConstraint.isActive = false

        let matchModeSearchCenterConstraint = matchModeControl.centerYAnchor.constraint(equalTo: searchField.centerYAnchor)
        let matchModePathCenterConstraint = matchModeControl.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor)
        let matchModeSearchTrailingConstraint = matchModeControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12)
        let matchModePathTrailingConstraint = matchModeControl.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -8)
        self.matchModeSearchCenterConstraint = matchModeSearchCenterConstraint
        self.matchModePathCenterConstraint = matchModePathCenterConstraint
        self.matchModeSearchTrailingConstraint = matchModeSearchTrailingConstraint
        self.matchModePathTrailingConstraint = matchModePathTrailingConstraint
        matchModePathCenterConstraint.isActive = false
        matchModePathTrailingConstraint.isActive = false

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: matchModeControl.leadingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            pathInputScrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            pathInputScrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            pathInputScrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            pathInputScrollView.heightAnchor.constraint(equalToConstant: 76),

            matchModeSearchCenterConstraint,
            matchModeSearchTrailingConstraint,
            matchModeControl.widthAnchor.constraint(equalToConstant: 280),
            matchModeControl.heightAnchor.constraint(equalToConstant: 28),

            filterBarSearchTopConstraint,
            filterBar.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            filterBar.heightAnchor.constraint(equalToConstant: 27),

            scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -5),

            statusSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusSeparator.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -2),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
            statusBar.heightAnchor.constraint(equalToConstant: 24),

            scopePopup.widthAnchor.constraint(equalToConstant: 205),
            categoryPopup.widthAnchor.constraint(equalToConstant: 115),
            settingsButton.widthAnchor.constraint(equalToConstant: 30)
        ])

        refreshFilterControls()
        content.layoutSubtreeIfNeeded()
        let pathContentSize = pathInputScrollView.contentSize
        pathInputTextView.minSize = NSSize(width: 0, height: pathContentSize.height)
        pathInputTextView.frame = NSRect(origin: .zero, size: pathContentSize)
        scrollView.layoutSubtreeIfNeeded()
        layoutColumns(initialLayout: true)
    }

    private func filterLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func labeledSwitch(title: String, control: NSSwitch) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        control.setAccessibilityLabel(title)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func configureFilterControls() {
        scopePopup.controlSize = .small
        scopePopup.preferredEdge = .minY

        categoryPopup.controlSize = .small
        categoryPopup.preferredEdge = .minY
        rebuildCategoryMenu()

        prioritizeFoldersButton.controlSize = .small
        prioritizeFoldersButton.target = self
        prioritizeFoldersButton.action = #selector(prioritizeFoldersChanged(_:))

        foldersFirstButton.controlSize = .small
        foldersFirstButton.target = self
        foldersFirstButton.action = #selector(foldersFirstChanged(_:))

        keepOnTopSwitch.controlSize = .small
        keepOnTopSwitch.target = self
        keepOnTopSwitch.action = #selector(windowBehaviorChanged(_:))

        allSpacesSwitch.controlSize = .small
        allSpacesSwitch.target = self
        allSpacesSwitch.action = #selector(windowBehaviorChanged(_:))

        settingsButton.bezelStyle = .texturedRounded
        settingsButton.controlSize = .small
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.string("Settings"))
        settingsButton.toolTip = L10n.string("Settings")
        settingsButton.target = self
        settingsButton.action = #selector(openSettings(_:))
    }

    private func configurePathInput() {
        pathInputScrollView.translatesAutoresizingMaskIntoConstraints = false
        pathInputScrollView.borderType = .bezelBorder
        pathInputScrollView.hasVerticalScroller = true
        pathInputScrollView.hasHorizontalScroller = false
        pathInputScrollView.autohidesScrollers = true
        pathInputScrollView.drawsBackground = true
        pathInputScrollView.backgroundColor = .textBackgroundColor
        pathInputScrollView.toolTip = L10n.string("Press Command-Return to resolve paths")

        pathInputTextView.delegate = self
        pathInputTextView.font = .systemFont(ofSize: NSFont.systemFontSize)
        pathInputTextView.textColor = .textColor
        pathInputTextView.backgroundColor = .textBackgroundColor
        pathInputTextView.drawsBackground = true
        pathInputTextView.isRichText = false
        pathInputTextView.importsGraphics = false
        pathInputTextView.allowsUndo = true
        pathInputTextView.isVerticallyResizable = true
        pathInputTextView.isHorizontallyResizable = false
        pathInputTextView.autoresizingMask = [.width]
        pathInputTextView.minSize = NSSize(width: 0, height: 0)
        pathInputTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        pathInputTextView.textContainerInset = NSSize(width: 5, height: 5)
        pathInputTextView.textContainer?.widthTracksTextView = true
        pathInputTextView.textContainer?.lineBreakMode = .byCharWrapping
        pathInputTextView.isAutomaticQuoteSubstitutionEnabled = false
        pathInputTextView.isAutomaticDashSubstitutionEnabled = false
        pathInputTextView.isAutomaticTextReplacementEnabled = false
        pathInputTextView.isContinuousSpellCheckingEnabled = false
        pathInputTextView.isGrammarCheckingEnabled = false
        pathInputTextView.placeholderString = L10n.string("Paste one or more file or folder paths")
        pathInputTextView.setAccessibilityLabel(L10n.string("Path input"))
        pathInputTextView.onCommit = { [weak self] in self?.performSearch() }
        pathInputScrollView.documentView = pathInputTextView
    }

    private func rebuildCategoryMenu() {
        categoryPopup.removeAllItems()
        let selectedCategory = SearchPreferences.category
        categoryPopup.addItem(withTitle: selectedCategory.title)
        categoryPopup.item(at: 0)?.toolTip = selectedCategory.title
        for category in SearchCategory.allCases {
            let item = NSMenuItem(title: category.title, action: #selector(categoryMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = category.rawValue
            item.state = category == selectedCategory ? .on : .off
            categoryPopup.menu?.addItem(item)
        }
        categoryPopup.toolTip = selectedCategory.title
    }

    private func refreshFilterControls() {
        scopePopup.removeAllItems()
        let rules = SearchPreferences.folderRules
        let savedPaths = rules.map(\.path)
        let selectedScope = SearchPreferences.scopePath
        let selectedTitle = selectedScope.map { scopeTitle(for: $0, among: savedPaths + [$0]) }
            ?? L10n.string("All Locations")
        scopePopup.addItem(withTitle: selectedTitle)
        scopePopup.item(at: 0)?.toolTip = selectedScope ?? L10n.string("All Locations")

        let allItem = NSMenuItem(title: L10n.string("All Locations"), action: #selector(scopeMenuItemSelected(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = ""
        allItem.state = selectedScope == nil ? .on : .off
        scopePopup.menu?.addItem(allItem)

        let externalVolumes = externalVolumeURLs()
        let externalPaths = externalVolumes.map(\.path)
        let externalItem = NSMenuItem(title: L10n.string("External Drives"), action: nil, keyEquivalent: "")
        let externalMenu = NSMenu(title: L10n.string("External Drives"))
        if externalVolumes.isEmpty {
            let unavailable = externalMenu.addItem(withTitle: L10n.string("No External Drives Detected"), action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
        } else {
            for volumeURL in externalVolumes {
                let item = NSMenuItem(
                    title: FileManager.default.displayName(atPath: volumeURL.path),
                    action: #selector(scopeMenuItemSelected(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.toolTip = volumeURL.path
                item.representedObject = volumeURL.path
                item.state = volumeURL.path == selectedScope ? .on : .off
                externalMenu.addItem(item)
            }
        }
        externalItem.submenu = externalMenu
        scopePopup.menu?.addItem(externalItem)

        if let selectedScope, !savedPaths.contains(selectedScope), !externalPaths.contains(selectedScope) {
            scopePopup.menu?.addItem(.separator())
            let heading = NSMenuItem(title: L10n.string("Temporary Scope"), action: nil, keyEquivalent: "")
            heading.isEnabled = false
            scopePopup.menu?.addItem(heading)
            let item = NSMenuItem(title: scopeTitle(for: selectedScope, among: savedPaths + [selectedScope]), action: #selector(scopeMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = selectedScope
            item.representedObject = selectedScope
            item.state = .on
            scopePopup.menu?.addItem(item)
        }

        if !rules.isEmpty {
            scopePopup.menu?.addItem(.separator())
            let savedFoldersItem = NSMenuItem(title: L10n.string("Saved Folders"), action: nil, keyEquivalent: "")
            let savedFoldersMenu = NSMenu(title: L10n.string("Saved Folders"))
            for rule in rules {
                let item = NSMenuItem(title: scopeTitle(for: rule.path, among: savedPaths), action: #selector(scopeMenuItemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.toolTip = rule.path
                item.representedObject = rule.path
                item.state = rule.path == selectedScope ? .on : .off
                savedFoldersMenu.addItem(item)
            }
            savedFoldersItem.submenu = savedFoldersMenu
            scopePopup.menu?.addItem(savedFoldersItem)
        }
        scopePopup.menu?.addItem(.separator())
        let chooseItem = NSMenuItem(title: L10n.string("Choose Temporary Folder…"), action: #selector(scopeCommandSelected(_:)), keyEquivalent: "")
        chooseItem.target = self
        chooseItem.representedObject = "__choose_folder__"
        scopePopup.menu?.addItem(chooseItem)
        let addItem = NSMenuItem(title: L10n.string("Add Saved Folder…"), action: #selector(scopeCommandSelected(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.representedObject = "__add_saved_folder__"
        scopePopup.menu?.addItem(addItem)
        let manageItem = NSMenuItem(title: L10n.string("Manage Saved Folders…"), action: #selector(scopeCommandSelected(_:)), keyEquivalent: "")
        manageItem.target = self
        manageItem.representedObject = "__manage_folders__"
        scopePopup.menu?.addItem(manageItem)

        scopePopup.toolTip = selectedScope ?? L10n.string("All Locations")
        rebuildCategoryMenu()
        prioritizeFoldersButton.state = SearchPreferences.prioritizeFolderRules ? .on : .off
        foldersFirstButton.state = SearchPreferences.foldersFirst ? .on : .off
        matchModeControl.selectedSegment = SearchMatchMode.allCases.firstIndex(of: SearchPreferences.matchMode) ?? 0
        updateControlsForSearchMode()
        synchronizeTableSortDescriptor()
    }

    private func updateControlsForSearchMode() {
        let isPathMode = SearchPreferences.matchMode == .path
        pathIgnoredFilterViews.forEach { $0.isHidden = isPathMode }
        searchField.isHidden = isPathMode
        pathInputScrollView.isHidden = !isPathMode
        filterBarSearchTopConstraint?.isActive = !isPathMode
        filterBarPathTopConstraint?.isActive = isPathMode
        matchModeSearchCenterConstraint?.isActive = !isPathMode
        matchModeSearchTrailingConstraint?.isActive = !isPathMode
        matchModePathCenterConstraint?.isActive = isPathMode
        matchModePathTrailingConstraint?.isActive = isPathMode
        searchField.placeholderString = L10n.string("Search files, folders, and applications")
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func focusActiveSearchInput() {
        if SearchPreferences.matchMode == .path {
            window?.makeFirstResponder(pathInputTextView)
        } else {
            window?.makeFirstResponder(searchField)
        }
    }

    private func scopeTitle(for path: String, among paths: [String]) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let duplicates = paths.filter { URL(fileURLWithPath: $0).lastPathComponent == name }
        guard duplicates.count > 1 else { return name }
        return "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
    }

    private func externalVolumeURLs() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.compactMap { volumeURL in
            guard let values = try? volumeURL.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  values.volumeIsInternal == false,
                  values.volumeIsLocal != false else { return nil }
            return FilePathSupport.userFacingURL(volumeURL).standardizedFileURL
        }
        .sorted {
            FileManager.default.displayName(atPath: $0.path)
                .localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
        }
    }

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 28
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: tableView.intercellSpacing.height)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.autoresizingMask = [.height]
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(openSelection(_:))
        tableView.target = self
        tableView.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onOpen = { [weak self] in self?.openSelection(nil) }
        tableView.onReveal = { [weak self] in self?.revealSelection(nil) }
        tableView.onShare = { [weak self] in self?.shareSelection(nil) }
        tableView.onGetInfo = { [weak self] in self?.showFinderInfo(nil) }
        tableView.onCopyPath = { [weak self] in self?.copyPath(nil) }
        tableView.onCopyFiles = { [weak self] in self?.copySelection(nil) }
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let fittedHeaderView = FittedTableHeaderView()
        fittedHeaderView.usesFittedResizing = { WindowPreferences.columnSizingMode == .fitWindow }
        fittedHeaderView.resizeDirections = { [weak self] dividerIndex in
            self?.fittedResizeDirections(at: dividerIndex) ?? (false, false)
        }
        fittedHeaderView.onResizeWillBegin = { [weak self] in self?.isAdjustingColumns = true }
        fittedHeaderView.onResize = { [weak self] dividerIndex, initialWidths, delta in
            self?.resizeFittedColumns(at: dividerIndex, initialWidths: initialWidths, delta: delta)
        }
        fittedHeaderView.onResizeDidEnd = { [weak self] in
            guard let self else { return }
            self.isAdjustingColumns = false
            self.saveFittedColumnLayout()
        }
        tableView.headerView = fittedHeaderView

        addColumn("name", title: L10n.string("Name"), width: 260, minimum: 140)
        addColumn("path", title: L10n.string("Path"), width: 360, minimum: 190)
        addColumn("kind", title: L10n.string("Kind"), width: 120, minimum: 70)
        addColumn("size", title: L10n.string("Size"), width: 85, minimum: 70)
        addColumn("modified", title: L10n.string("Modified"), width: 145, minimum: 115)
        restoreColumnOrder()
        if WindowPreferences.columnSizingMode == .manual {
            restoreColumnWidths(forKey: WindowPreferences.columnWidthsKey)
        }

        let menu = NSMenu()
        menu.delegate = self
        let open = menu.addItem(withTitle: L10n.string("Open"), action: #selector(openSelection(_:)), keyEquivalent: "")
        open.identifier = NSUserInterfaceItemIdentifier("command.open")
        open.target = self
        let openWith = menu.addItem(withTitle: L10n.string("Open With"), action: nil, keyEquivalent: "")
        openWith.identifier = NSUserInterfaceItemIdentifier("context.openWith")
        openWith.submenu = NSMenu(title: L10n.string("Open With"))
        let quickLook = menu.addItem(withTitle: L10n.string("Quick Look"), action: #selector(toggleQuickLook(_:)), keyEquivalent: "")
        quickLook.identifier = NSUserInterfaceItemIdentifier("command.quickLook")
        quickLook.target = self
        let reveal = menu.addItem(withTitle: L10n.string("Show in File Manager"), action: #selector(revealSelection(_:)), keyEquivalent: "")
        reveal.identifier = NSUserInterfaceItemIdentifier("command.reveal")
        reveal.target = self
        menu.addItem(.separator())
        let info = menu.addItem(withTitle: L10n.string("Get Info"), action: #selector(showFinderInfo(_:)), keyEquivalent: "")
        info.identifier = NSUserInterfaceItemIdentifier("command.getInfo")
        info.target = self
        let share = menu.addItem(withTitle: L10n.string("Share"), action: #selector(shareSelection(_:)), keyEquivalent: "")
        share.identifier = NSUserInterfaceItemIdentifier("command.share")
        share.target = self
        menu.addItem(.separator())
        let copyFiles = menu.addItem(withTitle: L10n.string("Copy Files"), action: #selector(copySelection(_:)), keyEquivalent: "")
        copyFiles.identifier = NSUserInterfaceItemIdentifier("command.copyFiles")
        copyFiles.target = self
        let copyPath = menu.addItem(withTitle: L10n.string("Copy Path"), action: #selector(copyPath(_:)), keyEquivalent: "")
        copyPath.identifier = NSUserInterfaceItemIdentifier("command.copyPath")
        copyPath.target = self
        tableView.menu = menu
        refreshContextMenuShortcuts()
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat, minimum: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minimum
        column.resizingMask = .userResizingMask
        column.headerToolTip = title
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        tableView.addTableColumn(column)
    }

    private func layoutColumns(initialLayout: Bool = false) {
        guard !isAdjustingColumns, !tableView.tableColumns.isEmpty else { return }
        let fitsWindow = WindowPreferences.columnSizingMode == .fitWindow
        let desiredScrollerStyle: NSScroller.Style = fitsWindow ? NSScroller.preferredScrollerStyle : .legacy
        if scrollView.scrollerStyle != desiredScrollerStyle {
            scrollView.scrollerStyle = desiredScrollerStyle
        }
        let allowsHorizontalScrolling = !fitsWindow
        if scrollView.hasHorizontalScroller != allowsHorizontalScrolling {
            scrollView.hasHorizontalScroller = allowsHorizontalScrolling
        }
        var contentInsets = scrollView.contentInsets
        contentInsets.bottom = 0
        scrollView.contentInsets = contentInsets
        scrollView.tile()
        let viewportWidth = floor(scrollView.contentSize.width)
        guard viewportWidth > 0 else { return }
        let usableWidth = fitsWindow ? fittedColumnLayoutWidth : viewportWidth
        guard usableWidth > 0 else { return }

        if fitsWindow {
            isAdjustingColumns = true
            if initialLayout, !hasRestoredFittedColumnLayout {
                restoreFittedColumnLayout(to: usableWidth)
                hasRestoredFittedColumnLayout = true
            } else {
                fitColumns(to: usableWidth, protecting: nil)
            }
            isAdjustingColumns = false
        } else if initialLayout {
            restoreColumnWidths(forKey: WindowPreferences.columnWidthsKey)
        }

        let columnsWidth = tableView.tableColumns.reduce(0) { $0 + $1.width }
        var frame = tableView.frame
        if fitsWindow {
            frame.size.width = usableWidth
            tableView.frame = frame
        } else {
            frame.size.width = columnsWidth
            tableView.frame = frame
            stabilizeManualScrollerLayout(columnsWidth: columnsWidth)
        }
        let horizontalScrollerIsHidden = scrollView.horizontalScroller?.isHidden != false
        if (fitsWindow || horizontalScrollerIsHidden), scrollView.contentView.bounds.origin.x != 0 {
            var origin = scrollView.contentView.bounds.origin
            origin.x = 0
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        refreshColumnResizeCursorRects()
    }

    private func stabilizeManualScrollerLayout(columnsWidth: CGFloat) {
        for _ in 0..<3 {
            scrollView.tile()
            scrollView.layoutSubtreeIfNeeded()
            let targetWidth = max(columnsWidth, floor(scrollView.contentSize.width))
            guard abs(tableView.frame.width - targetWidth) > 0.5 else { return }
            var frame = tableView.frame
            frame.size.width = targetWidth
            tableView.frame = frame
        }
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()
    }

    private var fittedColumnLayoutWidth: CGFloat {
        let insets = scrollView.contentInsets
        let viewportWidth = floor(scrollView.bounds.width - insets.left - insets.right)
        guard scrollView.hasVerticalScroller else { return max(0, viewportWidth) }
        let reservedWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollView.scrollerStyle) + 4
        return max(0, viewportWidth - reservedWidth)
    }

    private func fitColumns(to targetWidth: CGFloat, protecting protectedIdentifier: String?) {
        var difference = targetWidth - tableView.tableColumns.reduce(0) { $0 + $1.width }
        guard abs(difference) > 0.5 else { return }
        if difference > 0 {
            let preferredGrowth: [String] = ["name", "path"].filter { identifier in
                protectedIdentifier != identifier
            }
            let growthColumns = preferredGrowth.compactMap {
                tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier($0))
            }
            let recipients = growthColumns.isEmpty
                ? tableView.tableColumns.filter { $0.identifier.rawValue != protectedIdentifier }
                : growthColumns
            let totalWidth = recipients.reduce(0) { $0 + $1.width }
            guard !recipients.isEmpty else { return }
            for (index, column) in recipients.enumerated() {
                let addition = index == recipients.count - 1
                    ? difference
                    : difference * column.width / max(totalWidth, 1)
                column.width += addition
                difference -= addition
            }
            return
        }

        var requiredReduction = -difference
        let shrinkGroups = [
            ["path"],
            ["kind", "size"],
            ["name", "modified"]
        ]
        for identifiers in shrinkGroups {
            let columns = identifiers
                .filter { $0 != protectedIdentifier }
                .compactMap { tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier($0)) }
            requiredReduction -= shrink(columns, by: requiredReduction)
            if requiredReduction <= 0.5 { return }
        }
        if let protectedIdentifier,
           let protectedColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(protectedIdentifier)) {
            _ = shrink([protectedColumn], by: requiredReduction)
        }
    }

    private func shrink(_ columns: [NSTableColumn], by requestedReduction: CGFloat) -> CGFloat {
        guard requestedReduction > 0.5 else { return 0 }
        let capacities = columns.map { max(0, $0.width - $0.minWidth) }
        let totalCapacity = capacities.reduce(0, +)
        guard totalCapacity > 0 else { return 0 }
        let actualReduction = min(requestedReduction, totalCapacity)
        var remainingReduction = actualReduction
        for (index, column) in columns.enumerated() {
            let reduction = index == columns.count - 1
                ? min(capacities[index], remainingReduction)
                : min(capacities[index], actualReduction * capacities[index] / totalCapacity)
            column.width -= reduction
            remainingReduction -= reduction
        }
        return actualReduction - max(0, remainingReduction)
    }

    private func resizeFittedColumns(at dividerIndex: Int, initialWidths: [CGFloat], delta: CGFloat) {
        let columns = tableView.tableColumns
        guard columns.indices.contains(dividerIndex),
              columns.indices.contains(dividerIndex + 1),
              initialWidths.count == columns.count else { return }

        var widths = initialWidths
        if delta >= 0 {
            let adjustment = shrinkFittedWidths(
                &widths,
                columns: columns,
                candidateIndices: Array(columns.indices.dropFirst(dividerIndex + 1)),
                by: delta
            )
            widths[dividerIndex] = initialWidths[dividerIndex] + adjustment
        } else {
            let adjustment = shrinkFittedWidths(
                &widths,
                columns: columns,
                candidateIndices: Array(columns.indices.prefix(dividerIndex + 1)),
                by: -delta
            )
            widths[dividerIndex + 1] = initialWidths[dividerIndex + 1] + adjustment
        }

        for (column, width) in zip(columns, widths) {
            column.width = width
        }
        tableView.needsDisplay = true
        tableView.headerView?.needsDisplay = true
        refreshColumnResizeCursorRects()
    }

    private func fittedResizeDirections(at dividerIndex: Int) -> (left: Bool, right: Bool) {
        let columns = tableView.tableColumns
        guard columns.indices.contains(dividerIndex), dividerIndex + 1 < columns.count else {
            return (false, false)
        }
        let canMoveLeft = columns.indices.prefix(dividerIndex + 1).contains { index in
            columns[index].width - columns[index].minWidth > 0.5
        }
        let canMoveRight = columns.indices.dropFirst(dividerIndex + 1).contains { index in
            columns[index].width - columns[index].minWidth > 0.5
        }
        return (canMoveLeft, canMoveRight)
    }

    private func refreshColumnResizeCursorRects() {
        guard let headerView = tableView.headerView, let window = headerView.window else { return }
        window.invalidateCursorRects(for: headerView)
    }

    private func shrinkFittedWidths(
        _ widths: inout [CGFloat],
        columns: [NSTableColumn],
        candidateIndices: [Int],
        by requestedReduction: CGFloat
    ) -> CGFloat {
        var remainingReduction = requestedReduction
        let shrinkGroups = [
            ["path"],
            ["kind", "size"],
            ["name", "modified"]
        ]

        for identifiers in shrinkGroups where remainingReduction > 0.5 {
            let indices = candidateIndices.filter { identifiers.contains(columns[$0].identifier.rawValue) }
            let capacities = indices.map { max(0, widths[$0] - columns[$0].minWidth) }
            let totalCapacity = capacities.reduce(0, +)
            guard totalCapacity > 0 else { continue }

            let groupReduction = min(remainingReduction, totalCapacity)
            var unallocatedReduction = groupReduction
            for (offset, index) in indices.enumerated() {
                let reduction = offset == indices.count - 1
                    ? min(capacities[offset], unallocatedReduction)
                    : min(capacities[offset], groupReduction * capacities[offset] / totalCapacity)
                widths[index] -= reduction
                unallocatedReduction -= reduction
            }
            remainingReduction -= groupReduction - max(0, unallocatedReduction)
        }

        return requestedReduction - max(0, remainingReduction)
    }

    private func restoreColumnWidths(forKey key: String) {
        guard let widths = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] else { return }
        let wasAdjustingColumns = isAdjustingColumns
        isAdjustingColumns = true
        defer { isAdjustingColumns = wasAdjustingColumns }
        for column in tableView.tableColumns {
            if let width = widths[column.identifier.rawValue] { column.width = max(column.minWidth, width) }
        }
    }

    private func restoreFittedColumnLayout(to targetWidth: CGFloat) {
        guard let savedWidths = UserDefaults.standard.dictionary(
            forKey: WindowPreferences.automaticColumnWidthsKey
        ) as? [String: Double] else {
            fitColumns(to: targetWidth, protecting: nil)
            return
        }

        let columns = tableView.tableColumns
        let widths = columns.map { column in
            max(column.minWidth, CGFloat(savedWidths[column.identifier.rawValue] ?? Double(column.width)))
        }
        let savedReferenceWidth = UserDefaults.standard.object(
            forKey: WindowPreferences.automaticColumnReferenceWidthKey
        ) == nil
            ? widths.reduce(0, +)
            : CGFloat(UserDefaults.standard.double(forKey: WindowPreferences.automaticColumnReferenceWidthKey))

        if abs(savedReferenceWidth - targetWidth) <= 0.5 {
            applyColumnWidths(widths)
            fitColumns(to: targetWidth, protecting: nil)
            return
        }

        let minimumWidth = columns.reduce(CGFloat.zero) { $0 + $1.minWidth }
        let availableFlexibleWidth = max(0, targetWidth - minimumWidth)
        let savedFlexibleWidths = zip(columns, widths).map { column, width in
            max(0, width - column.minWidth)
        }
        let totalSavedFlexibleWidth = savedFlexibleWidths.reduce(0, +)
        guard totalSavedFlexibleWidth > 0.5 else {
            applyColumnWidths(widths)
            fitColumns(to: targetWidth, protecting: nil)
            return
        }

        var remainingFlexibleWidth = availableFlexibleWidth
        let adaptedWidths = columns.indices.map { index -> CGFloat in
            let addition: CGFloat
            if index == columns.count - 1 {
                addition = remainingFlexibleWidth
            } else {
                addition = availableFlexibleWidth * savedFlexibleWidths[index] / totalSavedFlexibleWidth
                remainingFlexibleWidth -= addition
            }
            return columns[index].minWidth + max(0, addition)
        }
        applyColumnWidths(adaptedWidths)
        fitColumns(to: targetWidth, protecting: nil)
    }

    private func applyColumnWidths(_ widths: [CGFloat]) {
        for (column, width) in zip(tableView.tableColumns, widths) {
            column.width = max(column.minWidth, width)
        }
    }

    private func saveColumnWidths(forKey key: String) {
        let widths = Dictionary(uniqueKeysWithValues: tableView.tableColumns.map { ($0.identifier.rawValue, Double($0.width)) })
        UserDefaults.standard.set(widths, forKey: key)
    }

    private func saveFittedColumnLayout() {
        guard WindowPreferences.columnSizingMode == .fitWindow else { return }
        saveColumnWidths(forKey: WindowPreferences.automaticColumnWidthsKey)
        let referenceWidth = fittedColumnLayoutWidth > 0
            ? fittedColumnLayoutWidth
            : tableView.tableColumns.reduce(0) { $0 + $1.width }
        UserDefaults.standard.set(
            Double(referenceWidth),
            forKey: WindowPreferences.automaticColumnReferenceWidthKey
        )
    }

    private func restoreColumnOrder() {
        guard let savedOrder = UserDefaults.standard.stringArray(forKey: WindowPreferences.columnOrderKey) else { return }
        let validOrder = savedOrder.filter { identifier in
            tableView.tableColumns.contains { $0.identifier.rawValue == identifier }
        }
        for (targetIndex, identifier) in validOrder.enumerated() {
            let currentIndex = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
            if currentIndex >= 0, currentIndex != targetIndex {
                tableView.moveColumn(currentIndex, toColumn: targetIndex)
            }
        }
    }

    private func saveColumnOrder() {
        UserDefaults.standard.set(tableView.tableColumns.map(\.identifier.rawValue), forKey: WindowPreferences.columnOrderKey)
    }

    private func resetColumnLayout() {
        isAdjustingColumns = true
        for (targetIndex, identifier) in Self.defaultColumnOrder.enumerated() {
            let currentIndex = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
            if currentIndex >= 0, currentIndex != targetIndex {
                tableView.moveColumn(currentIndex, toColumn: targetIndex)
            }
            if let width = Self.defaultColumnWidths[identifier] {
                tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.width = width
            }
        }
        isAdjustingColumns = false
        layoutColumns()
    }

    func windowDidResize(_ notification: Notification) {
        layoutColumns()
        if WindowPreferences.startupSize == .previous, let window, !window.inLiveResize {
            WindowPreferences.savedSize = window.frame.size
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if WindowPreferences.startupSize == .previous, let window {
            WindowPreferences.savedSize = window.frame.size
        }
        saveFittedColumnLayout()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowOriginWorkItem?.cancel()
        saveWindowOriginWorkItem = nil
        saveWindowOrigin()
        if WindowPreferences.startupSize == .previous, let window {
            WindowPreferences.savedSize = window.frame.size
        }
        saveFittedColumnLayout()
    }

    func windowDidMove(_ notification: Notification) {
        guard WindowPreferences.placement == .remember else { return }
        saveWindowOriginWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveWindowOriginWorkItem = nil
            self?.saveWindowOrigin()
        }
        saveWindowOriginWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func saveWindowOrigin() {
        guard WindowPreferences.placement == .remember, let window else { return }
        WindowPreferences.savedOrigin = window.frame.origin
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isAdjustingColumns else { return }
        if WindowPreferences.columnSizingMode == .fitWindow {
            if let resizedColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn {
                let usableWidth = fittedColumnLayoutWidth
                isAdjustingColumns = true
                fitColumns(to: usableWidth, protecting: resizedColumn.identifier.rawValue)
                var frame = tableView.frame
                frame.size.width = usableWidth
                tableView.frame = frame
                isAdjustingColumns = false
            } else {
                layoutColumns()
            }
            saveFittedColumnLayout()
        } else {
            layoutColumns()
            saveColumnWidths(forKey: WindowPreferences.columnWidthsKey)
        }
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !isAdjustingColumns else { return }
        saveColumnOrder()
    }

    func refreshContextMenuShortcuts() {
        guard let menu = tableView.menu else { return }
        for command in CommandID.resultListCommands {
            let identifier = NSUserInterfaceItemIdentifier("command.\(command.rawValue)")
            guard let item = menu.items.first(where: { $0.identifier == identifier }) else { continue }
            let shortcut = ShortcutSettings.shortcut(for: command)
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tableView.menu else { return }
        updateOpenWithMenu(in: menu)
        updateRevealMenuItem(in: menu)
    }

    private func updateRevealMenuItem(in menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == "command.reveal" }) else { return }
        item.title = FileManagerSupport.canSelectRevealedItem
            ? L10n.string("Show in File Manager")
            : L10n.string("Open Containing Folder")
    }

    private func updateOpenWithMenu(in menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == "context.openWith" }),
              let submenu = item.submenu else { return }
        submenu.removeAllItems()
        let urls = selectedURLs
        guard !urls.isEmpty else {
            let unavailable = submenu.addItem(withTitle: L10n.string("No Applications Available"), action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            return
        }

        var commonApplicationPaths: Set<String>?
        for url in urls {
            let paths = Set(NSWorkspace.shared.urlsForApplications(toOpen: url).map { $0.standardizedFileURL.path })
            commonApplicationPaths = commonApplicationPaths.map { $0.intersection(paths) } ?? paths
        }
        let applications = (commonApplicationPaths ?? []).map(URL.init(fileURLWithPath:)).sorted {
            FileManager.default.displayName(atPath: $0.path)
                .localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
        }
        if applications.isEmpty {
            let unavailable = submenu.addItem(withTitle: L10n.string("No Applications Available"), action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
        } else {
            for applicationURL in applications {
                let applicationName = FileManager.default.displayName(atPath: applicationURL.path)
                let applicationItem = submenu.addItem(
                    withTitle: applicationName,
                    action: #selector(openSelectionWithApplication(_:)),
                    keyEquivalent: ""
                )
                applicationItem.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
                applicationItem.image?.size = NSSize(width: 16, height: 16)
                applicationItem.representedObject = applicationURL as NSURL
                applicationItem.target = self
            }
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSynchronizingSort, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        let mode: ResultSortMode
        switch (key, descriptor.ascending) {
        case ("name", true): mode = .nameAscending
        case ("name", false): mode = .nameDescending
        case ("path", true): mode = .pathAscending
        case ("path", false): mode = .pathDescending
        case ("kind", true): mode = .kindAscending
        case ("kind", false): mode = .kindDescending
        case ("size", true): mode = .sizeAscending
        case ("size", false): mode = .sizeDescending
        case ("modified", true): mode = .modifiedAscending
        case ("modified", false): mode = .modifiedDescending
        default: return
        }
        activeSortMode = mode
        applyRanking()
    }

    private func synchronizeTableSortDescriptor() {
        let mode = activeSortMode
        let descriptor: NSSortDescriptor?
        switch mode {
        case .smart: descriptor = nil
        case .nameAscending: descriptor = NSSortDescriptor(key: "name", ascending: true)
        case .nameDescending: descriptor = NSSortDescriptor(key: "name", ascending: false)
        case .pathAscending: descriptor = NSSortDescriptor(key: "path", ascending: true)
        case .pathDescending: descriptor = NSSortDescriptor(key: "path", ascending: false)
        case .kindAscending: descriptor = NSSortDescriptor(key: "kind", ascending: true)
        case .kindDescending: descriptor = NSSortDescriptor(key: "kind", ascending: false)
        case .sizeAscending: descriptor = NSSortDescriptor(key: "size", ascending: true)
        case .sizeDescending: descriptor = NSSortDescriptor(key: "size", ascending: false)
        case .modifiedAscending: descriptor = NSSortDescriptor(key: "modified", ascending: true)
        case .modifiedDescending: descriptor = NSSortDescriptor(key: "modified", ascending: false)
        }
        isSynchronizingSort = true
        tableView.sortDescriptors = descriptor.map { [$0] } ?? []
        isSynchronizingSort = false
    }

    private func bindSearch() {
        searchService.onUpdate = { [weak self] update in
            guard let self else { return }
            switch update {
            case .idle:
                self.candidates = []
                self.applyRanking()
                self.spinner.stopAnimation(nil)
                self.updateIdleStatus()
            case .started:
                self.tableView.deselectAll(nil)
                self.spinner.startAnimation(nil)
                self.statusLabel.toolTip = nil
                self.statusLabel.stringValue = L10n.string("Starting Spotlight search…")
            case let .pathStarted(count):
                self.tableView.deselectAll(nil)
                self.spinner.startAnimation(nil)
                self.statusLabel.toolTip = nil
                self.statusLabel.stringValue = String.localizedStringWithFormat(
                    L10n.string("Resolving %lld paths…"),
                    Int64(count)
                )
            case let .gathering(count):
                self.statusLabel.toolTip = nil
                self.statusLabel.stringValue = String.localizedStringWithFormat(
                    L10n.string("Searching… %lld candidates found"),
                    Int64(count)
                )
            case let .results(results, coverage):
                self.candidates = results
                self.applyRanking()
                self.spinner.stopAnimation(nil)
                self.statusLabel.toolTip = nil
                switch coverage {
                case .candidateLimitReached:
                    self.statusLabel.stringValue = String.localizedStringWithFormat(
                        L10n.string("Showing first %1$lld results (at least %2$lld matches)"),
                        Int64(self.results.count),
                        Int64(self.candidates.count)
                    )
                case .timedOut:
                    self.statusLabel.stringValue = String.localizedStringWithFormat(
                        L10n.string("Showing %lld partial results (search timed out)"),
                        Int64(self.results.count)
                    )
                case .complete where self.candidates.count > Self.displayedResultLimit:
                    self.statusLabel.stringValue = String.localizedStringWithFormat(
                        L10n.string("Showing first %1$lld of %2$lld results"),
                        Int64(self.results.count),
                        Int64(self.candidates.count)
                    )
                case .complete:
                    self.statusLabel.stringValue = self.results.isEmpty
                        ? L10n.string("No matching Spotlight results. Protected locations may require Full Disk Access.")
                        : String.localizedStringWithFormat(L10n.string("%lld results"), Int64(self.results.count))
                }
            case let .pathResults(results, summary):
                self.candidates = results
                self.applyRanking()
                self.spinner.stopAnimation(nil)
                self.statusLabel.stringValue = Self.pathStatus(summary: summary, foundCount: self.results.count)
                self.statusLabel.toolTip = Self.pathIssueToolTip(summary: summary)
            case let .failed(failure):
                self.candidates = []
                self.applyRanking()
                self.spinner.stopAnimation(nil)
                self.statusLabel.toolTip = nil
                switch failure {
                case .couldNotStart:
                    self.statusLabel.stringValue = L10n.string("Spotlight search could not start.")
                case .timedOut:
                    self.statusLabel.stringValue = L10n.string("Spotlight search timed out.")
                }
            }
        }
    }

    private func currentRequest() -> SearchRequest {
        let matchMode = SearchPreferences.matchMode
        return SearchRequest(
            text: currentSearchText,
            category: matchMode == .path ? .all : SearchPreferences.category,
            scopePath: matchMode == .path ? nil : SearchPreferences.scopePath,
            matchMode: matchMode,
            pathInputs: nil
        )
    }

    private var currentSearchText: String {
        SearchPreferences.matchMode == .path ? pathInputTextView.string : searchField.stringValue
    }

    private func performSearch() {
        let request = currentRequest()
        activeSortMode = request.matchMode == .path ? .smart : SearchPreferences.sortMode
        synchronizeTableSortDescriptor()
        lastSearchRequest = request
        searchService.search(request)
    }

    private func preferencesDidChange() {
        scheduleFilterControlsRefresh()
        let defaultSortMode = SearchPreferences.sortMode
        if defaultSortMode != observedDefaultSortMode {
            observedDefaultSortMode = defaultSortMode
            activeSortMode = defaultSortMode
            synchronizeTableSortDescriptor()
        }
        if isChangingMatchMode {
            applyRanking()
            return
        }
        let request = currentRequest()
        if !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           request != lastSearchRequest {
            performSearch()
        } else {
            applyRanking()
        }
    }

    private func scheduleFilterControlsRefresh() {
        guard !isFilterRefreshScheduled else { return }
        isFilterRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFilterRefreshScheduled = false
            self.refreshFilterControls()
        }
    }

    private func applyRanking() {
        let selectedURLs = Set(self.selectedURLs.map(\.standardizedFileURL))
        let scrollOrigin = scrollView.contentView.bounds.origin
        let sortMode = activeSortMode
        let foldersFirst = SearchPreferences.foldersFirst
        let prioritizeFolderRules = SearchPreferences.prioritizeFolderRules
        let folderRules = SearchPreferences.folderRules
        let preservesPathInputOrder = lastSearchRequest?.matchMode == .path && sortMode == .smart
        let pathInputOrder = Dictionary(uniqueKeysWithValues: candidates.enumerated().map {
            ($0.element.url.standardizedFileURL, $0.offset)
        })
        let rankings = candidates.reduce(into: [URL: (priority: Int, ruleOrder: Int)]()) { values, result in
            values[result.url] = SearchPreferences.ranking(for: result.url, rules: folderRules)
        }
        let sortedCandidates = candidates.sorted { lhs, rhs in
            if preservesPathInputOrder {
                return (pathInputOrder[lhs.url.standardizedFileURL] ?? Int.max)
                    < (pathInputOrder[rhs.url.standardizedFileURL] ?? Int.max)
            }
            if prioritizeFolderRules {
                let lhsRanking = rankings[lhs.url] ?? (priority: Int.max, ruleOrder: Int.max)
                let rhsRanking = rankings[rhs.url] ?? (priority: Int.max, ruleOrder: Int.max)
                if lhsRanking.priority != rhsRanking.priority { return lhsRanking.priority < rhsRanking.priority }
            }
            if foldersFirst, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            if prioritizeFolderRules {
                let lhsRuleOrder = rankings[lhs.url]?.ruleOrder ?? Int.max
                let rhsRuleOrder = rankings[rhs.url]?.ruleOrder ?? Int.max
                if lhsRuleOrder != rhsRuleOrder { return lhsRuleOrder < rhsRuleOrder }
            }

            if sortMode == .smart {
                let lhsIsCommonDocument = !lhs.isDirectory
                    && Self.commonDocumentExtensions.contains(lhs.url.pathExtension.lowercased())
                let rhsIsCommonDocument = !rhs.isDirectory
                    && Self.commonDocumentExtensions.contains(rhs.url.pathExtension.lowercased())
                if lhsIsCommonDocument != rhsIsCommonDocument { return lhsIsCommonDocument }
                let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

            let comparison: ComparisonResult
            switch sortMode {
            case .smart:
                comparison = .orderedSame
            case .nameAscending, .nameDescending:
                comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case .pathAscending, .pathDescending:
                comparison = lhs.path.localizedStandardCompare(rhs.path)
            case .kindAscending, .kindDescending:
                comparison = lhs.kind.localizedStandardCompare(rhs.kind)
            case .sizeAscending, .sizeDescending:
                comparison = Self.compare(lhs.size, rhs.size)
            case .modifiedAscending, .modifiedDescending:
                comparison = Self.compare(lhs.modifiedAt, rhs.modifiedAt)
            }
            if comparison == .orderedSame {
                if sortMode == .kindAscending || sortMode == .kindDescending {
                    let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                    if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
                }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            switch sortMode {
            case .nameDescending, .pathDescending, .kindDescending, .sizeDescending, .modifiedDescending:
                return comparison == .orderedDescending
            default:
                return comparison == .orderedAscending
            }
        }
        results = Array(sortedCandidates.prefix(Self.displayedResultLimit))
        tableView.reloadData()
        tableView.deselectAll(nil)
        if !selectedURLs.isEmpty {
            let selectedRows = IndexSet(results.indices.filter { selectedURLs.contains(results[$0].url.standardizedFileURL) })
            if !selectedRows.isEmpty {
                tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
            }
        }
        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        DispatchQueue.main.async { [weak self] in self?.layoutColumns() }
    }

    func controlTextDidChange(_ obj: Notification) {
        searchInputDidChange()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === pathInputTextView else { return }
        searchInputDidChange()
        pathInputTextView.needsDisplay = true
    }

    private func searchInputDidChange() {
        searchService.cancel()
        lastSearchRequest = nil
        updateIdleStatus()
    }

    @objc private func executeSearch(_ sender: Any?) { performSearch() }

    @objc private func matchModeChanged(_ sender: NSSegmentedControl) {
        guard SearchMatchMode.allCases.indices.contains(sender.selectedSegment) else { return }
        let mode = SearchMatchMode.allCases[sender.selectedSegment]
        guard mode != SearchPreferences.matchMode else { return }
        searchService.cancel()
        lastSearchRequest = nil
        isChangingMatchMode = true
        SearchPreferences.matchMode = mode
        isChangingMatchMode = false
        updateControlsForSearchMode()
        updateIdleStatus()
        focusActiveSearchInput()
    }

    private func updateIdleStatus() {
        statusLabel.toolTip = nil
        let text = currentSearchText
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if SearchPreferences.matchMode == .path {
            let pathCount = PathInputParser.parse(text).count
            if pathCount > 1 {
                statusLabel.stringValue = String.localizedStringWithFormat(
                    L10n.string("%lld paths ready; press Command-Return"),
                    Int64(pathCount)
                )
            } else {
                statusLabel.stringValue = hasText
                    ? L10n.string("Press Command-Return to resolve paths")
                    : L10n.string("Paste paths and press Command-Return")
            }
        } else {
            statusLabel.stringValue = hasText
                ? L10n.string("Press Return to search")
                : L10n.string("Type a query and press Return")
        }
    }

    @objc private func categoryMenuItemSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let category = SearchCategory(rawValue: rawValue) else { return }
        SearchPreferences.category = category
    }

    @objc private func scopeMenuItemSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        SearchPreferences.scopePath = value.isEmpty ? nil : value
    }

    @objc private func scopeCommandSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        if value == "__choose_folder__" {
            chooseSearchFolder()
        } else if value == "__add_saved_folder__" {
            addSavedSearchFolders()
        } else if value == "__manage_folders__" {
            openSettings(sender)
        }
    }

    private func chooseSearchFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("Choose")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.refreshFilterControls()
                return
            }
            SearchPreferences.scopePath = url.path
        }
    }

    private func addSavedSearchFolders() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.string("Add")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, !panel.urls.isEmpty else {
                self.refreshFilterControls()
                return
            }
            var rules = SearchPreferences.folderRules
            let newURLs = panel.urls.filter { url in
                !rules.contains(where: { $0.path == url.path })
            }
            rules.append(contentsOf: newURLs.map { FolderRule(path: $0.path, priority: .normal) })
            SearchPreferences.folderRules = rules
            SearchPreferences.scopePath = panel.urls[0].path
        }
    }

    @objc private func prioritizeFoldersChanged(_ sender: NSButton) {
        SearchPreferences.prioritizeFolderRules = sender.state == .on
    }

    @objc private func foldersFirstChanged(_ sender: NSButton) {
        SearchPreferences.foldersFirst = sender.state == .on
    }

    @objc private func openSettings(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.showPreferences(_:)), to: NSApp.delegate, from: sender)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !results.isEmpty, commandSelector == #selector(NSResponder.moveDown(_:)) else { return false }
        if tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        window?.makeFirstResponder(tableView)
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard results.indices.contains(row) else { return nil }
        return results[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < results.count, let tableColumn else { return nil }
        let result = results[row]
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ResultTableCellView) ?? makeCell(identifier: identifier)

        switch identifier.rawValue {
        case "name":
            cell.textField?.stringValue = Self.singleLineDisplayText(result.displayName)
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: result.url.path)
        case "path": cell.textField?.stringValue = Self.singleLineDisplayText(result.path)
        case "kind": cell.textField?.stringValue = Self.singleLineDisplayText(result.kind)
        case "size": cell.textField?.stringValue = result.size.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "—"
        case "modified": cell.textField?.stringValue = result.modifiedAt.map(Self.dateFormatter.string(from:)) ?? "—"
        default: break
        }
        cell.fullToolTipText = identifier.rawValue == "kind" && !result.fullKind.isEmpty
            ? Self.singleLineDisplayText(result.fullKind)
            : cell.textField?.stringValue
        cell.updateToolTip()
        return cell
    }

    private static func singleLineDisplayText(_ value: String) -> String {
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? "—" : normalized
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> ResultTableCellView {
        let cell = ResultTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyDown
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.maximumNumberOfLines = 1
        text.cell?.usesSingleLineMode = true
        text.lineBreakMode = .byTruncatingMiddle
        if identifier.rawValue == "modified" {
            text.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        cell.addSubview(text)
        cell.textField = text
        if identifier.rawValue == "name" {
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
                image.heightAnchor.constraint(equalToConstant: 20),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private var selectedURLs: [URL] {
        tableView.selectedRowIndexes.compactMap { $0 < results.count ? results[$0].url : nil }
    }

    @objc func openSelection(_ sender: Any?) {
        let selectedResults = tableView.selectedRowIndexes.compactMap { $0 < results.count ? results[$0] : nil }
        guard !selectedResults.isEmpty else { return }
        confirmOpeningIfNeeded(itemCount: selectedResults.count) { [weak self] in
            self?.open(selectedResults)
        }
    }

    private func open(_ selectedResults: [SearchResult]) {
        let folders = selectedResults.filter(\.isDirectory).map(\.url)
        FileManagerSupport.openFolders(folders)
        selectedResults.filter { !$0.isDirectory }.forEach { NSWorkspace.shared.open($0.url) }
    }

    @objc func revealSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileManagerSupport.reveal(urls)
    }

    @objc private func openSelectionWithApplication(_ sender: NSMenuItem) {
        let urls = selectedURLs
        guard let applicationURL = sender.representedObject as? URL, !urls.isEmpty else { return }
        confirmOpeningIfNeeded(itemCount: urls.count) {
            NSWorkspace.shared.open(
                urls,
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    private func confirmOpeningIfNeeded(itemCount: Int, action: @escaping () -> Void) {
        guard itemCount > 1 else {
            action()
            return
        }
        guard !isOpenConfirmationPresented else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String.localizedStringWithFormat(
            L10n.string("Open %lld Selected Items?"),
            Int64(itemCount)
        )
        alert.informativeText = L10n.string("Opening multiple items may open many windows or launch multiple applications.")
        let openButton = alert.addButton(withTitle: L10n.string("Open"))
        openButton.keyEquivalent = ""
        let cancelButton = alert.addButton(withTitle: L10n.string("Cancel"))
        cancelButton.keyEquivalent = "\r"

        isOpenConfirmationPresented = true
        guard let window else {
            isOpenConfirmationPresented = false
            if alert.runModal() == .alertFirstButtonReturn { action() }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.isOpenConfirmationPresented = false
            if response == .alertFirstButtonReturn { action() }
        }
    }

    @objc func showFinderInfo(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        let paths = selectedURLs.map { "\"\(Self.escapeAppleScriptString($0.path))\"" }.joined(separator: ", ")
        let source = """
        repeat with itemPath in {\(paths)}
            set targetItem to (POSIX file (contents of itemPath)) as alias
            tell application "Finder"
                open information window of targetItem
                activate
            end tell
        end repeat
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("Could Not Show Info")
            alert.informativeText = L10n.string("Finder could not open the information window. Allow FindAll to control Finder in Privacy & Security > Automation, then try again.")
            alert.runModal()
        }
    }

    @objc func shareSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        sharingServicePicker = picker
        let visibleRect = tableView.visibleRect
        let fallbackPoint: NSPoint
        if tableView.selectedRow >= 0 {
            let selectedRect = tableView.rect(ofRow: tableView.selectedRow)
            fallbackPoint = NSPoint(x: selectedRect.midX, y: selectedRect.midY)
        } else {
            fallbackPoint = NSPoint(x: visibleRect.midX, y: visibleRect.midY)
        }
        let requestedPoint = sender is NSMenuItem
            ? tableView.contextMenuAnchorPoint ?? fallbackPoint
            : fallbackPoint
        let anchorPoint = NSPoint(
            x: min(max(requestedPoint.x, visibleRect.minX + 8), visibleRect.maxX - 8),
            y: min(max(requestedPoint.y, visibleRect.minY + 8), visibleRect.maxY - 8)
        )
        picker.show(
            relativeTo: NSRect(x: anchorPoint.x, y: anchorPoint.y, width: 1, height: 1),
            of: tableView,
            preferredEdge: .maxY
        )
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = selectedURLs.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func copySelection(_ sender: Any?) {
        let urls = selectedURLs as [NSURL]
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    @objc func toggleQuickLook(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { selectedURLs[index] as NSURL }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(openSelection(_:)), #selector(revealSelection(_:)), #selector(showFinderInfo(_:)), #selector(shareSelection(_:)), #selector(copySelection(_:)), #selector(copyPath(_:)), #selector(toggleQuickLook(_:))].contains(menuItem.action) {
            return !selectedURLs.isEmpty
        }
        return true
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let commonDocumentExtensions: Set<String> = [
        "doc", "docx", "docm", "dot", "dotx", "xls", "xlsx", "xlsm", "xlsb", "csv",
        "ppt", "pptx", "pptm", "pps", "ppsx", "pdf", "txt", "md", "markdown", "rtf", "rtfd",
        "pages", "numbers", "key", "odt", "ods", "odp"
    ]

    private static func pathStatus(summary: PathSearchSummary, foundCount: Int) -> String {
        var parts = [foundCount == 0
            ? L10n.string("No paths could be resolved")
            : String.localizedStringWithFormat(L10n.string("%lld path results"), Int64(foundCount))]
        if summary.notFoundCount > 0 {
            parts.append(String.localizedStringWithFormat(
                L10n.string("%lld not found"),
                Int64(summary.notFoundCount)
            ))
        }
        if summary.inaccessibleCount > 0 {
            parts.append(String.localizedStringWithFormat(
                L10n.string("%lld inaccessible"),
                Int64(summary.inaccessibleCount)
            ))
        }
        if summary.invalidCount > 0 {
            parts.append(String.localizedStringWithFormat(
                L10n.string("%lld invalid"),
                Int64(summary.invalidCount)
            ))
        }
        if summary.duplicateCount > 0 {
            parts.append(String.localizedStringWithFormat(
                L10n.string("%lld duplicates ignored"),
                Int64(summary.duplicateCount)
            ))
        }
        if summary.omittedCount > 0 {
            parts.append(String.localizedStringWithFormat(
                L10n.string("%lld paths omitted by the input limit"),
                Int64(summary.omittedCount)
            ))
        }
        return parts.joined(separator: " · ")
    }

    private static func pathIssueToolTip(summary: PathSearchSummary) -> String? {
        guard !summary.issues.isEmpty || summary.omittedCount > 0 else { return nil }
        var lines = summary.issues.map { issue in
            let input = singleLineDisplayText(issue.input)
            switch issue.reason {
            case .notFound:
                return String.localizedStringWithFormat(L10n.string("Not found: %@"), input)
            case .inaccessible:
                return String.localizedStringWithFormat(L10n.string("Inaccessible: %@"), input)
            case .invalid:
                return String.localizedStringWithFormat(L10n.string("Invalid path: %@"), input)
            case .duplicate:
                return String.localizedStringWithFormat(L10n.string("Duplicate ignored: %@"), input)
            }
        }
        if summary.hasMoreIssues {
            lines.append(L10n.string("More path issues are not shown."))
        }
        if summary.omittedCount > 0 {
            lines.append(String.localizedStringWithFormat(
                L10n.string("%lld paths omitted by the input limit"),
                Int64(summary.omittedCount)
            ))
        }
        return lines.joined(separator: "\n")
    }

    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        }
    }

    private static func escapeAppleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func showFullDiskAccessNoticeIfNeeded() {
        guard FullDiskAccessSupport.currentStatus() == .denied,
              !UserDefaults.standard.bool(forKey: Self.fullDiskAccessNoticeKey),
              let window else { return }
        UserDefaults.standard.set(true, forKey: Self.fullDiskAccessNoticeKey)
        DispatchQueue.main.async { [weak self, weak window] in
            guard self != nil, let window else { return }
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.string("Full Disk Access Recommended")
            alert.informativeText = L10n.string("FindAll can search ordinary indexed locations without Full Disk Access, but protected-location results may be incomplete.")
            alert.addButton(withTitle: L10n.string("Open System Settings"))
            alert.addButton(withTitle: L10n.string("Later"))
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    FullDiskAccessSupport.openSystemSettings()
                }
            }
        }
    }

    private func restoreWindowBehavior() {
        keepOnTopSwitch.state = WindowPreferences.keepOnTop ? .on : .off
        allSpacesSwitch.state = WindowPreferences.showOnAllSpaces ? .on : .off
        applyWindowBehavior()
    }

    @objc private func windowBehaviorChanged(_ sender: NSSwitch) {
        if sender === keepOnTopSwitch {
            WindowPreferences.keepOnTop = sender.state == .on
        } else if sender === allSpacesSwitch {
            WindowPreferences.showOnAllSpaces = sender.state == .on
        }
    }

    private func applyWindowBehavior() {
        guard let window else { return }
        window.level = keepOnTopSwitch.state == .on ? .floating : .normal
        var behavior = window.collectionBehavior
        behavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications])
        if allSpacesSwitch.state == .on {
            behavior.insert([.canJoinAllSpaces, .canJoinAllApplications])
        }
        window.collectionBehavior = behavior
    }

    private func recreateWindowForSpaceModeChange() {
        guard let oldWindow = window, let contentView = oldWindow.contentView else { return }
        let frame = oldWindow.frame
        let wasVisible = oldWindow.isVisible
        let shouldRestoreSearchFocus = oldWindow.firstResponder === searchField.currentEditor()
            || oldWindow.firstResponder === searchField

        saveWindowOriginWorkItem?.cancel()
        saveWindowOriginWorkItem = nil
        oldWindow.delegate = nil
        oldWindow.orderOut(nil)
        oldWindow.contentView = nil

        let replacement = Self.makeWindow(showOnAllSpaces: WindowPreferences.showOnAllSpaces)
        replacement.setFrame(frame, display: false)
        replacement.contentView = contentView
        replacement.delegate = self
        window = replacement
        windowUsesAllSpacesPresentation = WindowPreferences.showOnAllSpaces
        applyWindowBehavior()

        if wasVisible {
            if windowUsesAllSpacesPresentation {
                replacement.orderFrontRegardless()
                replacement.makeKey()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                replacement.makeKeyAndOrderFront(nil)
            }
            if shouldRestoreSearchFocus {
                replacement.makeFirstResponder(searchField)
            }
        }
    }

    private func restoreWindowFrame() {
        guard let window else { return }
        if WindowPreferences.startupSize == .previous, let size = WindowPreferences.savedSize {
            var frame = window.frame
            frame.size.width = max(window.minSize.width, size.width)
            frame.size.height = max(window.minSize.height, size.height)
            window.setFrame(frame, display: false)
        }
        if WindowPreferences.placement == .remember {
            if let origin = WindowPreferences.savedOrigin {
                window.setFrameOrigin(origin)
                constrainWindowToVisibleScreens()
            } else {
                centerWindowOnCurrentDisplay()
            }
        }
    }

    private func resetWindowSize() {
        guard let window else { return }
        var frame = window.frame
        frame.size = WindowPreferences.defaultWindowSize
        window.setFrame(frame, display: true, animate: true)
        constrainWindowToVisibleScreens()
    }

    private func positionWindowForPresentation() {
        guard window != nil else { return }
        switch WindowPreferences.placement {
        case .center:
            centerWindowOnCurrentDisplay()
        case .remember:
            constrainWindowToVisibleScreens()
        }
    }

    private func centerWindowOnCurrentDisplay() {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? window.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        let origin = NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func constrainWindowToVisibleScreens() {
        guard let window else { return }
        let intersectsVisibleScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        guard !intersectsVisibleScreen else { return }
        centerWindowOnCurrentDisplay()
    }

    private func windowPreferencesDidChange() {
        if WindowPreferences.showOnAllSpaces != windowUsesAllSpacesPresentation {
            recreateWindowForSpaceModeChange()
        }
        let newColumnSizingMode = WindowPreferences.columnSizingMode
        let columnSizingModeChanged = newColumnSizingMode != activeColumnSizingMode
        if columnSizingModeChanged {
            saveColumnWidths(forKey: WindowPreferences.columnWidthsKey)
            activeColumnSizingMode = newColumnSizingMode
            if newColumnSizingMode == .fitWindow {
                hasRestoredFittedColumnLayout = true
            }
        }
        if let window {
            if WindowPreferences.startupSize == .previous { WindowPreferences.savedSize = window.frame.size }
            if WindowPreferences.placement == .remember { WindowPreferences.savedOrigin = window.frame.origin }
        }
        restoreWindowBehavior()
        let shouldRestoreFittedLayout = !columnSizingModeChanged
            && newColumnSizingMode == .fitWindow
            && !hasRestoredFittedColumnLayout
        layoutColumns(initialLayout: shouldRestoreFittedLayout)
        if columnSizingModeChanged {
            if newColumnSizingMode == .fitWindow {
                saveFittedColumnLayout()
            } else {
                saveColumnWidths(forKey: WindowPreferences.columnWidthsKey)
            }
        }
    }
}

private final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class WindowDragTextField: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class WindowDragStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class PathInputTextView: NSTextView {
    var placeholderString = "" {
        didSet { needsDisplay = true }
    }
    var onCommit: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let origin = textContainerOrigin
        let lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        let rect = NSRect(
            x: origin.x + lineFragmentPadding,
            y: origin.y,
            width: max(0, bounds.width - origin.x - lineFragmentPadding - textContainerInset.width),
            height: max(0, bounds.height - origin.y)
        )
        (placeholderString as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor
            ]
        )
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers
        let isReturn = characters == "\r" || characters == "\n" || characters == "\u{3}"
        if isReturn, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL],
           !objects.isEmpty {
            let paths = objects.map { ($0 as URL).path }.joined(separator: "\n")
            insertText(paths, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }
}

private final class ActionTableView: NSTableView {
    var onQuickLook: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onShare: (() -> Void)?
    var onGetInfo: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onCopyFiles: (() -> Void)?
    private(set) var contextMenuAnchorPoint: NSPoint?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        contextMenuAnchorPoint = point
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if ShortcutSettings.shortcut(for: .open).matches(event) {
            onOpen?()
        } else if ShortcutSettings.shortcut(for: .quickLook).matches(event) {
            onQuickLook?()
        } else if ShortcutSettings.shortcut(for: .reveal).matches(event) {
            onReveal?()
        } else if ShortcutSettings.shortcut(for: .copyFiles).matches(event) {
            onCopyFiles?()
        } else if ShortcutSettings.shortcut(for: .copyPath).matches(event) {
            onCopyPath?()
        } else if ShortcutSettings.shortcut(for: .share).matches(event) {
            onShare?()
        } else if ShortcutSettings.shortcut(for: .getInfo).matches(event) {
            onGetInfo?()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { onCopyFiles?() }
}

private final class ResultTableCellView: NSTableCellView {
    var fullToolTipText: String?

    override func layout() {
        super.layout()
        updateToolTip()
    }

    func updateToolTip() {
        guard let textField, textField.bounds.width > 0 else {
            toolTip = nil
            textField?.toolTip = nil
            return
        }
        let displayedText = textField.stringValue
        let completeText = fullToolTipText ?? displayedText
        let isAbbreviated = completeText != displayedText
        let isTruncated = !textField.expansionFrame(withFrame: textField.bounds).isEmpty
        let resolvedToolTip = isAbbreviated || isTruncated
            ? completeText
            : nil
        toolTip = resolvedToolTip
        textField.toolTip = resolvedToolTip
    }
}

private final class FittedTableHeaderView: NSTableHeaderView {
    var usesFittedResizing: (() -> Bool)?
    var resizeDirections: ((Int) -> (left: Bool, right: Bool))?
    var onResizeWillBegin: (() -> Void)?
    var onResize: ((Int, [CGFloat], CGFloat) -> Void)?
    var onResizeDidEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard usesFittedResizing?() == true,
              let tableView,
              let dividerIndex = dividerIndex(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }

        // The trailing table edge is fixed in fitted mode. Inner dividers exchange
        // width with the columns on the opposite side while the pointer is tracking.
        guard dividerIndex + 1 < tableView.tableColumns.count else { return }
        let directions = resizeDirections?(dividerIndex) ?? (left: false, right: false)
        guard directions.left || directions.right else { return }
        let initialX = convert(event.locationInWindow, from: nil).x
        let initialWidths = tableView.tableColumns.map(\.width)
        onResizeWillBegin?()
        defer { onResizeDidEnd?() }

        while let nextEvent = window?.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if nextEvent.type == .leftMouseUp { break }
            let currentX = convert(nextEvent.locationInWindow, from: nil).x
            onResize?(dividerIndex, initialWidths, currentX - initialX)
        }
    }

    override func resetCursorRects() {
        guard usesFittedResizing?() == true, let tableView else {
            super.resetCursorRects()
            return
        }

        let tolerance: CGFloat = 5
        for dividerIndex in tableView.tableColumns.indices.dropLast() {
            let directions = resizeDirections?(dividerIndex) ?? (left: false, right: false)
            guard directions.left || directions.right else { continue }
            let dividerX = tableView.rect(ofColumn: dividerIndex).maxX
            let cursorRect = bounds.intersection(
                NSRect(x: dividerX - tolerance, y: bounds.minY, width: tolerance * 2, height: bounds.height)
            )
            guard !cursorRect.isEmpty else { continue }
            let cursor: NSCursor
            switch (directions.left, directions.right) {
            case (true, true): cursor = .resizeLeftRight
            case (true, false): cursor = .resizeLeft
            case (false, true): cursor = .resizeRight
            case (false, false): continue
            }
            addCursorRect(cursorRect, cursor: cursor)
        }
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        guard let tableView else { return nil }
        let tolerance: CGFloat = 5
        return tableView.tableColumns.indices.min { lhs, rhs in
            abs(tableView.rect(ofColumn: lhs).maxX - point.x)
                < abs(tableView.rect(ofColumn: rhs).maxX - point.x)
        }.flatMap { index in
            abs(tableView.rect(ofColumn: index).maxX - point.x) <= tolerance ? index : nil
        }
    }
}
