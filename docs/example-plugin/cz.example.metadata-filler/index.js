// Metadata Filler — finds books with missing metadata and completes them
// using Winston's own online lookup. Nothing here can touch the network
// directly; Winston.metadata.fetch is the only door, and the user controls it.
//
// This is the worked example from docs/WritingPlugins.md. Copy this folder into
// ~/Library/Application Support/Winston/Plugins/ and enable it in
// Settings → Plugins (grant Read library metadata, Fill in missing book
// metadata, Fetch metadata from online catalogs, and Show notifications).

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
