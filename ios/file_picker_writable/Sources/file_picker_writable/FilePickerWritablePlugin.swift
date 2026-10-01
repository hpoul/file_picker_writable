#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif
import UniformTypeIdentifiers

enum FilePickerError: Error {
  case readError(message: String)
  case invalidArguments(message: String)
  case noViewController
}

public class FilePickerWritablePlugin: NSObject, FlutterPlugin {
  private var _viewController: UIViewController {
    get throws {
      var vc: UIViewController?
      if #available(iOS 13, *) {
        // connectedScenes is unordered and each scene can have its own key
        // window: take the first key window that has a root controller.
      sceneLoop: for scene in UIApplication.shared.connectedScenes {
          guard let scene = scene as? UIWindowScene else { continue }
          for window in scene.windows {
            guard window.isKeyWindow, let root = window.rootViewController else { continue }
            vc = root
            break sceneLoop
          }
        }
      } else {
        vc = UIApplication.shared.keyWindow?.rootViewController
      }
      guard let vc = vc else {
        throw FilePickerError.noViewController
      }
      return vc
    }
  }

  private let _channel: FlutterMethodChannel
  private var _filePickerResult: FlutterResult?
  private var _filePickerPath: String?
  private var _filePickerDirectory = false
  private let _scopes = ScopeRegistry()
  private var isInitialized = false
  private var _initOpen: [(url: URL, persistable: Bool)] = []
  private var _eventSink: FlutterEventSink?
  private var _eventQueue: [[String: String]] = []
  // Serial: intake copies run off main in caller order (callers sort first).
  private let _intakeQueue = DispatchQueue(label: "design.codeux.file_picker_writable.intake", qos: .userInitiated)

  // Exposed to Objective-C so the (ObjC) plugin registrant can call it
  // when this plugin is integrated via CocoaPods.
  @objc(registerWithRegistrar:)
  public static func register(with registrar: FlutterPluginRegistrar) {
    // Published so the engine calls detachFromEngine(for:) on teardown.
    registrar.publish(FilePickerWritablePlugin(registrar: registrar))
  }

  public init(registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "design.codeux.file_picker_writable", binaryMessenger: registrar.messenger())
    _channel = channel

    super.init()

    registrar.addMethodCallDelegate(self, channel: channel)
    registrar.addApplicationDelegate(self)
    registrar.addSceneDelegate(self)

    let eventChannel = FlutterEventChannel(name: "design.codeux.file_picker_writable/events", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(self)
      
    #if os(macOS)
    NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleEvent(_:with:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    #endif
  }
  
  deinit {
    _scopes.releaseAll()
    #if os(macOS)
    NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    #endif
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    let dropped = _scopes.releaseAll()
    logDebug("Detached from engine: released \(dropped) scope token(s).")
  }
  
  #if os(macOS)
  @objc
  private func handleEvent(_ event: NSAppleEventDescriptor, with replyEvent: NSAppleEventDescriptor) {
      print("Got event. \(event)")
      guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
      guard let url = URL(string: urlString) else { return }
      print(url)
      channel.invokeMethod("handleUri", arguments: url.absoluteString)
  }
  #endif

    
  private func logDebug(_ message: String) {
    print("DEBUG", "FilePickerWritablePlugin:", message)
    sendEvent(event: ["type": "log", "level": "DEBUG", "message": message])
  }

  private func logError(_ message: String) {
    print("ERROR", "FilePickerWritablePlugin:", message)
    sendEvent(event: ["type": "log", "level": "ERROR", "message": message])
  }

  private func logWarning(_ message: String) {
    print("WARNING", "FilePickerWritablePlugin:", message)
    sendEvent(event: ["type": "log", "level": "warning", "message": message])
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "init":
        isInitialized = true
        for pending in _initOpen {
          _handleUrl(url: pending.url, persistable: pending.persistable)
        }
        _initOpen = []
        result(true)
      case "openFilePicker":
        try openFilePicker(result: result)
      case "openFilePickerForCreate":
        guard
          let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'args'")
        }
        try openFilePickerForCreate(path: path, result: result)
      case "readFileWithIdentifier":
        guard
          let args = call.arguments as? [String: Any],
          let identifier = args["identifier"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'identifier'")
        }
        try readFile(identifier: identifier, result: result)
      case "writeFileWithIdentifier":
        guard let args = call.arguments as? [String: Any],
              let identifier = args["identifier"] as? String,
              let path = args["path"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'identifier' and 'path' arguments.")
        }
        try writeFile(identifier: identifier, path: path, result: result)
      case "disposeIdentifier", "disposeAllIdentifiers":
        // iOS doesn't have a concept of disposing identifiers (bookmarks)
        result(nil)
      case "openDirectory":
        do {
          try openDirectory(result: result)
        } catch {
          result(_taxonomyError(error))
        }
      case "acquire":
        guard
          let args = call.arguments as? [String: Any],
          let identifier = args["identifier"] as? String,
          let session = args["session"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'identifier' and 'session'")
        }
        _offMain(result) { [self] in
          try _acquire(identifier: identifier, session: session)
        }
      case "release":
        guard
          let args = call.arguments as? [String: Any],
          let token = args["id"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'id'")
        }
        _offMain(result) { [self] in
          if !_scopes.release(token: token) {
            logDebug("release: unknown scope token \(token), ignored.")
          }
          logDebug("release: \(_scopes.counts) held.")
          return nil
        }
      case "listChildren":
        guard
          let args = call.arguments as? [String: Any],
          let identifier = args["identifier"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'identifier'")
        }
        _offMain(result) { [self] in
          try _listChildren(identifier: identifier)
        }
      case "lookupChild":
        guard
          let args = call.arguments as? [String: Any],
          let identifier = args["identifier"] as? String,
          let name = args["name"] as? String
        else {
          throw FilePickerError.invalidArguments(message: "Expected 'identifier' and 'name'")
        }
        _offMain(result) { [self] in
          try _lookupChild(identifier: identifier, name: name)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as FilePickerError {
      result(FlutterError(code: "FilePickerError", message: "\(error)", details: nil))
    } catch {
      result(FlutterError(code: "UnknownError", message: "\(error)", details: nil))
    }
  }
    
  func readFile(identifier: String, result: @escaping FlutterResult) throws {
    if !identifier.hasPrefix(ChildIdentifier.prefix), Data(base64Encoded: identifier) == nil {
      result(FlutterError(code: "InvalidDataError", message: "Unable to decode bookmark.", details: nil))
      return
    }
    // A plain bookmark or a child identifier; a child reads under its
    // root's scope.
    let resolved = try _resolve(identifier)
    let url = resolved.url
    logDebug("url: \(url) / isStale: \(resolved.isStale)")
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let securityScope = resolved.scopeURL.startAccessingSecurityScopedResource()
      defer {
        if securityScope {
          resolved.scopeURL.stopAccessingSecurityScopedResource()
        }
      }
      if !securityScope {
        logDebug("Warning: startAccessingSecurityScopedResource is false for \(resolved.scopeURL).")
      }
      do {
        try _requireContained(resolved)
        let copiedFile = try _copyToTempDirectory(url: url)
        DispatchQueue.main.async { [self] in
          result(_fileInfoResult(tempFile: copiedFile, originalURL: url, identifier: identifier))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "UnknownError", message: "\(error)", details: nil))
        }
      }
    }
  }
    
  func writeFile(identifier: String, path: String, result: @escaping FlutterResult) throws {
    if !identifier.hasPrefix(ChildIdentifier.prefix), Data(base64Encoded: identifier) == nil {
      throw FilePickerError.invalidArguments(message: "Unable to decode bookmark/identifier.")
    }
    let resolved = try _resolve(identifier)
    let url = resolved.url
    logDebug("url: \(url) / isStale: \(resolved.isStale)")
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      // A child identifier writes under its root's scope; for a plain
      // bookmark this is the file's own scope, started again below.
      let rootScope = resolved.scopeURL.startAccessingSecurityScopedResource()
      defer {
        if rootScope {
          resolved.scopeURL.stopAccessingSecurityScopedResource()
        }
      }
      do {
        try _requireContained(resolved)
        try _writeFile(path: path, destination: url)
        let sourceFile = URL(fileURLWithPath: path)
        DispatchQueue.main.async { [self] in
          result(_fileInfoResult(tempFile: sourceFile, originalURL: url, identifier: identifier))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "UnknownError", message: "\(error)", details: nil))
        }
      }
    }
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
      if destAccess {
        destination.stopAccessingSecurityScopedResource()
      }
      if sourceAccess {
        sourceFile.stopAccessingSecurityScopedResource()
      }
    }
    let data = try Data(contentsOf: sourceFile)
    try data.write(to: destination, options: .atomicWrite)
  }
    
  func openFilePickerForCreate(path: String, result: @escaping FlutterResult) throws {
    if _filePickerResult != nil {
      result(FlutterError(code: "DuplicatedCall", message: "Only one file open call at a time.", details: nil))
      return
    }
    _filePickerResult = result
    _filePickerPath = path
    let ctrl = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
//        let ctrl = UIDocumentPickerViewController(documentTypes: [kUTTypeFolder as String], in: UIDocumentPickerMode.open)
    ctrl.delegate = self
    ctrl.modalPresentationStyle = .currentContext
    try _viewController.present(ctrl, animated: true, completion: nil)
  }

  func openDirectory(result: @escaping FlutterResult) throws {
    if _filePickerResult != nil {
      result(FlutterError(code: "DuplicatedCall", message: "Only one file open call at a time.", details: nil))
      return
    }
    let presenter = try _viewController
    _filePickerResult = result
    _filePickerPath = nil
    _filePickerDirectory = true
    let ctrl = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    ctrl.delegate = self
    ctrl.modalPresentationStyle = .currentContext
    presenter.present(ctrl, animated: true, completion: nil)
  }

  /// Bookmarks a picked folder. No bytes are copied.
  private func _directoryResult(url: URL) throws -> [String: String] {
    guard url.startAccessingSecurityScopedResource() else {
      throw TaxonomyError(kind: ErrorKind.permissionLost, message: "Scope refused for picked folder \(url)")
    }
    defer {
      url.stopAccessingSecurityScopedResource()
    }
    let bookmark = try url.bookmarkData()
    return [
      "identifier": bookmark.base64EncodedString(),
      "persistable": "true",
      "uri": url.absoluteString,
      "fileName": url.lastPathComponent,
    ]
  }

  /// Resolves the bookmark and holds its scope until `release`. A stale
  /// bookmark is repaired: new bookmark bytes, `repaired: true`.
  private func _acquire(identifier: String, session: String) throws -> [String: Any] {
    let resolved = try _resolve(identifier)
    let url = resolved.url
    let token: String
    do {
      // A child's access is its root's scope, so the hold is on the root.
      let acquired = try _scopes.acquire(url: resolved.scopeURL, session: session)
      token = acquired.token
      if acquired.dropped > 0 {
        // Expected once after a hot restart. Anything else means a second
        // isolate called acquire, which breaks the root-isolate rule and
        // just released the other isolate's holds.
        logWarning("New Dart session: released \(acquired.dropped) scope token(s) of the previous one. acquire is a root-isolate verb.")
      }
    } catch is ScopeRegistry.StartRefused {
      throw TaxonomyError(kind: ErrorKind.permissionLost, message: "startAccessingSecurityScopedResource refused for \(url)")
    }
    do {
      try _requireContained(resolved)
      try _requireLive(url)
      let fresh = try resolved.currentIdentifier()
      logDebug("acquire: isStale=\(resolved.isStale), \(_scopes.counts) held.")
      return [
        "id": token,
        "identifier": fresh,
        "repaired": resolved.isStale,
        "path": url.path,
        "displayName": url.lastPathComponent,
      ]
    } catch {
      _scopes.release(token: token)
      throw error
    }
  }

  /// One level of the directory `identifier` names, under a scope held for
  /// this call only. A stale bookmark is repaired as in `_acquire`.
  private func _listChildren(identifier: String) throws -> [String: Any] {
    try _withDirectory(identifier) { resolved in
      let started = Date()
      let children = try FileManager.default.contentsOfDirectory(
        at: resolved.url,
        includingPropertiesForKeys: Self._childKeys,
        // No .skipsHiddenFiles: names starting with `.` are ordinary names.
        options: []
      )
      let listed = Date()
      // The root bookmark goes once per listing, as the shared identifier
      // prefix; each entry carries only its encoded name, and Dart
      // composes prefix + suffix (25.8 MB → ~0.13 MB of identifiers for
      // 10k children).
      // Minted once: a stale root costs a fresh bookmark per call.
      let root = try resolved.currentRoot()
      let identifierPrefix = ChildIdentifier.listingPrefix(
        root: root,
        parentPath: resolved.relativePath
      )
      var suffixBytes = 0
      let entries = try children.map { child in
        let suffix = ChildIdentifier.encode(child.lastPathComponent)
        suffixBytes += suffix.utf8.count
        return try _childEntry(child, identifierKey: "identifierSuffix", identifierValue: suffix)
      }
      logDebug(String(
        format: "listChildren: %d rows, directory read %.0f ms, entries %.0f ms, identifier bytes %d (prefix) + %d (suffixes)",
        children.count,
        listed.timeIntervalSince(started) * 1000,
        Date().timeIntervalSince(listed) * 1000,
        identifierPrefix.utf8.count,
        suffixBytes
      ))
      return [
        "identifier": resolved.identifier(withRoot: root),
        "repaired": resolved.isStale,
        "identifierPrefix": identifierPrefix,
        "entries": entries,
      ]
    }
  }

  /// The child `name` of the directory `identifier`, or nil when absent.
  private func _lookupChild(identifier: String, name: String) throws -> [String: Any]? {
    guard ChildIdentifier.isLeafName(name) else {
      throw TaxonomyError(kind: ErrorKind.invalidName, message: "Not a single leaf name: \"\(name)\"")
    }
    return try _withDirectory(identifier) { resolved in
      let child = resolved.url.appendingPathComponent(name)
      guard (try? child.checkResourceIsReachable()) == true else {
        return nil
      }
      // One entry: the full identifier, nothing to share.
      return try _childEntry(
        child,
        identifierKey: "identifier",
        identifierValue: ChildIdentifier.make(
          root: try resolved.currentRoot(),
          path: ChildIdentifier.join(resolved.relativePath, name)
        )
      )
    }
  }

  private static let _childKeys: [URLResourceKey] = [
    .nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
  ]

  /// An entry map with the identifier under `identifierKey`: the full
  /// `identifier`, or, in a listing, the `identifierSuffix` that Dart
  /// appends to the listing's shared `identifierPrefix`.
  private func _childEntry(_ url: URL, identifierKey: String, identifierValue: String) throws -> [String: Any] {
    let values = try url.resourceValues(forKeys: Set(Self._childKeys))
    let isDirectory = values.isDirectory ?? false
    let size: Any = isDirectory ? NSNull() : (values.fileSize.map { $0 as Any } ?? NSNull())
    let modified: Any = values.contentModificationDate
      .map { Int64($0.timeIntervalSince1970 * 1000) as Any } ?? NSNull()
    return [
      "name": values.name ?? url.lastPathComponent,
      identifierKey: identifierValue,
      "isDirectory": isDirectory,
      "size": size,
      "lastModified": modified,
    ]
  }

  /// Resolves a directory bookmark and holds its scope around `body` only
  /// (single-shot verbs manage scope per call, scope-registry-plan §4).
  private func _withDirectory<T>(_ identifier: String, _ body: (ResolvedIdentifier) throws -> T) throws -> T {
    let resolved = try _resolve(identifier)
    let url = resolved.url
    guard resolved.scopeURL.startAccessingSecurityScopedResource() else {
      throw TaxonomyError(kind: ErrorKind.permissionLost, message: "startAccessingSecurityScopedResource refused for \(resolved.scopeURL)")
    }
    defer {
      resolved.scopeURL.stopAccessingSecurityScopedResource()
    }
    try _requireContained(resolved)
    try _requireLive(url)
    guard (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
      throw TaxonomyError(kind: ErrorKind.notADirectory, message: "\(url.lastPathComponent) is not a directory")
    }
    return try body(resolved)
  }

  /// Resolves a plain bookmark or a child identifier (root bookmark plus
  /// relative path) to what it names and the root whose scope covers it.
  private func _resolve(_ identifier: String) throws -> ResolvedIdentifier {
    let (rootBookmark, path) = try ChildIdentifier.parse(identifier) ?? (identifier, "")
    let (root, isStale) = try _resolveBookmark(rootBookmark)
    let url = path.isEmpty
      ? root
      : ChildIdentifier.components(of: path).reduce(root) { $0.appendingPathComponent($1) }
    return ResolvedIdentifier(
      url: url,
      scopeURL: root,
      isStale: isStale,
      rootBookmark: rootBookmark,
      relativePath: path
    )
  }

  private func _resolveBookmark(_ identifier: String) throws -> (URL, Bool) {
    guard let bookmark = Data(base64Encoded: identifier) else {
      throw FilePickerError.invalidArguments(message: "Unable to decode bookmark.")
    }
    var isStale = false
    do {
      let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
      return (url, isStale)
    } catch {
      // Stale but unresolvable: from the caller's view the grant is gone.
      throw TaxonomyError(kind: ErrorKind.permissionLost, message: "Bookmark no longer resolves: \(error)", underlying: error)
    }
  }

  /// `not-found` when a child identifier's path, followed through
  /// symlinks, leaves its root. Call with the root's scope held.
  private func _requireContained(_ resolved: ResolvedIdentifier) throws {
    guard resolved.isContained else {
      throw TaxonomyError(
        kind: ErrorKind.notFound,
        message: "\(resolved.relativePath) leaves its root",
        details: ["reason": "outside-root"]
      )
    }
  }

  /// `not-found` unless `url` is reachable and outside the Trash. Call with
  /// the scope held.
  private func _requireLive(_ url: URL) throws {
    guard (try? url.checkResourceIsReachable()) == true else {
      throw TaxonomyError(kind: ErrorKind.notFound, message: "Nothing at \(url.path)")
    }
    // A Files delete is a move into the provider's `.Trash`, and the
    // bookmark follows it there. Deleted must read as gone, never as a
    // live folder the app would list and write into. No public resource
    // key reports "in the trash", so this matches a whole path component.
    if url.standardizedFileURL.pathComponents.contains(".Trash") {
      throw TaxonomyError(
        kind: ErrorKind.notFound,
        message: "\(url.lastPathComponent) is in the Trash",
        details: ["reason": "trashed"]
      )
    }
  }

  /// Runs `work` off main and replies on main, with taxonomy errors.
  private func _offMain(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any?) {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let reply: Any?
      do {
        reply = try work()
      } catch {
        reply = _taxonomyError(error)
      }
      DispatchQueue.main.async {
        result(reply)
      }
    }
  }

  /// Taxonomy kinds as the code, native domain and code in details;
  /// anything else stays loud under its own domain.
  private func _taxonomyError(_ error: Error) -> FlutterError {
    if let taxonomy = error as? TaxonomyError {
      var details = taxonomy.details
      if let underlying = taxonomy.underlying as NSError? {
        details["domain"] = underlying.domain
        details["code"] = underlying.code
      }
      return FlutterError(code: taxonomy.kind, message: taxonomy.message, details: details)
    }
    let nsError = error as NSError
    return FlutterError(
      code: nsError.domain,
      message: "\(error)",
      details: ["domain": nsError.domain, "code": nsError.code]
    )
  }

  func openFilePicker(result: @escaping FlutterResult) throws {
    if _filePickerResult != nil {
      result(FlutterError(code: "DuplicatedCall", message: "Only one file open call at a time.", details: nil))
      return
    }
    _filePickerResult = result
    _filePickerPath = nil
    let ctrl = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    //        let ctrl = UIDocumentPickerViewController(documentTypes: [kUTTypeItem as String], in: UIDocumentPickerMode.open)
    ctrl.delegate = self
    ctrl.modalPresentationStyle = .currentContext
    try _viewController.present(ctrl, animated: true, completion: nil)
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
      } catch {
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
      } catch {
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
    let tempFile = try _copyToTempDirectory(url: url)
    // Get bookmark *after* ensuring file has been materialized to local device!
    let bookmark = try url.bookmarkData()
    return _fileInfoResult(tempFile: tempFile, originalURL: url, bookmark: bookmark, persistable: persistable)
  }
    
  private func _fileInfoResult(tempFile: URL, originalURL: URL, bookmark: Data, persistable: Bool = true) -> [String: String] {
    _fileInfoResult(tempFile: tempFile, originalURL: originalURL, identifier: bookmark.base64EncodedString(), persistable: persistable)
  }

  private func _fileInfoResult(tempFile: URL, originalURL: URL, identifier: String, persistable: Bool = true) -> [String: String] {
    [
      "path": tempFile.path,
      "identifier": identifier,
      "persistable": "\(persistable)",
      "uri": originalURL.absoluteString,
      "fileName": originalURL.lastPathComponent,
    ]
  }

  private func _sendFilePickerResult(_ result: Any?) {
    DispatchQueue.main.async { [self] in
      if let _result = _filePickerResult {
        _result(result)
      }
      _filePickerResult = nil
    }
  }
}

extension FilePickerWritablePlugin: UIDocumentPickerDelegate {
  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
    if _filePickerDirectory {
      _filePickerDirectory = false
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        do {
          _sendFilePickerResult(try _directoryResult(url: url))
        } catch {
          _sendFilePickerResult(_taxonomyError(error))
        }
      }
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [self] in
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

          let tempFile = try _copyToTempDirectory(url: targetFile)
          // Get bookmark *after* ensuring file has been created!
          let bookmark = try targetFile.bookmarkData()
          _sendFilePickerResult(_fileInfoResult(tempFile: tempFile, originalURL: targetFile, bookmark: bookmark))
          return
        }
        try _sendFilePickerResult(_prepareUrlForReading(url: url, persistable: true))
      } catch {
        _sendFilePickerResult(FlutterError(code: "ErrorProcessingResult", message: "Error handling result url \(url): \(error)", details: nil))
        return
      }
    }
  }
        
  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    _filePickerDirectory = false
    _sendFilePickerResult(nil)
  }
}

// application delegate methods..
extension FilePickerWritablePlugin: FlutterApplicationLifeCycleDelegate, FlutterSceneLifeCycleDelegate {
  public func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
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

  // NOTE: this plugin deliberately does not implement
  // application(_:continue:restorationHandler:), so universal links are left
  // to Flutter's own deep linking and other plugins (cf. issue #38).

  public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?) -> Bool {
    logDebug("scene will connect with \(connectionOptions?.urlContexts.count ?? 0) URLContexts")
    var handled = false
    if let urlContexts = connectionOptions?.urlContexts {
      // Set order is undefined: sort for deterministic processing order.
      for context in urlContexts.sorted(by: { $0.url.absoluteString < $1.url.absoluteString }) {
        logDebug("attempting to handle \(context.url)")
        handled = _handle(url: context.url, persistable: context.options.openInPlace) || handled
      }
    }
    return handled
  }

  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    var handled = false
    logDebug("openURLContexts for \(URLContexts.count) items")
    // Set order is undefined: sort for deterministic processing order.
    for context in URLContexts.sorted(by: { $0.url.absoluteString < $1.url.absoluteString }) {
      logDebug("attempting to handle \(context.url)")
      handled = _handle(url: context.url, persistable: context.options.openInPlace) || handled
    }
    return handled
  }
    
  private func _handle(url: URL, persistable: Bool) -> Bool {
//        if (!url.isFileURL) {
//            logDebug("url \(url) is not a file url. ignoring it for now.")
//            return false
//        }
    if !isInitialized {
      _initOpen.append((url, persistable))
      return true
    }
    _handleUrl(url: url, persistable: persistable)
    return true
  }
    
  private func _handleUrl(url: URL, persistable: Bool) {
    guard url.isFileURL else {
      _channel.invokeMethod("handleUri", arguments: url.absoluteString)
      return
    }
    _intakeQueue.async { [self] in
      do {
        let arguments = try _prepareUrlForReading(url: url, persistable: persistable)
        DispatchQueue.main.async { [self] in
          _channel.invokeMethod("openFile", arguments: arguments) { _ in
            guard !persistable else {
              // Persistable files don't need cleanup
              return
            }
            if self._isInboxFile(url) {
              do {
                try FileManager.default.removeItem(at: url)
              } catch {
                self.logError("Failed to delete inbox file \(url); error: \(error)")
              }
            } else {
              self.logError("Unexpected non-persistable file \(url)")
            }
          }
        }
      } catch {
        DispatchQueue.main.async { [self] in
          logError("Error handling open url for \(url): \(error)")
          _channel.invokeMethod("handleError", arguments: [
            "message": "Error while handling openUrl for isFileURL=\(url.isFileURL): \(error)",
          ])
        }
      }
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
    // Whole body on main: callers may be on a background queue, and both
    // the sink and the queue are also touched from onListen/onCancel.
    DispatchQueue.main.async { [self] in
      if let _eventSink = _eventSink {
        _eventSink(event)
      } else {
        _eventQueue.append(event)
      }
    }
  }
}
