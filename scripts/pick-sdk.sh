#!/bin/zsh
# Prints an SDK path to build with, or nothing to use the default.
#
# Workaround: from the macOS 27.2 SDK, SwiftUI's @State is a compiler macro, but the Command
# Line Tools don't ship its compiler plugin (SwiftUIMacros), so builds fail without Xcode. When
# that plugin is missing, fall back to the newest installed SDK older than 27.
[[ -n "${SDKROOT:-}" ]] && exit 0
CLT=/Library/Developer/CommandLineTools
[[ "$(xcode-select -p 2>/dev/null)" == "$CLT" ]] || exit 0
ls "$CLT/usr/lib/swift/host/plugins" 2>/dev/null | grep -q SwiftUIMacros && exit 0
for sdk in "$CLT"/SDKs/MacOSX2[0-6].*.sdk(NOn[1]); do
  print -r -- "$sdk"
  exit 0
done
