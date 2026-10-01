#!/usr/bin/env bash
# Host unit tests for the Foundation-only iOS sources. The plugin's Swift
# package depends on the Flutter framework, so `swift test` cannot run
# there; these files compile on their own with swiftc instead.
set -euo pipefail

cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

swiftc -parse-as-library \
  ios/file_picker_writable/Sources/file_picker_writable/ChildIdentifier.swift \
  ios/test/ChildIdentifierTests.swift \
  -o "$out/child_identifier_tests"
"$out/child_identifier_tests"

swiftc -parse-as-library \
  ios/file_picker_writable/Sources/file_picker_writable/ChildIdentifier.swift \
  ios/file_picker_writable/Sources/file_picker_writable/TreeWalk.swift \
  ios/test/TreeWalkTests.swift \
  -o "$out/tree_walk_tests"
"$out/tree_walk_tests"
