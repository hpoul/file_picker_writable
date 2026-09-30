// D: package:jni transport — static Kotlin BenchReader.read(fd, pos, len): ByteArray.
import 'dart:developer' show Timeline;
import 'dart:typed_data';

import 'package:jni/jni.dart';

import 'main.dart' show RunStats;

const bool available = true;

/// Hot path: JNI CallStaticObjectMethod -> byte[] -> GetByteArrayRegion into
/// a malloc'ed buffer (getRange) -> Uint8List view over that buffer.
RunStats loop(int fd, int chunk, int total) {
  final cls = JClass.forName('dev/bench/chanbench/BenchReader');
  final read = cls.staticMethodId('read', '(IJI)[B');
  final calls = total ~/ chunk;
  final lat = Int32List(calls);
  var bytes = 0;
  var sink = 0;
  final sw = Stopwatch()..start();
  for (var i = 0; i < calls; i++) {
    final s = Timeline.now;
    final arr = read.call(cls, JByteArray.type, [
      JValueInt(fd),
      i * chunk,
      JValueInt(chunk),
    ]);
    final int8 = arr.getRange(0, chunk);
    final data = Uint8List.view(int8.buffer, 0, chunk);
    arr.release();
    lat[i] = Timeline.now - s;
    bytes += data.length;
    sink ^= data[0] ^ data[chunk - 1];
  }
  sw.stop();
  cls.release();
  if (sink == 12345678) {
    // ignore: avoid_print
    print('never');
  }
  return RunStats(bytes, sw.elapsedMicroseconds, lat);
}
