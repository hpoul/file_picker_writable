## Unreleased

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
  thread. File intake stays in arrival order via a serial queue.

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
