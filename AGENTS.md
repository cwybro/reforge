# Agent notes

Reforge is a SwiftUI macOS app built with SwiftPM. This machine may have only the Command Line Tools
(no Xcode), so always go through `make` / `./build.sh`. They add the flags Swift Testing needs
there, and fall back to an older installed SDK when the Command Line Tools can't build SwiftUI
with the newest one (`scripts/pick-sdk.sh`).

## Build

- `./build.sh` (or `make build`): optimized build, bundled and signed as `build/Reforge Dev.app` (git-ignored)
  (bundle ID `local.reforge.dev`), so it never competes with the installed `Reforge.app`. Only
  `make install` builds the real `local.reforge` identity, in a temp folder.
- `make dev`: build and open a dev copy. Dev builds always keep their settings and API key in
  `./.dev/` (the path is baked into their Info.plist), however they're opened, so they never touch
  the Keychain or your real config.
- Don't run `make install` / `make run` (they replace `/Applications/Reforge.app`) unless asked.

## Validate

- `make test`: unit and flow tests (Swift Testing). Fast (well under a second) and fully stubbed.
- `make e2e`: rebuilds the app, then drives it through the Accessibility API in stub mode. The app
  runs invisibly and never takes focus, so it doesn't disrupt whatever you're doing. Needs
  Accessibility permission for the terminal or IDE that runs it. If the tests say it's missing,
  ask the user to grant it rather than skipping the suite.
- `make perf`: performance suite (launch, idle CPU/memory, time for screens to appear, missed
  frames, hot code paths). Timing-based, so it's opt-in and not part of the pre-push checks. Run it
  when changing rendering, lists, scanning or main-thread work, and compare with
  `build/perf/latest.txt` from before your change. Opens visible (never focused) windows for
  about a minute.
- `make perf-trace`: records scenarios with Instruments' Animation Hitches template (needs Xcode)
  and checks the real render hitches and hangs it finds. Takes about 5 minutes (Instruments
  processes each recording), so use it to dig into a frame-rate problem. Traces land in `build/perf/traces/` to open in Instruments.
- Don't use plain `swift test`: without Xcode it fails to find the `Testing` module.
- UI suites (`make e2e`, `make perf`, `make perf-trace`) need an unlocked, awake Mac: while it's
  locked, macOS hides window contents from the Accessibility API. They say so when that's why.

Tests must stay deterministic. Use the injected fakes in `Tests/ReforgeTests/Support.swift`
and a fresh temp folder per test. Never use the network, the real Keychain, the user's config,
their AddOns folder, the Trash, launchd (LaunchAgents) or real notifications. Don't use fixed sleeps.

## New UI must ship with E2E tests

Every UI change comes with E2E tests (`Tests/ReforgeE2ETests`) in the same change, so the feature
works as expected from the start and later changes can't silently break it. Cover:

- **Routing:** every way to reach the new screen or element (buttons, menu items, keyboard
  shortcuts, links from other screens) and every way back out (Back, Done, Cancel, Skip, close).
- **Every interaction:** each button, toggle, picker, field, link, context-menu command and menu
  item, with assertions on what the user sees *and* on the resulting state (saved config, key,
  recorded installs/uninstalls, opened links).
- **Every state:** empty, loading-to-loaded, error with its retry, and disabled/enabled conditions.

How (see `UXCoverageTests.swift` for examples):

- Give every interactive element a stable `.accessibilityIdentifier` (`area.thing`, e.g. `search.retry`).
- Context-menu commands: mirror each one with `.accessibilityAction(named:)` (attached after
  `.accessibilityElement`/`.accessibilityIdentifier`) and drive that. AppKit doesn't reliably
  open menus for the never-active test app.
- Menu pickers: add `.adjustable(_:through:)` and drive them with `kAXIncrementAction`. Segmented
  pickers can be pressed by segment title (`pressChild(of:titled:)`).
- Links and Finder: go through `Opener` (`.opensLinksWithOpener()` for `Link`), which stub mode
  records to `opens.jsonl`.
- Failure paths: add a switch to `E2E.Fixture` (like `failChecks`, `failInstallFileIds`) rather
  than special-casing the app.
- New dependencies (network, files outside the fixture, system services) get a stub in
  `E2EStubs.swift`; stub mode must never fall back to production behaviour.

## Releases

Every push to `main` runs `.github/workflows/release.yml`: unit tests, a release build, and a GitHub
release `v1.0.<commit count>` with `Reforge.zip`, which the app's updater installs
(`Sources/Reforge/AppUpdate.swift`). So a push to main ships to users. `build.sh` stamps the same
version locally, so a local build of a commit matches its release.

## Before every push

1. Run `make test` and `make e2e`. Both must pass.
2. If anything fails, fix the cause (not the test, unless the test itself is wrong), then run
   **both** suites again. Push only once both pass on the same commit.
