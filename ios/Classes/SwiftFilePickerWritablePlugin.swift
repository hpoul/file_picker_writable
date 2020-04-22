import Flutter
import UIKit
import MobileCoreServices

enum FilePickerError: Error {
    case readError(message: String)
}

public class SwiftFilePickerWritablePlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {

    private let _viewController: UIViewController
    private var _filePickerResult: FlutterResult?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "design.codeux.file_picker_writable", binaryMessenger: registrar.messenger())
        guard let vc = UIApplication.shared.delegate?.window??.rootViewController else {
            NSLog("PANIC - unable to initialize plugin, no view controller available.")
            fatalError("No viewController available.")
        }
        let instance = SwiftFilePickerWritablePlugin(viewController: vc)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public init(viewController: UIViewController) {
        _viewController = viewController;
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "openFilePicker":
                openFilePicker(result: result)
            case "readFileWithIdentifier":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let identifier = args["identifier"] as? String else {
                        result(FlutterError(code: "InvalidArgument", message: "Expected argument 'identifier' got \(call.arguments ?? "null")", details: nil))
                        return
                }
                try readFile(identifier: identifier, result: result)
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
        print("url: \(url) / isStale: \(isStale)");
        if !url.startAccessingSecurityScopedResource() {
            throw FilePickerError.readError(message: "Unable to start accessing security scope resource.")
        }
        let copiedFile = try _copyToTempDirectory(url: url)
        url.stopAccessingSecurityScopedResource()
        result(_fileInfoResult(tempFile: copiedFile, originalURL: url, bookmark: bookmark))
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
    
    private func _fileInfoResult(tempFile: URL, originalURL: URL, bookmark: Data) -> [String: String] {
        let identifier = bookmark.base64EncodedString()
        return ["path": tempFile.path, "identifier": identifier, "uri": originalURL.absoluteString,]
    }

    private func _sendFilePickerResult(_ result: Any?) {
        if let _result = _filePickerResult {
            _result(result)
        }
        _filePickerResult = nil
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            _sendFilePickerResult(nil)
            return
        }
        do {
            let bookmark = try url.bookmarkData()
            let tempFile = try _copyToTempDirectory(url: url)
            _sendFilePickerResult(_fileInfoResult(tempFile: tempFile, originalURL: url, bookmark: bookmark))
        } catch {
            _sendFilePickerResult(FlutterError(code: "ErrorProcessingResult", message: "Error handling result url \(url): \(error)", details: nil))
            return
        }
        
        url.stopAccessingSecurityScopedResource()
    }
    
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        _sendFilePickerResult(nil)
    }
    
}
