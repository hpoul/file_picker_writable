import Flutter
import UIKit
import MobileCoreServices


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
        switch call.method {
        case "openFilePicker":
            openFilePicker(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
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
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)
        // Copy the file.
        do {
            try FileManager.default.copyItem(at: url, to: tempFile)
            return tempFile
        } catch let error {
            NSLog("Unable to copy file: \(error)")
            throw error
        }
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
            let identifier = bookmark.base64EncodedString()
            let tempFile = try _copyToTempDirectory(url: url)
            _sendFilePickerResult(["path": tempFile.absoluteString, "identifier": identifier])
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
