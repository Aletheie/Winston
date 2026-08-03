# Winston release checklist

Run this checklist for every public DMG. `Project.swift` is the source of truth for version metadata.

## Required release identity

- Set the intended `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION`.
- Run `Scripts/check-release-readiness.sh`. It must exit successfully.

Automatic updates are not included. Reintroducing them is a separate release project that
must add a real HTTPS feed, signing-key custody, archive signing, upgrade-path testing,
and matching app UI together. Do not ship a placeholder or partial update channel.

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

## DMG release

- Build and notarize the Release app with its real signing identity.
- Create the DMG with `Scripts/create-dmg.sh` and inspect its layout and bundled frameworks.
- Install the new DMG over the previous public build, relaunch, and verify the version and library data.
- Confirm the published DMG remains reachable from a clean machine.
