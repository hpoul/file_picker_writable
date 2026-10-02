## Unreleased

* **Experimental** (`@experimental`, may change in any minor release until
  it graduates; see `doc/scope-registry-plan.md` §8): directory picking and
  held access scopes, on Android and iOS. macOS and other platforms throw
  `UnsupportedError`.
  * `openDirectory()` picks a folder and returns a `FileInfo` whose
    identifier survives relaunches (a persisted tree grant on Android, a
    bookmark on iOS). Returns null on cancel. Nothing is copied.
  * `acquire(identifier:)` / `release(scope)` hold access across calls.
    Holds are refcounted per file; `release` is idempotent. A stale iOS
    bookmark is repaired: `AcquiredScope.repaired` is true and the app must
    persist `AcquiredScope.identifier` in place of the old one.
    `AcquiredScope.path` is a usable path on iOS and null on Android.
  * Failures are `PlatformException`s whose `code` is the error kind
    (`permission-lost`, `not-found`, `scope-closed`), with the native
    domain and code in `details`. Other failures keep their own code.
  * A folder deleted in the iOS Files app (moved into `.Trash`) reads as
    `not-found`, `reason: trashed`. On Android a folder on an unmounted
    volume of the system storage provider (a pulled USB stick or SD card)
    reads as `permission-lost`, `reason: volume-absent`, not as deleted.
  * `acquire` is a root-isolate verb: an acquire from a second isolate
    releases the first one's holds, and is logged as a warning.
  * On Android, `openDirectory` accepts a read-only tree and reports
    `persistable` accordingly.
  * `listChildren(identifier:)` lists one level of a picked directory in
    one call, metadata only (`ChildEntry`: name, identifier, isDirectory,
    size, lastModified), never copying a file. Child identifiers work
    wherever an identifier is taken, including `listChildren` and
    `acquire`. Dotfiles are listed like any other name.
  * `lookupChild(identifier:, name:)` answers "is there a child called
    this?" without listing: the entry, or null when absent. A gone
    parent is loud. On Android's system storage provider it is one row
    query, not a listing, and it matches like the file system:
    case-insensitively on shared storage and FAT/exFAT, where the
    returned name echoes the requested spelling. Treat a hit as "taken";
    stored names come from `listChildren`. A name that is not a single
    leaf throws `ArgumentError` (natively `invalid-name`).
  * Directory errors add `not-a-directory`; a missing or detached parent
    reuses `not-found` / `permission-lost` (`reason: volume-absent` or
    `trashed`).
  * On iOS, child identifiers are the picked folder's bookmark plus a
    relative path, and access comes from that folder's scope. Persist the
    picked folder's identifier and re-derive children by listing: a child
    identifier follows a rename only through its root, as on Android.
  * Large-file reads without a temp copy (`doc/large-file-reads-plan.md`):
    `openRead(scope:)` opens the file an `AcquiredScope` names and hands
    back a `ReadSession` that owns a native file descriptor (`seekable`,
    `length`). `FdReader` reads it over FFI into one reused buffer and
    returns views valid until the next call (a view kept longer shows
    later bytes, but never freed memory); an empty view is end of file.
    Read where the bytes are consumed: `FdReader.fromSession` on the same
    isolate, or `ReadSession.handoff()` and `FdReader.fromHandoff` in a
    helper isolate. More than 1 MiB per reader on the root isolate fails a
    debug assertion. Close with `FdReader.close()`, or `closeRead` for a
    session never wrapped; a `NativeFinalizer` closes what a collected
    reader or a killed helper left open. A handoff record is consumed
    once: a second reader on it is a `StateError`. Pipes read forward only
    (`seek-unsupported` otherwise).
  * New error kinds: `not-a-file` (`openRead` on a directory),
    `session-closed`, `seek-unsupported`, and `errno-<n>` for anything
    unmapped, n being the platform's own errno number. EIO, ENXIO and
    ENODEV are `permission-lost`, and close the reader at once.
  * The reader is a small C shim built by a native-assets build hook
    (`hook/build.dart`), so building needs a C toolchain (Xcode, or the
    Android NDK that Flutter already uses). Windows builds skip it (reads
    are unsupported there), and web builds never import `dart:ffi`. An app
    built before upgrading may keep a cached hook step and ship without
    the shim (the reader then fails to resolve its native functions): run
    `flutter clean` once.
  * Tree verbs (`doc/tree-writes-plan.md`): `createDirectory(scope:,
    name:)` under a held parent scope, `deleteEntry(identifier:,
    recursive:)` (single-shot; already gone is success; recursion is the
    plugin's own depth-first walk), and `moveEntry(identifier:,
    sourceParent:, newParent:, newName:)`, where a rename is a move with
    the same scope twice. A move returns a fresh entry: use its
    identifier from then on.
  * A taken name is `already-exists` and nothing is changed, never a
    silent auto-rename. A name the provider cleaned (Android stores
    `12:30 ride` as `12_30 ride`, on internal storage too) is
    `invalid-name` with `requested` and `actual` in the details, and the
    new folder is deleted again, or the renamed entry renamed back.
  * New error kinds: `already-exists`, `directory-not-empty`,
    `unsupported-move` (across providers or storage volumes: copy, then
    delete), `move-partial` (Android, a move plus rename whose rollback
    failed; the entry's identifier in the details) and `root-protected`:
    a picked folder's own root (or a single picked file) cannot be
    deleted or moved, only what is inside a picked folder. On Android a
    read-only tree grant is `permission-lost`, `reason: read-only`.
  * Write sessions without temp staging: `openWrite(scope:, name:,
    mimeType:)` creates a new file (fail-if-exists: a taken name is
    `already-exists`; exclusive on iOS) and hands back a `WriteSession`
    that owns a native descriptor. `FdWriter.writeChunk` writes over FFI
    and returns the acknowledged total (progress); `closeWrite` fsyncs
    (default on; `F_FULLFSYNC` on Apple where the volume supports it),
    closes and returns the stored `ChildEntry` (`size-mismatch` when
    something else wrote to the file); `abort` closes and deletes the
    partial, but only while the file under that name is still the
    session's (its identity from the create, plus its size), else
    `not-found` with `reason: replaced` and nothing deleted. Both are
    idempotent. As for reads,
    write where the bytes are produced: `FdWriter.fromSession`, or
    `WriteSession.handoff()` and `FdWriter.fromHandoff` in a helper,
    which then commits or aborts by itself through the plugin's channel.
    After a killed helper, `abortWrite(session, closeFd: false)` marks the
    session aborted and keeps the partial (nothing can prove it is still
    the session's file): delete it by name with `deleteEntry` once no
    writer can be running. A volume that accepts fewer bytes than
    offered is `errno-28` with `synthesized: true`, never a silent short
    write. More than 1 MiB per writer on the root isolate fails a debug
    assertion.
  * Streams: `FdReader.readStream({start, end, chunkLength})` reads a
    range as a stream of views, each valid until the listener is ready
    for the next (after `onData`, or an `await for` body), and closes the
    reader when it ends, fails or is cancelled. `FdWriter.writeStream`
    writes a `Stream<List<int>>` in order and returns the total; it does
    not commit.
* Android: every method-channel call now runs on a shared background
  TaskQueue instead of the main thread, so slow providers no longer block
  frames. The pickers and `init` still hop to the main thread. Launch URLs
  that arrive before `init` now queue in order instead of the last one
  winning, and each is delivered exactly once.
* Android: `init` now completes its method-channel call.

## 2.2.0

* Modernize Android build for current stable Flutter: AGP 9.1.0, Kotlin 2.4.0,
  Gradle 9.3.1, compileSdk 36, minSdk 24 (Android 7.0+); the example app
  targets SDK 36 and uses the declarative Gradle plugins DSL. The Kotlin
  plugin is no longer applied explicitly (the Flutter Gradle plugin applies
  it), so this version requires Flutter >= 3.44.
* iOS: raise minimum deployment target to 15.0; the example adopts the
  Flutter tool's implicit-engine AppDelegate and scene manifest migration;
  replace the deprecated `VALID_ARCHS` simulator restriction with
  `EXCLUDED_ARCHS` (fixes Apple Silicon simulator builds).
* Example: fix analyzer warnings, update stale SDK constraints, fix the
  widget test. Add `FileInfo` JSON unit tests; `flutter analyze` is clean.
* Verified: example runs on Android (API 36 emulator) and iOS (simulator)
  with Flutter 3.47.
* Add Swift Package Manager support for iOS and macOS (CocoaPods still
  supported). Native sources moved to `ios`/`macos/file_picker_writable`;
  the Objective-C shim is removed and the Swift plugin class is now
  `FilePickerWritablePlugin`.
* SPM: exclude the unreferenced PrivacyInfo.xcprivacy from targets to silence
  SwiftPM unhandled-file warnings.
* Add drag-and-drop file intake on Android: drops onto the app window are
  delivered grouped as FileInfo + temp files via registerDropHandler, with
  registerDropHoverHandler for drop-target highlighting. Every dropped file
  is copied before drop permissions are released; items without a file URI
  are skipped, and a drop carrying no file URIs at all is ignored silently.
  A partial group (some copies failed) is delivered together with an error
  event. The example gains a drop-target demo.
* Events that arrive before a handler is registered (file opens, URIs,
  errors, drops) now queue up and are delivered oldest-first instead of
  last-event-wins; handled queued events are disposed on delivery.
* iOS: look up view controllers from the key window's scene on iOS 13+
  (fixes scene-based apps), handle launch-time and runtime URLs through
  the scene delegate, and stop consuming universal links so they reach
  Flutter's own deep linking and other plugins (fixes #38). Bookmark
  reads and document-picker file work now run off the UI thread with
  results delivered on the main thread. Thanks @amake (rollup of #50,
  #53, #48, #43).
* Android: file read/write/dispose no longer require an Activity and fall
  back to the application context, e.g. when invoked from background
  tasks. Thanks @amake (rollup of #52).
* iOS: also run file writes and incoming-file intake (copy + bookmark)
  off the UI thread, with results and errors delivered on the main
  thread. File intake is processed in deterministic order via a serial
  queue.
* Fix `openFileForCreate` corrupting suggested file names longer than 30
  characters (the truncated temp name becomes the created file's name,
  eating extensions).
  [#36](https://github.com/hpoul/file_picker_writable/pull/36) (thanks @manaspratap)

## 2.1.0+1

* Android: require `compileSdk 33`

## 2.1.0

* Android: Upgrade to AGP 8.1.0, remove deprecated plugin registration, upgrade dependencies, etc.
* Require Dart >= 3.0.0
* Analyzer warning cleanup.

## 2.0.3

* iOS: Obtain iOS bookmark only after ensuring the file exists locally
  [#29](https://github.com/hpoul/file_picker_writable/pull/29) (thanks @amake)

## 2.0.2

* Add `disposeAllIdentifiers` thanks @amake [#21](https://github.com/hpoul/file_picker_writable/pull/21)
* Support for Flutter 3, upgrade various dependencies.

## 2.0.1

* Android: Use `wt` file mode for writing on Android 10 or later.
  [#23](https://github.com/hpoul/file_picker_writable/issues/23)

## 2.0.0+1

* Minor code cleanup.

## 2.0.0

* Stable null safety release

## 2.0.0-nullsafety.2

* Nullsafety migration.

## 1.2.0+1

* correctly await callback from `readFile` #6 (thanks [@amake](https://github.com/amake))

## 1.2.0

* Massive cleanup of the dart side API to make ensure proper cleanup of files.
  There should be no breaking changes, but a lot of deprecations.
* iOS: Fixed bug preventing subsequent reads to fail after first write.
* Add error handler which will be notified of errors happening prior to 
  file opens/url handlers.

## 1.1.1+4

* Android: better error handling, which previously might have caused crashes in previous version.
* iOS: Fix handling of `Copy to` use case. (ie. imported files, vs. opened files).
       & cleanup of `Inbox` folder. Again thanks https://github.com/amake

## 1.1.1+2

* Android fix crash when requesting persistable permissions (mostly for ACTION_VIEW intent) #1
  thanks @amake https://github.com/hpoul/file_picker_writable/pull/2

## 1.1.1+1

* iOS: Fix universal links handling.

## 1.1.1

* Implement the Uri handling part of the plugin for macos.

## 1.1.0

* Handle All URLs from intents or custom URL schemas, and propagate it to url handler.

## 1.0.1

* Android: make sure all file operations happen outside the main UI thread.
  * Everything uses coroutines now to correctly dispatch everything to a worker thread.

## 1.0.0+1

* Improved documentation & comments.
* Add `toJsonString` and `fromJsonString` to `FileInfo` for easier serialization.
* Loosen package dependency version constraint for `convert` package.

## 1.0.0

* Only handle file urls on iOS and file, content URLs on android.
* Send native logs to dart to make debugging easier.

## 1.0.0-rc.2

* Add support for handling "file open" intents on on android and iOS (openUrl).
  * (This will handle *all* incoming URLs and intents)

## 1.0.0-rc.1 Feature complete for iOS and Android 🎉️

* Show "Create file" dialog.
* Show "Open file" dialog.
* (re)read files using Uri identifier.
* write new contents to user selected files.

## 0.0.1

* Initial experiments
