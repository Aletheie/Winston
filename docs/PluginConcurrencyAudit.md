# Plugin Runtime — Concurrency & Security Verification

Scope: `Winston/Core/Plugins/`, `PluginService`, and the plugin-facing Settings
UI. This document describes the process-isolated runtime introduced for plugin
API 1.2; it intentionally avoids line-number references.

## Security boundary

Each enabled plugin session owns a separate `Process`. The process runs the same
signed Winston executable with the private `--winston-plugin-worker` argument,
but enters the worker main before constructing the SwiftUI app, persistence
stack, or `PluginService`. The worker environment is reduced to `TMPDIR` and its
working directory is a temporary directory.

Only the child process imports and owns JavaScriptCore runtime state. The host
and worker exchange newline-delimited, size-bounded `Codable` messages over
anonymous pipes:

- host → worker: immutable manifest/source/configuration, host responses,
  shutdown;
- worker → host: lifecycle events, bounded logs, and typed `PluginAPICall`
  values;
- no `JSContext`, `JSValue`, SwiftData model, file URL, or host closure crosses
  the process boundary.

JavaScript receives a bare context with `console`, `exports`, and only the
granted portions of `Winston`. It has no module loader, filesystem API, socket
API, process API, Objective-C bridge, or generic network primitive.

This boundary contains untrusted JavaScript and makes sessions killable. It is
not a defense against a native-code exploit in JavaScriptCore itself: the worker
uses the app's executable and code-signing identity. If that stronger attacker
model becomes required, the wire protocol is ready to move unchanged into a
separately signed, sandboxed helper/XPC target.

## Time, CPU, memory, and IPC bounds

`PluginRuntime` arms a wall-time watchdog for every synchronous JavaScript turn,
including initial evaluation, `activate`, promise continuations, and
`deactivate`. Expiry sends `SIGTERM`, then `SIGKILL` after a short grace period.
The process is reaped; no wedged queue or thread remains in Winston.

The worker also installs a process CPU rlimit. The host samples the worker's
physical footprint and terminates it when the per-session memory budget is
exceeded. Memory enforcement lives in the parent because macOS may reject a
low `RLIMIT_AS`/`RLIMIT_DATA` after the executable and frameworks are mapped.

Additional bounds prevent moving a denial of service across IPC:

- bundle, file-count, entry-source, and manifest size limits;
- a maximum encoded IPC line size and a maximum retained log-message size;
- at most 64 unresolved host promises per worker;
- quotas for plugin storage keys, values, entries, and total bytes;
- `library.list` pages of 1–100 results, bounded search text, at most 500
  scanned catalog rows per filtered page, and a bounded cursor offset.

Timeout, memory-limit, unexpected-exit, and protocol failures quarantine the
plugin and remove it from persistent auto-enable state.

## Content identity and permission grants

Discovery creates one immutable `PluginBundleSnapshot`. It recursively hashes
the relative path and bytes of every regular file with SHA-256. Symbolic links,
special files, traversal entry names, over-sized bundles, and folder/id
mismatches are rejected.

Permission consent is stored under `id@version#sha256:<bundle digest>`, not just
the manifest version. `PluginRuntime.load` snapshots the bundle again and
requires both the expected manifest and digest before sending source bytes to
the worker. Therefore a changed `index.js` cannot inherit consent or reuse a
runtime even when `id`, `version`, and the folder name stay unchanged.

## Session leases and late host calls

`PluginHostAPI.openSession` issues an unguessable lease containing the plugin id
and content digest. Every handler is closed over that lease. Disable, refresh,
quarantine, and runtime replacement invalidate it before shutdown begins.

Host calls validate the lease at entry and again after suspension. Catalog
writes validate it inside the `CatalogMutationService` commit closure. Storage
writes linearize their final atomic save under the session-registry lock, so
invalidation either happens before the write (which is refused) or after an
already-authorized commit has completed. Tracked host tasks are also canceled
when the runtime stops.

Consequences:

- a metadata request that finishes after disable cannot apply a later catalog
  update;
- a response from an old worker generation cannot reach a replacement worker;
- removing promise callbacks during teardown is not the only defense against
  late side effects—the host independently rejects the invalid lease.

## Swift concurrency and model isolation

The parent `PluginRuntime` is an actor. Pipe callbacks decode only `Sendable`
wire values and re-enter that actor. Host handlers are `@MainActor`, where
SwiftData fetches and catalog commits occur. Results are encoded DTO snapshots;
live `Book` models never cross actors or processes.

Inside the child, all JavaScriptCore objects remain confined to one private
serial queue. Promise calls are decoded to `PluginAPICall` before crossing IPC,
and host JSON is converted back to fresh JavaScript values only on that queue.

## Regression coverage

The focused suites verify:

- a code-byte change with an unchanged manifest invalidates consent and rebuilds
  the runtime;
- entry-point and bundle symlinks are rejected;
- infinite loops are actually killed and repeated runaway sessions leave no
  live worker PIDs;
- a memory bomb is killed by the footprint watchdog;
- host writes cannot commit after disable;
- paginated list decoding, permission gating, storage quotas, fault quarantine,
  and save/publish rollback paths.
