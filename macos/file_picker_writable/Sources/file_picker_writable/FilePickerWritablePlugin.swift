import Cocoa
import FlutterMacOS

public class FilePickerWritablePlugin: NSObject, FlutterPlugin {
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        _ = FilePickerWritablePlugin(with: registrar)
    }
    
    private let channel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var _eventSink: FlutterEventSink? = nil
    private var _eventQueue: [[String: String]] = []

    init(with registrar: FlutterPluginRegistrar) {
        channel = FlutterMethodChannel(name: "design.codeux.file_picker_writable", binaryMessenger: registrar.messenger)
        eventChannel = FlutterEventChannel(name: "design.codeux.file_picker_writable/events", binaryMessenger: registrar.messenger)
        super.init()
        registrar.addMethodCallDelegate(self, channel: channel)
        eventChannel.setStreamHandler(self)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleEvent(_:with:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    
    deinit {
        NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    
    @objc
    private func handleEvent(_ event: NSAppleEventDescriptor, with replyEvent: NSAppleEventDescriptor) {
        print("Got event. \(event)")
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        guard let url = URL(string: urlString) else { return }
        print(url)
        channel.invokeMethod("handleUri", arguments: url.absoluteString)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "init":
            result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}


extension FilePickerWritablePlugin: FlutterStreamHandler {
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

