import AppKit

final class AboutWindowController: NSWindowController {
    init() {
#if DEBUG
        let contentHeight: CGFloat = 500
#else
        let contentHeight: CGFloat = 360
#endif
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: contentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("About FindAll")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(L10n.string("FindAll application icon"))

        let name = label("FindAll", size: 26, weight: .bold)
        let standardVersion = label(
            String.localizedStringWithFormat(L10n.string("Version %@ (Build %@)"), version, build),
            size: 13
        )
        let description = label(L10n.string("A native, keyboard-friendly file search interface for macOS."), size: 13)
        let spotlight = label(L10n.string("Search results are provided using macOS Spotlight metadata."), size: 12, color: .secondaryLabelColor)

        var views: [NSView] = [icon, name, standardVersion]
#if DEBUG
        views.append(contentsOf: [
            label(String.localizedStringWithFormat(L10n.string("Version: v%@"), version), size: 12),
            label(String.localizedStringWithFormat(L10n.string("Build: %@"), build), size: 12),
            label(String.localizedStringWithFormat(L10n.string("Commit: %@"), info["FindAllGitCommit"] as? String ?? "unknown"), size: 12),
            label(String.localizedStringWithFormat(L10n.string("Status: %@"), info["FindAllGitStatus"] as? String ?? "unknown"), size: 12),
            label(String.localizedStringWithFormat(L10n.string("Build Time: %@"), info["FindAllBuildTime"] as? String ?? "unknown"), size: 12)
        ])
#endif
        views.append(contentsOf: [description, spotlight, projectLinkButton()])

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 104),
            icon.heightAnchor.constraint(equalToConstant: 104),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = .center
        field.maximumNumberOfLines = 3
        return field
    }

    private func projectLinkButton() -> NSButton {
        let button = NSButton(
            title: String.localizedStringWithFormat(
                L10n.string("Project page: %@"),
                "github.com/lalalaladam/FindAll"
            ),
            target: self,
            action: #selector(openProjectPage(_:))
        )
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .linkColor
        button.setAccessibilityLabel("FindAll GitHub")
        return button
    }

    @objc private func openProjectPage(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/lalalaladam/FindAll") else { return }
        NSWorkspace.shared.open(url)
    }
}
