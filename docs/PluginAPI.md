# Winston Plugin API (v1)

Winston plugins are plain JavaScript, run in-process in JavaScriptCore. A bare
JS context has **no** I/O of any kind — a plugin can only do what the `Winston`
API grants it, and each namespace exists only if its permission is declared in
the manifest *and* confirmed by the user in **Settings → Plugins**. Plugins are
disabled by default.

New to this? Start with the step-by-step **[Writing Winston Plugins](WritingPlugins.md)**
guide (beginner-friendly, with a full worked tutorial). This page is the terse
reference.

## Installing

Drop a folder into `~/Library/Application Support/Winston/Plugins/` and click
**Refresh** in Settings → Plugins:

```
Plugins/
  cz.example.my-plugin/     ← folder name must equal the manifest "id"
    manifest.json
    index.js
```

Plugin-writable state lives separately under `PluginData/<id>/` — replacing
the plugin folder (an update) never touches its data.

## manifest.json

```json
{
  "id": "cz.example.my-plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "api": "1",
  "entry": "index.js",
  "permissions": ["library.read"],
  "description": "What it does.",
  "author": "You"
}
```

- `id` — reverse-DNS style, lowercase letters/digits/dots/hyphens.
- `api` — targeted API major. Winston refuses to load a mismatched major.
- `permissions` — any of:

| Permission | Grants |
|---|---|
| `library.read` | `Winston.library.list/get` |
| `library.write` | `Winston.library.update` (fills **empty fields only**) |
| `metadata.fetch` | `Winston.metadata.fetch` through Winston's online catalog service |
| `ui.toast` | `Winston.ui.toast` |

`Winston.storage` and `console` need no permission (both are scoped to the
plugin itself). Unknown permission strings make the whole manifest invalid.

## Entry script

Attach entry points to the pre-created `exports` object:

```js
exports.activate = async () => {
    // runs once when the plugin is enabled (and at every launch while enabled)
};
exports.deactivate = () => {
    // best-effort, called when the plugin is disabled or Winston quits
};
```

`activate` has ~10 s to return — a plugin that hangs is quarantined and
persistently disabled. Every API call returns a **Promise**; rejections carry
a stable `code` (`invalid-argument`, `permission-denied`, `unavailable`,
`timeout`) plus a human-readable `message`.

## API reference

```js
Winston.host                        // { appVersion, apiVersion, locale }
Winston.capabilities.has(name)      // e.g. has("library.update") — feature-detect, don't version-sniff

console.log/info/warn/error/debug(...)   // → Settings → Plugins log + OSLog category "plugins"

await Winston.storage.set("key", value)  // value: anything JSON-serializable
await Winston.storage.get("key")         // → value or null
await Winston.storage.remove("key")

await Winston.library.list()             // → [Book]
await Winston.library.list({ text: "čapek" })  // filter on display title/author
await Winston.library.get(uuid)          // → Book or null
await Winston.library.update(uuid, {     // fills empty fields only; returns
    publisher: "Argo",                   //   { applied: ["publisher", ...] }
    title: "...", author: "...", year: "...", language: "...", translator: "...", isbn: "...",
    series: "...", seriesIndex: "...", description: "...", tags: ["..."]
})

await Winston.metadata.fetch({ isbn: "9788025712345" })          // or
await Winston.metadata.fetch({ title: "...", author: "..." })
// → { title, authors, publisher, year, description, subjects,
//     ratingsAverage, ratingsCount, ratingsSource } or null.
// Rejects with code "unavailable" while online metadata is off in Settings.

await Winston.ui.toast("message")               // styles: "info" (default),
await Winston.ui.toast("message", "success")    //         "success", "error"
```

A `Book` is a snapshot (changing it does nothing — use `library.update`):

```
uuid, title, author, displayTitle, displayAuthor, publisher, year, language, translator,
isbn, series, seriesIndex, tags, description, rating, communityRating,
readingStatus, format, fileSizeBytes, dateAdded, workUUID, workTitle,
editionCount, formats, physicalCopy, shelfLocation
```

## Rules of the sandbox

- No file paths in or out; books are addressed by `uuid` only.
- No network access — `metadata.fetch` goes through Winston's own catalog
  service, which the user can switch off globally.
- `library.update` can never overwrite a non-empty field, so user edits win.
- Uncaught exceptions are logged and counted; repeated faults quarantine the
  plugin. Note that a rejection you don't `catch` inside an `async` function
  is silent — wrap your `activate` body in `try/catch` and `console.error`.

Example plugins live in `docs/example-plugin/`: `cz.example.library-report`
(a minimal read-only report) and `cz.example.metadata-filler` (the
[guide](WritingPlugins.md)'s worked tutorial).
