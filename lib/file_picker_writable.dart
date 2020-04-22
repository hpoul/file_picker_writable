import 'dart:async';

import 'package:flutter/services.dart';

class FilePickerWritable {
  static const MethodChannel _channel =
      const MethodChannel('file_picker_writable');

  static Future<String> get platformVersion async {
    final String version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }
}
