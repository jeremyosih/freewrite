# PiDurableKit (vendored)

- Upstream: https://github.com/finnvoor/PiDurableKit
- Commit: `7288c6928df2040492901f5043ec15f87e05fc1e` (upstream `main`, committed 2026-10-19)
- Vendored: 2026-10-27, copied from the owner's T3 Voice vendoring of the same commit
- License: CC0 1.0 (`LICENSE`); bundled third-party notices in `Sources/PiDurableKit/Resources/ThirdPartyNotices.txt`

## What is here

- `Sources/PiDurableKit/` from upstream, unmodified, including `Resources/` (`pi-durable.js`, `quickjs.wasm`,
  `codemode-worker.js`, `Documentation/`, `ThirdPartyNotices.txt`). The JS bundle is used as shipped; it was not rebuilt.
- `Package.swift`: upstream's `PiDurableKit` library target (resources + `sqlite3`), without its tests and DocC.
- Left out: `Sources/PiDurableKit/PiDurableKit.docc`, `JS/` (esbuild/npm tooling), `Tests/`.

Freewrite uses it as a local Swift package (`freewrite.xcodeproj` → `Vendor/PiDurableKit`, product `PiDurableKit`).

## Local changes

None.

## Updating

Fetch the new commit into a fresh empty directory (`git fetch --depth 1 origin <sha>`), replace `Sources/PiDurableKit`
(minus `.docc`) and `LICENSE`, update the SHA and date above, then build the app and run the review tests.
