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
