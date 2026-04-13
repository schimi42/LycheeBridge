# LycheeBridge

LycheeBridge is a macOS app plus Share Extension that receives photos from Apple Photos and uploads them into an album on a configured Lychee gallery.

## Project layout

- `LycheeBridge/Shared`: models, stores, Keychain integration, Lychee API client, upload coordinator
- `LycheeBridge/App`: macOS host app built with SwiftUI
- `LycheeBridge/ShareExtension`: macOS share extension that imports images from `NSItemProvider`

## Important setup

Before shipping or signing this app, update the following placeholders:

- Bundle identifiers:
  - `de.lumirio.LycheeBridge`
  - `de.lumirio.LycheeBridge.ShareExtension`
- URL scheme: `lycheebridge`

For local development without a paid Apple Developer account, the project now avoids App Groups and uses a shared folder under `~/Library/Application Support/de.lumirio.LycheeBridge` for handoff between the app and the share extension.
