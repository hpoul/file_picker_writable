import Flutter
import UIKit
import MobileCoreServices

enum FilePickerError: Error {
    case readError(message: String)
    case invalidArguments(message: String)
}

public class SwiftFilePickerWritablePlugin: NSObject, FlutterPlugin {

    private let _viewController: UIViewController
    private let _channel: FlutterMethodChannel
    private var _filePickerResult: FlutterResult?
    private var _filePickerPath: String?
    private var isInitialized = false
    private var _initOpen: (url: URL, persistable: Bool)?
    private var _eventSink: FlutterEventSink? = nil
    private var _eventQueue: [[String: String]] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        guard let vc = UIApplication.shared.delegate?.window??.rootViewController else {
            NSLog("PANIC - unable to initialize plugin, no view controller available.")
            fatalError("No viewController available.")
        }
        _ = SwiftFilePickerWritablePlugin(viewController: vc, registrar: registrar)
    }

    public init(viewController: UIViewController, registrar: FlutterPluginRegistrar) {

        let channel = FlutterMethodChannel(name: "design.codeux.file_picker_writable", binaryMessenger: registrar.messenger())
        _viewController = viewController;
        _channel = channel

        super.init()

        registrar.addMethodCallDelegate(self, channel: channel)
        registrar.addApplicationDelegate(self)

        let eventChannel = FlutterEventChannel(name: "design.codeux.file_picker_writable/events", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(self)
    }
    
    private func logDebug(_ message: String) {
        print("DEBUG", "FilePickerWritablePlugin:", message)
        sendEvent(event: ["type": "log", "level": "DEBUG", "message": message])
    }
    private func logError(_ message: String) {
        print("ERROR", "FilePickerWritablePlugin:", message)
        sendEvent(event: ["type": "log", "level": "ERROR", "message": message])
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "init":
                isInitialized = true
                if let (openUrl, persistable) = _initOpen {
                    _handleUrl(url: openUrl, persistable: persistable)
                    _initOpen = nil
                }
                result(true)
            case "openFilePicker":
                openFilePicker(result: result)
            case "openFilePickerForCreate":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let path = args["path"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'args'")
                }
                openFilePickerForCreate(path: path, result: result)
            case "isDirectoryAccessSupported":
                result(true)
            case "openDirectoryPicker":
                guard let args = call.arguments as? Dictionary<String, Any> else {
                    throw FilePickerError.invalidArguments(message: "Expected 'args'")
                }
                openDirectoryPicker(result: result, initialDirUrl: args["initialDirUri"] as? String)
            case "readFileWithIdentifier":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let identifier = args["identifier"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'identifier'")
                }
                try readFile(identifier: identifier, result: result)
            case "getDirectory":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let rootIdentifier = args["rootIdentifier"] as? String,
                    let fileIdentifier = args["fileIdentifier"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'rootIdentifier' and 'fileIdentifier'")
                }
                try getDirectory(rootIdentifier: rootIdentifier, fileIdentifier: fileIdentifier, result: result)
            case "resolveRelativePath":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let directoryIdentifier = args["directoryIdentifier"] as? String,
                    let relativePath = args["relativePath"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'directoryIdentifier' and 'relativePath'")
                }
                try resolveRelativePath(directoryIdentifier: directoryIdentifier, relativePath: relativePath, result: result)
            case "writeFileWithIdentifier":
                guard let args = call.arguments as? Dictionary<String, Any>,
                    let identifier = args["identifier"] as? String,
                    let path = args["path"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'identifier' and 'path' arguments.")
                }
                try writeFile(identifier: identifier, path: path, result: result)
            case "disposeIdentifier":
                // iOS doesn't have a concept of disposing identifiers (bookmarks)
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch let error as FilePickerError {
            result(FlutterError(code: "FilePickerError", message: "\(error)", details: nil))
        } catch let error {
            result(FlutterError(code: "UnknownError", message: "\(error)", details: nil))
        }
    }
    
    func readFile(identifier: String, result: @escaping FlutterResult) throws {
        guard let bookmark = Data(base64Encoded: identifier) else {
            result(FlutterError(code: "InvalidDataError", message: "Unable to decode bookmark.", details: nil))
            return
        }
        var isStale: Bool = false
        let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        logDebug("url: \(url) / isStale: \(isStale)");
        let securityScope = url.startAccessingSecurityScopedResource()
        defer {
            if securityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if !securityScope {
            logDebug("Warning: startAccessingSecurityScopedResource is false for \(url).")
        }
        let copiedFile = try _copyToTempDirectory(url: url)
        result(_fileInfoResult(tempFile: copiedFile, originalURL: url, bookmark: bookmark))
    }
    
    func getDirectory(rootIdentifier: String, fileIdentifier: String, result: @escaping FlutterResult) throws {
        // In principle these URLs could be opaque like on Android, in which
        // case this analysis would not work. But it seems that URLs even for
        // cloud-based content providers are always file:// (tested with iCloud
        // Drive, Google Drive, Dropbox, FileBrowser)
        guard let rootUrl = restoreUrl(from: rootIdentifier) else {
            result(FlutterError(code: "InvalidDataError", message: "Unable to decode root bookmark.", details: nil))
            return
        }
        guard let fileUrl = restoreUrl(from: fileIdentifier) else {
            result(FlutterError(code: "InvalidDataError", message: "Unable to decode file bookmark.", details: nil))
            return
        }
        guard fileUrl.absoluteString.starts(with: rootUrl.absoluteString) else {
            result(FlutterError(code: "InvalidArguments", message: "The supplied file \(fileUrl) is not a child of \(rootUrl)", details: nil))
            return
        }
        let dirUrl = fileUrl.deletingLastPathComponent()
        result([
            "identifier": try dirUrl.bookmarkData().base64EncodedString(),
            "persistable": "true",
            "uri": dirUrl.absoluteString,
            "fileName": dirUrl.lastPathComponent,
        ])
    }

    func resolveRelativePath(directoryIdentifier: String, relativePath: String, result: @escaping FlutterResult) throws {
        guard let url = restoreUrl(from: directoryIdentifier) else {
            result(FlutterError(code: "InvalidDataError", message: "Unable to restore URL from identifier.", details: nil))
            return
        }
        let childUrl = url.appendingPathComponent(relativePath).standardized
        logDebug("Resolved to \(childUrl)")
        var coordError: NSError? = nil
        var bookmarkError: Error? = nil
        var identifier: String? = nil
        // Coordinate reading the item here because it might be a
        // not-yet-downloaded file, in which case we can't get a bookmark for
        // it--bookmarkData() fails with a "file doesn't exist" error
        NSFileCoordinator().coordinate(readingItemAt: childUrl, error: &coordError) { url in
            do {
                identifier = try childUrl.bookmarkData().base64EncodedString()
            } catch let error {
                bookmarkError = error
            }
        }
        if let error = coordError ?? bookmarkError {
            throw error
        }
        result([
            "identifier": identifier,
            "persistable": "true",
            "uri": childUrl.absoluteString,
            "fileName": childUrl.lastPathComponent,
            "isDirectory": "\(isDirectory(childUrl))",
        ])
    }

    func writeFile(identifier: String, path: String, result: @escaping FlutterResult) throws {
        guard let bookmark = Data(base64Encoded: identifier) else {
            throw FilePickerError.invalidArguments(message: "Unable to decode bookmark/identifier.")
        }
        var isStale: Bool = false
        let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        logDebug("url: \(url) / isStale: \(isStale)");
        try _writeFile(path: path, destination: url)
        let sourceFile = URL(fileURLWithPath: path)
        result(_fileInfoResult(tempFile: sourceFile, originalURL: url, bookmark: bookmark))
    }
    
    // TODO: skipDestinationStartAccess is not doing anything right now. maybe get rid of it.
    private func _writeFile(path: String, destination: URL, skipDestinationStartAccess: Bool = false) throws {
        let sourceFile = URL(fileURLWithPath: path)
        
        let destAccess = destination.startAccessingSecurityScopedResource()
        if !destAccess {
            logDebug("Warning: startAccessingSecurityScopedResource is false for \(destination) (destination); skipDestinationStartAccess=\(skipDestinationStartAccess)")
//            throw FilePickerError.invalidArguments(message: "Unable to access original url \(destination)")
        }
        let sourceAccess = sourceFile.startAccessingSecurityScopedResource()
        if !sourceAccess {
            logDebug("Warning: startAccessingSecurityScopedResource is false for \(sourceFile) (sourceFile)")
//            throw FilePickerError.readError(message: "Unable to access source file \(sourceFile)")
        }
        defer {
            if (destAccess) {
                destination.stopAccessingSecurityScopedResource();
            }
            if (sourceAccess) {
                sourceFile.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: sourceFile)
        try data.write(to: destination, options: .atomicWrite)
    }
    
    func openFilePickerForCreate(path: String, result: @escaping FlutterResult) {
        if (_filePickerResult != nil) {
            result(FlutterError(code: "DuplicatedCall", message: "Only one file open call at a time.", details: nil))
            return
        }
        _filePickerResult = result
        _filePickerPath = path
        let ctrl = UIDocumentPickerViewController(documentTypes: [kUTTypeFolder as String], in: UIDocumentPickerMode.open)
        ctrl.delegate = self
        ctrl.modalPresentationStyle = .currentContext
        _viewController.present(ctrl, animated: true, completion: nil)
    }

    func openFilePicker(result: @escaping FlutterResult) {
        if (_filePickerResult != nil) {
            result(FlutterError(code: "DuplicatedCall", message: "Only one file open call at a time.", details: nil))
            return
        }
        _filePickerResult = result
        _filePickerPath = nil
        let ctrl = UIDocumentPickerViewController(documentTypes: [kUTTypeItem as String], in: UIDocumentPickerMode.open)
        ctrl.delegate = self
        ctrl.modalPresentationStyle = .currentContext
        _viewController.present(ctrl, animated: true, completion: nil)
    }

    func openDirectoryPicker(result: @escaping FlutterResult, initialDirUrl: String?) {
        if (_filePickerResult != nil) {
            result(FlutterError(code: "DuplicatedCall", message: "Only one file open call at a time.", details: nil))
            return
        }
        _filePickerResult = result
        _filePickerPath = nil
        let ctrl = UIDocumentPickerViewController(documentTypes: [kUTTypeFolder as String], in: .open)
        ctrl.delegate = self
        if #available(iOS 13.0, *) {
            if let initialDirUrl = initialDirUrl {
                ctrl.directoryURL = URL(string: initialDirUrl)
            }
        }
        ctrl.modalPresentationStyle = .currentContext
        _viewController.present(ctrl, animated: true, completion: nil)
    }

    private func _copyToTempDirectory(url: URL) throws -> URL {
        let tempDir = NSURL.fileURL(withPath: NSTemporaryDirectory(), isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
        // Copy the file with coordination to ensure e.g. cloud documents are
        // downloaded or updated with the latest content
        var coordError: NSError? = nil
        var copyError: Error? = nil
        NSFileCoordinator().coordinate(readingItemAt: url, error: &coordError) { url in
            do {
                // This is the best, safest place to do the copy
                try FileManager.default.copyItem(at: url, to: tempFile)
            } catch let error {
                copyError = error
            }
        }
        if let coordError = coordError {
            logDebug("Error coordinating access to \(url): \(coordError)")
            copyError = nil
            // Try again without coordination because e.g. if the device is
            // offline and the content provider is cloud-based then the
            // coordination will fail but we might still be able to access a
            // cached copy of the file
            do {
                try FileManager.default.copyItem(at: url, to: tempFile)
            } catch let error {
                copyError = error
            }
        }
        if let copyError = copyError {
            NSLog("Unable to copy file: \(copyError)")
            throw copyError
        }
        return tempFile
    }
    
    private func _prepareUrlForReading(url: URL, persistable: Bool) throws -> [String: String] {
        let securityScope = url.startAccessingSecurityScopedResource()
        defer {
            if securityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if !securityScope {
            logDebug("Warning: startAccessingSecurityScopedResource is false for \(url)")
        }
        let bookmark = try url.bookmarkData()
        let tempFile = try _copyToTempDirectory(url: url)
        return _fileInfoResult(tempFile: tempFile, originalURL: url, bookmark: bookmark, persistable: persistable)
    }
    
    private func _prepareDirUrlForReading(url: URL) throws -> [String:String] {
        let securityScope = url.startAccessingSecurityScopedResource()
        defer {
            if securityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if !securityScope {
            logDebug("Warning: startAccessingSecurityScopedResource is false for \(url)")
        }
        let bookmark = try url.bookmarkData()
        return [
            "identifier": bookmark.base64EncodedString(),
            "persistable": "true",
            "uri": url.absoluteString,
            "fileName": url.lastPathComponent,
        ]
    }

    private func _fileInfoResult(tempFile: URL, originalURL: URL, bookmark: Data, persistable: Bool = true) -> [String: String] {
        let identifier = bookmark.base64EncodedString()
        return [
            "path": tempFile.path,
            "identifier": identifier,
            "persistable": "\(persistable)",
            "uri": originalURL.absoluteString,
            "fileName": originalURL.lastPathComponent,
        ]
    }

    private func _sendFilePickerResult(_ result: Any?) {
        if let _result = _filePickerResult {
            _result(result)
        }
        _filePickerResult = nil
    }
}

extension SwiftFilePickerWritablePlugin : UIDocumentPickerDelegate {

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        do {
            if let path = _filePickerPath {
                _filePickerPath = nil
                guard url.startAccessingSecurityScopedResource() else {
                    throw FilePickerError.readError(message: "Unable to acquire acces to \(url)")
                }
                logDebug("Need to write \(path) to \(url)")
                let sourceFile = URL(fileURLWithPath: path)
                let targetFile = url.appendingPathComponent(sourceFile.lastPathComponent)
//                if !targetFile.startAccessingSecurityScopedResource() {
//                    logDebug("Warning: Unnable to acquire acces to \(targetFile)")
//                }
//                defer {
//                    targetFile.stopAccessingSecurityScopedResource()
//                }
                try _writeFile(path: path, destination: targetFile, skipDestinationStartAccess: true)
                
                let bookmark = try targetFile.bookmarkData()
                let tempFile = try _copyToTempDirectory(url: targetFile)
                _sendFilePickerResult(_fileInfoResult(tempFile: tempFile, originalURL: targetFile, bookmark: bookmark))
                return
            }
            if isDirectory(url) {
                _sendFilePickerResult(try _prepareDirUrlForReading(url: url))
            } else {
                _sendFilePickerResult(try _prepareUrlForReading(url: url, persistable: true))
            }
        } catch {
            _sendFilePickerResult(FlutterError(code: "ErrorProcessingResult", message: "Error handling result url \(url): \(error)", details: nil))
            return
        }
        
    }
        
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        _sendFilePickerResult(nil)
    }
    
    private func isDirectory(_ url: URL) -> Bool {
        if #available(iOS 9.0, *) {
            return url.hasDirectoryPath
        } else if let resVals = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDir = resVals.isDirectory {
            return isDir
        } else {
            return false
        }
    }

    private func restoreUrl(from identifier: String) -> URL? {
        guard let bookmark = Data(base64Encoded: identifier) else {
            return nil
        }
        var isStale: Bool = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        logDebug("url: \(url) / isStale: \(isStale)");
        return url
    }
}

// application delegate methods..
extension SwiftFilePickerWritablePlugin: FlutterApplicationLifeCycleDelegate {
    public func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        logDebug("Opening URL \(url) - options: \(options)")
        let persistable: Bool
        if #available(iOS 9.0, *) {
            // Will be true for files received by "Open in", false for "Copy to"
            persistable = options[.openInPlace] as? Bool ?? false
        } else {
            // Prior to iOS 9.0 files must not be openable in-place?
            persistable = false
        }
        return _handle(url: url, persistable: persistable)
    }
    
    public func application(_ application: UIApplication, handleOpen url: URL) -> Bool {
        logDebug("handleOpen for \(url)")
        // This is an old API predating open-in-place support(?)
        return _handle(url: url, persistable: false)
    }
    
    public func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([Any]) -> Void) -> Bool {
        // (handle universal links)
        // Get URL components from the incoming user activity
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
            let incomingURL = userActivity.webpageURL else {
                logDebug("Unsupported user activity. \(userActivity)")
                return false
        }
        logDebug("continue userActivity webpageURL: \(incomingURL)")
        // TODO: Confirm that persistable should be true here
        return _handle(url: incomingURL, persistable: true)
    }
    
    private func _handle(url: URL, persistable: Bool) -> Bool {
//        if (!url.isFileURL) {
//            logDebug("url \(url) is not a file url. ignoring it for now.")
//            return false
//        }
        if (!isInitialized) {
            _initOpen = (url, persistable)
            return true
        }
        _handleUrl(url: url, persistable: persistable)
        return true
    }
    
    private func _handleUrl(url: URL, persistable: Bool) {
        do {
            if (url.isFileURL) {
                _channel.invokeMethod("openFile", arguments: try _prepareUrlForReading(url: url, persistable: persistable)) { result in
                    guard !persistable else {
                        // Persistable files don't need cleanup
                        return
                    }
                    if self._isInboxFile(url) {
                        do {
                            try FileManager.default.removeItem(at: url)
                        } catch let error {
                            self.logError("Failed to delete inbox file \(url); error: \(error)")
                        }
                    } else {
                        self.logError("Unexpected non-persistable file \(url)")
                    }
                }
            } else {
                _channel.invokeMethod("handleUri", arguments: url.absoluteString)
            }
        } catch let error {
            logError("Error handling open url for \(url): \(error)")
            _channel.invokeMethod("handleError", arguments: [
                "message": "Error while handling openUrl for isFileURL=\(url.isFileURL): \(error)"
            ])
        }
    }

    private func _isInboxFile(_ url: URL) -> Bool {
        let inboxes = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).map {
            $0.resolvingSymlinksInPath().appendingPathComponent("Inbox").absoluteString
        }
        let resolvedUrl = url.resolvingSymlinksInPath().absoluteString
        return inboxes.contains { resolvedUrl.starts(with: $0) }
    }
}

extension SwiftFilePickerWritablePlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        _eventSink = events
        let queue = _eventQueue
        _eventQueue = []
        for item in queue {
            events(item)
        }
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        _eventSink = nil
        return nil
    }
    
    private func sendEvent(event: [String: String]) {
        if let _eventSink = _eventSink {
            _eventSink(event)
        } else {
            _eventQueue.append(event)
        }
    }
    
}
