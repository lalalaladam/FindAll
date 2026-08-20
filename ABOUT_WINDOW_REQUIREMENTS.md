# About Window Requirements

These requirements apply whenever the FindAll About window is created, modified,
debugged, reviewed, or rebuilt.

## Required Content and Order

The About window must show, in this order:

1. Application icon
2. Application name: `FindAll`
3. Standard version line:

       Version X.Y.Z (Build N)

4. Debug metadata, in Debug builds only:

       Version: vX.Y.Z
       Build: N
       Commit: <hash>
       Status: <clean/dirty>
       Build Time: <timestamp>

5. Short project description
6. Spotlight attribution or explanation:

       Search results are provided using macOS Spotlight metadata.

7. Credits, copyright, or project link when applicable

Release builds may hide only Debug-specific metadata. They must retain the standard
version line, project description, and Spotlight explanation.

## Window Implementation

- Use a custom native `NSWindow` managed by a strongly retained
  `AboutWindowController`.
- Do not use the standard system About panel.
- The About menu item must have an explicit target/action.
- Use a uniquely named action such as:

      @objc func showFindAllCustomAbout(_ sender: Any?)

- Set `NSWindow.isReleasedWhenClosed = false`.
- Closing and reopening About must continue to work reliably.
- Give the window a valid non-zero initial content size.
- Avoid recursive or circular Auto Layout sizing during controller initialization.
- Activate the application before presenting the window.
- Reuse the existing controller and window instead of creating a new instance on every open.

## No-Scroll Requirement

The complete About hierarchy must be non-scrollable.

Do not use:

- `NSScrollView`
- SwiftUI `ScrollView`
- `List`
- `Form`
- `Table`
- `TextEditor`
- any other scroll-capable container

All required content must be visible simultaneously when the window opens.

Prefer native controls such as:

- `NSView`
- `NSImageView`
- `NSTextField`
- `NSStackView`
- `NSBox`
- `NSButton` for an optional project link

## Sizing and Alignment

- Use deterministic sizing appropriate for the static content.
- Do not clip, truncate, hide, or shrink required content to an unreadable size.
- Prevent resizing below the size required to display all content.
- Prefer a non-resizable window unless resizing provides a demonstrated benefit.
- Horizontally center:
  - application icon
  - application name
  - standard version line
  - every Debug metadata line
  - project description
  - Spotlight explanation
  - credits and project text
- For AppKit text fields, set text alignment explicitly; centering the frame alone is
  not sufficient.
- Allow descriptions and attribution to wrap deterministically without requiring scrolling.

## Version and Build Metadata

- Read the marketing version and numeric build number from the application bundle.
- Do not duplicate release version values as About-window string literals.
- `CFBundleVersion` must equal the Git commit count used for the build.
- Inject Debug-only metadata through build settings or generated build metadata that is
  excluded from Release output.
- If Debug metadata is unavailable, display an explicit safe fallback rather than crashing.
- Localize labels without changing the underlying version, build, commit, status, or
  timestamp values.

## Accessibility and Interaction

- Give the icon, text, and optional project-link button appropriate accessibility labels.
- Ensure keyboard focus does not become trapped.
- The standard Close Window command and Escape should close the About window when safe.
- An optional project link must use a normal button or link control and open through a
  public macOS API.
- Do not collect analytics or make a network request merely by opening About.

## Verification

- Ensure About-related changes compile successfully and satisfy these requirements by
  code inspection.
- Verify that Debug and Release configurations include the correct respective metadata.
- Manual visual and interaction verification is normally performed by the user.
- Do not launch and visually inspect the application unless explicitly requested.
- Treat user-reported About-window behavior as authoritative runtime evidence.
- Do not claim runtime behavior was verified unless it was actually tested.
