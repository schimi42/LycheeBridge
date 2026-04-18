# LycheeBridge

LycheeBridge is a macOS app with a Share Extension for sending photos from Apple Photos to a [Lychee](https://lycheeorg.dev/) gallery.

The app is designed for a simple workflow:

1. Select photos in Apple Photos.
2. Share them to LycheeBridge.
3. Choose a Lychee album.
4. Review titles and tags.
5. Upload the photos.

LycheeBridge keeps the main window focused on the upload flow while diagnostics, tag overview, and upload progress live in separate windows.

## Features

- macOS Share Extension for receiving images from Apple Photos.
- Upload to a selected Lychee album through Lychee's session-based API.
- Per-photo title and tag editing before upload.
- Common tags that apply to every pending photo.
- Tag autocomplete from existing Lychee tags.
- Newly typed tags are added to the local autocomplete pool immediately.
- Embedded JPEG metadata extraction for title and keyword fields when available.
- Per-photo upload and metadata status reporting.
- Separate upload progress window with automatic close after successful uploads.
- API diagnostics window with redacted request and response traces.
- Metadata diagnostics window for inspecting embedded image metadata.

## Requirements

- macOS 14 or newer.
- Xcode 16 or newer for building from source.
- A Lychee gallery with a user that can upload and edit photos.
- The Lychee API endpoints used by LycheeBridge must be available under `/api/v2`.

LycheeBridge currently uses username/password session login. Login requests are rate limited by Lychee, so the app reuses session cookies where possible and avoids logging in for every API request.

## Current Limitations

- The app is currently focused on Apple Photos sharing on macOS.
- Apple Photos titles and keywords are usually not exported into shared image files. LycheeBridge can read embedded metadata when it exists, for example from older Aperture/iPhoto workflows, but manual editing is still needed for many Apple Photos exports.
- Retry UI is shown as a placeholder for failed uploads, but retry behavior is not implemented yet.
- Metadata updates happen after upload. If Lychee returns no safe photo id, title and tag updates are skipped rather than applied to the wrong photo.
- The first public release should be treated as an early release until more Lychee installations have tested it.

## Installing From Source

1. Clone the repository.
2. Open `LycheeBridge.xcodeproj` in Xcode.
3. Select the `LycheeBridge` scheme.
4. Build and run the app.
5. Enable the Share Extension in macOS if it does not appear automatically.

If the Share Extension does not update after rebuilding, remove old builds of the app, clean the build folder in Xcode, and run the app again so macOS registers the current extension binary.

## First Run

1. Start LycheeBridge.
2. Enter the Lychee server URL, username, and password.
3. Click `Save Settings`.
4. Click `Test Connection`.
5. Select a destination album.
6. Share one or more photos from Apple Photos to LycheeBridge.
7. Add titles and tags.
8. Click `Upload to Album`.

## Windows And Menus

- Main window: connection, pending import, metadata editing, destination album, and upload action.
- `Lychee > Show Tags`: opens the tag overview window.
- `Diagnostics > Show API Diagnostics`: opens redacted API traces.
- `Diagnostics > Show Metadata Diagnostics`: opens extracted file metadata.
- Upload progress window: opens automatically when an upload starts.

## Privacy And Security

- Passwords are stored in the macOS Keychain.
- Imported photos are copied into the app group's shared container so the app and Share Extension can exchange them.
- Pending imported files remain in the shared container until upload succeeds or the user clears the pending import.
- API diagnostics redact sensitive values such as cookies, passwords, and CSRF tokens before storing traces in memory.
- Diagnostics are intended for troubleshooting and should be reviewed before sharing logs.

## Development

Project layout:

- `LycheeBridge/App`: SwiftUI host app, windows, menus, and view model.
- `LycheeBridge/ShareExtension`: macOS Share Extension entry point.
- `LycheeBridge/Shared`: shared models, storage, API client, parsers, keychain access, metadata extraction, and upload coordination.
- `Docs/InternalStructure.md`: maintainer-oriented architecture notes.

Build from the command line:

```sh
xcodebuild -scheme LycheeBridge \
  -project LycheeBridge.xcodeproj \
  -destination 'platform=macOS' \
  build
```

For unsigned local build checks:

```sh
xcodebuild -scheme LycheeBridge \
  -project LycheeBridge.xcodeproj \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LycheeBridgeDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Release Notes

See `Docs/ReleaseNotes.md` for release highlights and known limitations.

## License

LycheeBridge is licensed under the Mozilla Public License 2.0. See `LICENSE` for details.
