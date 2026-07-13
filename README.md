<div align="center">

<img src="docs/images/icon.png" width="128" alt="Winston icon">

# Winston

### *Two plus two still make four.* <sup>[?](https://en.wikipedia.org/wiki/2_%2B_2_%3D_5 "Freedom is the freedom to say that two plus two make four. (Winston Smith, Nineteen Eighty-Four)")</sup>

**Your books, on your Mac, on your Kindle.**

<sub>7 MB download · zero dependencies · zero network calls · one cable</sub>

[Download](https://github.com/Aletheie/Winston/releases) · [What it does](#what-it-does) · [Where it's going](#where-its-going) · [Build it](#build-from-source)

<p>
<img alt="macOS 26.4+" src="https://img.shields.io/badge/macOS-26.4%2B-000000?style=flat-square&logo=apple">
<img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-333333?style=flat-square">
<img alt="early access" src="https://img.shields.io/badge/status-early%20access%200.1-e8590c?style=flat-square">
<img alt="MIT" src="https://img.shields.io/badge/license-MIT-4c9a2a?style=flat-square">
<img alt="249 tests" src="https://img.shields.io/badge/tests-249-4c9a2a?style=flat-square">
</p>

https://github.com/user-attachments/assets/488cb698-cd61-4d0a-9fb2-f569d8ae6b86
</div>

> [!IMPORTANT]
> Winston is **early access**. I use it for my own library, but it is still 0.x: parts will change and several planned features are not finished yet. If something breaks, [tell me](https://github.com/Aletheie/Winston/issues).

## Not another Calibre

Winston is a native Mac app for managing an ebook library and getting books onto a Kindle. Library management, conversion, covers, device cleanup and highlights are all part of the same workflow. It stays offline until you enable an online feature. Calibre is only an optional fallback for formats Winston does not yet convert natively.

Longer term, I want Winston to understand **books, not files**. Two translations of Dune belong to the same work. Replacing a broken EPUB should not create another book. That part is still on the roadmap.

## What it does

### Library

- Grid and table views, search, filters, collections, smart collections, reading status, duplicate detection and bulk editing.
- Rename an author, series or tag once and it changes across the library. Author names such as "Tolkien, J. R. R." can be flipped to "J. R. R. Tolkien."
- Import an existing Calibre library with its metadata, or watch a folder for new books. Rescans and online lookups leave manually edited fields alone.
- Statistics, a yearly reading goal, **Surprise Me** for picking a random unread book, and cover sizing with `Cmd +` and `Cmd -`.
- Real page counts for PDFs and estimates for other formats. Very short books are flagged as probable store samples.
- Automatic backups of the catalog and covers. The catalog exports as CSV; highlights export as plain text.

### Conversion

- Built-in EPUB to MOBI conversion, written in Swift. No Calibre process and no bundled conversion binary.
- TXT, HTML and PDF use the same native pipeline. Calibre is optional for AZW3 and other formats.
- Splits Czech and other accented text at valid Unicode boundaries, embeds the selected cover, and writes the trailer records Kindle needs for indexing.
- Runs conversion off the main thread. Byte-level golden tests cover the MOBI writer.

### Kindle

- Older Kindles are detected as USB drives. An MTP backend for newer models is implemented but still needs real-hardware testing.
- A transfer converts when needed, copies the book and its home-screen thumbnail, removes macOS `._` files, then ejects the device so the Kindle can reindex.
- Books can be copied from the device into the library. `My Clippings.txt` becomes structured notes matched to their books and can be exported.

### Discovery

- [Hardcover](https://hardcover.app) integration matches the series you own and shows missing volumes.
- **Discover** browses by genre or search. Results can be saved to a wishlist, with search links to your preferred bookstore or library catalog.
- All network features stay off until you enable them in Settings.

### Plugins

- Plain JavaScript plugins run in JavaScriptCore and live in `~/Library/Application Support/Winston/Plugins/`.
- Each manifest declares permissions, which the user approves in Settings. Plugins have no direct filesystem or network access.
- Plugins start disabled. A load timeout or five uncaught errors quarantines one; its logs remain available in Settings.
- [Example plugins](docs/example-plugin) · [API reference](docs/PluginAPI.md) · [Writing guide](docs/WritingPlugins.md)

### macOS integration

- Quick Look previews for MOBI and AZW3 in Finder.
- Standard menus and keyboard shortcuts.
- Three themes, including the retro terminal theme, plus an app-wide font setting.
- English and Czech localization and a built-in Help book.
- A corrupted library store is moved aside so the app can recover instead of entering a crash loop.

## Screenshots

<div align="center">

<table>
<tr>
<td width="50%"><img src="docs/screenshots/library-table.png" alt="Table view"><br><sub><b>Table view.</b> Sort, filter, edit in bulk.</sub></td>
<td width="50%"><img src="docs/screenshots/book-detail.png" alt="Book detail"><br><sub><b>Book detail.</b> Metadata, cover, reading status.</sub></td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/device-kindle.png" alt="Kindle transfer"><br><sub><b>Kindle.</b> Convert and send in one action.</sub></td>
<td width="50%"><img src="docs/screenshots/discover.png" alt="Discover"><br><sub><b>Discover.</b> Find new books, fill the gaps in your series.</sub></td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/stats.png" alt="Statistics"><br><sub><b>Statistics.</b> What your library is made of.</sub></td>
<td width="50%"><img src="docs/screenshots/help-book.png" alt="Help book"><br><sub><b>The manual.</b> A real Help book, right in the Help menu.</sub></td>
</tr>
</table>

<table>
<tr>
<td width="33%"><img src="docs/screenshots/theme-purple.png" alt="Purple theme"><br><sub><b>Purple.</b></sub></td>
<td width="33%"><img src="docs/screenshots/theme-white.png" alt="White theme"><br><sub><b>White.</b></sub></td>
<td width="33%"><img src="docs/screenshots/theme-black.png" alt="Black theme"><br><sub><b>Black.</b></sub></td>
</tr>
</table>

</div>

## Where it's going

Near term:

- [ ] Notarized releases
- [ ] Automatic updates through Sparkle
- [ ] Native AZW3 output
- [ ] MTP verified on a current Kindle
- [ ] Layered app icon with the full glass treatment

Longer term:

- [ ] **Series watch:** release notifications for series already in the library
- [ ] **Translation plugin:** optional AI-assisted book translation, starting with English and Czech
- [ ] **Editions:** group translations and editions under the same work
- [ ] **Import inbox:** preview changes before import, with one-click undo
- [ ] **Metadata provenance:** store the source of each value and lock hand-edited fields
- [ ] **Highlight remapping:** carry highlights over when an EPUB is replaced

## Install

**Requirements:** macOS 26.4 or newer and Apple Silicon. Calibre is optional and only needed for formats Winston cannot convert itself.

1. Download the zip from [Releases](https://github.com/Aletheie/Winston/releases).
2. Move `Winston.app` to Applications.
3. On first launch, right-click the app and choose **Open**.

The app is signed but **not notarized yet**, so the third step is currently required once.

## Build from source

```bash
brew install libmtp libusb tuist   # libmtp talks to newer Kindles
git clone https://github.com/Aletheie/Winston.git
cd Winston
tuist generate                     # the .xcodeproj is generated, not committed
open Winston.xcworkspace
```

Build and install a release directly into `/Applications`:

```bash
./Scripts/install-app.sh
```

The script uses your Apple Development identity. An ad hoc signature cannot load the bundled `libmtp` under the hardened runtime.

Tests:

```bash
xcodebuild test -workspace Winston.xcworkspace -scheme Winston -only-testing:WinstonTests
```

All test fixtures are generated at runtime; there are no binary fixtures in the repository.

## The Kindle part, explained

Three details matter when sideloading:

- A Kindle does not read a raw EPUB. Winston converts it to MOBI natively or to AZW3 through Calibre before transfer.
- A sideloaded book appears after the device reindexes on eject. Winston ejects it after the transfer.
- The home screen cover comes from the file itself. Winston embeds the cover selected in the library.

If a stubborn Kindle still refuses a converted MOBI: `defaults write cz.annajung.Winston preferKindleAZW3 -bool YES` switches every transfer to AZW3. Needs Calibre.

Verified on a Paperwhite 11th generation.

## Known limits

- **MTP still needs real-hardware verification.** The path for newer Kindles is implemented; the USB-drive path used by older models is proven.
- **No App Store, no iCloud sync.** Raw USB access means the sandbox is off, which rules out both. Your backups are plain files you can copy.
- **Not notarized yet**, hence the right click on first launch.
- **No Intel Macs.** The libmtp build Winston links against is Apple Silicon only.

## Tech

- Swift 6 with MainActor isolation by default
- SwiftUI and SwiftData
- JavaScriptCore for plugins
- Quick Look app extension for MOBI and AZW3 previews
- `libmtp` and `libusb` for MTP devices
- [Tuist](https://tuist.dev) for project generation
- ZIPFoundation for EPUB archives; Sparkle is included for the planned update feed
- Hardened runtime; the main app is unsandboxed for USB access, while the Quick Look extension is sandboxed
- 249 tests in 50 suites, including golden byte tests for the MOBI writer

`Winston/Core` contains conversion, device, metadata, persistence and plugin code. `Winston/Features` contains the SwiftUI screens.

## License

[MIT](LICENSE).

<div align="center">
<sub>Named after Winston Smith, who kept a diary the Party could not read.<br>Your library deserves the same.</sub>
</div>
