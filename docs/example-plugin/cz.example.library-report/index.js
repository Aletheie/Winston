// Example Winston plugin: reports how many books lack an ISBN or a description.
// Copy this folder into ~/Library/Application Support/Winston/Plugins/ and
// enable it in Settings → Plugins.

exports.activate = async () => {
    try {
        let total = 0;
        let noIsbn = 0;
        let noDescription = 0;
        let cursor = null;
        do {
            const page = await Winston.library.list({ cursor, limit: 100 });
            for (const book of page.items) {
                total++;
                if (!book.isbn) noIsbn++;
                if (!book.description) noDescription++;
            }
            cursor = page.nextCursor;
        } while (cursor);

        console.log(`scanned ${total} books: ${noIsbn} without ISBN, ${noDescription} without description`);
        await Winston.storage.set("lastReport", {
            at: new Date().toISOString(),
            total,
            noIsbn,
            noDescription,
        });
        await Winston.ui.toast(`${total} books — ${noIsbn} without ISBN, ${noDescription} without description`);
    } catch (e) {
        // Rejections that escape an async activate are silent — always report.
        console.error(`report failed: ${e.code ?? ""} ${e.message}`);
    }
};
