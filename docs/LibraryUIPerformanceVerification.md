# Library UI performance verification

This workflow measures the real `MainActor` cost and SwiftUI invalidation caused by one
catalog mutation. It uses a persistent SwiftData store and a Release build. Dataset
preparation is deliberately outside every trace.

## Run the matrix

```sh
Scripts/profile-library-ui.sh
```

The default matrix records 1,000, 10,000, and 50,000 books with the Time Profiler,
SwiftUI, Data Persistence, and Allocations templates. It also launches one separate
SQLDebug process per dataset and automatically counts SQLite `SELECT` statements
inside diagnostic scopes. A specific empty output directory can be supplied:

```sh
Scripts/profile-library-ui.sh /private/tmp/WinstonLibraryRun
```

For a smoke run, override only the dataset sizes:

```sh
WINSTON_PERF_COUNTS="1000" Scripts/profile-library-ui.sh
```

`WINSTON_PERF_TIME_LIMIT` changes the per-trace safety limit; the default is `120s`.
`WINSTON_PERF_LOCAL_FETCH_BUDGET` changes the maximum SQL `SELECT` count for each
local mutation; the default is `12`.
Run on the target Mac with other work paused. Keep `machine.txt`, the app commit, and
the Xcode version with every result set.

## What the fixture contains

Each book has stable metadata, an available `BookAsset`, and one to three collection
relationships. Every tenth book has a reading session and every twenty-fifth book has
a highlight. The target book also has a second physical asset on disk. The four
template runs for a dataset start from separate copies of the same pristine store.

The app performs these real `LibraryViewModel` mutations in order:

1. reading status;
2. collection membership;
3. title;
4. custom cover;
5. primary asset.

It then runs the real chunked edition scan and imports one real item from a generated
Calibre `metadata.db`. The Calibre interval includes its global catalog reconciliation
snapshot, staged-file transaction, SwiftData commit, post-import edition evaluation,
and read-model synchronization.

Background plugin refresh, device monitoring, watch-folder work, maintenance, notices,
and online metadata backfill are disabled only while the opt-in scenario environment
variable is present.

The script assigns a unique bundle identifier, bundle name, and executable name only to
its disposable Release product. This lets launch-time Instruments support load
correctly without activating or terminating another Winston build that may already be
running. After those changes, it ad-hoc signs that disposable copy with
`get-task-allow` and disabled library validation so launch-time SwiftUI and Allocations
instrumentation can attach. These profiling entitlements are never applied to the
shipping target.

## Reading the traces

Use these signpost intervals to isolate each mutation:

- `LibraryPerfStatus`
- `LibraryPerfCollection`
- `LibraryPerfTitle`
- `LibraryPerfCover`
- `LibraryPerfAsset`
- `LibraryPerfEditionScan`
- `LibraryPerfCalibreImport`

For startup and persistence work, also inspect:

- `LibraryInitialLoad` — container creation, root `@Query` fetches, the initial
  read-model snapshot, and the first sidebar render;
- `LibrarySnapshot` — `Book` to `Work`, `BookAsset`, collection, and highlight
  traversal while materializing immutable records;
- `SidebarFacets`; sidebar `collection.books` traversals appear in the relationship
  fault call stacks inside `LibraryInitialLoad` or the enclosing mutation interval;
- `EditionScan`, `EditionCandidateFetchPage`, and `EditionCandidateFetch`;
- `CalibreCatalogIndex`; `CatalogIdentityIndexRebuild` and nested
  `GlobalBookFetch` appear only for the initial/recovery rebuild.

In Time Profiler, filter to Winston's main thread and record both elapsed interval time
and sampled main-thread CPU time. In the SwiftUI trace, count view updates for
`ContentView`, `LibraryView`, `SidebarView`, and `LibraryReadModelSyncView`. The opt-in
events `ContentViewBody`, `LibraryViewBody`, `SidebarViewBody`, and
`LibraryReadModelSyncViewBody` are captured as Points of Interest in the Time Profiler
trace and provide an explicit cross-check without adding observed state. In
Allocations, record allocated and persistent bytes for the same mutation interval.

Some beta Xcode/macOS combinations can finish the SwiftUI template with a
`Trace file had no SwiftUI data` warning. Record that limitation in the result notes;
an empty exported `swiftui-updates` table is not a zero-recomputation result. Use the
explicit body events in Time Profiler for that run and repeat the native SwiftUI
measurement on a toolchain that populates the table.

The Data Persistence run includes Points of Interest, so correlate framework fetches,
object faults, and relationship faults with the same intervals. The script exports all
three raw tables and writes their total event counts to
`data-persistence-counts.csv`; interval-level counts still belong in `results.csv`.

In Allocations, record allocated bytes, persistent bytes, peak live bytes, and the
combined peak live count for `Book`, `BookAsset`, `Work`, `BookCollection`,
`Highlight`, and `ReadingSession`. That live-model count is the public-tooling proxy
for the private SwiftData identity-map/registered-object count. Distinguish the
initial identity-map population from the five local mutations: a low SQL count with a
growing live-model peak is still a memory regression.

`swiftdata-query-counts.csv` is generated automatically from
`logs/books-*-swiftdata-sql.log`. Every scope occurrence has its own row. The five
local mutations (`status`, `collection`, `title`, `cover`, and `asset`) are gated at
12 `SELECT` statements apiece by default. This is an intentionally simple,
reproducible store-level budget; Data Persistence fetch events remain the authority
for framework-level fetch and fault classification. A budget failure leaves every
trace and CSV intact, then exits the script with status 2.

`trace-manifest.csv` maps every Instruments run to the corresponding trace, process
log, atomic completion result, and exported trace table-of-contents XML.

Do not compare Debug measurements with this baseline. Keep the store on storage
representative of the target machine: copying it to a RAM disk removes SQLite and
relationship-faulting costs that this verification is intended to expose.

SQLDebug is deliberately run in a separate process. Use its output for statement
counts and query shape only; never compare its absolute latency or allocation numbers
with the Instruments runs because logging materially perturbs execution.
