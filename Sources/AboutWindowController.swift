import AppKit

final class AboutWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "About FindAll")
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
        icon.setAccessibilityLabel(String(localized: "FindAll application icon"))

        let name = label("FindAll", size: 26, weight: .bold)
        let standardVersion = label("Version \(version) (Build \(build))", size: 13)
        let description = label(String(localized: "A native, keyboard-friendly file search interface for macOS."), size: 13)
        let spotlight = label(String(localized: "Search results are provided using macOS Spotlight metadata."), size: 12, color: .secondaryLabelColor)

        var views: [NSView] = [icon, name, standardVersion]
#if DEBUG
        views.append(contentsOf: [
            label("Version: v\(version)", size: 12),
            label("Build: \(build)", size: 12),
            label("Commit: \(info["FindAllGitCommit"] as? String ?? "unknown")", size: 12),
            label("Status: \(info["FindAllGitStatus"] as? String ?? "unknown")", size: 12),
            label("Build Time: \(info["FindAllBuildTime"] as? String ?? "unknown")", size: 12)
        ])
#endif
        views.append(contentsOf: [description, spotlight, label("© 2026 FindAll", size: 12, color: .secondaryLabelColor)])

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
}
