# Winston release checklist

Run this checklist for every public DMG. `Project.swift` is the source of truth for version and update metadata.

## Required release identity

- Replace the placeholder `SUFeedURL` with the live HTTPS appcast URL.
- Set the intended `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION`.
- Keep the existing `SUPublicEDKey`; do not rotate it after users have installed a signed release.
- Confirm that the Sparkle EdDSA private key has a tested backup outside the login Keychain.
- Run `Scripts/check-release-readiness.sh`. It must exit successfully.

## Build and automated verification

```sh
XDG_STATE_HOME=/private/tmp/tuist-state tuist generate --no-open
xcodebuild -workspace Winston.xcworkspace -scheme Winston -configuration Release build
xcodebuild test -workspace Winston.xcworkspace -scheme Winston -destination 'platform=macOS' -only-testing:WinstonTests
git diff --check
```

The build must be warning-free, all unit tests must pass, and the localization check must report no missing Czech or stale catalog entries.

## Manual verification

- In Black theme and Czech, verify grid keyboard navigation, visible focus, Return-to-open, context-menu deletion confirmation, collection/tag deletion confirmation, and device storage wording.
- Turn on Larger Text, Reduce Motion, Reduce Transparency, Increase Contrast, and Differentiate Without Color individually; inspect the Library, Device, Discover, OPDS, Book Doctor, Statistics, and toast surfaces.
- Verify single- and multi-book deletion move managed book files to Trash.
- Connect Kindle hardware and run import, send, remove, sync-plan, refresh, and eject spot checks.
- Spot-check Purple and White themes for focus rings, genre selection, alert copy, glass fallbacks, and text contrast.
- Run the existing UI tests from Xcode if macOS TCC permits automation.

## DMG and update path

- Build and notarize the Release app with its real signing identity.
- Create the DMG with `Scripts/create-dmg.sh` and inspect its layout and bundled frameworks.
- Publish a signed Sparkle archive and appcast entry using the escrowed EdDSA key.
- Install the previous public DMG, use **Check for Updates**, install the new version, relaunch, and verify the version and library data.
- Confirm the published appcast and archive are served over HTTPS and remain reachable from a clean machine.
