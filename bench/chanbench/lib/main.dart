// Throwaway transport benchmark: native -> Dart bulk reads on Android.
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show FramePhase;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'jni_transport.dart' as jni;

const host = String.fromEnvironment('HOST', defaultValue: '?');
const avd = String.fromEnvironment('AVD', defaultValue: '?');
const reps = int.fromEnvironment('REPS', defaultValue: 3);
const onlyTransport = String.fromEnvironment('ONLY', defaultValue: '');
const gib = 1 << 30;
const chunkSizes = [64 << 10, 256 << 10, 1 << 20];
const mode = kProfileMode
    ? 'profile'
    : kReleaseMode
    ? 'release'
    : 'debug';

// C: libc pread64 via dart:ffi, leaf call.
@Native<IntPtr Function(Int, Pointer<Void>, IntPtr, Int64)>(
  symbol: 'pread64',
  isLeaf: true,
)
external int _pread64(int fd, Pointer<Void> buf, int n, int off);

const mainChan = MethodChannel('bench/main');
const bgChan = MethodChannel('bench/bg');

String meta = '';
final List<FrameTiming> _timings = [];

class RunStats {
  RunStats(this.bytes, this.micros, this.lat);
  final int bytes;
  final int micros;
  final Int32List lat;
}

void main() {
  runApp(const BenchApp());
}

class BenchApp extends StatefulWidget {
  const BenchApp({super.key});
  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp> {
  String status = 'starting';

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      runSuite((s) => setState(() => status = s));
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(status),
            ],
          ),
        ),
      ),
    );
  }
}

void bench(String line) => print('BENCH $line');

Future<void> runSuite(void Function(String) setStatus) async {
  setStatus('preparing file');
  final sw = Stopwatch()..start();
  final info = (await mainChan.invokeMethod<Map>('prepare'))!;
  bench('prepare_ms=${sw.elapsedMilliseconds} $info');
  meta =
      'flutter=3.47.0 mode=$mode avd=$avd sdk=${info['sdk']} '
      'abi=${info['abi']} host="$host"';
  bench('META $meta');
  final fd = (await mainChan.invokeMethod<int>('openFd'))!;
  bench('fd=$fd');

  // Clock sanity: Timeline.now vs latest frame timing.
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  if (_timings.isNotEmpty) {
    final last = _timings.last.timestampInMicroseconds(FramePhase.rasterFinish);
    bench('clock_delta_us=${Timeline.now - last} (should be small, <2e6)');
  } else {
    bench('WARN no frame timings received yet');
  }

  final results = <String, List<Map<String, num>>>{};

  // Idle baseline for the spinner on this emulator.
  {
    setStatus('idle baseline');
    final t0 = Timeline.now;
    await Future<void>.delayed(const Duration(seconds: 5));
    final t1 = Timeline.now;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final f = frameStats(t0, t1);
    bench('IDLE 5s ${f.line} $meta');
  }

  // Bare round trip, 0-byte payload.
  for (final (name, chan) in [('main', mainChan), ('bg', bgChan)]) {
    for (var r = 0; r < reps; r++) {
      setStatus('ping $name $r');
      final lat = Int32List(1000);
      final t0 = Timeline.now;
      for (var i = 0; i < 1000; i++) {
        final s = Timeline.now;
        await chan.invokeMethod<void>('ping');
        lat[i] = Timeline.now - s;
      }
      final t1 = Timeline.now;
      final p = pct(lat);
      bench(
        'PING chan=$name rep=$r calls=1000 total_ms=${(t1 - t0) / 1000} '
        'mean_us=${p.mean} p50_us=${p.p50} p99_us=${p.p99} max_us=${p.max} $meta',
      );
      results.putIfAbsent('PING/$name', () => []).add({
        'mean_us': p.mean,
        'p50_us': p.p50,
        'p99_us': p.p99,
        'max_us': p.max,
      });
    }
  }

  final transports = <String, Future<RunStats> Function(int chunk)>{
    'A1-mc-io-dispatch': (c) => channelLoop(mainChan, 'readIO', c),
    'A2-mc-platform-sync': (c) => channelLoop(mainChan, 'readSync', c),
    'B-mc-taskqueue': (c) => channelLoop(bgChan, 'read', c),
    'C1-ffi-iso-view': (c) => Isolate.run(() => ffiLoop(fd, c, copy: false)),
    'C2-ffi-iso-copy': (c) => Isolate.run(() => ffiLoop(fd, c, copy: true)),
    'C3-ffi-iso-send': (c) => ffiSendLoop(fd, c),
    'C4-ffi-ui-copy': (c) => ffiUiLoop(fd, c),
    if (jni.available) 'D-jni': (c) => jniLoop(fd, c),
  };

  // Warm the page cache once so rep 0 of the first transport is not the only
  // cold run (the emulator has no root, so drop_caches is unavailable anyway).
  setStatus('warm-up read');
  final warm = await Isolate.run(() => ffiLoop(fd, 1 << 20, copy: false));
  bench(
    'WARMUP MiB_s=${(warm.bytes / (1 << 20) / (warm.micros / 1e6)).toStringAsFixed(1)} $meta',
  );

  for (var r = 0; r < reps; r++) {
    for (final entry in transports.entries) {
      if (onlyTransport.isNotEmpty && !entry.key.startsWith(onlyTransport)) {
        continue;
      }
      for (final chunk in chunkSizes) {
        setStatus('${entry.key} ${chunk >> 10}K rep $r');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final t0 = Timeline.now;
        RunStats st;
        try {
          st = await entry.value(chunk);
        } catch (e, s) {
          bench('ERROR ${entry.key} chunk=$chunk $e\n$s');
          continue;
        }
        final t1 = Timeline.now;
        // Let the engine flush its timings batch (<= 1 s).
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final f = frameStats(t0, t1);
        final p = pct(st.lat);
        final mibs = st.bytes / (1 << 20) / (st.micros / 1e6);
        bench(
          'RUN transport=${entry.key} chunk_kib=${chunk >> 10} rep=$r '
          'bytes=${st.bytes} calls=${st.lat.length} time_ms=${st.micros / 1000} '
          'MiB_s=${mibs.toStringAsFixed(1)} '
          'mean_us=${p.mean} p50_us=${p.p50} p99_us=${p.p99} max_us=${p.max} '
          '${f.line} $meta',
        );
        results.putIfAbsent('${entry.key}/${chunk >> 10}', () => []).add({
          'MiB_s': mibs,
          'mean_us': p.mean,
          'p50_us': p.p50,
          'p99_us': p.p99,
          'max_us': p.max,
          ...f.map,
        });
      }
    }
  }

  for (final e in results.entries) {
    final keys = e.value.first.keys;
    final parts = <String>[];
    for (final k in keys) {
      final vals = e.value.map((m) => m[k]!.toDouble()).toList()..sort();
      final med = vals[vals.length ~/ 2];
      parts.add(
        '$k=${med is double && med != med.roundToDouble() ? med.toStringAsFixed(1) : med.round()}',
      );
    }
    final worst = e.value
        .map((m) => (m['worst_ms'] ?? 0).toDouble())
        .fold(0.0, (a, b) => a > b ? a : b);
    bench(
      'MEDIAN ${e.key} n=${e.value.length} ${parts.join(' ')} worst_any_ms=${worst.toStringAsFixed(1)} $meta',
    );
  }
  bench('DONE');
  await Future<void>.delayed(const Duration(seconds: 4));
  exit(0);
}

// ---------------------------------------------------------------- transports

/// A/B hot path: one MethodChannel call per chunk, bytes arrive as Uint8List.
Future<RunStats> channelLoop(
  MethodChannel chan,
  String method,
  int chunk,
) async {
  final calls = gib ~/ chunk;
  final lat = Int32List(calls);
  var bytes = 0;
  var sink = 0;
  final sw = Stopwatch()..start();
  for (var i = 0; i < calls; i++) {
    final s = Timeline.now;
    final data = await chan.invokeMethod<Uint8List>(method, {
      'pos': i * chunk,
      'len': chunk,
    });
    lat[i] = Timeline.now - s;
    bytes += data!.length;
    sink ^= data[0] ^ data[data.length - 1];
  }
  sw.stop();
  if (sink == 12345678) print('never');
  return RunStats(bytes, sw.elapsedMicroseconds, lat);
}

/// C hot path: pread64 into a malloc'ed buffer; optionally copy to a Uint8List.
RunStats ffiLoop(int fd, int chunk, {required bool copy}) {
  final calls = gib ~/ chunk;
  final lat = Int32List(calls);
  final buf = malloc<Uint8>(chunk);
  var bytes = 0;
  var sink = 0;
  final sw = Stopwatch()..start();
  for (var i = 0; i < calls; i++) {
    final s = Timeline.now;
    final n = _pread64(fd, buf.cast(), chunk, i * chunk);
    if (n != chunk) throw StateError('pread returned $n at ${i * chunk}');
    final view = buf.asTypedList(n);
    if (copy) {
      final out = Uint8List(n)..setRange(0, n, view);
      sink ^= out[0] ^ out[n - 1];
    } else {
      sink ^= view[0] ^ view[n - 1];
    }
    lat[i] = Timeline.now - s;
    bytes += n;
  }
  sw.stop();
  malloc.free(buf);
  if (sink == 12345678) print('never');
  return RunStats(bytes, sw.elapsedMicroseconds, lat);
}

/// C4: same as ffiLoop(copy: true) but on the UI isolate, yielding to the
/// event loop after every chunk so frames can get in.
Future<RunStats> ffiUiLoop(int fd, int chunk) async {
  final calls = gib ~/ chunk;
  final lat = Int32List(calls);
  final buf = malloc<Uint8>(chunk);
  var bytes = 0;
  var sink = 0;
  final sw = Stopwatch()..start();
  for (var i = 0; i < calls; i++) {
    final s = Timeline.now;
    final n = _pread64(fd, buf.cast(), chunk, i * chunk);
    if (n != chunk) throw StateError('pread returned $n');
    final out = Uint8List(n)..setRange(0, n, buf.asTypedList(n));
    sink ^= out[0] ^ out[n - 1];
    lat[i] = Timeline.now - s;
    bytes += n;
    await Future<void>.delayed(Duration.zero);
  }
  sw.stop();
  malloc.free(buf);
  if (sink == 12345678) print('never');
  return RunStats(bytes, sw.elapsedMicroseconds, lat);
}

/// C3: helper isolate preads + copies to a Uint8List and sends each chunk to
/// the UI isolate over a SendPort; the UI isolate acks each chunk
/// (backpressure). Latency = UI-side round trip per chunk.
Future<RunStats> ffiSendLoop(int fd, int chunk) async {
  final calls = gib ~/ chunk;
  final lat = Int32List(calls);
  final rx = ReceivePort();
  final ackRx = ReceivePort();
  final iso = await Isolate.spawn(_sender, (
    rx.sendPort,
    ackRx.sendPort,
    fd,
    chunk,
    calls,
  ));
  final ackPort = (await ackRx.first) as SendPort;
  var bytes = 0;
  var sink = 0;
  final it = StreamIterator(rx);
  final sw = Stopwatch()..start();
  for (var i = 0; i < calls; i++) {
    final s = Timeline.now;
    ackPort.send(i);
    await it.moveNext();
    final data = it.current as Uint8List;
    lat[i] = Timeline.now - s;
    bytes += data.length;
    sink ^= data[0] ^ data[data.length - 1];
  }
  sw.stop();
  rx.close();
  ackRx.close();
  iso.kill();
  if (sink == 12345678) print('never');
  return RunStats(bytes, sw.elapsedMicroseconds, lat);
}

Future<void> _sender((SendPort, SendPort, int, int, int) args) async {
  final (out, ackOut, fd, chunk, calls) = args;
  final acks = ReceivePort();
  ackOut.send(acks.sendPort);
  final buf = malloc<Uint8>(chunk);
  final it = StreamIterator(acks);
  for (var i = 0; i < calls; i++) {
    await it.moveNext();
    final n = _pread64(fd, buf.cast(), chunk, i * chunk);
    final data = Uint8List(n)..setRange(0, n, buf.asTypedList(n));
    out.send(data);
  }
  malloc.free(buf);
}

/// D: package:jni static call BenchReader.read(fd, pos, len) -> byte[] -> Uint8List.
Future<RunStats> jniLoop(int fd, int chunk) async {
  return Isolate.run(() => jni.loop(fd, chunk, gib));
}

// ---------------------------------------------------------------- stats

({double mean, int p50, int p99, int max}) pct(Int32List lat) {
  final s = Int32List.fromList(lat)..sort();
  final mean = s.fold<int>(0, (a, b) => a + b) / s.length;
  return (
    mean: double.parse(mean.toStringAsFixed(1)),
    p50: s[s.length ~/ 2],
    p99: s[(s.length * 99) ~/ 100],
    max: s.last,
  );
}

class FrameSummary {
  int frames = 0;
  int jank = 0; // totalSpan > 16.7 ms
  int jank33 = 0; // totalSpan > 33.4 ms
  int uiStall = 0; // buildDuration > 16.7 ms (UI isolate blocked)
  int gaps40 = 0; // vsync-to-vsync interval > 40 ms (idle emulator: 16.7/33.3)
  double fps = 0;
  double worstMs = 0;
  double medianSpanMs = 0;
  double buildWorstMs = 0;
  double rasterWorstMs = 0;
  double maxGapMs = 0;

  Map<String, num> get map => {
    'frames': frames,
    'fps': fps,
    'jank': jank,
    'jank33': jank33,
    'uiStall': uiStall,
    'gaps40': gaps40,
    'worst_ms': worstMs,
    'medianSpan_ms': medianSpanMs,
    'buildWorst_ms': buildWorstMs,
    'maxGap_ms': maxGapMs,
  };

  String get line =>
      'frames=$frames fps=${fps.toStringAsFixed(1)} jank=$jank '
      'jank33=$jank33 uiStall=$uiStall gaps40=$gaps40 '
      'worst_ms=${worstMs.toStringAsFixed(1)} '
      'medianSpan_ms=${medianSpanMs.toStringAsFixed(1)} '
      'buildWorst_ms=${buildWorstMs.toStringAsFixed(1)} '
      'rasterWorst_ms=${rasterWorstMs.toStringAsFixed(1)} '
      'maxGap_ms=${maxGapMs.toStringAsFixed(1)}';
}

FrameSummary frameStats(int t0, int t1) {
  final f = FrameSummary();
  final spans = <int>[];
  var worst = 0, build = 0, raster = 0, maxGap = 0;
  int? prevVsync;
  final inWindow =
      _timings.where((t) {
        final ts = t.timestampInMicroseconds(FramePhase.buildStart);
        return ts >= t0 && ts <= t1;
      }).toList()..sort(
        (a, b) => a
            .timestampInMicroseconds(FramePhase.vsyncStart)
            .compareTo(b.timestampInMicroseconds(FramePhase.vsyncStart)),
      );
  for (final t in inWindow) {
    f.frames++;
    final span = t.totalSpan.inMicroseconds;
    spans.add(span);
    if (span > 16700) f.jank++;
    if (span > 33400) f.jank33++;
    if (t.buildDuration.inMicroseconds > 16700) f.uiStall++;
    if (span > worst) worst = span;
    if (t.buildDuration.inMicroseconds > build) {
      build = t.buildDuration.inMicroseconds;
    }
    if (t.rasterDuration.inMicroseconds > raster) {
      raster = t.rasterDuration.inMicroseconds;
    }
    final v = t.timestampInMicroseconds(FramePhase.vsyncStart);
    if (prevVsync != null) {
      final gap = v - prevVsync;
      if (gap > 40000) f.gaps40++;
      if (gap > maxGap) maxGap = gap;
    }
    prevVsync = v;
  }
  spans.sort();
  f.fps = f.frames / ((t1 - t0) / 1e6);
  f.worstMs = worst / 1000;
  f.medianSpanMs = spans.isEmpty ? 0 : spans[spans.length ~/ 2] / 1000;
  f.buildWorstMs = build / 1000;
  f.rasterWorstMs = raster / 1000;
  f.maxGapMs = maxGap / 1000;
  return f;
}
