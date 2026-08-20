import AppKit
import QuickLookUI

final class MainWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSMenuItemValidation {
    private let searchField = NSSearchField()
    private let scopePopup = NSPopUpButton()
    private let categoryPopup = NSPopUpButton()
    private let prioritizeFoldersButton = NSButton(checkboxWithTitle: String(localized: "Prioritize folder rules"), target: nil, action: nil)
    private let foldersFirstButton = NSButton(checkboxWithTitle: String(localized: "Folders first"), target: nil, action: nil)
    private let settingsButton = NSButton()
    private let scrollView = NSScrollView()
    private let tableView = ActionTableView()
    private let statusLabel = NSTextField(labelWithString: String(localized: "Type a query and press Return"))
    private let spinner = NSProgressIndicator()
    private let keepOnTopButton = NSButton(checkboxWithTitle: String(localized: "Keep on top in current Space"), target: nil, action: nil)
    private let allSpacesButton = NSButton(checkboxWithTitle: String(localized: "Show on all Spaces"), target: nil, action: nil)
    private let searchService = FileSearchService()
    private var candidates: [SearchResult] = []
    private var results: [SearchResult] = []
    private var lastSearchRequest: SearchRequest?
    private var preferencesObserver: NSObjectProtocol?
    private var isAdjustingColumns = false
    private var isSynchronizingSort = false
    private var lastColumnWidths: [NSUserInterfaceItemIdentifier: CGFloat] = [:]

    private enum WindowPreferenceKey {
        static let keepOnTop = "window.keepOnTop"
        static let showOnAllSpaces = "window.showOnAllSpaces"
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FindAll"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        restoreWindowBehavior()
        bindSearch()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: SearchPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.preferencesDidChange()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    func showAndFocusSearch() {
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        searchField.placeholderString = String(localized: "Search files, folders, and applications")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(executeSearch(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

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
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder

        configureTable()
        scrollView.documentView = tableView

        let scopeLabel = filterLabel(String(localized: "Scope:"))
        let categoryLabel = filterLabel(String(localized: "Type:"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let filterBar = NSStackView(views: [scopeLabel, scopePopup, categoryLabel, categoryPopup, spacer, prioritizeFoldersButton, foldersFirstButton, settingsButton])
        filterBar.orientation = .horizontal
        filterBar.alignment = .centerY
        filterBar.spacing = 7
        filterBar.translatesAutoresizingMaskIntoConstraints = false

        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusBar = NSStackView(views: [spinner, statusLabel, statusSpacer, keepOnTopButton, allSpacesButton])
        statusBar.orientation = .horizontal
        statusBar.alignment = .centerY
        statusBar.spacing = 8
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        [searchField, filterBar, scrollView, statusBar].forEach(content.addSubview)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            filterBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 5),
            filterBar.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: 27),

            scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -5),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
            statusBar.heightAnchor.constraint(equalToConstant: 24),

            scopePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            scopePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 230),
            categoryPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 105),
            settingsButton.widthAnchor.constraint(equalToConstant: 30)
        ])

        refreshFilterControls()
        DispatchQueue.main.async { [weak self] in self?.fitColumnsToViewport() }
    }

    private func filterLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func configureFilterControls() {
        scopePopup.controlSize = .small
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))

        categoryPopup.controlSize = .small
        categoryPopup.target = self
        categoryPopup.action = #selector(categoryChanged(_:))
        for category in SearchCategory.allCases {
            let item = NSMenuItem(title: category.title, action: nil, keyEquivalent: "")
            item.representedObject = category.rawValue
            categoryPopup.menu?.addItem(item)
        }

        prioritizeFoldersButton.controlSize = .small
        prioritizeFoldersButton.target = self
        prioritizeFoldersButton.action = #selector(prioritizeFoldersChanged(_:))

        foldersFirstButton.controlSize = .small
        foldersFirstButton.target = self
        foldersFirstButton.action = #selector(foldersFirstChanged(_:))

        keepOnTopButton.controlSize = .small
        keepOnTopButton.target = self
        keepOnTopButton.action = #selector(windowBehaviorChanged(_:))

        allSpacesButton.controlSize = .small
        allSpacesButton.target = self
        allSpacesButton.action = #selector(windowBehaviorChanged(_:))

        settingsButton.bezelStyle = .texturedRounded
        settingsButton.controlSize = .small
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: String(localized: "Settings"))
        settingsButton.toolTip = String(localized: "Settings")
        settingsButton.target = self
        settingsButton.action = #selector(openSettings(_:))
    }

    private func refreshFilterControls() {
        scopePopup.removeAllItems()
        let allItem = NSMenuItem(title: String(localized: "All Locations"), action: nil, keyEquivalent: "")
        allItem.representedObject = ""
        scopePopup.menu?.addItem(allItem)
        for rule in SearchPreferences.folderRules {
            let folderName = URL(fileURLWithPath: rule.path).lastPathComponent
            let item = NSMenuItem(title: "\(folderName) — \(rule.priority.title)", action: nil, keyEquivalent: "")
            item.toolTip = rule.path
            item.representedObject = rule.path
            scopePopup.menu?.addItem(item)
        }
        scopePopup.menu?.addItem(.separator())
        let chooseItem = NSMenuItem(title: String(localized: "Choose Folder…"), action: nil, keyEquivalent: "")
        chooseItem.representedObject = "__choose_folder__"
        scopePopup.menu?.addItem(chooseItem)

        let scopePath = SearchPreferences.scopePath ?? ""
        if let item = scopePopup.itemArray.first(where: { ($0.representedObject as? String) == scopePath }) {
            scopePopup.select(item)
        } else {
            scopePopup.select(allItem)
        }
        if let item = categoryPopup.itemArray.first(where: { ($0.representedObject as? String) == SearchPreferences.category.rawValue }) {
            categoryPopup.select(item)
        }
        prioritizeFoldersButton.state = SearchPreferences.prioritizeFolderRules ? .on : .off
        foldersFirstButton.state = SearchPreferences.foldersFirst ? .on : .off
        synchronizeTableSortDescriptor()
    }

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 28
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.autoresizingMask = [.width, .height]
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(openSelection(_:))
        tableView.target = self
        tableView.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onOpen = { [weak self] in self?.openSelection(nil) }
        tableView.onReveal = { [weak self] in self?.revealSelection(nil) }
        tableView.onCopyPath = { [weak self] in self?.copyPath(nil) }
        tableView.onCopyFiles = { [weak self] in self?.copySelection(nil) }

        addColumn("name", title: String(localized: "Name"), width: 260, minimum: 140)
        addColumn("path", title: String(localized: "Path"), width: 360, minimum: 190)
        addColumn("kind", title: String(localized: "Kind"), width: 120, minimum: 85)
        addColumn("size", title: String(localized: "Size"), width: 85, minimum: 70)
        addColumn("modified", title: String(localized: "Modified"), width: 145, minimum: 115)
        tableView.tableColumns.last?.resizingMask = []
        restoreColumnWidths()

        let menu = NSMenu()
        let open = menu.addItem(withTitle: String(localized: "Open"), action: #selector(openSelection(_:)), keyEquivalent: "")
        open.identifier = NSUserInterfaceItemIdentifier("command.open")
        open.target = self
        let quickLook = menu.addItem(withTitle: String(localized: "Quick Look"), action: #selector(toggleQuickLook(_:)), keyEquivalent: "")
        quickLook.identifier = NSUserInterfaceItemIdentifier("command.quickLook")
        quickLook.target = self
        let reveal = menu.addItem(withTitle: String(localized: "Show in File Manager"), action: #selector(revealSelection(_:)), keyEquivalent: "")
        reveal.identifier = NSUserInterfaceItemIdentifier("command.reveal")
        reveal.target = self
        menu.addItem(.separator())
        let copyPath = menu.addItem(withTitle: String(localized: "Copy Path"), action: #selector(copyPath(_:)), keyEquivalent: "")
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
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        tableView.addTableColumn(column)
    }

    private func fitColumnsToViewport() {
        guard !isAdjustingColumns, !tableView.tableColumns.isEmpty else { return }
        let availableWidth = max(scrollView.contentSize.width - 1, tableView.tableColumns.reduce(0) { $0 + $1.minWidth })
        guard availableWidth > 0 else { return }
        isAdjustingColumns = true
        defer { isAdjustingColumns = false }

        var difference = tableView.tableColumns.reduce(0) { $0 + $1.width } - availableWidth
        if difference > 0.5 {
            for column in tableView.tableColumns.reversed() {
                let reduction = min(difference, column.width - column.minWidth)
                column.width -= reduction
                difference -= reduction
                if difference <= 0.5 { break }
            }
        } else if difference < -0.5 {
            let filler = tableView.tableColumns.first(where: { $0.identifier.rawValue == "path" })
                ?? tableView.tableColumns.last
            filler?.width += -difference
        }

        var frame = tableView.frame
        frame.size.width = availableWidth
        tableView.frame = frame
        let visibleOrigin = scrollView.contentView.bounds.origin
        if visibleOrigin.x != 0 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: visibleOrigin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        snapshotColumnWidths()
        saveColumnWidths()
    }

    private func snapshotColumnWidths() {
        lastColumnWidths = Dictionary(uniqueKeysWithValues: tableView.tableColumns.map { ($0.identifier, $0.width) })
    }

    private func restoreColumnWidths() {
        guard let widths = UserDefaults.standard.dictionary(forKey: "table.columnWidths") as? [String: Double] else { return }
        for column in tableView.tableColumns {
            if let width = widths[column.identifier.rawValue] { column.width = max(column.minWidth, width) }
        }
    }

    private func saveColumnWidths() {
        let widths = Dictionary(uniqueKeysWithValues: tableView.tableColumns.map { ($0.identifier.rawValue, Double($0.width)) })
        UserDefaults.standard.set(widths, forKey: "table.columnWidths")
    }

    func windowDidResize(_ notification: Notification) {
        fitColumnsToViewport()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isAdjustingColumns,
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let index = tableView.tableColumns.firstIndex(where: { $0 === column }),
              index + 1 < tableView.tableColumns.count else {
            if !isAdjustingColumns { snapshotColumnWidths() }
            return
        }

        let neighbor = tableView.tableColumns[index + 1]
        let previousColumnWidth = lastColumnWidths[column.identifier] ?? column.width
        let previousNeighborWidth = lastColumnWidths[neighbor.identifier] ?? neighbor.width
        let pairWidth = previousColumnWidth + previousNeighborWidth
        let maximumColumnWidth = pairWidth - neighbor.minWidth
        let adjustedColumnWidth = min(max(column.width, column.minWidth), maximumColumnWidth)

        isAdjustingColumns = true
        column.width = adjustedColumnWidth
        neighbor.width = pairWidth - adjustedColumnWidth
        isAdjustingColumns = false
        snapshotColumnWidths()
        saveColumnWidths()
    }

    func refreshContextMenuShortcuts() {
        guard let menu = tableView.menu else { return }
        for command in [CommandID.open, .quickLook, .reveal, .copyPath] {
            let identifier = NSUserInterfaceItemIdentifier("command.\(command.rawValue)")
            guard let item = menu.items.first(where: { $0.identifier == identifier }) else { continue }
            let shortcut = ShortcutSettings.shortcut(for: command)
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
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
        SearchPreferences.sortMode = mode
    }

    private func synchronizeTableSortDescriptor() {
        let mode = SearchPreferences.sortMode
        let descriptor: NSSortDescriptor?
        switch mode {
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
                self.statusLabel.stringValue = String(localized: "Type a query and press Return")
            case .started:
                self.spinner.startAnimation(nil)
                self.statusLabel.stringValue = String(localized: "Starting Spotlight search…")
            case let .gathering(count):
                self.spinner.startAnimation(nil)
                self.statusLabel.stringValue = String.localizedStringWithFormat(
                    String(localized: "Searching… %lld results"),
                    Int64(count)
                )
            case let .results(results):
                self.candidates = results
                self.applyRanking()
                self.spinner.stopAnimation(nil)
                self.statusLabel.stringValue = self.results.isEmpty
                    ? String(localized: "No matching Spotlight results")
                    : String.localizedStringWithFormat(String(localized: "%lld results"), Int64(self.results.count))
                if !self.results.isEmpty && self.tableView.selectedRow < 0 {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
            case let .failed(failure):
                self.candidates = []
                self.applyRanking()
                self.spinner.stopAnimation(nil)
                switch failure {
                case .couldNotStart:
                    self.statusLabel.stringValue = String(localized: "Spotlight search could not start.")
                case .timedOut:
                    self.statusLabel.stringValue = String(localized: "Spotlight did not respond. Make sure Spotlight indexing is enabled.")
                }
            }
        }
    }

    private func currentRequest() -> SearchRequest {
        SearchRequest(text: searchField.stringValue, category: SearchPreferences.category, scopePath: SearchPreferences.scopePath)
    }

    private func performSearch() {
        let request = currentRequest()
        lastSearchRequest = request
        searchService.search(request)
    }

    private func preferencesDidChange() {
        refreshFilterControls()
        let request = currentRequest()
        if !request.text.isEmpty, request != lastSearchRequest {
            searchService.cancel()
            lastSearchRequest = nil
            statusLabel.stringValue = String(localized: "Press Return to search")
        } else {
            applyRanking()
        }
    }

    private func applyRanking() {
        let sortMode = SearchPreferences.sortMode
        let foldersFirst = SearchPreferences.foldersFirst
        let prioritizeFolderRules = SearchPreferences.prioritizeFolderRules
        let folderRules = SearchPreferences.folderRules
        let rankings = candidates.reduce(into: [URL: (priority: Int, ruleOrder: Int)]()) { values, result in
            values[result.url] = SearchPreferences.ranking(for: result.url, rules: folderRules)
        }
        results = candidates.sorted { lhs, rhs in
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

            let comparison: ComparisonResult
            switch sortMode {
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
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            switch sortMode {
            case .nameDescending, .pathDescending, .kindDescending, .sizeDescending, .modifiedDescending:
                return comparison == .orderedDescending
            default:
                return comparison == .orderedAscending
            }
        }
        tableView.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        searchService.cancel()
        lastSearchRequest = nil
        if !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusLabel.stringValue = String(localized: "Press Return to search")
        }
    }

    @objc private func executeSearch(_ sender: Any?) { performSearch() }

    @objc private func categoryChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let category = SearchCategory(rawValue: rawValue) else { return }
        SearchPreferences.category = category
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        if value == "__choose_folder__" {
            chooseSearchFolder()
        } else {
            SearchPreferences.scopePath = value.isEmpty ? nil : value
        }
    }

    private func chooseSearchFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.refreshFilterControls()
                return
            }
            SearchPreferences.addFolder(path: url.path)
            SearchPreferences.scopePath = url.path
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < results.count, let tableColumn else { return nil }
        let result = results[row]
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
        cell.imageView?.isHidden = identifier.rawValue != "name"

        switch identifier.rawValue {
        case "name":
            cell.textField?.stringValue = result.displayName
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: result.url.path)
        case "path": cell.textField?.stringValue = result.path
        case "kind": cell.textField?.stringValue = result.kind
        case "size": cell.textField?.stringValue = result.size.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "—"
        case "modified": cell.textField?.stringValue = result.modifiedAt.map(Self.dateFormatter.string(from:)) ?? "—"
        default: break
        }
        cell.textField?.toolTip = cell.textField?.stringValue
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyDown
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20),
            image.heightAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
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
        let folders = selectedResults.filter(\.isDirectory).map(\.url)
        if !folders.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(folders) }
        selectedResults.filter { !$0.isDirectory }.forEach { NSWorkspace.shared.open($0.url) }
    }

    @objc func revealSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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
        if [#selector(openSelection(_:)), #selector(revealSelection(_:)), #selector(copyPath(_:)), #selector(toggleQuickLook(_:))].contains(menuItem.action) {
            return !selectedURLs.isEmpty
        }
        return true
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

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

    private func restoreWindowBehavior() {
        keepOnTopButton.state = UserDefaults.standard.bool(forKey: WindowPreferenceKey.keepOnTop) ? .on : .off
        allSpacesButton.state = UserDefaults.standard.bool(forKey: WindowPreferenceKey.showOnAllSpaces) ? .on : .off
        applyWindowBehavior()
    }

    @objc private func windowBehaviorChanged(_ sender: NSButton) {
        UserDefaults.standard.set(keepOnTopButton.state == .on, forKey: WindowPreferenceKey.keepOnTop)
        UserDefaults.standard.set(allSpacesButton.state == .on, forKey: WindowPreferenceKey.showOnAllSpaces)
        applyWindowBehavior()
    }

    private func applyWindowBehavior() {
        guard let window else { return }
        window.level = keepOnTopButton.state == .on ? .floating : .normal
        var behavior = window.collectionBehavior
        behavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        if allSpacesButton.state == .on {
            behavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
        window.collectionBehavior = behavior
    }
}

private final class ActionTableView: NSTableView {
    var onQuickLook: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onCopyFiles: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if ShortcutSettings.shortcut(for: .open).matches(event) {
            onOpen?()
        } else if ShortcutSettings.shortcut(for: .quickLook).matches(event) {
            onQuickLook?()
        } else if ShortcutSettings.shortcut(for: .reveal).matches(event) {
            onReveal?()
        } else if ShortcutSettings.shortcut(for: .copyPath).matches(event) {
            onCopyPath?()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { onCopyFiles?() }
}
