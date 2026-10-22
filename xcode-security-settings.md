# Xcode Security Settings

Security build-setting decisions for Winston. `Project.swift` is the source of truth; generated Xcode project files are not edited directly.

## Enabled settings

- `ENABLE_ENHANCED_SECURITY` to `YES`: Enables Xcode's compiler-side Enhanced Security protections project-wide.
- `com.apple.security.hardened-process`: Enables the runtime half of Enhanced Security for the Winston application target.
- `com.apple.security.hardened-process.enhanced-security-version-string` to `2`: Selects the current v2 runtime protections.
- `com.apple.security.hardened-process.hardened-heap`: Adds allocator type-isolation buckets.
- `com.apple.security.hardened-process.dyld-ro`: Makes dyld state read-only.
- `com.apple.security.hardened-process.platform-restrictions-string` to `2`: Enables current dyld and Mach-message restrictions.
- `ENABLE_HARDENED_RUNTIME` to `YES`: Already enabled for the app and Quick Look extension before this audit.

## Disabled settings

- `ENABLE_POINTER_AUTHENTICATION` to `NO`: Winston bundles Homebrew `libmtp`/`libusb` arm64 binaries. Revisit only when every binary dependency ships an `arm64e` slice. The override is present on the app, Quick Look, unit-test, and UI-test settings so embedded and host binaries stay compatible.

## Deferred

- `com.apple.security.hardened-process.checked-allocations`: Hardware memory tagging is default-off, hardware-dependent, and needs a staged soft-mode rollout plus hardware testing.
- `ENABLE_C_BOUNDS_SAFETY`: Winston contains no project-compiled C source. The `CLibMTP` system module exposes precompiled Homebrew libraries, so bounds annotations would require an upstream or wrapper adoption project.
- Basic `CLANG_*`, `GCC_*`, and `CLANG_ANALYZER_SECURITY_*` safety settings: Winston and its Quick Look extension compile Swift only. These diagnostics cannot analyze the precompiled `libmtp`/`libusb` implementation; enable them if project-owned C, C++, Objective-C, or Objective-C++ source is added.
