# Release Notes

## LycheeBridge 0.1.0

Initial public release candidate.

### Highlights

- Share photos from Apple Photos to LycheeBridge through the macOS Share Extension.
- Upload one or more pending photos to a selected Lychee album.
- Review thumbnails before upload.
- Edit per-photo titles and tags before upload.
- Add common tags that apply to all pending photos.
- Use Lychee tag autocomplete based on tags fetched from the connected gallery.
- Apply titles and tags to Lychee after each photo upload.
- Inspect upload progress in a separate progress window.
- Use API and metadata diagnostics windows for troubleshooting.
- Store the Lychee password in the macOS Keychain.

### Known Limitations

- Apple Photos usually does not export user-entered titles and keywords into shared image files. LycheeBridge can read embedded JPEG metadata when it exists, for example in images previously managed by Aperture or iPhoto, but many Apple Photos shares still require manual title and tag entry.
- Metadata is applied after upload. If LycheeBridge cannot resolve the final Lychee photo id safely, title and tag updates are skipped rather than applied to the wrong photo.
- Failed uploads keep the pending import so the files are not lost, but a one-click retry flow is not implemented yet.
- Lychee tags are user/permission dependent. A non-admin Lychee user may not see the same tag list as an admin user.
- The first release has primarily been tested with Lychee v7 API endpoints under `/api/v2`.
- The Share Extension is focused on image sharing from Apple Photos on macOS.

### Before Publishing

- Build from a clean archive.
- Export a signed and notarized distribution artifact.
- Verify the exported app locally with `codesign`, `stapler`, and Gatekeeper before testing on a fresh Mac.
- Confirm the Share Extension appears in Apple Photos on a clean system.
- Review diagnostics output before sharing logs publicly.
