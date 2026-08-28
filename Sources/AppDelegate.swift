import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let relaunchDockIconEnvironmentKey = "FINDALL_RELAUNCH_SHOW_DOCK_ICON"
    private static let hotKeySignature = OSType(0x46414C4C)

    private var mainWindowController: MainWindowController!
    private var shelfWindowController: ShelfWindowController!
    private let shelfStore = ShelfStore()
    private let folderContentsWindowManager = FolderContentsWindowManager()
    private var preferencesWindowController: PreferencesWindowController?
    private var aboutWindowController: AboutWindowController?
    private var shelfServiceProvider: ShelfServiceProvider?
    private var hotKeyRefs: [CommandID: EventHotKeyRef] = [:]
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard showsDockIconAtLaunch else { return }
        _ = NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement makes every process start as an agent. A visible Dock icon is
        // implemented only by promoting that fresh process; hiding never depends on
        // demoting an already-regular application.
        if showsDockIconAtLaunch, NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        mainWindowController = MainWindowController()
        shelfWindowController = ShelfWindowController(store: shelfStore)
        mainWindowController.onAddToShelf = { [weak self] urls in
            self?.shelfWindowController.addAndShow(urls)
        }
        mainWindowController.onShowFolderContents = { [weak self] url, sourceWindow in
            self?.folderContentsWindowManager.showContents(of: url, relativeTo: sourceWindow)
        }
        folderContentsWindowManager.onAddToShelf = { [weak self] urls in
            self?.shelfWindowController.addAndShow(urls)
        }
        let serviceProvider = ShelfServiceProvider { [weak self] urls in
            self?.shelfWindowController.addAndShow(urls)
        }
        shelfServiceProvider = serviceProvider
        NSApp.servicesProvider = serviceProvider
        configureMainMenu()
        refreshShortcutConfiguration()
        if !wasLaunchedAsLoginItem {
            showMainWindow(nil)
        }
    }

    private var showsDockIconAtLaunch: Bool {
        switch ProcessInfo.processInfo.environment[Self.relaunchDockIconEnvironmentKey] {
        case "1": return true
        case "0": return false
        default: return WindowPreferences.showDockIcon
        }
    }

    private var wasLaunchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        let appMenu = addMenu(to: mainMenu, title: "FindAll")
        let about = appMenu.addItem(withTitle: L10n.string("About FindAll"), action: #selector(showFindAllCustomAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: L10n.string("Settings…"), action: #selector(showPreferences(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("Hide FindAll"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L10n.string("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L10n.string("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("Quit FindAll"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = addMenu(to: mainMenu, title: L10n.string("File"))
        addCommandItem(to: fileMenu, title: L10n.string("Open"), command: .open, action: #selector(MainWindowController.openSelection(_:)))
        addCommandItem(to: fileMenu, title: L10n.string("Show in File Manager"), command: .reveal, action: #selector(MainWindowController.revealSelection(_:)))
        addCommandItem(to: fileMenu, title: L10n.string("Copy Path"), command: .copyPath, action: #selector(MainWindowController.copyPath(_:)))
        addCommandItem(to: fileMenu, title: L10n.string("Add to Shelf"), command: .addToShelf, action: #selector(MainWindowController.addSelectionToShelf(_:)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.string("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = addMenu(to: mainMenu, title: L10n.string("Edit"))
        editMenu.addItem(withTitle: L10n.string("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.string("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.string("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.string("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.string("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.string("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = addMenu(to: mainMenu, title: L10n.string("Window"))
        windowMenu.addItem(withTitle: L10n.string("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.string("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let show = windowMenu.addItem(withTitle: L10n.string("Show FindAll"), action: #selector(showMainWindow(_:)), keyEquivalent: "0")
        show.target = self
        let showShelf = windowMenu.addItem(withTitle: L10n.string("Show Shelf"), action: #selector(toggleShelf(_:)), keyEquivalent: "")
        showShelf.target = self
        windowMenu.addItem(withTitle: L10n.string("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
    }

    private func addMenu(to mainMenu: NSMenu, title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        mainMenu.addItem(item)
        return menu
    }

    private func addCommandItem(to menu: NSMenu, title: String, command: CommandID, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("command.\(command.rawValue)")
        item.target = mainWindowController
    }

    func refreshShortcutConfiguration() {
        for command in CommandID.allCases {
            let identifier = NSUserInterfaceItemIdentifier("command.\(command.rawValue)")
            guard let item = NSApp.mainMenu?.items
                .compactMap(\.submenu)
                .compactMap({ menu in menu.items.first { $0.identifier == identifier } })
                .first else { continue }
            let shortcut = ShortcutSettings.shortcut(for: command)
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        mainWindowController.refreshContextMenuShortcuts()
        folderContentsWindowManager.refreshShortcutConfiguration()
        registerGlobalHotKeys()
    }

    func relaunchApplication(onFailure: @escaping (Error) -> Void) {
        unregisterGlobalHotKeys()

        _ = UserDefaults.standard.synchronize()
        let shouldShowDockIcon = WindowPreferences.showDockIcon
        let previousActivationPolicy = NSApp.activationPolicy()
        let transitionedToAgent = !shouldShowDockIcon
            && previousActivationPolicy == .regular
            && NSApp.setActivationPolicy(.accessory)

        let launchReplacement = { [weak self] in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            configuration.environment = [
                Self.relaunchDockIconEnvironmentKey: shouldShowDockIcon ? "1" : "0"
            ]
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        if transitionedToAgent {
                            _ = NSApp.setActivationPolicy(previousActivationPolicy)
                        }
                        self?.registerGlobalHotKeys()
                        onFailure(error)
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        }

        // On macOS 27, let Dock observe the foreground-to-agent transition before
        // starting the replacement process. Otherwise the overlapping process lifetimes
        // can be presented as the app continuing to run in the background.
        if transitionedToAgent {
            DispatchQueue.main.async(execute: launchReplacement)
        } else {
            launchReplacement()
        }
    }

    @objc private func showMainWindow(_ sender: Any?) {
        if !mainWindowController.showsOnAllSpaces {
            NSApp.activate(ignoringOtherApps: true)
        }
        mainWindowController.showAndFocusSearch()
    }

    @objc private func toggleShelf(_ sender: Any?) {
        shelfWindowController.toggleVisibility()
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController { [weak self] in
                self?.refreshShortcutConfiguration()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.center()
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showFindAllCustomAbout(_ sender: Any?) {
        if aboutWindowController == nil { aboutWindowController = AboutWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.center()
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func registerGlobalHotKeys() {
        unregisterGlobalHotKeys()
        if hotKeyHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID(signature: 0, id: 0)
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    switch hotKeyID.id {
                    case AppDelegate.hotKeyID(for: .globalToggle):
                        if delegate.mainWindowController.shouldHideForGlobalToggle {
                            delegate.mainWindowController.window?.orderOut(nil)
                        } else {
                            delegate.showMainWindow(nil)
                        }
                    case AppDelegate.hotKeyID(for: .shelfToggle):
                        delegate.toggleShelf(nil)
                    default:
                        break
                    }
                }
                return noErr
            }, 1, &eventType, nil, &hotKeyHandlerRef)
        }

        for command in CommandID.globalCommands {
            let shortcut = ShortcutSettings.shortcut(for: command)
            let identifier = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID(for: command))
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                carbonModifiers(shortcut.modifiers),
                identifier,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs[command] = hotKeyRef
            } else {
                NSSound.beep()
            }
        }
    }

    private func unregisterGlobalHotKeys() {
        hotKeyRefs.values.forEach { _ = UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
    }

    func validateGlobalShortcut(_ shortcut: KeyboardShortcut, for command: CommandID) -> OSStatus {
        guard command.isGlobal else { return OSStatus(paramErr) }
        let current = ShortcutSettings.shortcut(for: command)
        if current.keyCode == shortcut.keyCode,
           current.modifiers == shortcut.modifiers,
           hotKeyRefs[command] != nil { return noErr }

        var candidateRef: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.hotKeySignature, id: 100 + Self.hotKeyID(for: command))
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            carbonModifiers(shortcut.modifiers),
            identifier,
            GetApplicationEventTarget(),
            0,
            &candidateRef
        )
        if let candidateRef { UnregisterEventHotKey(candidateRef) }
        return status
    }

    private static func hotKeyID(for command: CommandID) -> UInt32 {
        switch command {
        case .globalToggle: return 1
        case .shelfToggle: return 2
        default: return 0
        }
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}
