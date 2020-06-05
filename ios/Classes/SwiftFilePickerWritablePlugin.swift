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
    private var _initOpenUrl: URL? = nil
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
                if let openUrl = _initOpenUrl {
                    _handleUrl(url: openUrl)
                    _initOpenUrl = nil
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
            case "readFileWithIdentifier":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let identifier = args["identifier"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'identifier'")
                }
                try readFile(identifier: identifier, result: result)
            case "writeFileWithIdentifier":
                guard let args = call.arguments as? Dictionary<String, Any>,
                    let identifier = args["identifier"] as? String,
                    let path = args["path"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'identifier' and 'path' arguments.")
                }
                try writeFile(identifier: identifier, path: path, result: result)
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
        let ctrl = UIDocumentPickerViewController(documentTypes: [kUTTypeItem as String], in: UIDocumentPickerMode.open)
        ctrl.delegate = self
        ctrl.modalPresentationStyle = .currentContext
        _viewController.present(ctrl, animated: true, completion: nil)
    }

    private func _copyToTempDirectory(url: URL) throws -> URL {
        let tempDir = NSURL.fileURL(withPath: NSTemporaryDirectory(), isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
        // Copy the file.
        do {
            try FileManager.default.copyItem(at: url, to: tempFile)
            return tempFile
        } catch let error {
            NSLog("Unable to copy file: \(error)")
            throw error
        }
    }
    
    private func _prepareUrlForReading(url: URL) throws -> [String: String] {
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
        return _fileInfoResult(tempFile: tempFile, originalURL: url, bookmark: bookmark)
    }
    
    private func _fileInfoResult(tempFile: URL, originalURL: URL, bookmark: Data) -> [String: String] {
        let identifier = bookmark.base64EncodedString()
        return [
            "path": tempFile.path,
            "identifier": identifier,
            "persistable": "true", // There is no known failure mode given correct configuration
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
                guard url.startAccessingSecurityScopedResource() else {
                    throw FilePickerError.readError(message: "Unnable to acquire acces to \(url)")
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
            _sendFilePickerResult(try _prepareUrlForReading(url: url))
        } catch {
            _sendFilePickerResult(FlutterError(code: "ErrorProcessingResult", message: "Error handling result url \(url): \(error)", details: nil))
            return
        }
        
    }
        
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        _sendFilePickerResult(nil)
    }
    
}

// application delegate methods..
extension SwiftFilePickerWritablePlugin: FlutterApplicationLifeCycleDelegate {
    public func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        logDebug("Opening URL \(url) - options: \(options)")
        return _handle(url: url)
    }
    
    public func application(_ application: UIApplication, handleOpen url: URL) -> Bool {
        logDebug("handleOpen for \(url)")
        return _handle(url: url)
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
        return _handle(url: incomingURL)
    }
    
    private func _handle(url: URL) -> Bool {
//        if (!url.isFileURL) {
//            logDebug("url \(url) is not a file url. ignoring it for now.")
//            return false
//        }
        if (!isInitialized) {
            _initOpenUrl = url
            return true
        }
        _handleUrl(url: url)
        return true
    }
    
    private func _handleUrl(url: URL) {
        do {
            if (url.isFileURL) {
                _channel.invokeMethod("openFile", arguments: try _prepareUrlForReading(url: url))
            } else {
                _channel.invokeMethod("handleUri", arguments: url.absoluteString)
            }
        } catch let error {
            logError("Error handling open url for \(url): \(error)")
        }
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
