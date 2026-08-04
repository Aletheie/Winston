# Import review real-hardware verification

Run this list before release with representative hardware. Record the model, firmware, macOS version, connection type, result, and any retained recovery transaction.

## Kindle over MTP

- Connect a current Kindle over USB and wait for it to appear in Winston.
- Copy one device-only book to the library. For a clean single file, verify the default immediate approval path; with “Always review imports” enabled, verify the review sheet appears.
- Copy two or more device-only books. Verify the review sheet appears before any catalog row or managed-library file is created.
- Leave the review open for at least one minute and verify the device copy remains available.
- Cancel. Verify all Winston-owned import leases are removed and the catalog is unchanged.
- Repeat and approve. Verify each selected file is published once, deselected files are not failures, and “Show Imported Books” reveals the committed books.
- Disconnect during preparation and during commit. Verify the operation either cancels cleanly before catalog save or appears in Import Review & Recovery after a durable catalog save.

## Kindle mounted as mass storage

- Repeat the MTP checks with a Kindle that mounts as a USB volume.
- Verify import review never ejects the device automatically.
- Use Winston’s explicit Eject control only after review completion and confirm the safe-to-disconnect message.

## File evidence

- Test EPUB, PDF, MOBI/AZW3, TXT, and HTML files where the device supports them.
- Include an exact-content duplicate with a different filename; it must default to Skip.
- Include two books with ambiguous title/author matches; neither may merge automatically.
- Include a DRM-protected file; it must remain visible and nonselectable.
- Include a damaged and an unsupported file; both must remain visible with an actionable explanation.
- Edit title, author, language, ISBN, and series metadata in review and verify the approved values are the values committed.

## Accessibility and appearance

- Repeat the sheet check in Black with Czech localization and in Purple with English localization.
- Verify full keyboard operation: table navigation, Space selection, Return approval, Escape cancellation, and focus visibility.
- Verify VoiceOver announces selection state, source filename, proposed action, warnings, progress, and result controls.
