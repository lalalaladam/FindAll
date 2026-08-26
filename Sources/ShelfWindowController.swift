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
    private enum PreferenceKey {
        static let columnWidths = "shelf.table.fittedColumnWidths.v1"
        static let columnReferenceWidth = "shelf.table.fittedColumnReferenceWidth.v1"
        static let columnOrder = "shelf.table.columnOrder.v1"
        static let keepOnTop = "shelf.window.keepOnTop.v1"
        static let showOnAllSpaces = "shelf.window.showOnAllSpaces.v1"
    }

    private let store: ShelfStore
    private let tableView = ShelfTableView()
    private let scrollView = NSScrollView()
    private let emptyStateView = ShelfEmptyStateView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private let clearButton = NSButton()
    private let keepOnTopSwitch = NSSwitch()
    private let allSpacesSwitch = NSSwitch()
    private let actionButtonStack = NSStackView()
    private var storeObserver: NSObjectProtocol?
    private var didRestoreFrame = false
    private var hasRestoredColumnLayout = false
    private var isAdjustingColumns = false

    init(store: ShelfStore) {
        self.store = store
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 420)
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
        panel.minSize = NSSize(width: 720, height: 420)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        didRestoreFrame = panel.setFrameUsingName("FindAllShelfWindowFrame")
        if didRestoreFrame {
            normalizeRestoredFrame(of: panel)
        }
        panel.setFrameAutosaveName("FindAllShelfWindowFrame")

        dropView.onDropURLs = { [weak self] urls in
            guard let self else { return false }
            let added = self.store.add(urls)
            if !added.isEmpty { self.select(urls: added) }
            return !added.isEmpty
        }
        dropView.onDropHighlightChanged = { [weak self] isHighlighted in
            self?.emptyStateView.setDropHighlighted(isHighlighted)
        }

        buildInterface(in: dropView)
        configureTable()
        restoreWindowBehavior()
        dropView.layoutSubtreeIfNeeded()
        layoutColumns(initialLayout: true)
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

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButtonStack.orientation = .horizontal
        actionButtonStack.alignment = .centerY
        actionButtonStack.spacing = 8
        actionButtonStack.detachesHiddenViews = true
        actionButtonStack.addArrangedSubview(removeButton)
        actionButtonStack.addArrangedSubview(clearButton)

        keepOnTopSwitch.controlSize = .small
        keepOnTopSwitch.target = self
        keepOnTopSwitch.action = #selector(windowBehaviorChanged(_:))
        allSpacesSwitch.controlSize = .small
        allSpacesSwitch.target = self
        allSpacesSwitch.action = #selector(windowBehaviorChanged(_:))

        let keepOnTopControl = labeledSwitch(
            title: L10n.string("Keep on top in current Space"),
            control: keepOnTopSwitch
        )
        let allSpacesControl = labeledSwitch(
            title: L10n.string("Show on all Spaces"),
            control: allSpacesSwitch
        )
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [statusLabel, footerSpacer, keepOnTopControl, allSpacesControl, actionButtonStack])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.detachesHiddenViews = true

        [scrollView, emptyStateView, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            emptyStateView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
    }

    private func labeledSwitch(title: String, control: NSSwitch) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        control.setAccessibilityLabel(title)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: tableView.intercellSpacing.height)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.autoresizingMask = [.height]
        tableView.doubleAction = #selector(openSelection(_:))
        tableView.target = self
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.onOpen = { [weak self] in self?.openSelection(nil) }
        tableView.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onReveal = { [weak self] in self?.revealSelection(nil) }
        tableView.onRemove = { [weak self] in self?.removeSelection(nil) }

        let fittedHeaderView = FittedTableHeaderView()
        fittedHeaderView.usesFittedResizing = { true }
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

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = L10n.string("Name")
        nameColumn.width = 210
        nameColumn.minWidth = 140
        nameColumn.resizingMask = .userResizingMask
        nameColumn.headerToolTip = nameColumn.title
        let locationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("location"))
        locationColumn.title = L10n.string("Location")
        locationColumn.width = 310
        locationColumn.minWidth = 180
        locationColumn.resizingMask = .userResizingMask
        locationColumn.headerToolTip = locationColumn.title
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(locationColumn)
        restoreColumnOrder()

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

    private func layoutColumns(initialLayout: Bool = false) {
        guard !isAdjustingColumns, !tableView.tableColumns.isEmpty else { return }
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        scrollView.hasHorizontalScroller = false
        scrollView.tile()
        let targetWidth = fittedColumnLayoutWidth
        guard targetWidth > 0 else { return }

        isAdjustingColumns = true
        if initialLayout, !hasRestoredColumnLayout {
            restoreFittedColumnLayout(to: targetWidth)
            hasRestoredColumnLayout = true
        } else {
            fitColumns(to: targetWidth)
        }
        var frame = tableView.frame
        frame.size.width = targetWidth
        tableView.frame = frame
        isAdjustingColumns = false

        if scrollView.contentView.bounds.origin.x != 0 {
            var origin = scrollView.contentView.bounds.origin
            origin.x = 0
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        refreshColumnResizeCursorRects()
    }

    private var fittedColumnLayoutWidth: CGFloat {
        let insets = scrollView.contentInsets
        let viewportWidth = floor(scrollView.bounds.width - insets.left - insets.right)
        guard scrollView.hasVerticalScroller else { return max(0, viewportWidth) }
        let reservedWidth = NSScroller.scrollerWidth(
            for: .regular,
            scrollerStyle: scrollView.scrollerStyle
        ) + 4
        return max(0, viewportWidth - reservedWidth)
    }

    private func fitColumns(to targetWidth: CGFloat) {
        applyColumnWidths(adaptedColumnWidths(to: targetWidth, from: tableView.tableColumns.map(\.width)))
    }

    private func adaptedColumnWidths(to targetWidth: CGFloat, from sourceWidths: [CGFloat]) -> [CGFloat] {
        let columns = tableView.tableColumns
        guard sourceWidths.count == columns.count, !columns.isEmpty else { return sourceWidths }
        let minimumWidth = columns.reduce(CGFloat.zero) { $0 + $1.minWidth }
        let availableFlexibleWidth = max(0, targetWidth - minimumWidth)
        let sourceFlexibleWidths = zip(columns, sourceWidths).map { column, width in
            max(0, width - column.minWidth)
        }
        let totalSourceFlexibleWidth = sourceFlexibleWidths.reduce(0, +)
        let weights: [CGFloat]
        if totalSourceFlexibleWidth > 0.5 {
            weights = sourceFlexibleWidths.map { $0 / totalSourceFlexibleWidth }
        } else {
            weights = Array(repeating: 1 / CGFloat(columns.count), count: columns.count)
        }

        var remainingFlexibleWidth = availableFlexibleWidth
        return columns.indices.map { index in
            let addition: CGFloat
            if index == columns.count - 1 {
                addition = remainingFlexibleWidth
            } else {
                addition = availableFlexibleWidth * weights[index]
                remainingFlexibleWidth -= addition
            }
            return columns[index].minWidth + max(0, addition)
        }
    }

    private func resizeFittedColumns(at dividerIndex: Int, initialWidths: [CGFloat], delta: CGFloat) {
        let columns = tableView.tableColumns
        guard columns.indices.contains(dividerIndex),
              columns.indices.contains(dividerIndex + 1),
              initialWidths.count == columns.count else { return }

        let leftCapacity = max(0, initialWidths[dividerIndex] - columns[dividerIndex].minWidth)
        let rightCapacity = max(0, initialWidths[dividerIndex + 1] - columns[dividerIndex + 1].minWidth)
        let adjustment = min(max(delta, -leftCapacity), rightCapacity)
        var widths = initialWidths
        widths[dividerIndex] = initialWidths[dividerIndex] + adjustment
        widths[dividerIndex + 1] = initialWidths[dividerIndex + 1] - adjustment
        applyColumnWidths(widths)
        tableView.needsDisplay = true
        tableView.headerView?.needsDisplay = true
        refreshColumnResizeCursorRects()
    }

    private func fittedResizeDirections(at dividerIndex: Int) -> (left: Bool, right: Bool) {
        let columns = tableView.tableColumns
        guard columns.indices.contains(dividerIndex), dividerIndex + 1 < columns.count else {
            return (false, false)
        }
        return (
            left: columns[dividerIndex].width - columns[dividerIndex].minWidth > 0.5,
            right: columns[dividerIndex + 1].width - columns[dividerIndex + 1].minWidth > 0.5
        )
    }

    private func refreshColumnResizeCursorRects() {
        guard let headerView = tableView.headerView, let window = headerView.window else { return }
        window.invalidateCursorRects(for: headerView)
    }

    private func restoreFittedColumnLayout(to targetWidth: CGFloat) {
        guard let savedWidths = UserDefaults.standard.dictionary(
            forKey: PreferenceKey.columnWidths
        ) as? [String: Double] else {
            fitColumns(to: targetWidth)
            return
        }

        let columns = tableView.tableColumns
        let widths = columns.map { column -> CGFloat in
            guard let savedWidth = savedWidths[column.identifier.rawValue], savedWidth.isFinite else {
                return column.width
            }
            return max(column.minWidth, CGFloat(savedWidth))
        }
        let storedReferenceWidth = UserDefaults.standard.object(forKey: PreferenceKey.columnReferenceWidth) == nil
            ? widths.reduce(0, +)
            : CGFloat(UserDefaults.standard.double(forKey: PreferenceKey.columnReferenceWidth))
        let referenceWidth = storedReferenceWidth.isFinite && storedReferenceWidth > 0
            ? storedReferenceWidth
            : widths.reduce(0, +)

        if abs(referenceWidth - targetWidth) <= 0.5 {
            applyColumnWidths(widths)
            fitColumns(to: targetWidth)
        } else {
            applyColumnWidths(adaptedColumnWidths(to: targetWidth, from: widths))
        }
    }

    private func applyColumnWidths(_ widths: [CGFloat]) {
        for (column, width) in zip(tableView.tableColumns, widths) where width.isFinite {
            column.width = max(column.minWidth, width)
        }
    }

    private func saveFittedColumnLayout() {
        guard !tableView.tableColumns.isEmpty else { return }
        let widths = Dictionary(uniqueKeysWithValues: tableView.tableColumns.map {
            ($0.identifier.rawValue, Double($0.width))
        })
        UserDefaults.standard.set(widths, forKey: PreferenceKey.columnWidths)
        let referenceWidth = fittedColumnLayoutWidth > 0
            ? fittedColumnLayoutWidth
            : tableView.tableColumns.reduce(0) { $0 + $1.width }
        UserDefaults.standard.set(Double(referenceWidth), forKey: PreferenceKey.columnReferenceWidth)
    }

    private func restoreColumnOrder() {
        guard let savedOrder = UserDefaults.standard.stringArray(forKey: PreferenceKey.columnOrder) else { return }
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
        UserDefaults.standard.set(
            tableView.tableColumns.map(\.identifier.rawValue),
            forKey: PreferenceKey.columnOrder
        )
    }

    private func restoreWindowBehavior() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PreferenceKey.keepOnTop) == nil {
            defaults.set(WindowPreferences.keepOnTop, forKey: PreferenceKey.keepOnTop)
        }
        if defaults.object(forKey: PreferenceKey.showOnAllSpaces) == nil {
            defaults.set(WindowPreferences.showOnAllSpaces, forKey: PreferenceKey.showOnAllSpaces)
        }
        keepOnTopSwitch.state = defaults.bool(forKey: PreferenceKey.keepOnTop) ? .on : .off
        allSpacesSwitch.state = defaults.bool(forKey: PreferenceKey.showOnAllSpaces) ? .on : .off
        applyWindowBehavior()
    }

    @objc private func windowBehaviorChanged(_ sender: NSSwitch) {
        if sender === keepOnTopSwitch {
            UserDefaults.standard.set(sender.state == .on, forKey: PreferenceKey.keepOnTop)
        } else if sender === allSpacesSwitch {
            UserDefaults.standard.set(sender.state == .on, forKey: PreferenceKey.showOnAllSpaces)
        }
        applyWindowBehavior()
    }

    private func applyWindowBehavior() {
        guard let window else { return }
        let keepOnTop = keepOnTopSwitch.state == .on
        (window as? NSPanel)?.isFloatingPanel = keepOnTop
        window.level = keepOnTop ? .floating : .normal
        var behavior = window.collectionBehavior
        behavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications])
        if allSpacesSwitch.state == .on {
            behavior.insert([.canJoinAllSpaces, .canJoinAllApplications])
        }
        window.collectionBehavior = behavior
    }

    private func normalizeRestoredFrame(of window: NSWindow) {
        var frame = window.frame
        frame.size.width = max(frame.width, window.minSize.width)
        frame.size.height = max(frame.height, window.minSize.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        if let screen {
            frame = window.constrainFrameRect(frame, to: screen)
        }
        window.setFrame(frame, display: false)
    }

    private func reloadStore() {
        let selectedPaths = Set(selectedURLs.map { $0.standardizedFileURL.path })
        tableView.reloadData()
        let selection = IndexSet(store.urls.indices.filter {
            selectedPaths.contains(store.urls[$0].standardizedFileURL.path)
        })
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
        let isEmpty = store.urls.isEmpty
        scrollView.isHidden = isEmpty
        emptyStateView.isHidden = !isEmpty
        statusLabel.isHidden = isEmpty
        actionButtonStack.isHidden = isEmpty
        statusLabel.stringValue = String.localizedStringWithFormat(L10n.string("%lld items"), Int64(store.urls.count))
        updateActionAvailability()
        layoutColumns()
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

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isAdjustingColumns else { return }
        layoutColumns()
        saveFittedColumnLayout()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !isAdjustingColumns else { return }
        saveColumnOrder()
        layoutColumns()
    }

    func windowDidResize(_ notification: Notification) {
        layoutColumns()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        layoutColumns()
        saveFittedColumnLayout()
    }

    func windowWillClose(_ notification: Notification) {
        saveFittedColumnLayout()
        saveColumnOrder()
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

private final class ShelfEmptyStateView: NSView {
    private var isDropHighlighted = false

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let imageView = NSImageView()
        imageView.image = NSImage(
            systemSymbolName: "tray.and.arrow.down",
            accessibilityDescription: L10n.string("Drag files and folders here")
        )
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.setAccessibilityLabel(L10n.string("Drag files and folders here"))

        let titleLabel = NSTextField(labelWithString: L10n.string("Drag files and folders here"))
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let addHintLabel = NSTextField(
            wrappingLabelWithString: L10n.string("You can also add items from Finder's context menu or use the Shelf shortcut.")
        )
        addHintLabel.alignment = .center
        addHintLabel.textColor = .secondaryLabelColor
        addHintLabel.font = .systemFont(ofSize: 12)
        addHintLabel.maximumNumberOfLines = 2

        let safetyLabel = NSTextField(
            wrappingLabelWithString: L10n.string("Temporary references; original files are never moved or deleted.")
        )
        safetyLabel.alignment = .center
        safetyLabel.textColor = .tertiaryLabelColor
        safetyLabel.font = .systemFont(ofSize: 11)
        safetyLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleLabel, addHintLabel, safetyLabel])
        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 6
        let stack = NSStackView(views: [imageView, textStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 38),
            imageView.heightAnchor.constraint(equalToConstant: 38),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -36),
            addHintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            safetyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Drag files and folders here"))
    }

    required init?(coder: NSCoder) { nil }

    func setDropHighlighted(_ highlighted: Bool) {
        guard highlighted != isDropHighlighted else { return }
        isDropHighlighted = highlighted
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.borderWidth = isDropHighlighted ? 2 : 1
        layer?.borderColor = (isDropHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        let opacity: CGFloat = isDropHighlighted ? 0.72 : 0.32
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(opacity).cgColor
    }
}

private final class ShelfDropView: NSView {
    var onDropURLs: (([URL]) -> Bool)?
    var onDropHighlightChanged: ((Bool) -> Void)?
    private var isDropHighlighted = false {
        didSet {
            layer?.borderWidth = isDropHighlighted ? 3 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            onDropHighlightChanged?(isDropHighlighted)
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
