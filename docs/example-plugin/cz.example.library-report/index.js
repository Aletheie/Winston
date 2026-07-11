// Example Winston plugin: reports how many books lack an ISBN or a description.
// Copy this folder into ~/Library/Application Support/Winston/Plugins/ and
// enable it in Settings → Plugins.

exports.activate = async () => {
    try {
        const books = await Winston.library.list();
        const noIsbn = books.filter((b) => !b.isbn).length;
        const noDescription = books.filter((b) => !b.description).length;

        console.log(`scanned ${books.length} books: ${noIsbn} without ISBN, ${noDescription} without description`);
        await Winston.storage.set("lastReport", {
            at: new Date().toISOString(),
            total: books.length,
            noIsbn,
            noDescription,
        });
        await Winston.ui.toast(`${books.length} books — ${noIsbn} without ISBN, ${noDescription} without description`);
    } catch (e) {
        // Rejections that escape an async activate are silent — always report.
        console.error(`report failed: ${e.code ?? ""} ${e.message}`);
    }
};
