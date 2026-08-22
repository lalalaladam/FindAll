import AppKit
import QuickLookUI
import UniformTypeIdentifiers

final class FolderContentsWindowManager {
    private var controllers: [String: FolderContentsWindowController] = [:]

    func showContents(of folderURL: URL, relativeTo sourceWindow: NSWindow?) {
        precondition(Thread.isMainThread)
        let normalizedURL = FilePathSupport.userFacingURL(folderURL).standardizedFileURL
        let key = normalizedURL.path
        if let controller = controllers[key] {
            controller.showAndActivate()
            return
        }

        let controller = FolderContentsWindowController(folderURL: normalizedURL)
        controller.onShowFolderContents = { [weak self] url, sourceWindow in
            self?.showContents(of: url, relativeTo: sourceWindow)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.controllers[key] === controller else { return }
            self.controllers.removeValue(forKey: key)
        }
        controllers[key] = controller
        controller.position(relativeTo: sourceWindow)
        controller.showAndActivate()
    }

    func refreshShortcutConfiguration() {
        controllers.values.forEach { $0.refreshContextMenuShortcuts() }
    }
}

private enum FolderContentsGroupKind: Int, CaseIterable {
    case folder
    case textDocument
    case pdf
    case spreadsheet
    case presentation
    case image
    case video
    case audio
    case archiveAndDiskImage
    case application
    case other

    var title: String {
        switch self {
        case .folder: return L10n.string("Folders")
        case .pdf: return "PDF"
        case .textDocument: return L10n.string("Text and Documents")
        case .spreadsheet: return L10n.string("Spreadsheets")
        case .presentation: return L10n.string("Presentations")
        case .image: return L10n.string("Images")
        case .video: return L10n.string("Videos")
        case .audio: return L10n.string("Audio")
        case .archiveAndDiskImage: return L10n.string("Archives and Disk Images")
        case .application: return L10n.string("Applications")
        case .other: return L10n.string("Other Files")
        }
    }

    static func classify(_ result: SearchResult) -> FolderContentsGroupKind {
        if result.isDirectory { return .folder }

        let pathExtension = result.url.pathExtension.lowercased()
        let type = result.contentTypeIdentifier.flatMap(UTType.init)

        if pathExtension == "pdf" || conforms(type, to: "com.adobe.pdf") { return .pdf }
        if applicationExtensions.contains(pathExtension)
            || conforms(type, to: "com.apple.application-bundle") { return .application }
        if spreadsheetExtensions.contains(pathExtension)
            || conforms(type, to: "public.spreadsheet") { return .spreadsheet }
        if presentationExtensions.contains(pathExtension)
            || conforms(type, to: "public.presentation") { return .presentation }
        if conforms(type, to: "public.image") { return .image }
        if conforms(type, to: "public.movie") { return .video }
        if conforms(type, to: "public.audio") { return .audio }
        if archiveExtensions.contains(pathExtension)
            || conforms(type, to: "public.archive")
            || conforms(type, to: "public.disk-image") { return .archiveAndDiskImage }
        if documentExtensions.contains(pathExtension)
            || conforms(type, to: "public.text")
            || conforms(type, to: "public.document") { return .textDocument }
        return .other
    }

    private static func conforms(_ type: UTType?, to identifier: String) -> Bool {
        guard let type, let parent = UTType(identifier) else { return false }
        return type.conforms(to: parent)
    }

    private static let applicationExtensions: Set<String> = ["app"]
    private static let spreadsheetExtensions: Set<String> = [
        "csv", "numbers", "ods", "tsv", "xls", "xlsb", "xlsm", "xlsx", "xlt", "xltx"
    ]
    private static let presentationExtensions: Set<String> = [
        "key", "odp", "pot", "potx", "pps", "ppsx", "ppt", "pptm", "pptx"
    ]
    private static let archiveExtensions: Set<String> = [
        "7z", "bz2", "dmg", "gz", "iso", "rar", "tar", "tgz", "xz", "zip"
    ]
    private static let documentExtensions: Set<String> = [
        "doc", "docm", "docx", "dot", "dotx", "json", "markdown", "md", "odt", "pages",
        "plist", "rtf", "rtfd", "text", "txt", "xml", "yaml", "yml"
    ]

    private var prioritizedExtensionFamilies: [[String]] {
        switch self {
        case .folder: return []
        case .textDocument:
            return [
                ["docx"], ["doc"], ["pages"], ["rtf", "rtfd"], ["txt", "text"],
                ["md", "markdown"], ["odt"], ["json"], ["xml"], ["yaml", "yml"], ["plist"]
            ]
        case .pdf: return [["pdf"]]
        case .spreadsheet:
            return [
                ["xlsx"], ["xls"], ["numbers"], ["csv"], ["tsv"], ["ods"],
                ["xlsm"], ["xlsb"], ["xlt", "xltx"]
            ]
        case .presentation:
            return [
                ["pptx"], ["ppt"], ["key"], ["odp"], ["pptm"], ["pps", "ppsx"], ["pot", "potx"]
            ]
        case .image:
            return [
                ["png"], ["jpg", "jpeg"], ["heic", "heif"], ["webp"], ["gif"],
                ["tif", "tiff"], ["svg"], ["bmp"]
            ]
        case .video: return [["mp4"], ["mov"], ["m4v"], ["mkv"], ["webm"], ["avi"]]
        case .audio: return [["mp3"], ["m4a"], ["aac"], ["wav"], ["flac"], ["aiff"], ["ogg"]]
        case .archiveAndDiskImage:
            return [["zip"], ["rar"], ["7z"], ["dmg"], ["iso"], ["tar"], ["gz", "tgz"], ["bz2"], ["xz"]]
        case .application: return [["app"]]
        case .other: return []
        }
    }

    func extensionRank(for pathExtension: String) -> (priority: Int, variantPriority: Int, extensionKey: String) {
        let normalizedExtension = pathExtension.lowercased()
        for (priority, family) in prioritizedExtensionFamilies.enumerated() {
            guard let variantPriority = family.firstIndex(of: normalizedExtension) else { continue }
            return (priority, variantPriority, normalizedExtension)
        }
        let fallbackPriority = prioritizedExtensionFamilies.count
        return (
            fallbackPriority,
            0,
            normalizedExtension.isEmpty ? "\u{10FFFF}" : normalizedExtension
        )
    }
}

private enum FolderContentsSortMode: String {
    case smart
    case nameAscending
    case nameDescending
    case kindAscending
    case kindDescending
    case sizeAscending
    case sizeDescending
    case modifiedAscending
    case modifiedDescending

    var isSizeSort: Bool {
        self == .sizeAscending || self == .sizeDescending
    }

    var descriptor: NSSortDescriptor? {
        switch self {
        case .smart: return nil
        case .nameAscending: return NSSortDescriptor(key: "name", ascending: true)
        case .nameDescending: return NSSortDescriptor(key: "name", ascending: false)
        case .kindAscending: return NSSortDescriptor(key: "kind", ascending: true)
        case .kindDescending: return NSSortDescriptor(key: "kind", ascending: false)
        case .sizeAscending: return NSSortDescriptor(key: "size", ascending: true)
        case .sizeDescending: return NSSortDescriptor(key: "size", ascending: false)
        case .modifiedAscending: return NSSortDescriptor(key: "modified", ascending: true)
        case .modifiedDescending: return NSSortDescriptor(key: "modified", ascending: false)
        }
    }

    init?(descriptor: NSSortDescriptor) {
        guard let key = descriptor.key else { return nil }
        switch (key, descriptor.ascending) {
        case ("name", true): self = .nameAscending
        case ("name", false): self = .nameDescending
        case ("kind", true): self = .kindAscending
        case ("kind", false): self = .kindDescending
        case ("size", true): self = .sizeAscending
        case ("size", false): self = .sizeDescending
        case ("modified", true): self = .modifiedAscending
        case ("modified", false): self = .modifiedDescending
        default: return nil
        }
    }
}

private enum FolderContentsPreferences {
    private static let groupsByTypeKey = "folderContents.groupsByType"

    static var groupsByType: Bool {
        get {
            guard UserDefaults.standard.object(forKey: groupsByTypeKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: groupsByTypeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: groupsByTypeKey) }
    }
}

private final class FolderContentsGroupNode {
    let kind: FolderContentsGroupKind
    var children: [FolderContentsFileNode]

    init(kind: FolderContentsGroupKind, children: [FolderContentsFileNode]) {
        self.kind = kind
        self.children = children
    }
}

private final class FolderContentsFileNode {
    let result: SearchResult

    init(result: SearchResult) {
        self.result = result
    }
}

final class FolderContentsWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSMenuDelegate, NSMenuItemValidation {
    var onShowFolderContents: ((URL, NSWindow?) -> Void)?
    var onClose: (() -> Void)?

    private let folderURL: URL
    private let outlineView = FolderContentsOutlineView()
    private let scrollView = NSScrollView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let groupingButton = NSButton(
        checkboxWithTitle: L10n.string("Group by Type"),
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let refreshButton = NSButton()
    private let loadQueue = DispatchQueue(label: "com.lalalaladam.FindAll.folder-contents", qos: .userInitiated)
    private var results: [SearchResult] = []
    private var groups: [FolderContentsGroupNode] = []
    private var flatNodes: [FolderContentsFileNode] = []
    private var loadGeneration = 0
    private var groupsByType: Bool
    private var activeSortMode: FolderContentsSortMode
    private var sizeSortFolderOrder: [String: Int]?
    private var isSynchronizingSort = false
    private var isAdjustingColumns = false
    private var hasBecomeKey = false
    private var preferencesObserver: NSObjectProtocol?
    private var sharingServicePicker: NSSharingServicePicker?
    private var isOpenConfirmationPresented = false

    init(folderURL: URL) {
        self.folderURL = folderURL
        groupsByType = FolderContentsPreferences.groupsByType
        activeSortMode = .smart
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = FileManager.default.displayName(atPath: folderURL.path)
        window.representedURL = folderURL
        window.minSize = NSSize(width: 720, height: 360)
        window.isReleasedWhenClosed = false
        buildInterface()
        applyWindowBehavior()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: WindowPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyWindowBehavior()
        }
        refreshContents()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    func position(relativeTo sourceWindow: NSWindow?) {
        guard let window else { return }
        guard let sourceWindow, let screen = sourceWindow.screen else {
            window.center()
            return
        }
        let proposedTopLeft = NSPoint(x: sourceWindow.frame.minX + 28, y: sourceWindow.frame.maxY - 28)
        window.setFrameTopLeftPoint(proposedTopLeft)
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
    }

    func showAndActivate() {
        applyWindowBehavior()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(outlineView)
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        pathLabel.stringValue = folderURL.path
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.toolTip = folderURL.path
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        refreshButton.bezelStyle = .texturedRounded
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L10n.string("Refresh"))
        refreshButton.toolTip = L10n.string("Refresh")
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)

        groupingButton.controlSize = .small
        groupingButton.state = groupsByType ? .on : .off
        groupingButton.toolTip = L10n.string("Group by Type")
        groupingButton.target = self
        groupingButton.action = #selector(groupingChanged(_:))
        groupingButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        groupingButton.setContentHuggingPriority(.required, for: .horizontal)

        let topBar = NSStackView(views: [pathLabel, groupingButton, refreshButton])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.distribution = .fill
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        configureOutlineView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusBar = NSStackView(views: [spinner, statusLabel])
        statusBar.orientation = .horizontal
        statusBar.alignment = .centerY
        statusBar.spacing = 8
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        [topBar, scrollView, separator, statusBar].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 7),
            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            statusBar.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7)
        ])
        contentView.layoutSubtreeIfNeeded()
        layoutColumns()
    }

    private func configureOutlineView() {
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.style = .plain
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 0
        outlineView.autosaveExpandedItems = false
        outlineView.intercellSpacing = NSSize(width: 0, height: outlineView.intercellSpacing.height)
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.autoresizingMask = [.height]
        outlineView.target = self
        outlineView.doubleAction = #selector(openSelection(_:))
        outlineView.onOpen = { [weak self] in self?.openSelection(nil) }
        outlineView.onShowFolderContents = { [weak self] in self?.showFolderContents(nil) }
        outlineView.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }
        outlineView.onReveal = { [weak self] in self?.revealSelection(nil) }
        outlineView.onCopyFiles = { [weak self] in self?.copySelection(nil) }
        outlineView.onCopyPath = { [weak self] in self?.copyPath(nil) }
        outlineView.onShare = { [weak self] in self?.shareSelection(nil) }
        outlineView.onGetInfo = { [weak self] in self?.showFinderInfo(nil) }
        outlineView.onRefresh = { [weak self] in self?.refresh(nil) }
        outlineView.isActionableRow = { [weak self] row in self?.fileNode(atRow: row) != nil }
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

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
            self.layoutColumns()
        }
        outlineView.headerView = fittedHeaderView

        addColumn("name", title: L10n.string("Name"), width: 400, minimum: 190)
        addColumn("kind", title: L10n.string("Kind"), width: 110, minimum: 90)
        addColumn("size", title: L10n.string("Size"), width: 80, minimum: 75)
        addColumn("modified", title: L10n.string("Modified"), width: 170, minimum: 150)
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        updateSortAvailability()
        synchronizeSortDescriptor()
        configureContextMenu()
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat, minimum: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minimum
        column.resizingMask = .userResizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        outlineView.addTableColumn(column)
    }

    private func layoutColumns() {
        guard !isAdjustingColumns, !outlineView.tableColumns.isEmpty else { return }
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        scrollView.hasHorizontalScroller = false
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()
        let targetWidth = fittedColumnLayoutWidth
        guard targetWidth > 0 else { return }

        isAdjustingColumns = true
        fitColumns(to: targetWidth)
        var frame = outlineView.frame
        frame.size.width = targetWidth
        outlineView.frame = frame
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
        let difference = targetWidth - outlineView.tableColumns.reduce(0) { $0 + $1.width }
        guard abs(difference) > 0.5 else { return }
        if difference > 0,
           let nameColumn = outlineView.tableColumn(
               withIdentifier: NSUserInterfaceItemIdentifier("name")
           ) {
            nameColumn.width += difference
            return
        }

        var requiredReduction = -difference
        for identifiers in [["name"], ["kind", "size"], ["modified"]] {
            let columns = identifiers.compactMap {
                outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier($0))
            }
            requiredReduction -= shrink(columns, by: requiredReduction)
            if requiredReduction <= 0.5 { return }
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
        let columns = outlineView.tableColumns
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
        outlineView.needsDisplay = true
        outlineView.headerView?.needsDisplay = true
        refreshColumnResizeCursorRects()
    }

    private func fittedResizeDirections(at dividerIndex: Int) -> (left: Bool, right: Bool) {
        let columns = outlineView.tableColumns
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
        guard let headerView = outlineView.headerView, let window = headerView.window else { return }
        window.invalidateCursorRects(for: headerView)
    }

    private func shrinkFittedWidths(
        _ widths: inout [CGFloat],
        columns: [NSTableColumn],
        candidateIndices: [Int],
        by requestedReduction: CGFloat
    ) -> CGFloat {
        var remainingReduction = requestedReduction
        for identifiers in [["name"], ["kind", "size"], ["modified"]]
        where remainingReduction > 0.5 {
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

    private func updateSortAvailability() {
        guard let kindColumn = outlineView.tableColumns.first(where: { $0.identifier.rawValue == "kind" }) else { return }
        kindColumn.sortDescriptorPrototype = groupsByType
            ? nil
            : NSSortDescriptor(key: "kind", ascending: true)
    }

    private func configureContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        addMenuItem(to: menu, title: L10n.string("Open"), command: .open, action: #selector(openSelection(_:)))
        addMenuItem(
            to: menu,
            title: L10n.string("Show Folder Contents in New Window"),
            command: .showFolderContents,
            action: #selector(showFolderContents(_:))
        )
        addMenuItem(to: menu, title: L10n.string("Quick Look"), command: .quickLook, action: #selector(toggleQuickLook(_:)))
        addMenuItem(to: menu, title: L10n.string("Show in File Manager"), command: .reveal, action: #selector(revealSelection(_:)))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: L10n.string("Get Info"), command: .getInfo, action: #selector(showFinderInfo(_:)))
        addMenuItem(to: menu, title: L10n.string("Share"), command: .share, action: #selector(shareSelection(_:)))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: L10n.string("Copy Files"), command: .copyFiles, action: #selector(copySelection(_:)))
        addMenuItem(to: menu, title: L10n.string("Copy Path"), command: .copyPath, action: #selector(copyPath(_:)))
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: L10n.string("Refresh"), action: #selector(refresh(_:)), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = .command
        refresh.target = self
        outlineView.menu = menu
        refreshContextMenuShortcuts()
    }

    private func addMenuItem(to menu: NSMenu, title: String, command: CommandID, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("command.\(command.rawValue)")
        item.target = self
    }

    func refreshContextMenuShortcuts() {
        guard let menu = outlineView.menu else { return }
        for command in CommandID.resultListCommands {
            let identifier = NSUserInterfaceItemIdentifier("command.\(command.rawValue)")
            guard let item = menu.items.first(where: { $0.identifier == identifier }) else { continue }
            let shortcut = ShortcutSettings.shortcut(for: command)
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
    }

    @objc private func refresh(_ sender: Any?) {
        refreshContents()
    }

    @objc private func groupingChanged(_ sender: NSButton) {
        let newValue = sender.state == .on
        guard newValue != groupsByType else { return }
        groupsByType = newValue
        FolderContentsPreferences.groupsByType = newValue
        updateSortAvailability()
        synchronizeSortDescriptor()
        rebuildContents()
    }

    private func refreshContents() {
        loadGeneration += 1
        let generation = loadGeneration
        spinner.startAnimation(nil)
        refreshButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = L10n.string("Loading folder contents…")
        let folderURL = self.folderURL
        loadQueue.async { [weak self] in
            let output: Result<([SearchResult], Int), Error>
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: [
                        .contentModificationDateKey,
                        .contentTypeKey,
                        .fileSizeKey,
                        .isDirectoryKey,
                        .isPackageKey,
                        .localizedNameKey,
                        .localizedTypeDescriptionKey
                    ],
                    options: [.skipsHiddenFiles]
                )
                var loadedResults: [SearchResult] = []
                var unavailableCount = 0
                loadedResults.reserveCapacity(urls.count)
                for url in urls {
                    switch SearchResult.load(from: FilePathSupport.userFacingURL(url).standardizedFileURL) {
                    case let .success(result): loadedResults.append(result)
                    case .failure: unavailableCount += 1
                    }
                }
                output = .success((loadedResults, unavailableCount))
            } catch {
                output = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                self.spinner.stopAnimation(nil)
                self.refreshButton.isEnabled = true
                switch output {
                case let .success((results, unavailableCount)):
                    self.results = results
                    self.rebuildContents()
                    self.updateStatus(unavailableCount: unavailableCount)
                case let .failure(error):
                    self.results = []
                    self.rebuildContents()
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = L10n.string("Could not read folder contents")
                    self.statusLabel.toolTip = error.localizedDescription
                }
            }
        }
    }

    private func rebuildContents() {
        let selectedPaths = Set(selectedURLs.map { $0.standardizedFileURL.path })
        if groupsByType {
            let grouped = Dictionary(grouping: results, by: FolderContentsGroupKind.classify)
            groups = FolderContentsGroupKind.allCases.compactMap { kind in
                guard let values = grouped[kind], !values.isEmpty else { return nil }
                let children = sorted(values, in: kind).map(FolderContentsFileNode.init)
                return FolderContentsGroupNode(kind: kind, children: children)
            }
            flatNodes = []
        } else {
            groups = []
            flatNodes = sorted(results, in: nil).map(FolderContentsFileNode.init)
        }
        if activeSortMode.isSizeSort {
            sizeSortFolderOrder = currentFolderOrder()
        }
        outlineView.reloadData()
        if groupsByType {
            groups.forEach { outlineView.expandItem($0) }
        }
        let selectedRows = IndexSet((0..<outlineView.numberOfRows).filter { row in
            guard let node = fileNode(atRow: row) else { return false }
            return selectedPaths.contains(node.result.url.standardizedFileURL.path)
        })
        if !selectedRows.isEmpty {
            outlineView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        }
        DispatchQueue.main.async { [weak self] in self?.layoutColumns() }
    }

    private func sorted(_ values: [SearchResult], in groupKind: FolderContentsGroupKind?) -> [SearchResult] {
        values.sorted { lhs, rhs in
            if activeSortMode == .smart {
                if let groupKind {
                    return smartOrder(lhs, rhs, in: groupKind)
                }
                let lhsGroupKind = FolderContentsGroupKind.classify(lhs)
                let rhsGroupKind = FolderContentsGroupKind.classify(rhs)
                if lhsGroupKind != rhsGroupKind {
                    return lhsGroupKind.rawValue < rhsGroupKind.rawValue
                }
                return smartOrder(lhs, rhs, in: lhsGroupKind)
            }
            if activeSortMode.isSizeSort {
                if groupKind == .folder {
                    return folderOrderDuringSizeSort(lhs, rhs)
                }
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                if lhs.isDirectory && rhs.isDirectory {
                    return folderOrderDuringSizeSort(lhs, rhs)
                }
            }
            let comparison: ComparisonResult
            switch activeSortMode {
            case .smart:
                comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case .nameAscending, .nameDescending:
                comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case .kindAscending, .kindDescending:
                comparison = lhs.kind.localizedStandardCompare(rhs.kind)
            case .sizeAscending, .sizeDescending:
                if lhs.size == nil || rhs.size == nil {
                    if lhs.size == nil, rhs.size != nil { return false }
                    if lhs.size != nil, rhs.size == nil { return true }
                    comparison = .orderedSame
                } else {
                    comparison = lhs.size! < rhs.size! ? .orderedAscending
                        : lhs.size! > rhs.size! ? .orderedDescending : .orderedSame
                }
            case .modifiedAscending, .modifiedDescending:
                if lhs.modifiedAt == nil || rhs.modifiedAt == nil {
                    if lhs.modifiedAt == nil, rhs.modifiedAt != nil { return false }
                    if lhs.modifiedAt != nil, rhs.modifiedAt == nil { return true }
                    comparison = .orderedSame
                } else {
                    comparison = lhs.modifiedAt! < rhs.modifiedAt! ? .orderedAscending
                        : lhs.modifiedAt! > rhs.modifiedAt! ? .orderedDescending : .orderedSame
                }
            }
            if comparison == .orderedSame {
                let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            switch activeSortMode {
            case .nameDescending, .kindDescending, .sizeDescending, .modifiedDescending:
                return comparison == .orderedDescending
            default:
                return comparison == .orderedAscending
            }
        }
    }

    private func currentFolderOrder() -> [String: Int] {
        let folderNodes: [FolderContentsFileNode]
        if groupsByType {
            folderNodes = groups.first(where: { $0.kind == .folder })?.children ?? []
        } else {
            folderNodes = flatNodes.filter(\.result.isDirectory)
        }
        return Dictionary(uniqueKeysWithValues: folderNodes.enumerated().map { index, node in
            (node.result.url.standardizedFileURL.path, index)
        })
    }

    private func folderOrderDuringSizeSort(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        let lhsRank = sizeSortFolderOrder?[lhs.url.standardizedFileURL.path]
        let rhsRank = sizeSortFolderOrder?[rhs.url.standardizedFileURL.path]
        switch (lhsRank, rhsRank) {
        case let (lhsRank?, rhsRank?):
            return lhsRank < rhsRank
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return smartOrder(lhs, rhs, in: .folder)
        }
    }

    private func smartOrder(
        _ lhs: SearchResult,
        _ rhs: SearchResult,
        in groupKind: FolderContentsGroupKind
    ) -> Bool {
        if groupKind != .folder {
            let lhsRank = groupKind.extensionRank(for: lhs.url.pathExtension)
            let rhsRank = groupKind.extensionRank(for: rhs.url.pathExtension)
            if lhsRank.priority != rhsRank.priority { return lhsRank.priority < rhsRank.priority }
            if lhsRank.variantPriority != rhsRank.variantPriority {
                return lhsRank.variantPriority < rhsRank.variantPriority
            }
            let extensionComparison = lhsRank.extensionKey.localizedStandardCompare(rhsRank.extensionKey)
            if extensionComparison != .orderedSame { return extensionComparison == .orderedAscending }
        }
        switch (lhs.modifiedAt, rhs.modifiedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func updateStatus(unavailableCount: Int) {
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
        if unavailableCount > 0 {
            statusLabel.stringValue = String.localizedStringWithFormat(
                L10n.string("%lld items, %lld unavailable"),
                Int64(results.count),
                Int64(unavailableCount)
            )
        } else {
            statusLabel.stringValue = String.localizedStringWithFormat(
                L10n.string("%lld items"),
                Int64(results.count)
            )
        }
    }

    private func synchronizeSortDescriptor() {
        isSynchronizingSort = true
        if let descriptor = activeSortMode.descriptor {
            outlineView.sortDescriptors = [descriptor]
        } else {
            outlineView.sortDescriptors = []
        }
        isSynchronizingSort = false
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSynchronizingSort,
              let descriptor = outlineView.sortDescriptors.first,
              let mode = FolderContentsSortMode(descriptor: descriptor) else { return }
        if mode.isSizeSort, !activeSortMode.isSizeSort {
            sizeSortFolderOrder = currentFolderOrder()
        } else if !mode.isSizeSort {
            sizeSortFolderOrder = nil
        }
        activeSortMode = mode
        rebuildContents()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groupsByType ? groups.count : flatNodes.count }
        return (item as? FolderContentsGroupNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? FolderContentsGroupNode { return group.children[index] }
        return groupsByType ? groups[index] : flatNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FolderContentsGroupNode
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is FolderContentsGroupNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is FolderContentsFileNode
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FolderContentsFileNode else { return nil }
        return node.result.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? FolderContentsGroupNode {
            let identifier = NSUserInterfaceItemIdentifier("folderContents.group")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? makeGroupCell(identifier: identifier)
            cell.textField?.stringValue = String.localizedStringWithFormat(
                L10n.string("%@ (%lld)"),
                group.kind.title,
                Int64(group.children.count)
            )
            return cell
        }
        guard let tableColumn else { return nil }
        guard let node = item as? FolderContentsFileNode else { return nil }
        let result = node.result
        let identifier = tableColumn.identifier
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? FolderContentsCellView)
            ?? makeFileCell(identifier: identifier)
        switch identifier.rawValue {
        case "name":
            cell.textField?.stringValue = Self.singleLine(result.displayName)
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: result.url.path)
        case "kind": cell.textField?.stringValue = Self.singleLine(result.kind)
        case "size": cell.textField?.stringValue = result.size.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "—"
        case "modified": cell.textField?.stringValue = result.modifiedAt.map(Self.dateFormatter.string(from:)) ?? "—"
        default: break
        }
        cell.fullToolTipText = cell.textField?.stringValue
        cell.updateToolTip()
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        QLPreviewPanel.shared()?.reloadData()
    }

    private func makeGroupCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.font = .boldSystemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = text
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeFileCell(identifier: NSUserInterfaceItemIdentifier) -> FolderContentsCellView {
        let cell = FolderContentsCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        text.maximumNumberOfLines = 1
        text.cell?.usesSingleLineMode = true
        if identifier.rawValue == "modified" {
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            text.alignment = .right
        }
        cell.textField = text
        cell.addSubview(text)
        if identifier.rawValue == "name" {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyDown
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = image
            cell.addSubview(image)
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

    private func fileNode(atRow row: Int) -> FolderContentsFileNode? {
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FolderContentsFileNode
    }

    private var selectedNodes: [FolderContentsFileNode] {
        outlineView.selectedRowIndexes.compactMap(fileNode(atRow:))
    }

    private var selectedURLs: [URL] { selectedNodes.map(\.result.url) }

    private var selectedFolderURL: URL? {
        guard selectedNodes.count == 1, selectedNodes[0].result.isBrowsableDirectory else { return nil }
        return selectedNodes[0].result.url
    }

    @objc private func showFolderContents(_ sender: Any?) {
        guard let selectedFolderURL else { return }
        onShowFolderContents?(selectedFolderURL, window)
    }

    @objc private func openSelection(_ sender: Any?) {
        let selectedResults = selectedNodes.map(\.result)
        guard !selectedResults.isEmpty else { return }
        confirmOpeningIfNeeded(itemCount: selectedResults.count) { [weak self] in
            let folders = selectedResults.filter(\.isDirectory).map(\.url)
            FileManagerSupport.openFolders(folders)
            selectedResults.filter { !$0.isDirectory }.forEach { NSWorkspace.shared.open($0.url) }
            self?.window?.makeKey()
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
        alert.messageText = String.localizedStringWithFormat(L10n.string("Open %lld Selected Items?"), Int64(itemCount))
        alert.informativeText = L10n.string("Opening multiple items may open many windows or launch multiple applications.")
        alert.addButton(withTitle: L10n.string("Open"))
        alert.addButton(withTitle: L10n.string("Cancel"))
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

    @objc private func revealSelection(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        FileManagerSupport.reveal(selectedURLs)
    }

    @objc private func copySelection(_ sender: Any?) {
        let urls = selectedURLs as [NSURL]
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    @objc private func copyPath(_ sender: Any?) {
        let paths = selectedURLs.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func shareSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        sharingServicePicker = picker
        let row = outlineView.selectedRow
        let anchor = row >= 0 ? outlineView.rect(ofRow: row) : outlineView.visibleRect
        picker.show(relativeTo: anchor, of: outlineView, preferredEdge: .maxY)
    }

    @objc private func showFinderInfo(_ sender: Any?) {
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === outlineView.menu else { return }
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "command.showFolderContents" }) {
            item.isHidden = selectedFolderURL == nil
        }
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "command.reveal" }) {
            item.title = FileManagerSupport.canSelectRevealedItem
                ? L10n.string("Show in File Manager")
                : L10n.string("Open Containing Folder")
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showFolderContents(_:)) { return selectedFolderURL != nil }
        if menuItem.action == #selector(refresh(_:)) { return refreshButton.isEnabled }
        if [#selector(openSelection(_:)), #selector(revealSelection(_:)), #selector(copySelection(_:)), #selector(copyPath(_:)), #selector(shareSelection(_:)), #selector(showFinderInfo(_:)), #selector(toggleQuickLook(_:))].contains(menuItem.action) {
            return !selectedURLs.isEmpty
        }
        return true
    }

    private func applyWindowBehavior() {
        guard let window else { return }
        window.level = WindowPreferences.keepOnTop ? .floating : .normal
        var behavior = window.collectionBehavior
        behavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications])
        if WindowPreferences.showOnAllSpaces {
            behavior.insert([.canJoinAllSpaces, .canJoinAllApplications])
        }
        window.collectionBehavior = behavior
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if hasBecomeKey {
            refreshContents()
        } else {
            hasBecomeKey = true
        }
    }

    func windowDidResize(_ notification: Notification) {
        layoutColumns()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        layoutColumns()
    }

    func windowWillClose(_ notification: Notification) {
        loadGeneration += 1
        onClose?()
        onClose = nil
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
    }

    private static func escapeAppleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private final class FolderContentsOutlineView: NSOutlineView {
    var onOpen: (() -> Void)?
    var onShowFolderContents: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onReveal: (() -> Void)?
    var onCopyFiles: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onShare: (() -> Void)?
    var onGetInfo: (() -> Void)?
    var onRefresh: (() -> Void)?
    var isActionableRow: ((Int) -> Bool)?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        .zero
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, isActionableRow?(row) == true else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 15,
           event.modifierFlags.intersection(KeyboardShortcut.supportedModifiers) == .command {
            onRefresh?()
        } else if ShortcutSettings.shortcut(for: .open).matches(event) {
            onOpen?()
        } else if ShortcutSettings.shortcut(for: .showFolderContents).matches(event) {
            onShowFolderContents?()
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

private final class FolderContentsCellView: NSTableCellView {
    var fullToolTipText: String?

    override func layout() {
        super.layout()
        updateToolTip()
    }

    func updateToolTip() {
        guard let textField else { return }
        let completeText = fullToolTipText ?? textField.stringValue
        let isTruncated = !textField.expansionFrame(withFrame: textField.bounds).isEmpty
        let resolvedToolTip = isTruncated ? completeText : nil
        toolTip = resolvedToolTip
        textField.toolTip = resolvedToolTip
    }
}
