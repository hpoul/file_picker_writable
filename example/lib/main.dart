// The directory demo exercises the experimental scope API on purpose.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_picker_writable_example/device_checks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:simple_json_persistence/simple_json_persistence.dart';

final _logger = Logger('main');

Future<void> main() async {
  Logger.root.level = Level.ALL;
  PrintAppender().attachToLogger(Logger.root);

  runApp(const MyApp());
}

class AppDataBloc {
  final store = SimpleJsonPersistence.getForTypeWithDefault(
    (json) => AppData.fromJson(json),
    defaultCreator: () => AppData(files: []),
    name: 'AppData',
  );
}

class AppData implements HasToJson {
  AppData({required this.files, this.directories = const []});
  final List<FileInfo> files;

  /// Picked directories, persisted so acquire can be retried after a
  /// relaunch.
  final List<FileInfo> directories;

  static AppData fromJson(Map<String, dynamic> json) => AppData(
    files: _fileInfos(json['files']),
    directories: _fileInfos(json['directories']),
  );

  static List<FileInfo> _fileInfos(Object? json) =>
      ((json as List<dynamic>?) ?? const <dynamic>[])
          .where((dynamic element) => element != null)
          .map((dynamic e) => FileInfo.fromJson(e as Map<String, dynamic>))
          .toList();

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'files': files,
    'directories': directories,
  };

  AppData copyWith({List<FileInfo>? files, List<FileInfo>? directories}) =>
      AppData(
        files: files ?? this.files,
        directories: directories ?? this.directories,
      );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> {
  final AppDataBloc _appDataBloc = AppDataBloc();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: MainScreen(appDataBloc: _appDataBloc));
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, required this.appDataBloc});
  final AppDataBloc appDataBloc;

  @override
  MainScreenState createState() => MainScreenState();
}

class MainScreenState extends State<MainScreen> {
  AppDataBloc get _appDataBloc => widget.appDataBloc;
  late final FilePickerState _pickerState;

  @override
  void initState() {
    super.initState();
    final state = FilePickerWritable().init();
    _pickerState = state;
    if (autoCheck) {
      unawaited(_runDeviceChecks());
    }
    state.registerFileOpenHandler((fileInfo, file) async {
      _logger.fine('got file info. we are mounted:$mounted');
      if (!mounted) {
        return false;
      }
      await SimpleAlertDialog.readFileContentsAndShowDialog(
        fileInfo,
        file,
        context,
        bodyTextPrefix:
            'Should open file from external app.\n\n'
            'fileName: ${fileInfo.fileName}\n'
            'uri: ${fileInfo.uri}\n\n\n',
      );
      return true;
    });
    state.registerUriHandler((uri) {
      SimpleAlertDialog(
        titleText: 'Handling Uri',
        bodyText: 'Got a uri to handle: $uri',
      ).show(context);
      return true;
    });
    state.registerErrorEventHandler((errorEvent) async {
      _logger.fine('Handling error event, mounted: $mounted');
      if (!mounted) {
        return false;
      }
      await SimpleAlertDialog(
        titleText: 'Received error event',
        bodyText: errorEvent.message,
      ).show(context);
      return true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('File Picker Example')),
      body: SingleChildScrollView(
        child: SizedBox(
          width: double.infinity,
          child: StreamBuilder<AppData>(
            stream: _appDataBloc.store.onValueChangedAndLoad,
            builder: (context, snapshot) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Wrap(
                  children: <Widget>[
                    ElevatedButton(
                      onPressed: _openFilePicker,
                      child: const Text('Open File Picker'),
                    ),
                    const SizedBox(width: 32),
                    ElevatedButton(
                      onPressed: _openFilePickerForCreate,
                      child: const Text('Create New File'),
                    ),
                    const SizedBox(width: 32),
                    ElevatedButton(
                      onPressed: FilePickerWritable().disposeAllIdentifiers,
                      child: const Text('Dispose All IDs'),
                    ),
                    const SizedBox(width: 32),
                    ElevatedButton(
                      onPressed: _openDirectory,
                      child: const Text('Open Directory'),
                    ),
                  ],
                ),
                if (snapshot.hasData) ...[
                  for (final directory in snapshot.data!.directories) ...[
                    DirectoryScopeDisplay(
                      // Keyed so removing a card never hands its state
                      // (and its held scopes) to the next folder.
                      key: ValueKey(directory.identifier),
                      directory: directory,
                      appDataBloc: _appDataBloc,
                    ),
                  ],
                ],
                DropTargetDemo(pickerState: _pickerState),
                ...?(!snapshot.hasData
                    ? null
                    : snapshot.data!.files.map(
                        (fileInfo) => FileInfoDisplay(
                          fileInfo: fileInfo,
                          appDataBloc: _appDataBloc,
                        ),
                      )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openFilePicker() async {
    final fileInfo = await FilePickerWritable().openFile((
      fileInfo,
      file,
    ) async {
      _logger.fine('Got picker result: $fileInfo');
      final data = await _appDataBloc.store.load();
      await _appDataBloc.store.save(
        data.copyWith(files: data.files + [fileInfo]),
      );
      return fileInfo;
    });
    if (fileInfo == null) {
      _logger.fine('User cancelled.');
    }
  }

  /// The device run of device_checks.dart, over every picked directory.
  Future<void> _runDeviceChecks() async {
    final data = await _appDataBloc.store.load();
    if (data.directories.isEmpty) {
      _logger.info('DEVICE no directory picked yet; pick one, then relaunch');
    }
    for (final directory in data.directories) {
      await (cleanUp
          ? removeDeviceFixture(directory)
          : runDeviceChecks(directory));
    }
    if (!cleanUp && data.directories.length >= 2) {
      await runCrossPickChecks(data.directories[0], data.directories[1]);
    }
  }

  Future<void> _openDirectory() async {
    try {
      final directory = await FilePickerWritable().openDirectory();
      if (directory == null) {
        _logger.fine('User cancelled.');
        return;
      }
      _logger.fine('Got directory: $directory');
      final data = await _appDataBloc.store.load();
      // Re-picking a folder renews its grant; it keeps its one card.
      if (data.directories.any((d) => d.identifier == directory.identifier)) {
        return;
      }
      await _appDataBloc.store.save(
        data.copyWith(directories: data.directories + [directory]),
      );
    } on Exception catch (e) {
      if (!mounted) {
        return;
      }
      await SimpleAlertDialog.showErrorDialog(e, context);
    }
  }

  Future<void> _openFilePickerForCreate() async {
    final rand = Random().nextInt(10000000);
    final fileInfo = await FilePickerWritable().openFileForCreate(
      fileName: 'newfile.$rand.codeux',
      writer: (file) async {
        final content = 'File created at ${DateTime.now()}\n\n';
        await file.writeAsString(content);
      },
    );
    if (fileInfo == null) {
      _logger.info('User canceled.');
      return;
    }
    final data = await _appDataBloc.store.load();
    await _appDataBloc.store.save(
      data.copyWith(files: data.files + [fileInfo]),
    );
  }
}

class FileInfoDisplay extends StatelessWidget {
  const FileInfoDisplay({
    super.key,
    required this.fileInfo,
    required this.appDataBloc,
  });

  final AppDataBloc appDataBloc;
  final FileInfo fileInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: <Widget>[
              const Text('Selected File:'),
              Text(
                fileInfo.fileName ?? 'null',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.apply(fontSizeFactor: 0.75),
              ),
              Text(
                fileInfo.identifier,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'uri:${fileInfo.uri}',
                style: theme.textTheme.bodyMedium
                    ?.apply(fontSizeFactor: 0.7)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
              Text(
                'fileName: ${fileInfo.fileName}',
                style: theme.textTheme.bodyMedium
                    ?.apply(fontSizeFactor: 0.7)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () async {
                      try {
                        await FilePickerWritable().readFile(
                          identifier: fileInfo.identifier,
                          reader: (fileInfo, file) async {
                            await SimpleAlertDialog.readFileContentsAndShowDialog(
                              fileInfo,
                              file,
                              context,
                            );
                          },
                        );
                      } on Exception catch (e) {
                        if (!context.mounted) {
                          return;
                        }
                        await SimpleAlertDialog.showErrorDialog(e, context);
                      }
                    },
                    child: const Text('Read'),
                  ),
                  TextButton(
                    onPressed: () async {
                      await FilePickerWritable().writeFile(
                        identifier: fileInfo.identifier,
                        writer: (file) async {
                          final content =
                              'New Content written at ${DateTime.now()}.\n\n';
                          await file.writeAsString(content);
                          if (!context.mounted) {
                            return;
                          }
                          await SimpleAlertDialog(
                            bodyText: 'Written: $content',
                          ).show(context);
                        },
                      );
                    },
                    child: const Text('Overwrite'),
                  ),
                  IconButton(
                    onPressed: () async {
                      try {
                        await FilePickerWritable().disposeIdentifier(
                          fileInfo.identifier,
                        );
                      } on Exception catch (e) {
                        if (!context.mounted) {
                          return;
                        }
                        await SimpleAlertDialog.showErrorDialog(e, context);
                      }
                      final appData = await appDataBloc.store.load();
                      await appDataBloc.store.save(
                        appData.copyWith(
                          files: appData.files
                              .where((element) => element != fileInfo)
                              .toList(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A picked directory with acquire/release controls: the device checks of
/// doc/scope-registry-plan.md §7 (relaunch, stale repair, refcount).
class DirectoryScopeDisplay extends StatefulWidget {
  const DirectoryScopeDisplay({
    super.key,
    required this.directory,
    required this.appDataBloc,
  });

  final FileInfo directory;
  final AppDataBloc appDataBloc;

  @override
  DirectoryScopeDisplayState createState() => DirectoryScopeDisplayState();
}

class DirectoryScopeDisplayState extends State<DirectoryScopeDisplay> {
  final List<AcquiredScope> _held = [];
  String _status = 'not acquired';

  @override
  void dispose() {
    for (final scope in _held) {
      unawaited(FilePickerWritable().release(scope));
    }
    _lookupName.dispose();
    super.dispose();
  }

  Future<void> _acquire() async {
    try {
      final scope = await FilePickerWritable().acquire(
        identifier: widget.directory.identifier,
      );
      _logger.fine('Acquired: $scope');
      if (scope.repaired) {
        // The app MUST persist the fresh identifier in place of the old.
        final data = await widget.appDataBloc.store.load();
        await widget.appDataBloc.store.save(
          data.copyWith(
            directories: [
              for (final d in data.directories) ...[
                d.identifier == widget.directory.identifier
                    ? FileInfo(
                        identifier: scope.identifier,
                        persistable: d.persistable,
                        uri: d.uri,
                        fileName: scope.displayName,
                      )
                    : d,
              ],
            ],
          ),
        );
      }
      if (!mounted) {
        await FilePickerWritable().release(scope);
        return;
      }
      setState(() {
        _held.add(scope);
        _status =
            'held ${_held.length}: ${scope.displayName}, '
            'repaired: ${scope.repaired}, path: ${scope.path}';
      });
    } on PlatformException catch (e) {
      _logger.warning('acquire failed', e);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'error ${e.code}: ${e.message}';
      });
    }
  }

  Future<void> _release() async {
    if (_held.isEmpty) {
      return;
    }
    final scope = _held.removeLast();
    await FilePickerWritable().release(scope);
    if (!mounted) {
      return;
    }
    setState(() {
      _status = _held.isEmpty ? 'released' : 'held ${_held.length}';
    });
  }

  /// The listing on screen, and the identifiers descended through.
  DirectoryListing? _listing;
  final List<String> _listPath = [];
  final _lookupName = TextEditingController(text: '.howitwent');

  Future<void> _list(String identifier) async {
    try {
      final listing = await FilePickerWritable().listChildren(
        identifier: identifier,
      );
      _logger.fine(
        'Listed ${listing.entries.length} (repaired: ${listing.repaired}): '
        '${listing.entries}',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _listing = listing;
        _listPath.add(identifier);
      });
    } on PlatformException catch (e) {
      _logger.warning('listChildren failed', e);
      if (mounted) {
        setState(() {
          _status = 'error ${e.code}: ${e.message}';
        });
      }
    }
  }

  Future<void> _lookup() async {
    final name = _lookupName.text;
    final parent = _listPath.isEmpty
        ? widget.directory.identifier
        : _listPath.last;
    try {
      final child = await FilePickerWritable().lookupChild(
        identifier: parent,
        name: name,
      );
      _logger.fine('Lookup "$name": $child');
      if (mounted) {
        setState(() {
          _status = 'lookup "$name": ${child ?? 'absent'}';
        });
      }
    } on Exception catch (e) {
      _logger.warning('lookupChild failed', e);
      if (mounted) {
        setState(() {
          _status = 'lookup "$name" failed: $e';
        });
      }
    }
  }

  /// The traversal device checks of doc/tree-traversal-plan.md §7 in one
  /// tap, logged line by line: lookups (hit, dotfile, miss, case, folder),
  /// a timed listing, one level down, and a file listed as a directory.
  Future<void> _runChecks() async {
    final plugin = FilePickerWritable();
    final root = widget.directory.identifier;
    Future<void> step(String label, Future<Object?> Function() run) async {
      try {
        _logger.info('CHECK $label: ${await run()}');
      } on Exception catch (e) {
        _logger.info('CHECK $label: threw $e');
      }
    }

    for (final name in [
      '.howitwent',
      'trip.json',
      'missing.txt',
      'TRIP.JSON',
      'media',
    ]) {
      await step(
        'lookup "$name"',
        () => plugin.lookupChild(identifier: root, name: name),
      );
    }
    final stopwatch = Stopwatch()..start();
    final listing = await plugin.listChildren(identifier: root);
    _logger.info(
      'CHECK list root: ${listing.entries.length} entries in '
      '${stopwatch.elapsedMilliseconds} ms: ${listing.entries.take(5)}',
    );
    for (final child in listing.entries.take(5)) {
      await step(
        'list child "${child.name}"',
        () => plugin
            .listChildren(identifier: child.identifier)
            .then((l) => l.entries),
      );
      // A child identifier stands on its own: acquire it directly.
      await step('acquire child "${child.name}"', () async {
        final scope = await plugin.acquire(identifier: child.identifier);
        await plugin.release(scope);
        return scope;
      });
      if (child.isDirectory) {
        // Two levels down: a grandchild's identifier works too.
        await step('grandchildren of "${child.name}"', () async {
          final grandchildren = await plugin.listChildren(
            identifier: child.identifier,
          );
          Future<Object> childCount(ChildEntry entry) async {
            try {
              return (await plugin.listChildren(
                identifier: entry.identifier,
              )).entries.length;
            } on PlatformException catch (e) {
              return e.code;
            }
          }

          return [
            for (final grandchild in grandchildren.entries) ...[
              '${grandchild.name}: ${await childCount(grandchild)}',
            ],
          ];
        });
      } else {
        // The one-shot copy verb takes a child identifier as well.
        await step('readFile child "${child.name}"', () {
          return plugin.readFile(
            identifier: child.identifier,
            reader: (info, file) async => '${file.lengthSync()} bytes',
          );
        });
      }
    }
    if (mounted) {
      setState(() {
        _status = 'checks done, see log';
      });
    }
  }

  Future<void> _remove() async {
    final data = await widget.appDataBloc.store.load();
    await widget.appDataBloc.store.save(
      data.copyWith(
        directories: data.directories
            .where((d) => d.identifier != widget.directory.identifier)
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: <Widget>[
              Text('Directory: ${widget.directory.fileName}'),
              Text(
                widget.directory.identifier,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              Text(
                'scope: $_status',
                key: const ValueKey('scope-status'),
                style: theme.textTheme.bodySmall,
              ),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(onPressed: _acquire, child: const Text('Acquire')),
                  TextButton(onPressed: _release, child: const Text('Release')),
                  TextButton(
                    onPressed: () {
                      _listPath.clear();
                      _list(widget.directory.identifier);
                    },
                    child: const Text('List'),
                  ),
                  TextButton(
                    onPressed: _runChecks,
                    child: const Text('Run checks'),
                  ),
                  IconButton(
                    onPressed: _remove,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _lookupName,
                      decoration: const InputDecoration(
                        labelText: 'Look up child by name',
                      ),
                    ),
                  ),
                  TextButton(onPressed: _lookup, child: const Text('Lookup')),
                ],
              ),
              if (_listing != null) ...[
                for (final child in _listing!.entries) ...[
                  ListTile(
                    dense: true,
                    leading: Icon(
                      child.isDirectory
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                    ),
                    title: Text(child.name),
                    subtitle: Text(
                      'size: ${child.size}, modified: ${child.lastModified}',
                    ),
                    // Files too: listing one shows the loud
                    // not-a-directory in the status line.
                    onTap: () => _list(child.identifier),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SimpleAlertDialog extends StatelessWidget {
  const SimpleAlertDialog({super.key, this.titleText, required this.bodyText});
  final String? titleText;
  final String bodyText;

  Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (context) => this);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: titleText == null ? null : Text(titleText!),
      content: Text(bodyText),
      actions: <Widget>[
        TextButton(
          child: const Text('Ok'),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  static Future<void> readFileContentsAndShowDialog(
    FileInfo fi,
    File file,
    BuildContext context, {
    String bodyTextPrefix = '',
  }) async {
    final dataList = await file.openRead(0, 64).toList();
    final data = dataList.expand((element) => element).toList();
    final hexString = hex.encode(data);
    final utf8String = utf8.decode(data, allowMalformed: true);
    final fileContentExample = 'hexString: $hexString\n\nutf8: $utf8String';

    if (!context.mounted) {
      return;
    }
    await SimpleAlertDialog(
      titleText: 'Read first ${data.length} bytes of file',
      bodyText: '$bodyTextPrefix $fileContentExample',
    ).show(context);
  }

  static Future<void> showErrorDialog(Exception e, BuildContext context) async {
    await SimpleAlertDialog(
      titleText: 'Error',
      bodyText: e.toString(),
    ).show(context);
  }
}

class DropTargetDemo extends StatefulWidget {
  const DropTargetDemo({super.key, required this.pickerState});
  final FilePickerState pickerState;

  @override
  DropTargetDemoState createState() => DropTargetDemoState();
}

class DropTargetDemoState extends State<DropTargetDemo> {
  bool _hovering = false;
  final List<String> _drops = [];

  @override
  void initState() {
    super.initState();
    widget.pickerState.registerDropHandler(_onDrop);
    widget.pickerState.registerDropHoverHandler(_onHover);
  }

  @override
  void dispose() {
    widget.pickerState.removeDropHandler(_onDrop);
    widget.pickerState.removeDropHoverHandler(_onHover);
    super.dispose();
  }

  Future<bool> _onDrop(DropEvent drop) async {
    final summaries = <String>[];
    for (final item in drop.items) {
      final bytes = await item.file.readAsBytes();
      summaries.add(
        '${item.fileInfo.fileName ?? 'unnamed'} (${bytes.length} bytes)',
      );
      _logger.fine('Drop: ${item.fileInfo}');
    }
    if (!mounted) {
      return true;
    }
    setState(() {
      _drops.addAll(summaries);
    });
    return true;
  }

  void _onHover(bool entered) {
    _logger.fine('Drop hover: $entered');
    if (_hovering == entered) return;
    setState(() {
      _hovering = entered;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: <Widget>[
              const Text('Drop target (Android)'),
              const SizedBox(height: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: double.infinity,
                padding: const EdgeInsets.all(24.0),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _hovering
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                    width: _hovering ? 3.0 : 1.0,
                  ),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: Text(
                  _hovering
                      ? 'Release to drop!'
                      : 'Drop files anywhere in the window.',
                  textAlign: TextAlign.center,
                ),
              ),
              ..._drops.map(
                (summary) => Text(summary, style: theme.textTheme.bodySmall),
              ),
              if (_drops.isEmpty) ...[
                Text('No drops yet.', style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
