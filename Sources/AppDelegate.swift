import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController!
    private var preferencesWindowController: PreferencesWindowController?
    private var aboutWindowController: AboutWindowController?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        mainWindowController = MainWindowController()
        configureMainMenu()
        refreshShortcutConfiguration()
        showMainWindow(nil)
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
        let about = appMenu.addItem(withTitle: String(localized: "About FindAll"), action: #selector(showFindAllCustomAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showPreferences(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide FindAll"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit FindAll"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = addMenu(to: mainMenu, title: String(localized: "File"))
        addCommandItem(to: fileMenu, title: String(localized: "Open"), command: .open, action: #selector(MainWindowController.openSelection(_:)))
        addCommandItem(to: fileMenu, title: String(localized: "Show in File Manager"), command: .reveal, action: #selector(MainWindowController.revealSelection(_:)))
        addCommandItem(to: fileMenu, title: String(localized: "Copy Path"), command: .copyPath, action: #selector(MainWindowController.copyPath(_:)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = addMenu(to: mainMenu, title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = addMenu(to: mainMenu, title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let show = windowMenu.addItem(withTitle: String(localized: "Show FindAll"), action: #selector(showMainWindow(_:)), keyEquivalent: "0")
        show.target = self
        windowMenu.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
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
        for command in [CommandID.reveal, .copyPath] {
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
        registerGlobalHotKey()
    }

    @objc private func showMainWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController.showAndFocusSearch()
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

    private func registerGlobalHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if hotKeyHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    if delegate.mainWindowController.window?.isVisible == true && NSApp.isActive {
                        delegate.mainWindowController.window?.orderOut(nil)
                    } else {
                        delegate.showMainWindow(nil)
                    }
                }
                return noErr
            }, 1, &eventType, nil, &hotKeyHandlerRef)
        }

        let shortcut = ShortcutSettings.shortcut(for: .globalToggle)
        let identifier = EventHotKeyID(signature: OSType(0x46414C4C), id: 1)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), carbonModifiers(shortcut.modifiers), identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { NSSound.beep() }
    }

    func validateGlobalShortcut(_ shortcut: KeyboardShortcut) -> OSStatus {
        let current = ShortcutSettings.shortcut(for: .globalToggle)
        if current.keyCode == shortcut.keyCode,
           current.modifiers == shortcut.modifiers,
           hotKeyRef != nil { return noErr }

        var candidateRef: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x46414C4C), id: 2)
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

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}
