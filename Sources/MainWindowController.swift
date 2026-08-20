import AppKit
import QuickLookUI

final class MainWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSMenuItemValidation {
    private let searchField = NSSearchField()
    private let tableView = ActionTableView()
    private let statusLabel = NSTextField(labelWithString: String(localized: "Type a query and press Return"))
    private let spinner = NSProgressIndicator()
    private let searchService = FileSearchService()
    private var results: [SearchResult] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FindAll"
        window.minSize = NSSize(width: 680, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        bindSearch()
    }

    required init?(coder: NSCoder) { nil }

    func showAndFocusSearch() {
        if window?.isVisible == false {
            window?.center()
        }
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

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder

        configureTable()
        scrollView.documentView = tableView

        content.addSubview(searchField)
        content.addSubview(scrollView)
        content.addSubview(spinner)
        content.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 34),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9)
        ])
        layoutColumnsToFit()
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

        addColumn("name", title: String(localized: "Name"), width: 260)
        addColumn("path", title: String(localized: "Location"), width: 380)
        addColumn("kind", title: String(localized: "Kind"), width: 140)
        addColumn("size", title: String(localized: "Size"), width: 90)
        addColumn("modified", title: String(localized: "Modified"), width: 150)

        let menu = NSMenu()
        let open = menu.addItem(withTitle: String(localized: "Open"), action: #selector(openSelection(_:)), keyEquivalent: "")
        open.identifier = NSUserInterfaceItemIdentifier("command.open")
        open.target = self
        let quickLook = menu.addItem(withTitle: String(localized: "Quick Look"), action: #selector(toggleQuickLook(_:)), keyEquivalent: "")
        quickLook.identifier = NSUserInterfaceItemIdentifier("command.quickLook")
        quickLook.target = self
        let reveal = menu.addItem(withTitle: String(localized: "Reveal in Finder"), action: #selector(revealSelection(_:)), keyEquivalent: "")
        reveal.identifier = NSUserInterfaceItemIdentifier("command.reveal")
        reveal.target = self
        menu.addItem(.separator())
        let copyPath = menu.addItem(withTitle: String(localized: "Copy Path"), action: #selector(copyPath(_:)), keyEquivalent: "")
        copyPath.identifier = NSUserInterfaceItemIdentifier("command.copyPath")
        copyPath.target = self
        tableView.menu = menu
        refreshContextMenuShortcuts()
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 70
        column.resizingMask = .userResizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        tableView.addTableColumn(column)
    }

    private func layoutColumnsToFit() {
        guard tableView.tableColumns.count == 5 else { return }
        let availableWidth = max(window?.contentView?.bounds.width ?? 980, 680)
        let kindWidth: CGFloat = 110
        let sizeWidth: CGFloat = 80
        let modifiedWidth: CGFloat = 135
        let flexibleWidth = max(availableWidth - kindWidth - sizeWidth - modifiedWidth - 8, 355)
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))?.width = max(150, flexibleWidth * 0.38)
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("path"))?.width = max(205, flexibleWidth * 0.62)
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("kind"))?.width = kindWidth
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size"))?.width = sizeWidth
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("modified"))?.width = modifiedWidth
    }

    func windowDidResize(_ notification: Notification) {
        layoutColumnsToFit()
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
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }
        let ascending = descriptor.ascending
        results.sort { lhs, rhs in
            let order: ComparisonResult
            switch key {
            case "name": order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case "path": order = lhs.path.localizedStandardCompare(rhs.path)
            case "kind": order = lhs.kind.localizedStandardCompare(rhs.kind)
            case "size": order = Self.compare(lhs.size, rhs.size)
            case "modified": order = Self.compare(lhs.modifiedAt, rhs.modifiedAt)
            default: return false
            }
            if order == .orderedSame {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        tableView.reloadData()
    }

    private func bindSearch() {
        searchService.onResultsChanged = { [weak self] results, searching in
            guard let self else { return }
            self.results = results
            if self.tableView.sortDescriptors.isEmpty {
                self.tableView.reloadData()
            } else {
                self.tableView(self.tableView, sortDescriptorsDidChange: [])
            }
            self.statusLabel.stringValue = searching
                ? String(localized: "Searching… \(results.count) results")
                : results.isEmpty && !self.searchField.stringValue.isEmpty
                    ? String(localized: "No matching Spotlight-indexed files")
                    : String(localized: "\(results.count) results")
            searching ? self.spinner.startAnimation(nil) : self.spinner.stopAnimation(nil)
            if !results.isEmpty && self.tableView.selectedRow < 0 {
                self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        searchService.cancel()
        spinner.stopAnimation(nil)
        statusLabel.stringValue = searchField.stringValue.isEmpty
            ? String(localized: "Type a query and press Return")
            : String(localized: "Press Return to search")
    }

    @objc private func executeSearch(_ sender: Any?) {
        searchService.search(text: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !results.isEmpty else { return false }
        guard commandSelector == #selector(NSResponder.moveDown(_:)) else { return false }
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
        selectedURLs.forEach { NSWorkspace.shared.open($0) }
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

    @objc func copy(_ sender: Any?) {
        onCopyFiles?()
    }
}
