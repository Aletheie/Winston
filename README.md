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

Calibre is a broad toolbox. Winston is deliberately narrower: a Mac app for keeping an ebook library and using it with a Kindle. It includes its own conversion engine, treats the Kindle as a device rather than a folder, and stays offline unless you enable an online feature.

The longer-term goal is a library that understands **books, not files**. Two translations of Dune are not duplicates, and a corrected EPUB is not a new book. Winston is moving toward that model one release at a time.

## What it does

Winston covers the path from importing an EPUB to opening it on a Kindle.

### Ships its own conversion engine

The app includes an EPUB-to-MOBI converter written specifically for Winston, rather than wrapping Calibre or bundling another converter. It preserves accented text, embeds the selected cover and writes the trailer records a Kindle needs to index the file. The output is covered by byte-level tests, and conversion runs off the main thread. TXT, HTML and PDF are handled natively too; Calibre remains an optional fallback for other formats.

### Treats the Kindle like it matters

Connect a Kindle and Winston detects older models that mount as a drive; it also includes an MTP path for newer models. During transfer it converts unsupported formats, copies the book and its cover thumbnail, removes macOS metadata files and ejects the device so it can reindex.

Books can also be copied back into the library. Highlights from `My Clippings.txt` are imported as structured, exportable notes and matched to their books.

### Knows which books you are missing

Online features are opt-in. When enabled, Winston uses [Hardcover](https://hardcover.app) to show which volumes of a series you own and which are missing. The **Discover** tab browses books by genre or search, and anything you find can be saved to a wishlist alongside your library.

### Extends without asking for blind trust

Winston supports small JavaScript add-ons that you can install or write yourself by copying a folder into Plugins. Each plugin declares what it needs access to, starts disabled and is quarantined if it repeatedly fails. Logs are available in Settings. The planned AI translation feature will use the same system. See the [working examples](docs/example-plugin), [API docs](docs/PluginAPI.md) and [writing guide](docs/WritingPlugins.md).

### Behaves like it belongs on your Mac

Winston provides Finder Quick Look previews for MOBI and AZW3, standard menus and keyboard shortcuts, three themes and an app-wide font choice. It is localized in English and Czech and includes a Help book for the library, Kindle transfers and plugins. If the library store becomes corrupted, Winston moves it aside and recovers instead of getting stuck in a crash loop.

### Sweats the small stuff

- Author names such as "Tolkien, J. R. R." can be normalized across the library. Renaming an author, series or tag in the sidebar updates every matching book.
- Calibre libraries import with their metadata, and a watched folder can pick up new books automatically.
- Smart collections update from saved searches. Rescans and online lookups do not overwrite fields you edited by hand.
- **Surprise Me** picks a random unread book; Cmd plus and Cmd minus resize the cover grid.
- Statistics includes a yearly reading goal, while wishlist entries can link directly to your preferred bookstore or library catalog.
- The catalog and covers are backed up automatically. The catalog exports as CSV and highlights as plain text.

### And yes, it manages books

Grid and table views, search, filters, collections, reading statuses, duplicate detection, statistics and bulk editing are all included.

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

- [ ] Notarized releases, so the app opens with a plain double click
- [ ] Auto updates through Sparkle
- [ ] Native AZW3 output, removing the last reason to have Calibre installed
- [ ] The MTP path verified on a current Kindle
- [ ] A layered app icon with the full glass treatment

Longer term:

- [ ] **Series watch.** Notify you when a new volume in one of your series is released.
- [ ] **Translation plugin.** Optional AI-assisted book translation, starting with English and Czech.
- [ ] **Editions, not duplicates.** Group translations and editions of the same work under one book.
- [ ] **Import inbox.** Review what an import found and what it will change, with one-click undo.
- [ ] **Metadata you can trust.** Track where each value came from and allow hand-edited fields to be locked.
- [ ] **Highlights that survive.** Carry highlights across when a broken EPUB is replaced with a clean copy.

## Install

Download the zip from [Releases](https://github.com/Aletheie/Winston/releases), unzip it and move `Winston.app` to Applications.

The app is signed but **not notarized yet**. On first launch, right-click the app, choose **Open** and confirm. This is only required once.

**Needs:** macOS 26.4 or newer, Apple Silicon. Calibre only if you want the exotic conversions.

## Build from source

```bash
brew install libmtp libusb tuist   # libmtp talks to newer Kindles
git clone https://github.com/Aletheie/Winston.git
cd Winston
tuist generate                     # the .xcodeproj is generated, not committed
open Winston.xcworkspace
```

Release build straight into `/Applications`:

```bash
./Scripts/install-app.sh
```

The script signs with your Apple Development identity on purpose. With an ad hoc signature the hardened runtime refuses to load the bundled `libmtp` and the app dies on launch.

Tests:

```bash
xcodebuild test -workspace Winston.xcworkspace -scheme Winston -only-testing:WinstonTests
```

249 tests in 50 suites. All fixtures are generated at runtime, no binary blobs in the repo.

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

Swift 6 with MainActor isolation by default, SwiftUI, SwiftData. The Xcode project is generated by [Tuist](https://tuist.dev) from `Project.swift`. The EPUB to MOBI writer is pinned by golden byte tests, because a MOBI missing its trailer records copies to a Kindle fine and then silently never appears.

Want to poke around? `Winston/Core` has the conversion, device and metadata engines. `Winston/Features` has the UI.

## License

[MIT](LICENSE).

<div align="center">
<sub>Named after Winston Smith, who kept a diary the Party could not read.<br>Your library deserves the same.</sub>
</div>
