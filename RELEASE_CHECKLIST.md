# FinderSync Release Checklist

1. Run local gate checks:
   - `scripts/check_findersync_release_gate.sh`
2. Build and sign both targets with release provisioning.
3. Inspect signed entitlements on built artifacts:
   - App: `codesign -d --entitlements :- <FormatKit.app>`
   - Extension: `codesign -d --entitlements :- <FormatKit.app>/Contents/PlugIns/FormatKitFinderExtension.appex`
4. Verify both signed entitlements include:
   - `com.apple.security.app-sandbox`
   - `com.apple.security.files.bookmarks.app-scope`
   - `com.apple.security.application-groups` with `group.com.ajbeaver.FormatKit`
5. Manual sandbox validation (Finder extension enabled):
   - Archive single file on Desktop
   - Archive multi-file same folder
   - Convert audio file(s)
   - Convert video file
6. Confirm failure paths are user-visible:
   - request store unavailable
   - bookmark creation failure
   - stale/malformed request
