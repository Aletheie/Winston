# Public release fixtures

`Winston-v0.1.store` is an anonymized SwiftData catalog created by the code at the
public `v0.1` tag. It contains two books, one collection, one highlight and one
wishlist item, with fixed UUIDs and dates.

The migration test copies the store to a temporary directory, opens that copy with
the current model, runs the same catalog and reading-history backfills as startup,
and checks both the old data and the new relationships. Never replace this fixture
with a database created by the current model: its value is that it carries the exact
schema metadata shipped in 0.1.

SHA-256: `17b0fe3d77b634a6e481ca2fe4e2ca23a9cc6c598eb95aa598ba190f3f62e1dd`
