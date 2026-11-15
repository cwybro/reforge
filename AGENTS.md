# Agent notes

Reforge is a SwiftUI macOS app built with SwiftPM. This machine may have only the Command Line Tools
(no Xcode), so always go through `make` / `./build.sh`. They add the flags Swift Testing needs
there, and fall back to an older installed SDK when the Command Line Tools can't build SwiftUI
with the newest one (`scripts/pick-sdk.sh`).

## Build

- `./build.sh` (or `make build`): optimized build, bundled and signed as `build/Reforge Dev.app` (git-ignored)
  (bundle ID `local.reforge.dev`), so it never competes with the installed `Reforge.app`. Only
  `make install` builds the real `local.reforge` identity, in a temp folder.
- `make dev`: build and open a dev copy. Its settings and API key live in `./.dev/`, so it never
  touches the Keychain or your real config.
- Don't run `make install` / `make run` (they replace `/Applications/Reforge.app`) unless asked.

## Validate

- `make test`: unit and flow tests (Swift Testing). Fast (well under a second) and fully stubbed.
- `make e2e`: rebuilds the app, then drives it through the Accessibility API in stub mode. The app
  runs invisibly and never takes focus, so it doesn't disrupt whatever you're doing. Needs
  Accessibility permission for the terminal or IDE that runs it. If the tests say it's missing,
  ask the user to grant it rather than skipping the suite.
- Don't use plain `swift test`: without Xcode it fails to find the `Testing` module.

Tests must stay deterministic. Use the injected fakes in `Tests/ReforgeTests/Support.swift`
and a fresh temp folder per test. Never use the network, the real Keychain, the user's config,
their AddOns folder, the Trash, launchd (LaunchAgents) or real notifications. Don't use fixed sleeps.

## Before every push

1. Run `make test` and `make e2e`. Both must pass.
2. If anything fails, fix the cause (not the test, unless the test itself is wrong), then run
   **both** suites again. Push only once both pass on the same commit.
