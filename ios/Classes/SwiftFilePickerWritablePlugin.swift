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

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "design.codeux.file_picker_writable", binaryMessenger: registrar.messenger())
        guard let vc = UIApplication.shared.delegate?.window??.rootViewController else {
            NSLog("PANIC - unable to initialize plugin, no view controller available.")
            fatalError("No viewController available.")
        }
        let instance = SwiftFilePickerWritablePlugin(viewController: vc, channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }

    public init(viewController: UIViewController, channel: FlutterMethodChannel) {
        _viewController = viewController;
        _channel = channel
    }
    
    private func logDebug(_ message: String) {
        print("DEBUG", "FilePickerWritablePlugin:", message)
    }
    private func logError(_ message: String) {
        print("ERROR", "FilePickerWritablePlugin:", message)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "init":
                isInitialized = true
                if let openUrl = _initOpenUrl {
                    _channel.invokeMethod("openFile", arguments: try _prepareUrlForReading(url: openUrl))
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
        if !url.startAccessingSecurityScopedResource() {
            throw FilePickerError.readError(message: "Unable to start accessing security scope resource.")
        }
        let copiedFile = try _copyToTempDirectory(url: url)
        url.stopAccessingSecurityScopedResource()
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
            logDebug("Warning: Unable to access original url \(destination) (destination) \(skipDestinationStartAccess)")
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
        let bookmark = try url.bookmarkData()
        let tempFile = try _copyToTempDirectory(url: url)
        return _fileInfoResult(tempFile: tempFile, originalURL: url, bookmark: bookmark)
    }
    
    private func _fileInfoResult(tempFile: URL, originalURL: URL, bookmark: Data) -> [String: String] {
        let identifier = bookmark.base64EncodedString()
        return [
            "path": tempFile.path,
            "identifier": identifier,
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
    
    private func _handle(url: URL) -> Bool {
        if (!isInitialized) {
            _initOpenUrl = url
            return true
        }
        do {
            _channel.invokeMethod("openFile", arguments: try _prepareUrlForReading(url: url))
        } catch let error {
            logError("Error handling open url for \(url): \(error)")
        }
        return true
    }
}
