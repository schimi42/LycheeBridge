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

The host app and share extension exchange imported photos through the App Group container `group.de.lumirio.LycheeBridge`. Both targets need the App Group entitlement for sharing configuration and incoming photo bundles.
