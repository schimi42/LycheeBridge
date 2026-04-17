# Internal Structure

This document explains how LycheeBridge is organized internally. It is intended for maintainers and contributors who need to change upload behavior, Share Extension handoff, metadata handling, or Lychee API integration.

## High-Level Architecture

LycheeBridge has two executable targets:

- `LycheeBridge`: the macOS host app.
- `LycheeBridgeShare`: the macOS Share Extension.

Both targets share code from `LycheeBridge/Shared`.

The Share Extension receives files from Apple Photos, copies them into the App Group container, writes a manifest, and opens the host app through a custom URL. The host app reads the manifest, lets the user edit metadata, uploads the files to Lychee, then applies title and tag metadata through follow-up API calls.

## Data Flow

1. Apple Photos invokes the Share Extension with one or more `NSItemProvider` attachments.
2. `ShareViewController` imports supported image representations.
3. `SharedImportStore` creates a bundle directory in the App Group container.
4. Imported files and `manifest.json` are written into the bundle directory.
5. The latest bundle id is written to `latestBundleID.txt`.
6. The Share Extension opens `lycheebridge://import?id=<bundle-id>`.
7. `ContentView` forwards the URL to `AppViewModel`.
8. `AppViewModel` loads the bundle and initializes editable metadata.
9. The user selects an album, edits titles and tags, then starts upload.
10. `UploadCoordinator` uploads each photo through `LycheeClient`.
11. If Lychee returns a direct photo id, that id is used.
12. If Lychee only returns an upload filename, the app resolves the photo id by checking album photos and matching the local file checksum.
13. `UploadCoordinator` applies title and tag metadata to the resolved photo id.
14. If every upload and metadata update succeeds, the pending import is removed.

## App Target

### `LycheeBridgeApp.swift`

Defines the app entry point and windows:

- Main window: `ContentView`.
- API diagnostics: `DiagnosticsView`.
- Metadata diagnostics: `MetadataDiagnosticsView`.
- Lychee tags: `LycheeTagsView`.
- Upload progress: `UploadProgressWindow`.

It also defines menu commands:

- `Diagnostics > Show API Diagnostics`
- `Diagnostics > Show Metadata Diagnostics`
- `Lychee > Show Tags`

### `ContentView.swift`

Contains the main upload workflow:

- Connection settings.
- Pending import controls.
- Photo metadata editor.
- Destination album picker.
- Upload action.

The main window intentionally does not show diagnostics, tag overview, or upload result rows. Those views live in separate windows to keep the upload flow focused.

Important nested views:

- `PhotoMetadataEditor`: thumbnail, title field, and tag field for one photo.
- `EditableTagField`: tag entry, autocomplete suggestions, selected tag chips.
- `TagList`: reusable tag overview grid.
- `UploadResultRow`: reusable upload result and metadata status row.

### `AppViewModel.swift`

The main state container for the app. It owns:

- Saved configuration and credentials.
- Loaded albums.
- Loaded Lychee tags.
- Pending import bundle.
- Editable metadata per imported photo.
- Common tags.
- Upload, connection, album, and tag status messages.
- Diagnostics trace text.

It is annotated with `@MainActor` because it drives SwiftUI state and coordinates UI-visible async work.

Key responsibilities:

- Load initial pending import, albums, and tags.
- Handle incoming `lycheebridge://import` URLs.
- Save settings and selected album.
- Maintain local tag suggestions.
- Start uploads through `UploadCoordinator`.
- Clear pending imports after full success.

## Share Extension Target

### `ShareViewController.swift`

This is the Share Extension entry point.

Responsibilities:

- Display import status.
- Read `NSExtensionItem` attachments.
- Choose supported image representations.
- Preserve useful filenames where possible.
- Create a shared import bundle.
- Open the host app with the bundle id.

The extension supports common image UTTypes including JPEG, PNG, HEIC, TIFF, and generic images.

## Shared Code

### `Models.swift`

Defines shared domain models:

- `ImportedPhoto`
- `ImportedPhotoMetadata`
- `ImportedPhotoEditableMetadata`
- `ShareImportBundle`
- `LycheeConfiguration`
- `LycheeCredentials`
- `LycheeAlbum`
- `LycheeTag`
- `UploadResult`
- `MetadataOperationStatus`

`ImportedPhotoEditableMetadata` normalizes titles and tags before upload. Tags are trimmed and deduplicated case-insensitively.

### `AppGroup.swift`

Defines shared identifiers and common App Group paths:

- App Group id.
- Custom URL scheme and host.
- Incoming bundle directory name.

Both app targets must have matching App Group entitlements.

### `SharedImportStore.swift`

Handles the file handoff between the Share Extension and host app.

Each import creates:

- One bundle directory under the App Group container.
- A copied image file for every imported photo.
- `manifest.json` describing the bundle.
- `latestBundleID.txt` pointing to the newest bundle.

The store also clears bundle directories after successful upload or explicit user cleanup.

### `PhotoMetadataExtractor.swift`

Reads embedded image metadata from imported files.

It extracts title-like and tag-like fields when they are present in the image file. Apple Photos often does not write user-entered titles and keywords into the shared file, so this extractor is useful but not sufficient for all Photos workflows.

### `LycheeConfigurationStore.swift`

Stores non-secret configuration in the shared container and stores the password through `KeychainStore`.

### `KeychainStore.swift`

Small wrapper around macOS Keychain APIs for storing the Lychee password.

### `LycheeAPI.swift`

The Lychee client.

Responsibilities:

- Bootstrap the web session.
- Log in using Lychee's session API.
- Reuse authenticated cookies when possible.
- Fetch albums.
- Fetch tags.
- Upload photos.
- Rename uploaded photos.
- Apply tags to uploaded photos.
- Record redacted diagnostics traces.

The client avoids unnecessary login attempts because Lychee rate limits login requests.

Upload id resolution deserves special attention:

- Lychee upload responses can return an upload filename instead of the final 24-character photo id.
- The client computes the local file's SHA-1 checksum.
- It fetches `Album::photos` with cache bypassing.
- It matches the local checksum against Lychee `checksum` and `original_checksum`.
- Filename matching is only a conservative fallback.

This prevents metadata from being applied to the wrong photo when filenames or album ordering are ambiguous.

### `LycheeResponseParsers.swift`

Contains JSON parsers for:

- Album lists.
- Tag lists.
- Upload response ids and filenames.
- Album photo lookup.
- API error messages.

The upload photo id parser accepts Lychee's URL-safe 24-character ids, including `_` and `-`.

### `LycheeDebugTrace.swift`

Formats API request and response diagnostics.

Sensitive values such as passwords, cookies, and CSRF tokens are redacted before traces are stored in the app state.

### `UploadCoordinator.swift`

Coordinates uploads and metadata updates.

For each imported photo, it:

- Marks upload status.
- Retries transient upload errors.
- Applies title metadata if requested.
- Applies tag metadata if requested.
- Records per-photo title and tag status.
- Produces an upload summary.

Metadata failures do not undo a successful upload. They are surfaced in the progress window so the user can see what succeeded and what needs attention.

## State And Error Handling

The app favors conservative behavior:

- If no safe uploaded photo id can be resolved, metadata updates are skipped.
- If upload fails, pending import files remain available.
- If all uploads and metadata updates succeed, pending files are cleared.
- If cleanup fails after upload, the upload result remains visible and the error is appended to the upload message.

## Diagnostics

Diagnostics are in memory only during the app session.

Windows:

- API diagnostics show redacted HTTP traces.
- Metadata diagnostics show extracted embedded file metadata.
- Lychee tags show the fetched and local tag suggestion pool.
- Upload progress shows live upload and metadata status.

## Release-Sensitive Identifiers

These values must remain consistent across app, extension, entitlements, and release signing:

- Host bundle id: `de.lumirio.LycheeBridge`
- Share Extension bundle id: `de.lumirio.LycheeBridge.ShareExtension`
- App Group id: `group.de.lumirio.LycheeBridge`
- URL scheme: `lycheebridge`

Changing them after release can break existing Share Extension registration, stored settings, keychain entries, or App Group data.

## License

LycheeBridge is licensed under the Mozilla Public License 2.0. Keep the root `LICENSE` file in source and binary distributions, and make source changes to MPL-covered files available when distributing modified versions.
