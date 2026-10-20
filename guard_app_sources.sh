#!/bin/bash
# Wraps every app-target (Sources/XTermux) file in `#if canImport(UIKit)` so
# the Linux toolchain — which has no SwiftUI/UIKit/Security — can build the
# package for `swift test` (SwiftPM builds all targets, not just test deps).
# Idempotent: files already guarded are skipped.
cd "$(dirname "$0")"
find Sources/XTermux -type f -name '*.swift' | while IFS= read -r file; do
  if head -n1 "$file" | grep -q '#if canImport'; then
    continue
  fi
  {
    echo '#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere'
    cat "$file"
    echo '#endif'
  } > "$file.tmp"
  mv "$file.tmp" "$file"
  echo "guarded: $file"
done
