# Writing Winston Plugins — A Beginner's Guide

This is the hand-holding, start-from-zero guide. If you just want the terse API
surface, see **[PluginAPI.md](PluginAPI.md)**. If you have never written
JavaScript before, start here and read top to bottom.

A Winston plugin is a small folder with a `manifest.json` and one JavaScript
file. Winston runs it *in-process* in JavaScriptCore — a JavaScript engine with
**no built-in I/O**. Your plugin cannot read files, open sockets, or run
programs. The only things it can do are what the `Winston` object hands it, and
each of those must be declared in the manifest **and** confirmed by the user.
Plugins are **disabled by default**; nothing runs until someone switches yours on
in **Settings → Plugins**.

> **One thing up front, if you've seen the draft API:** there is **no**
> `Winston.network.fetch(url)`. A plugin can't hit arbitrary URLs by design.
> The only way to pull data from outside is `Winston.metadata.fetch(...)`, which
> goes through Winston's *own* book-metadata service and is off unless the user
> has enabled online metadata. The tutorial below uses the real call.

---

## 1. Getting started (the essentials)

### Where the folder goes

Put your plugin folder here (create the `Plugins` folder if it isn't there yet):

```
~/Library/Application Support/Winston/Plugins/
```

The fastest way to open it: **Settings → Plugins → Open Plugins Folder**.

Your plugin is one folder whose **name must exactly match the `id`** in its
manifest:

```
Plugins/
  cz.example.metadata-filler/     ← folder name == manifest "id"
    manifest.json                 ← required
    index.js                      ← your code (any name; see "entry")
```

After you add or change a folder, click **Refresh** in Settings → Plugins.

Anything your plugin *saves* (via `Winston.storage`) lives somewhere else:

```
~/Library/Application Support/Winston/PluginData/<your-id>/
```

That separation is deliberate — replacing your plugin folder to ship an update
never wipes the user's saved data.

### The manifest

`manifest.json` describes your plugin. Every key below is required except
`description` and `author`:

```json
{
  "id": "cz.example.metadata-filler",
  "name": "Metadata Filler",
  "version": "1.0.0",
  "api": "1",
  "entry": "index.js",
  "permissions": ["library.read", "library.write", "metadata.fetch", "ui.toast"],
  "description": "Fills in missing publisher/description/tags from online metadata.",
  "author": "Your Name"
}
```

| Key | Meaning |
|---|---|
| `id` | Reverse-DNS-style identifier, **lowercase** letters, digits, dots, hyphens (3–100 chars). Must equal the folder name. |
| `name` | Human name shown in Settings and in your toast messages. |
| `version` | Your plugin's own version. Bumping it **re-asks** the user for permissions — so a new version that wants more access can't inherit the old consent. |
| `api` | Which Winston plugin-API major you target. This Winston implements **`"1"`**. A mismatch refuses to load (with a clear reason) rather than half-working. |
| `entry` | The script file to run, e.g. `"index.js"`. Must be a plain filename inside your folder (no `/`, no `..`). |
| `permissions` | The capabilities you request (see below). An **unknown** permission string makes the whole manifest invalid. |
| `description`, `author` | Optional, shown in Settings. |

### How permissions work

A capability's namespace **only exists inside your plugin if you both declared
its permission and the user granted it.** Ungranted, it is literally `undefined`
in JavaScript — there is no back door.

| Permission | Unlocks |
|---|---|
| `library.read` | `Winston.library.list()` and `Winston.library.get()` |
| `library.write` | `Winston.library.update()` (fills **empty fields only** — never overwrites) |
| `metadata.fetch` | `Winston.metadata.fetch()` through Winston's online catalog service |
| `ui.toast` | `Winston.ui.toast()` |

`Winston.storage` and `console` need **no** permission — both are scoped to your
plugin alone.

When the user first enables your plugin, Winston shows a consent sheet listing
exactly what you asked for. Nothing runs until they confirm.

### The shape of a plugin

Bare JavaScriptCore has no module system. You attach your entry points to a
pre-made `exports` object:

```js
exports.activate = async () => {
    // Runs once when the plugin is enabled, and again at every launch
    // while it stays enabled. This is where your work happens.
};

exports.deactivate = () => {
    // Optional, best-effort. Called when the plugin is disabled or Winston
    // quits. Don't rely on it for anything critical.
};
```

`activate` has about **10 seconds** to return. A plugin that hangs is
*quarantined* and left disabled — so don't do slow work synchronously; `await`
it (see below).

---

## 2. Tutorial — "Your First Metadata Fetcher"

We'll build a real plugin that finds books missing a publisher or description,
looks each one up online through Winston, and fills in the blanks. It touches
every core idea: permissions, `async`/`await`, Promises, JSON, reading the
library, calling out for metadata, and writing results back safely.

> **Copy-paste ready:** this exact plugin ships in
> [`docs/example-plugin/cz.example.metadata-filler/`](example-plugin/cz.example.metadata-filler/).
> Drop that folder into your `Plugins/` directory and enable it.

### 2a. Two files

`manifest.json` — exactly the one shown above.

`index.js`:

```js
// Metadata Filler — finds books with missing metadata and completes them
// using Winston's own online lookup. Nothing here can touch the network
// directly; Winston.metadata.fetch is the only door, and the user controls it.

// How many books to process per run. Kept small so we're polite to the
// metadata sources and finish well inside the ~10s activate budget.
const MAX_PER_RUN = 5;

exports.activate = async () => {
    // ALWAYS wrap an async activate in try/catch. A Promise rejection that
    // escapes activate is invisible to you — no crash, but no log either.
    try {
        // Feature-detect instead of assuming. If the user didn't grant a
        // capability, its namespace is `undefined`. capabilities.has() lets
        // you degrade gracefully rather than throw a TypeError.
        if (!Winston.capabilities.has("metadata.fetch")) {
            console.error("This plugin needs the 'metadata.fetch' permission.");
            return;
        }

        // 1. READ THE LIBRARY.
        // Winston.library.list() returns a Promise, so we `await` it. Forget
        // the await and `books` would be a Promise object, not an array —
        // the #1 beginner bug.
        const books = await Winston.library.list();
        console.log(`library has ${books.length} books`);

        // 2. PICK THE ONES THAT NEED HELP.
        // Each book is a read-only snapshot (see the field list in PluginAPI.md).
        // Changing it here does nothing — you must call library.update.
        const needy = books
            .filter((b) => !b.publisher || !b.description)
            .slice(0, MAX_PER_RUN);

        if (needy.length === 0) {
            await Winston.ui.toast("Every book already has publisher and description.");
            return;
        }

        let filledCount = 0;

        // 3. FOR EACH, LOOK IT UP AND FILL THE GAPS.
        for (const book of needy) {
            // metadata.fetch needs an ISBN or at least a title. Prefer the
            // ISBN when we have one; fall back to title + author.
            const query = book.isbn
                ? { isbn: book.isbn }
                : { title: book.displayTitle, author: book.displayAuthor };

            let found;
            try {
                // This is the ONLY outbound call. It resolves to a metadata
                // snapshot, or null if nothing matched.
                found = await Winston.metadata.fetch(query);
            } catch (e) {
                // If online metadata is switched off in Settings, this rejects
                // with code "unavailable". Tell the user once and stop.
                if (e.code === "unavailable") {
                    await Winston.ui.toast(
                        "Turn on online metadata in Settings to use this plugin.",
                        "error"
                    );
                    return;
                }
                // Any other lookup error: log it and move to the next book.
                console.error(`lookup failed for "${book.displayTitle}": ${e.message}`);
                continue;
            }

            if (!found) {
                console.log(`no match for "${book.displayTitle}"`);
                continue;
            }

            // 4. WRITE IT BACK — fill-empty-only.
            // The fetched shape (authors[], subjects[]) differs from the patch
            // shape (author string, tags[]), so we map between them. Winston
            // ignores any field that's already set on the book, so this can
            // never clobber the user's edits.
            const patch = {
                publisher: found.publisher,
                year: found.year,
                description: found.description,
                author: found.authors && found.authors.join(", "),
                tags: found.subjects,
            };

            // library.update reports exactly which fields it actually filled.
            const result = await Winston.library.update(book.uuid, patch);
            if (result.applied.length > 0) {
                filledCount++;
                console.log(`"${book.displayTitle}" ← filled: ${result.applied.join(", ")}`);
            }
        }

        // 5. REMEMBER WHEN WE LAST RAN (storage round-trips any JSON value).
        await Winston.storage.set("lastRun", {
            at: new Date().toISOString(),
            filled: filledCount,
        });

        // 6. TELL THE USER.
        await Winston.ui.toast(
            `Filled metadata for ${filledCount} of ${needy.length} book(s).`,
            "success"
        );
    } catch (e) {
        // The safety net. `e.code` is present on errors from the Winston API.
        console.error(`activate failed: ${e.code ?? "js-error"} — ${e.message}`);
    }
};
```

### 2b. Run it

1. Copy the folder into `~/Library/Application Support/Winston/Plugins/`.
2. **Settings → Plugins → Refresh.** Your plugin appears, **Disabled**.
3. Flip its toggle. Confirm the permission sheet (Read library metadata, Fill in
   missing book metadata, Show notifications).
4. Make sure **online metadata is enabled** in Settings (otherwise you'll get the
   friendly "turn it on" toast — which is itself a good sign the error path works).
5. Watch the toast and expand the plugin's **Log** in the pane.

### 2c. What each piece taught you

- **`await`** pauses until a Promise resolves. Every `Winston.*` call returns a
  Promise — always `await` it (or `.then()` it).
- **Snapshots vs. writes.** `library.list/get` give you read-only copies; the
  only way to change a book is `library.update`, and it fills empty fields only.
- **Error codes.** API rejections carry a stable `code` (`invalid-argument`,
  `permission-denied`, `unavailable`, `timeout`) plus a human `message`. Branch
  on `code`.
- **Feature detection.** `Winston.capabilities.has(name)` beats assuming a
  namespace exists.

---

## 3. Debugging & troubleshooting

### `console` — your primary tool

```js
console.debug("fine detail");
console.log("normal progress");     // console.info is the same level
console.warn("something's off");
console.error("it broke:", err.message);
```

Everything you log goes to **two** places:

1. **In-app**, live: Settings → Plugins → your plugin → the **Log** disclosure
   shows the most recent lines (errors in red). This is the fastest loop while
   writing a plugin.
2. **macOS unified logging** (OSLog), under subsystem `cz.annajung.Winston`,
   category `plugins`.

### Watching logs in Console.app

Open **Console.app** (Applications → Utilities), select your Mac in the sidebar,
click **Start streaming**, and put this in the search field:

```
subsystem:cz.annajung.Winston category:plugins
```

Or from Terminal (note the quoting — the whole predicate is one single-quoted
argument):

```sh
log stream --predicate 'subsystem == "cz.annajung.Winston" && category == "plugins"'
```

To read past logs instead of streaming, swap `stream` for `show --last 30m`.

### Common beginner mistakes — and how Winston reports them (without crashing)

Winston never lets a misbehaving plugin take down the app. Here's what each
mistake looks like from your side:

| Mistake | What you'll see |
|---|---|
| **Forgot `await`** | Your variable is a `Promise`, not the value — e.g. `books.length` is `undefined` and `.filter` throws. Look for a `TypeError` in the log. |
| **Bad `uuid`** | `library.get`/`update` reject with code `invalid-argument`. The book isn't found or the string isn't a UUID. |
| **Called a capability you weren't granted** | The namespace is `undefined`, so you get `TypeError: undefined is not an object`. Declare the permission in the manifest and re-enable. Guard with `Winston.capabilities.has(...)`. |
| **`metadata.fetch` while online metadata is off** | Rejects with code `unavailable`. Not an error in your code — the user has to enable it in Settings. |
| **Syntax error / threw at load** | The plugin won't activate; its status in the pane reads **Failed: …** with the message. The app keeps running. |
| **Uncaught exception at runtime** | Logged to your buffer and counted. **Five** uncaught exceptions ⇒ the plugin is **quarantined** and disabled until you re-enable it. |
| **`activate` hangs / infinite loop** | After ~10 s the loader gives up and marks the plugin **Quarantined**. (Winston can't force-stop a runaway script, so avoid `while(true)` and always `await` slow work.) |
| **Rejection escaped an `async` function silently** | *Nothing* is logged — JavaScriptCore has no unhandled-rejection hook. This is why every example wraps its `activate` body in `try/catch` and `console.error`s. Do the same. |

### A minimal "is it even running?" plugin

When in doubt, prove the pipeline works before writing real logic:

```js
exports.activate = async () => {
    console.log("hello from my plugin");
    if (Winston.capabilities.has("ui.toast")) {
        await Winston.ui.toast("plugin is alive");
    }
};
```

If you see the log line and the toast, your folder name, manifest, and
permissions are all correct — build up from there.

---

See **[PluginAPI.md](PluginAPI.md)** for the complete API reference and the full
list of `Book` snapshot fields.
