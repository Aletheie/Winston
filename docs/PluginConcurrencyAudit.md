# Plugin System — Concurrency & Security Verification

Audit of the JavaScriptCore plugin runtime against Swift 6 / `MainActor`-default
isolation and the app's threat model. Scope: `Winston/Core/Plugins/` +
`Winston/App/PluginsSettingsPane.swift`. Line references are current as of this
writing; anchor on the symbol names if they drift.

**Reconciliation note.** The brief that prompted this audit describes an API that
does not match what shipped — `AddonManager`, an `Addons/` folder,
`Winston.book.updateTitle`, and a generic `await Winston.network.fetch(url)`. The
shipped system is `PluginService` + per-plugin `PluginRuntime` + `PluginHostAPI`,
under `Plugins/`, with `Winston.library.update(uuid, {...})` and **no arbitrary
network** — plugins reach the network only through the gated `Winston.metadata.fetch`.
Everything below audits the real code.

**Verdict: sound.** No must-fix concurrency or security defect. Three residual
edges are *by design* and documented below so they are chosen, not accidental.

---

## 1. Thread safety / Swift 6 isolation — VERIFIED

`JSContext` and `JSValue` are not `Sendable` and, in this design, never become a
concurrency problem because **they never cross an actor or a queue boundary.**

- **Single-queue confinement.** `PluginRuntime` is `@unchecked Sendable`
  (`PluginRuntime.swift:52`) on one documented invariant: every access to JSC
  state — `vm`, `context`, `pending`, `nextCallID`, `lastException` — happens on
  the plugin's private serial `DispatchQueue` (`:57–73`). This is the same
  `nonisolated(unsafe)` discipline `AppPaths` uses, but enforced at runtime:
  `dispatchPrecondition(condition: .onQueue(queue))` guards `loadOnQueue` (:113),
  `makePendingPromise` (:329), and `teardownOnQueue` (:161). JS only ever executes
  on this queue, so a JS-invoked block is already on it.

- **The queue is deliberately not the cooperative pool.** Plugin JS must never
  occupy a Swift Concurrency thread or the main actor. A dedicated `DispatchQueue`
  means a wedged script costs one thread, isolated from both (see §3).

- **The `MainActor` hop is correct and `JSValue`-free.** The round trip
  (`PluginRuntime.swift:306–357`):
  1. A JS call enters the `@convention(block)` installed by `installAsyncMethod`,
     on the plugin queue.
  2. `decode` turns raw `JSValue` arguments into a `Sendable` `PluginAPICall`
     value (`PluginAPICall`/`PluginMetadataPatch` are `nonisolated ... Sendable`,
     `PluginHostAPI.swift:8–34`) — still on the queue.
  3. `makePendingPromise` creates the JS `Promise`, stores `(resolve, reject)` in
     `pending`, and spawns `Task { await handler(call) }`. `handler` is
     `@MainActor @Sendable` (`typealias PluginHostHandler`, `PluginHostAPI` line
     region `:39`), so the `await` hops to the main actor to touch SwiftData.
  4. The result comes back as `Result<Data?, PluginError>` — JSON bytes, fully
     `Sendable`.
  5. `complete(_:with:)` re-enters the plugin queue via `queue.async` and settles
     the promise with a freshly built `JSValue`.

  No `JSValue` is ever captured by the `Task` or handed to the main actor. The
  DTOs (`PluginBookDTO`, `PluginFetchedMetadataDTO`, `PluginApplyResultDTO`) are
  the model firewall — a `@Model Book` is snapshotted on the main actor and only
  its `Codable` projection travels.

- **Per-plugin VM.** Each runtime owns its own `JSVirtualMachine` + `JSContext`
  (`:123–124`), so no `JSValue` from one plugin can be used in another's context.

- **No registration race.** `pending[id]` is populated *synchronously* inside the
  `JSValue(newPromiseIn:)` executor, which runs during `makePendingPromise` before
  it returns; `complete` re-enters via `queue.async` and therefore cannot run
  until the current queue item finishes. The resolve/reject can never fire before
  the promise is registered.

## 2. Retain cycles in the Swift↔JS bridge — VERIFIED CLEAN

A `JSContext` strongly retains its global object and every installed block. If a
block captured `self` (the runtime) strongly, the cycle `runtime → context →
block → runtime` would leak the entire VM, because JSC's garbage collector and
ARC do not cooperate. The code avoids this everywhere it matters:

- `installAsyncMethod`'s block is `{ [weak self] arg0, arg1 in … }`
  (`PluginRuntime.swift:311`).
- `context.exceptionHandler` is `{ [weak self] _, exception in … }` (:130).
- The completion `Task` is `Task { [weak self] in … }` (:336).
- The `console` blocks (:179) capture only `logBuffer` and `pluginID` — a sibling
  object and a `String` — **not** `self` or `context`. `context → console block →
  logBuffer` is a leaf; `PluginLogBuffer` holds no back-reference, so there is no
  cycle.

The handler chain is also weak on the host side: `PluginHostAPI.makeHandler`
returns `{ [weak self] call in … }` (`PluginHostAPI.swift:104`), so the plugin's
retained handler does not pin the `PluginHostAPI`.

## 3. Infinite loops / watchdog — VERIFIED, with the limit stated honestly

The brief asks for a timeout "so a plugin with `while(true)` cannot freeze a
background thread forever." That exact guarantee **is not achievable with public
JavaScriptCore**: the framework exposes no way to interrupt a running script. The
private `JSContextGroupSetExecutionTimeLimit` (in `JSContextRefPrivate.h`) is not
available in the shipping framework. So the honest design goal is weaker and the
code meets it exactly:

> The *caller* always gets an answer within a deadline and can quarantine the
> plugin; a wedged script keeps only its own dedicated thread, never the main
> actor or the cooperative pool.

- **`withPluginDeadline`** (`PluginDiagnostics.swift:75–91`) races the operation
  against `Task.sleep(for:)`, arbitrated by a resume-once `ResumeGate` (:95–104)
  so the continuation resumes exactly once and the loser's result is dropped. On
  timeout the operation is **not** cancelled — it can't be — but the caller
  receives `PluginError.timeout`.
- **Quarantine.** `PluginService.activate` wraps `runtime.load` in
  `withPluginDeadline(seconds: loadDeadline)` (default 10 s, `:55`). On timeout it
  drops the runtime from the dictionary *without awaiting shutdown*, removes it
  from `enabledPluginIDs` (persistently disabled), and sets `.quarantined`
  (`:153–161`). The wedged queue thread is **leaked by design** — one thread.
- **Fault-count quarantine.** Five uncaught JS exceptions
  (`maxFaults`, `:57`) trip `recordFault` → quarantine (`:169–178`), independent
  of the timeout path.
- **Bounded teardown.** Even `deactivate()` runs under its own 5 s deadline
  (`shutdownRuntime`, `:180–185`), so a plugin that hangs *on the way out* still
  can't block the app.

### Residual edges (by design — not defects)

1. **Post-activation wedge is not watchdogged.** Only `load`/`activate` runs under
   `withPluginDeadline`. A `while(true)` inside a *promise callback* that fires
   after activation (e.g. inside a `.then` on a resolved host call) wedges the
   plugin's own queue thread with no timeout and no quarantine. Blast radius is
   that single plugin's thread; subsequent host calls to it silently queue behind
   the wedge. It is contained but silent. Fixing it fully needs the unavailable
   interruption API; a partial mitigation (a watchdog around each `complete`
   dispatch that quarantines on overrun) is possible if desired.
2. **`Winston.storage.set` is unbounded.** `saveStorage` (`PluginHostAPI.swift:233`)
   writes whatever the plugin serialized to its own `PluginData/<id>/storage.json`
   with no size cap. Self-scoped disk growth only.
3. **Silent async rejection.** A rejection escaping an `async activate` is
   invisible — JSC has no unhandled-rejection hook. This is a plugin-author
   caveat, already called out in `PluginAPI.md` and enforced by convention
   (`try/catch` around the `activate` body).

## 4. Security posture — VERIFIED STRONG

The app runs with the sandbox off (for raw USB / libmtp), but plugins get a real
**capability sandbox** inside a bare `JSContext` that has no ambient I/O:

- **Least privilege, doubly enforced.** Only granted namespaces are *installed*
  in the context — an ungranted capability is `undefined` in JS, with no hidden
  method to reach (`installWinston`, `PluginRuntime.swift:195–299`). Independently,
  `PluginHostAPI.handle` re-checks the permission on every call
  (`PluginHostAPI.swift:110–170`). Consent is per `id@version`
  (`PluginManifest.grantKey`), so a permission expansion in an update re-prompts
  instead of inheriting (`PluginService.needsConsent`, `:106–110`).
- **Path traversal closed.** `manifest.entry` must be a plain filename (no `/`, no
  `..`); `id` must equal the folder name and match
  `^[a-z0-9][a-z0-9.-]{2,99}$`; the entry file is capped at 5 MB
  (`PluginManifest.validationFailure`, `:105–130`). The storage path is derived
  from that regex-constrained `id`, so `PluginData/<id>/` cannot escape either.
- **No data-loss primitive.** `library.update` is fill-empty-only and routed
  through `saveQuietly()` (`PluginHostAPI.apply`, `:198–220`) — a plugin can
  complete a record but never overwrite a user edit.
- **Network is gated, not granted.** `metadata.fetch` is the *only* path off the
  machine, it rides on `library.read`, and it refuses to run unless
  `AppSettings.onlineMetadataEnabled` is on (`:132–143`) — off ⇒ zero network,
  matching the app-wide guarantee.
- **No impersonation.** Toasts are prefixed with the plugin name
  (`"\(manifest.name): \(message)"`, `:162`) so a plugin can't pose as Winston.
- **Strict manifest decoding.** An unknown permission string fails the whole
  manifest (`PluginPermission` is a closed `Codable` enum, `PluginManifest.swift:12`),
  so a plugin written against a newer surface is rejected up front with a visible
  reason rather than half-working.

## Optional hardening (not required)

- Cap value/total size in `PluginHostAPI.saveStorage` (edge #2).
- Give `metadata.fetch` its own permission instead of folding it into
  `library.read`, so "read my library" and "look things up online" are separate
  consents.
- A per-dispatch watchdog around `complete` to quarantine a post-activation wedge
  (edge #1), accepting it still leaks the one thread.

These are refinements to an already-sound design; none is a fix for a live bug.
