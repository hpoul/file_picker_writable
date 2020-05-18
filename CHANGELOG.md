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
