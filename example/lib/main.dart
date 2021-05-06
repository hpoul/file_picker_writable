import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:simple_json_persistence/simple_json_persistence.dart';

final _logger = Logger('main');

Future<void> main() async {
  Logger.root.level = Level.ALL;
  PrintAppender().attachToLogger(Logger.root);

  runApp(MyApp());
}

class AppDataBloc {
  final store = SimpleJsonPersistence.getForTypeWithDefault(
    (json) => AppData.fromJson(json),
    defaultCreator: () => AppData(files: [], directories: []),
  );
}

class AppData implements HasToJson {
  AppData({required this.files, required this.directories});
  final List<FileInfo> files;
  final List<DirectoryInfo> directories;

  static AppData fromJson(Map<String, dynamic> json) => AppData(
        files: (json['files'] as List<dynamic>? ?? <dynamic>[])
            .where((dynamic element) => element != null)
            .map((dynamic e) => FileInfo.fromJson(e as Map<String, dynamic>))
            .toList(),
        directories: (json['directories'] as List<dynamic>? ?? <dynamic>[])
            .where((dynamic element) => element != null)
            .map((dynamic e) =>
                DirectoryInfo.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'files': files,
        'directories': directories,
      };

  AppData copyWith({
    List<FileInfo>? files,
    List<DirectoryInfo>? directories,
  }) =>
      AppData(
        files: files ?? this.files,
        directories: directories ?? this.directories,
      );
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final AppDataBloc _appDataBloc = AppDataBloc();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MainScreen(
        appDataBloc: _appDataBloc,
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({Key? key, required this.appDataBloc}) : super(key: key);
  final AppDataBloc appDataBloc;

  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  AppDataBloc get _appDataBloc => widget.appDataBloc;

  @override
  void initState() {
    super.initState();
    final state = FilePickerWritable().init();
    state.registerFileOpenHandler((fileInfo, file) async {
      _logger.fine('got file info. we are mounted:$mounted');
      if (!mounted) {
        return false;
      }
      await SimpleAlertDialog.readFileContentsAndShowDialog(
        fileInfo,
        file,
        context,
        bodyTextPrefix: 'Should open file from external app.\n\n'
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
      appBar: AppBar(
        title: const Text('File Picker Example'),
      ),
      body: SingleChildScrollView(
        child: Container(
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
                      child: const Text('Open File Picker'),
                      onPressed: _openFilePicker,
                    ),
                    const SizedBox(width: 32),
                    ElevatedButton(
                      child: const Text('Create New File'),
                      onPressed: _openFilePickerForCreate,
                    ),
                    const SizedBox(width: 32),
                    ElevatedButton(
                      child: const Text('Open Directory Picker'),
                      onPressed: _openDirectoryPicker,
                    ),
                  ],
                ),
                if (snapshot.hasData)
                  for (final fileInfo in snapshot.data!.files)
                    EntityInfoDisplay(
                      entityInfo: fileInfo,
                      appDataBloc: _appDataBloc,
                    ),
                if (snapshot.hasData)
                  for (final directoryInfo in snapshot.data!.directories)
                    EntityInfoDisplay(
                      entityInfo: directoryInfo,
                      appDataBloc: _appDataBloc,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openFilePicker() async {
    final fileInfo =
        await FilePickerWritable().openFile((fileInfo, file) async {
      _logger.fine('Got picker result: $fileInfo');
      final data = await _appDataBloc.store.load();
      await _appDataBloc.store
          .save(data.copyWith(files: data.files + [fileInfo]));
      return fileInfo;
    });
    if (fileInfo == null) {
      _logger.fine('User cancelled.');
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
    await _appDataBloc.store
        .save(data.copyWith(files: data.files + [fileInfo]));
  }

  Future<void> _openDirectoryPicker() async {
    final directoryInfo = await FilePickerWritable().openDirectory();
    if (directoryInfo == null) {
      _logger.fine('User cancelled.');
    } else {
      _logger.fine('Got picker result: $directoryInfo');
      final data = await _appDataBloc.store.load();
      await _appDataBloc.store
          .save(data.copyWith(directories: data.directories + [directoryInfo]));
    }
  }
}

class EntityInfoDisplay extends StatelessWidget {
  const EntityInfoDisplay({
    Key? key,
    required this.entityInfo,
    required this.appDataBloc,
  }) : super(key: key);

  final AppDataBloc appDataBloc;
  final EntityInfo entityInfo;

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
              if (entityInfo is FileInfo) const Text('Selected File:'),
              if (entityInfo is DirectoryInfo)
                const Text('Selected Directory:'),
              Text(
                entityInfo.fileName ?? 'null',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.caption!.apply(fontSizeFactor: 0.75),
              ),
              Text(
                entityInfo.identifier,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'uri:${entityInfo.uri}',
                style: theme.textTheme.bodyText2!
                    .apply(fontSizeFactor: 0.7)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
              Text(
                'fileName: ${entityInfo.fileName}',
                style: theme.textTheme.bodyText2!
                    .apply(fontSizeFactor: 0.7)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
              ButtonBar(
                alignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (entityInfo is FileInfo) ...[
                    TextButton(
                      onPressed: () async {
                        await FilePickerWritable().readFile(
                            identifier: entityInfo.identifier,
                            reader: (fileInfo, file) async {
                              await SimpleAlertDialog
                                  .readFileContentsAndShowDialog(
                                      fileInfo, file, context);
                            });
                      },
                      child: const Text('Read'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await FilePickerWritable().writeFile(
                            identifier: entityInfo.identifier,
                            writer: (file) async {
                              final content =
                                  'New Content written at ${DateTime.now()}.\n\n';
                              await file.writeAsString(content);
                              await SimpleAlertDialog(
                                bodyText: 'Written: $content',
                              ).show(context);
                            });
                      },
                      child: const Text('Overwrite'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final directoryInfo = await FilePickerWritable()
                            .openDirectory(initialDirUri: entityInfo.uri);
                        if (directoryInfo != null) {
                          final data = await appDataBloc.store.load();
                          await appDataBloc.store.save(data.copyWith(
                              directories: data.directories + [directoryInfo]));
                        }
                      },
                      child: const Text('Pick dir'),
                    ),
                  ],
                  IconButton(
                    onPressed: () async {
                      await FilePickerWritable()
                          .disposeIdentifier(entityInfo.identifier);
                      final appData = await appDataBloc.store.load();
                      await appDataBloc.store.save(
                        appData.copyWith(
                          files: appData.files
                              .where((element) => element != entityInfo)
                              .toList(),
                          directories: appData.directories
                              .where((element) => element != entityInfo)
                              .toList(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}

class SimpleAlertDialog extends StatelessWidget {
  const SimpleAlertDialog({Key? key, this.titleText, required this.bodyText})
      : super(key: key);
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
            }),
      ],
    );
  }

  static Future readFileContentsAndShowDialog(
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
    await SimpleAlertDialog(
      titleText: 'Read first ${data.length} bytes of file',
      bodyText: '$bodyTextPrefix $fileContentExample',
    ).show(context);
  }
}
