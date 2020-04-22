import 'dart:async';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';

final _logger = Logger('main');

void main() {
  Logger.root.level = Level.ALL;
  PrintAppender().attachToLogger(Logger.root);
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  FileInfo _fileInfo;

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('File Picker Example'),
        ),
        body: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              const Text('Hello world'),
              RaisedButton(
                child: const Text('Open File Picker'),
                onPressed: _openFilePicker,
              ),
              ...?_fileInfo == null
                  ? null
                  : [
                      FileInfoDisplay(
                        fileInfo: _fileInfo,
                      )
                    ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFilePicker() async {
    final fileInfo = await FilePickerWritable().openFilePicker();
    _logger.fine('Got picker result: $fileInfo');
    setState(() {
      _fileInfo = fileInfo;
    });
  }
}

class FileInfoDisplay extends StatelessWidget {
  const FileInfoDisplay({Key key, this.fileInfo}) : super(key: key);
  final FileInfo fileInfo;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const Text('Selected File:'),
        Text(fileInfo.file.path),
        Text(
          fileInfo.identifier,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
