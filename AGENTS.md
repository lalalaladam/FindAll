# AGENTS.md

## Development

- Read and understand the existing architecture before modifying code.
- Modify only files required for the task.
- Preserve existing functionality unless explicitly requested otherwise.
- Avoid unnecessary architectural refactoring, dependencies, and new files.
- Maintain compatibility with the project's supported macOS version and architecture.
- Prefer public Apple frameworks and native controls.
- After meaningful code or project changes, ensure the project builds successfully.
- Do not claim runtime or visual behavior was verified unless it was actually tested.

## Xcode

- Use `DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"` for command-line
  builds in the current development environment.
- Set `DEVELOPER_DIR` per command. Do not rely on or change the system-wide
  `xcode-select` setting.
- Until the project is created, the expected identifiers are:
  - Project: `FindAll.xcodeproj`
  - Scheme: `FindAll`
  - Product: `FindAll.app`
  - Bundle Identifier: `com.lalalaladam.FindAll`
- Update this file and `STANDARD_RELEASE_WORKFLOW.md` if the actual project differs.

## Git

- Do not commit, push, tag, publish, or create releases without explicit user authorization.
- Do not discard, overwrite, or stage unrelated user changes.
- Generated build products must remain excluded from Git.
- Never force-push or rewrite history unless the user explicitly requests the exact action.

### Commit Messages

- Write commit titles in English only.
- Write commit descriptions bilingually when a description is included.
- Put English first, followed by a Chinese translation with the same meaning.
- Keep titles concise and imperative when appropriate.

## Build Metadata

Use the Git commit count as the numeric build number:

    CFBundleVersion = git rev-list --count HEAD

Do not manually assign a different `CFBundleVersion`.

Debug builds must make the following metadata available to the About window:

- Marketing version
- Build number
- Short Git commit hash
- Working-tree status (`clean` / `dirty`)
- Build timestamp (`yyyyMMdd.HHmmss`)

## Debug Verification Builds

Every successful command-line Debug build performed as a task verification must archive
the runnable application into:

    Build/Debug-<BuildNumber>-<GitHash>-<Timestamp>/

Example:

    Build/Debug-12-213a61a-20260820.142500/

Rules:

- `BuildNumber` is the result of `git rev-list --count HEAD`.
- `GitHash` is the short Git HEAD hash.
- Never overwrite an earlier archived Debug build.
- The archive must contain the runnable app built from that exact working-tree state.
- `Build/` must remain ignored by Git.
- Use a temporary DerivedData directory outside `Build/`.
- After archiving and verifying the app, remove temporary build products.
- Ordinary interactive Xcode Run operations are not subject to this archive requirement.

## Official Releases

- Before preparing or publishing an official release, read and follow:

      STANDARD_RELEASE_WORKFLOW.md

- A request to build or package does not authorize committing, pushing, tagging,
  or creating a GitHub Release.
- Release builds must be created from a clean, committed source state.
- Until signing policy changes explicitly, official artifacts use ad-hoc signing and
  must not be described as Developer ID signed, notarized, or stapled.

## About Window

Before creating, modifying, debugging, reviewing, or rebuilding the About window,
read and follow:

    ABOUT_WINDOW_REQUIREMENTS.md

## Verification

- Perform build-time and code-level verification proportional to the change.
- Manual UI and visual verification is normally performed by the user.
- Do not launch and visually inspect the app unless explicitly requested.
- Treat user-reported UI and runtime behavior as authoritative evidence.
