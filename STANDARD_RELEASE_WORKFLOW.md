# Standard Release Workflow

Follow this workflow for every stable FindAll release. Replace `X.Y.Z` with the
intended marketing version, for example `1.0.0`.

The project has not yet been created. Before the first release, verify that the
project, scheme, product, bundle identifier, deployment target, and architectures
below match the actual Xcode project. Update this document if they differ.

## Expected Project Identity

- Project: `FindAll.xcodeproj`
- Scheme: `FindAll`
- Product: `FindAll.app`
- Bundle Identifier: `com.lalalaladam.FindAll`
- Deployment target: macOS 14 or later
- Release architecture: `arm64`

## Release Constraints

- Official artifacts must use the Release configuration.
- Release source must be a clean, committed Git state.
- `CFBundleVersion` is always the Git commit count; never assign it manually.
- Until the signing policy is explicitly changed, release artifacts use ad-hoc signing.
- Do not attempt Developer ID signing, notarization, or stapling without an appropriate
  Apple Developer identity and explicit user authorization.
- An ad-hoc signature is not an Apple identity signature and does not prevent Gatekeeper
  from warning about an application downloaded from the Internet.
- Committing, pushing, tagging, and creating a GitHub Release each require explicit user
  authorization. A request to build or package does not authorize publication.
- Stop on failed verification. Do not silently substitute a Debug or older product.

## 1. Verify Project Configuration

Before preparing the source, confirm the documented identifiers against Xcode:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -list -project FindAll.xcodeproj

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -showBuildSettings \
  -project FindAll.xcodeproj \
  -scheme FindAll \
  -configuration Release
```

Confirm the product name, bundle identifier, deployment target, supported architecture,
and application path. Stop and update this document if the commands do not match it.

## 2. Prepare the Release Source

1. Finish and verify all intended source and documentation changes.
2. Set `MARKETING_VERSION` to `X.Y.Z` in the Xcode project. Do not edit
   `CURRENT_PROJECT_VERSION` or `CFBundleVersion` to assign a build number.
3. Review the exact changes:

   ```bash
   git status --short
   git diff --check
   git diff
   ```

4. With explicit user authorization, stage only intended files and create an English
   Conventional Commit, for example:

   ```bash
   git add <explicit-file-list>
   git commit -m "chore: prepare vX.Y.Z release"
   ```

5. Confirm the source is clean and record its identity:

   ```bash
   git status --short
   git rev-parse HEAD
   git rev-parse --short HEAD
   git rev-list --count HEAD
   ```

   Stop if the working tree is not clean. The numeric result of
   `git rev-list --count HEAD` is the release build number.

## 3. Create the Release Archive

Use a fresh archive path below `Build/`, which must be ignored by Git. Never overwrite
an earlier archive or release directory.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild clean archive \
  -project FindAll.xcodeproj \
  -scheme FindAll \
  -configuration Release \
  -archivePath "Build/Archives/FindAll-vX.Y.Z.xcarchive" \
  CURRENT_PROJECT_VERSION=<GitCommitCount> \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO
```

If Xcode is installed under another name, set `DEVELOPER_DIR` only for the command.
Do not change the user's system-wide developer-directory setting.

Copy the application from the archive without modifying the archive:

```bash
mkdir "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>"
ditto \
  "Build/Archives/FindAll-vX.Y.Z.xcarchive/Products/Applications/FindAll.app" \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/FindAll.app"
```

If archive creation or extraction fails, stop.

## 4. Ad-Hoc Sign and Verify

Apply an explicit ad-hoc signature to the extracted application:

```bash
codesign --force --sign - --timestamp=none \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/FindAll.app"
```

Verify the bundle and executable:

```bash
codesign --verify --deep --strict --verbose=2 \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/FindAll.app"

plutil -p \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/FindAll.app/Contents/Info.plist"

lipo -archs \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/FindAll.app/Contents/MacOS/FindAll"
```

Verification must confirm:

- `CFBundleShortVersionString` is `X.Y.Z`.
- `CFBundleVersion` is the recorded Git commit count.
- `CFBundleIdentifier` is `com.lalalaladam.FindAll`.
- The executable contains only the intended release architecture (`arm64` initially).
- The bundle has a valid ad-hoc signature and no Developer ID identity.
- Release metadata does not contain Debug-only build metadata.
- The About window displays `Version X.Y.Z (Build N)` and omits only Debug metadata.

`spctl --assess` may reject an ad-hoc-signed, unnotarized application. That is expected
and must not be represented as successful notarization.

## 5. Package and Checksum

Run these commands from the release output directory so the checksum records only the
artifact filename:

```bash
cd "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>"
ditto -c -k --keepParent "FindAll.app" "FindAll-vX.Y.Z-arm64.zip"
shasum -a 256 "FindAll-vX.Y.Z-arm64.zip" > "FindAll-vX.Y.Z-arm64.sha256"
shasum -a 256 -c "FindAll-vX.Y.Z-arm64.sha256"
```

The only public release artifacts are:

- `FindAll-vX.Y.Z-arm64.zip`
- `FindAll-vX.Y.Z-arm64.sha256`

Do not upload the raw `.app`, `.xcarchive`, DerivedData, Debug products, search data,
preferences, or local test files.

## 6. Functional Release Checks

Before publication, perform or obtain explicit user verification for the following:

- The global activation shortcut opens and closes the search window reliably.
- The search field receives focus and does not lose the first typed character.
- A Spotlight-indexed file, folder, and application can be found.
- A newer query cannot be overwritten by stale results from an older query.
- Open, Quick Look, Reveal in Finder, copy, and copy-path actions work.
- User-customized shortcuts appear consistently in menus and execute the correct action.
- Favorite scopes and normal/preferred/pinned folder priorities persist and sort correctly.
- Multi-selection and applicable batch actions behave correctly.
- Missing files, inaccessible scopes, and unmounted volumes fail gracefully.
- Release builds do not display Debug metadata.

Record which checks were performed by code/build verification and which were manually
verified. Do not claim an unperformed runtime check passed.

## 7. Tag, Push, and Publish

Perform this section only with explicit user authorization.

1. Confirm the repository is still clean and HEAD is the commit used above:

   ```bash
   git status --short
   git rev-parse HEAD
   ```

2. Create an annotated version tag:

   ```bash
   git tag -a vX.Y.Z -m "FindAll vX.Y.Z"
   ```

3. Push the release commit and tag without force:

   ```bash
   git push origin main
   git push origin vX.Y.Z
   ```

4. Create a GitHub Release for `vX.Y.Z` and upload only the ZIP and SHA-256 files.

If any tracked source file changes after the archive is built, do not reuse the artifacts.
Commit the correction with authorization, then repeat from clean-source verification.

## 8. Final Verification

Before declaring the release complete, confirm:

- The working tree is clean.
- The release commit equals the commit used for the archive.
- Local and remote `vX.Y.Z` tags reference that commit.
- `origin/main` contains that commit.
- The GitHub Release uses the correct tag.
- The GitHub Release contains only the intended ZIP and checksum artifacts.
- The published checksum matches the published ZIP.

Never force-push, rewrite history, delete or overwrite tags/releases, or bypass a failed
verification without explicit user instruction.
