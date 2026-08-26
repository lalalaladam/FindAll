import AppKit
import QuickLookUI

final class ShelfStore {
    static let didChangeNotification = Notification.Name("FindAllShelfStoreDidChange")

    private(set) var urls: [URL] = []

    @discardableResult
    func add(_ incomingURLs: [URL]) -> [URL] {
        precondition(Thread.isMainThread)
        var knownPaths = Set(urls.map(Self.identityPath(for:)))
        var added: [URL] = []

        for incomingURL in incomingURLs where incomingURL.isFileURL {
            let url = FilePathSupport.userFacingURL(incomingURL).standardizedFileURL
            let path = Self.identityPath(for: url)
            guard !knownPaths.contains(path), FileManager.default.fileExists(atPath: url.path) else { continue }
            knownPaths.insert(path)
            urls.append(url)
            added.append(url)
        }

        if !added.isEmpty {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        return added
    }

    func remove(at indexes: IndexSet) {
        precondition(Thread.isMainThread)
        let validIndexes = indexes.filter { urls.indices.contains($0) }
        guard !validIndexes.isEmpty else { return }
        for index in validIndexes.reversed() { urls.remove(at: index) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func remove(_ urlsToRemove: [URL]) {
        precondition(Thread.isMainThread)
        let paths = Set(urlsToRemove.map(Self.identityPath(for:)))
        guard !paths.isEmpty else { return }
        let originalCount = urls.count
        urls.removeAll { paths.contains(Self.identityPath(for: $0)) }
        if urls.count != originalCount {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    func clear() {
        precondition(Thread.isMainThread)
        guard !urls.isEmpty else { return }
        urls.removeAll()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func identityPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

final class ShelfWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSMenuItemValidation {
    private let store: ShelfStore
    private let tableView = ShelfTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: L10n.string("Drag files and folders here"))
    private let statusLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private let clearButton = NSButton()
    private var storeObserver: NSObjectProtocol?
    private var didRestoreFrame = false

    init(store: ShelfStore) {
        self.store = store
        let contentRect = NSRect(x: 0, y: 0, width: 560, height: 360)
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let dropView = ShelfDropView(frame: contentRect)
        panel.contentView = dropView
        super.init(window: panel)

        panel.delegate = self
        panel.title = L10n.string("FindAll Shelf")
        panel.minSize = NSSize(width: 420, height: 260)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
        didRestoreFrame = panel.setFrameUsingName("FindAllShelfWindowFrame")
        panel.setFrameAutosaveName("FindAllShelfWindowFrame")

        dropView.onDropURLs = { [weak self] urls in
            guard let self else { return false }
            let added = self.store.add(urls)
            if !added.isEmpty { self.select(urls: added) }
            return !added.isEmpty
        }

        buildInterface(in: dropView)
        configureTable()
        reloadStore()
        storeObserver = NotificationCenter.default.addObserver(
            forName: ShelfStore.didChangeNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.reloadStore()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    func toggleVisibility() {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            showShelf()
        }
    }

    func showShelf() {
        guard let window else { return }
        if !didRestoreFrame {
            positionOnPointerScreen()
            didRestoreFrame = true
        }
        window.orderFrontRegardless()
        window.makeKey()
    }

    func addAndShow(_ urls: [URL]) {
        let added = store.add(urls)
        showShelf()
        select(urls: added.isEmpty ? urls : added)
    }

    private func buildInterface(in content: NSView) {
        let heading = NSTextField(labelWithString: L10n.string("Shelf"))
        heading.font = .boldSystemFont(ofSize: 18)
        heading.setAccessibilityRole(.staticText)

        let hint = NSTextField(labelWithString: L10n.string("Temporary references; original files are never moved or deleted."))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [heading, hint])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        removeButton.title = L10n.string("Remove from Shelf")
        removeButton.target = self
        removeButton.action = #selector(removeSelection(_:))
        removeButton.bezelStyle = .rounded

        clearButton.title = L10n.string("Clear Shelf")
        clearButton.target = self
        clearButton.action = #selector(clearShelf(_:))
        clearButton.bezelStyle = .rounded

        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.isSelectable = false
        emptyLabel.setAccessibilityLabel(L10n.string("Drag files and folders here"))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        let buttonStack = NSStackView(views: [removeButton, clearButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        [titleStack, scrollView, emptyLabel, statusLabel, buttonStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            titleStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            titleStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 30),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -30),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: buttonStack.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            buttonStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.doubleAction = #selector(openSelection(_:))
        tableView.target = self
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.onOpen = { [weak self] in self?.openSelection(nil) }
        tableView.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onReveal = { [weak self] in self?.revealSelection(nil) }
        tableView.onRemove = { [weak self] in self?.removeSelection(nil) }

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = L10n.string("Name")
        nameColumn.width = 210
        nameColumn.minWidth = 140
        let locationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("location"))
        locationColumn.title = L10n.string("Location")
        locationColumn.width = 310
        locationColumn.minWidth = 180
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(locationColumn)

        let menu = NSMenu()
        addMenuItem(to: menu, title: L10n.string("Open"), action: #selector(openSelection(_:)))
        addMenuItem(to: menu, title: L10n.string("Quick Look"), action: #selector(toggleQuickLook(_:)))
        addMenuItem(to: menu, title: L10n.string("Show in File Manager"), action: #selector(revealSelection(_:)))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: L10n.string("Remove from Shelf"), action: #selector(removeSelection(_:)))
        tableView.menu = menu
    }

    private func addMenuItem(to menu: NSMenu, title: String, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    private func reloadStore() {
        let selectedPaths = Set(selectedURLs.map { $0.standardizedFileURL.path })
        tableView.reloadData()
        let selection = IndexSet(store.urls.indices.filter {
            selectedPaths.contains(store.urls[$0].standardizedFileURL.path)
        })
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
        emptyLabel.isHidden = !store.urls.isEmpty
        statusLabel.stringValue = String.localizedStringWithFormat(L10n.string("%lld items"), Int64(store.urls.count))
        updateActionAvailability()
        QLPreviewPanel.shared()?.reloadData()
    }

    private func select(urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        let indexes = IndexSet(store.urls.indices.filter {
            paths.contains(store.urls[$0].standardizedFileURL.path)
        })
        guard !indexes.isEmpty else { return }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        tableView.scrollRowToVisible(indexes.first!)
    }

    private var selectedURLs: [URL] {
        tableView.selectedRowIndexes.compactMap { store.urls.indices.contains($0) ? store.urls[$0] : nil }
    }

    private func updateActionAvailability() {
        removeButton.isEnabled = !selectedURLs.isEmpty
        clearButton.isEnabled = !store.urls.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.urls.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionAvailability()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard store.urls.indices.contains(row) else { return nil }
        return store.urls[row] as NSURL
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.urls.indices.contains(row), let tableColumn else { return nil }
        let url = store.urls[row]
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        if identifier.rawValue == "name" {
            cell.textField?.stringValue = FileManager.default.displayName(atPath: url.path)
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            cell.textField?.stringValue = url.deletingLastPathComponent().path
        }
        cell.toolTip = url.path
        cell.textField?.toolTip = url.path
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.maximumNumberOfLines = 1
        text.lineBreakMode = .byTruncatingMiddle
        cell.textField = text
        cell.addSubview(text)

        if identifier.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            cell.imageView = image
            cell.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
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

    @objc private func openSelection(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        let directories = selectedURLs.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        FileManagerSupport.openFolders(directories)
        selectedURLs.filter { !directories.contains($0) }.forEach { NSWorkspace.shared.open($0) }
    }

    @objc private func revealSelection(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        FileManagerSupport.reveal(selectedURLs)
    }

    @objc private func removeSelection(_ sender: Any?) {
        let selection = tableView.selectedRowIndexes
        guard !selection.isEmpty else { return }
        let nextRow = min(selection.first ?? 0, max(0, store.urls.count - selection.count - 1))
        store.remove(at: selection)
        if !store.urls.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: min(nextRow, store.urls.count - 1)), byExtendingSelection: false)
        }
    }

    @objc private func clearShelf(_ sender: Any?) {
        store.clear()
    }

    @objc private func toggleQuickLook(_ sender: Any?) {
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

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedURLs[index] as NSURL
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(openSelection(_:)), #selector(revealSelection(_:)), #selector(removeSelection(_:)), #selector(toggleQuickLook(_:))].contains(menuItem.action) {
            return !selectedURLs.isEmpty
        }
        return true
    }

    private func positionOnPointerScreen() {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
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
}

private final class ShelfDropView: NSView {
    var onDropURLs: (([URL]) -> Bool)?
    private var isDropHighlighted = false {
        didSet {
            layer?.borderWidth = isDropHighlighted ? 3 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender.draggingPasteboard)
        isDropHighlighted = !urls.isEmpty
        return urls.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropHighlighted = false
        let urls = fileURLs(from: sender.draggingPasteboard)
        return !urls.isEmpty && onDropURLs?(urls) == true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDropHighlighted = false
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? [])
            .map { $0 as URL }
    }
}

private final class ShelfTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(KeyboardShortcut.supportedModifiers)
        if event.keyCode == 49, modifiers.isEmpty {
            onQuickLook?()
        } else if [36, 76].contains(Int(event.keyCode)), modifiers.isEmpty {
            onOpen?()
        } else if event.keyCode == 51, modifiers.isEmpty {
            onRemove?()
        } else if [36, 76].contains(Int(event.keyCode)), modifiers == .command {
            onReveal?()
        } else {
            super.keyDown(with: event)
        }
    }
}
