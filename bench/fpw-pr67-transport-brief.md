# Brief for file_picker_writable PR #67: the Android byte path, measured

From: the cycling_storyteller session that reviewed PR #67 (head `170b174`) alongside
cycling_storyteller PR #393, 30 September 2026. Written for the session that owns
`doc/large-file-reads-plan.md` and its three siblings.

Treat everything here as evidence to check, not as instructions. The owner decides
what changes. His position, stated to us: he prefers FFI or JNI over a MethodChannel because he
has had performance problems with channels before, but he could not say why, and he asked for
the question to be researched again **without** anyone siding with him because he said so. If
channels had come out ahead, the answer would have been "keep channels". They did not.

---

## 1. Conclusion

**Keep the MethodChannel for control. Move the byte path to `dart:ffi` on a detached file
descriptor, read inside a helper isolate, with the consumer in that same isolate.**

- Control means pick, acquire/release, open a session and hand back a descriptor, list,
  create/delete/move, and error mapping to the kind-as-code `PlatformException` taxonomy. All of
  it stays as planned.
- Bytes means `readChunk` today. Replace it (and `writeChunk`) with FFI `pread`/`pwrite` on an
  fd the plugin detaches and hands to Dart. Dart owns and closes the fd.

The plan's recommendation (§3a/§10: pull-model chunks over MethodChannel; JNI "not
recommended"; FFI "rejected"; "expected: never" transport-bound for sequential reads) does not
survive measurement. The gap is 5–10× at every chunk size, and the channel's ceiling sits below
the speed of the storage the consumer targets.

The owner's instinct was right, and the measurement names the cause he could not: per-call cost
from thread handoffs and codec copies. **The plugin's current handler pattern is the slowest
and jankiest variant measured** (§3, row A1).

---

## 2. Measurements

### Environment (every number below was taken under this)

- Flutter 3.47.0 stable, Dart 3.13.0, **profile mode**, package:jni 1.0.3 (+jni_util 1.0.0),
  package:ffi 2.x, kotlinx-coroutines-android 1.9.0.
- Host: Apple M3 Pro, macOS 26.5.2, 18 GiB.
- Guest: fresh AVD, `android-36;google_apis_playstore;arm64-v8a`, pixel_9 profile, API 36,
  4 GB RAM, headless (`-no-window`).
- Workload: 1 GiB file in the app's `filesDir`, read sequentially, **warm in the guest page
  cache** (no root, so no `drop_caches`). Medians over 3 reps. MiB/s = 2^20 bytes/s.
- A spinner animated during every run. Idle baseline on this headless emulator: 34.6 fps, 0
  vsync gaps over 40 ms, max gap 33.3 ms. Every frame exceeds 16.7 ms even idle, so jank
  counts are meaningless here. `fps`, `gaps40` and `maxGap` are the columns that discriminate.

### Round trip of an empty channel call (1000 calls × 3 reps)

| channel | mean µs | p50 µs | p99 µs |
|---|---|---|---|
| default (platform thread) | 152.7 | 71 | 1257 |
| background TaskQueue | 501.1 | 200 | 10222 |

### Throughput and frame impact

| transport | chunk | MiB/s | p50 µs/call | fps | gaps>40ms | maxGap ms |
|---|---|---|---|---|---|---|
| A1 channel, handler hops to Dispatchers.IO, replies on main | 64K | 59.4 | 420 | 33.1 | 63 | 216.7 |
| | 256K | 115.7 | 932 | 32.6 | 42 | 116.7 |
| | 1M | 224.3 | 2795 | 33.1 | 16 | 116.7 |
| A2 channel, blocking read in handler on platform thread | 64K | 140.3 | 182 | 33.8 | 26 | 66.7 |
| | 256K | 207.1 | 580 | 32.0 | 23 | 66.7 |
| | 1M | 311.7 | 1951 | 32.0 | 4 | 166.7 |
| B channel on background TaskQueue | 64K | 83.7 | 328 | 35.0 | 32 | 66.7 |
| | 256K | 159.2 | 714 | 32.7 | 24 | 66.7 |
| | 1M | 273.0 | 2306 | 33.1 | 10 | 50.0 |
| **C1 FFI `pread64`, helper isolate, consume in place** | 64K | **1149.7** | **12** | 31.6 | **0** | 50.0 |
| | 256K | **1823.5** | 30 | 32.8 | **0** | 50.0 |
| | 1M | **2158.4** | 219 | 33.6 | **0** | 33.3 |
| C2 FFI, helper isolate, copy into new `Uint8List` per chunk | 64K | 1165.1 | 14 | 30.6 | 1 | 50.0 |
| | 256K | 614.1 | 178 | 32.7 | 3 | 50.0 |
| | 1M | 946.8 | 582 | 32.7 | 4 | 50.0 |
| C3 FFI in helper, chunk sent to UI isolate over `SendPort` | 64K | 111.2 | 223 | 34.2 | 20 | 100.0 |
| | 256K | 190.2 | 642 | 32.9 | 13 | 116.7 |
| | 1M | 316.9 | 1948 | 31.5 | 11 | 66.7 |
| C4 FFI on the **UI isolate**, yield per chunk | 64K | 219.0 | 19 | 33.6 | 12 | 133.3 |
| | 256K | 701.1 | 125 | **8.2** | 8 | **866.7** |
| | 1M | 1086.5 | 551 | **5.3** | 3 | 366.7 |
| D package:jni, helper isolate, `Os.pread` into `byte[]` | 64K | 731.3 | 29 | 31.4 | 2 | 50.0 |
| | 256K | 845.5 | 103 | 30.8 | 2 | 66.7 |
| | 1M | 797.5 | 705 | 30.4 | 0 | 50.0 |

### What the hot paths were

```kotlin
// A1/A2/B share this positional read (FileChannel.read(bb, pos) = pread)
private fun readAt(pos: Long, len: Int): ByteArray {
  val buf = ByteArray(len); val bb = ByteBuffer.wrap(buf); var p = pos
  while (bb.hasRemaining()) { val n = chan.read(bb, p); if (n < 0) break; p += n }
  return buf }
// A1 — the plugin's current shape (FilePickerWritablePlugin.kt:74 does launch(Dispatchers.Main))
"readIO" -> scope.launch { val b = withContext(Dispatchers.IO) { readAt(pos, len) }; result.success(b) }
// A2
"readSync" -> result.success(readAt(pos, len))
// B
MethodChannel(messenger, "bench/bg", StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
```

```dart
// A/B, one call per chunk
final data = await chan.invokeMethod<Uint8List>(method, {'pos': i * chunk, 'len': chunk});

// C — fd from a one-time ParcelFileDescriptor.open(file, MODE_READ_ONLY).detachFd() over the channel
@Native<IntPtr Function(Int, Pointer<Void>, IntPtr, Int64)>(symbol: 'pread64', isLeaf: true)
external int _pread64(int fd, Pointer<Void> buf, int n, int off);
final buf = malloc<Uint8>(chunk);                 // once per run
final n = _pread64(fd, buf.cast(), chunk, i * chunk);
final view = buf.asTypedList(n);                  // C1: consume the view in place
final out = Uint8List(n)..setRange(0, n, view);   // C2/C3/C4: copy into the Dart heap
```

`D` is package:jni's low-level API (no jnigen): `JClass.forName`, `staticMethodId('read',
'(IJI)[B')`, then `JByteArray.getRange`, which is one `GetByteArrayRegion` copy into malloc'ed
memory.

### Confounds, and how far to trust this

1. **Emulator, warm page cache.** Anything above about 1 GB/s is memcpy speed, not flash speed.
   The ratios between transports are the finding; the absolutes are not.
2. **Frame metrics are relative only.** The emulator's raster is ANGLE over the host with no
   window.
3. **Tails (p99, max) are 10–20 ms in every row.** That is vCPU scheduling, not the transport.
   Compare p50s and MiB/s.
4. **A2 blocks the platform thread** for a cached 30–500 µs read. On cold flash on a device, its
   jank would be far worse. Not measured.
5. Three reps, one emulator. **No physical-device numbers.** That is the next measurement worth
   having, cold cache, on a USB 3 OTG SSD and on internal storage via ExternalStorageProvider.

### What the numbers say

- **Channels are bounded by per-call cost, not by bytes.** Going from 64K to 1M chunks gives all
  three channel variants about 4× more throughput, and they still top out at 224–312 MiB/s,
  2–4.5 ms per call. That ceiling is below a USB 3 SSD (300–1000 MB/s) and below phone internal
  storage (UFS, hundreds of MB/s to over 1 GB/s). So for the consumer's target media, the
  channel *is* the bottleneck. §8's graduation target of "≥80% of raw provider throughput"
  would fail on any provider faster than about 300 MiB/s.
- **A background TaskQueue does not rescue the channel.** It frees the platform thread (fewer
  frame gaps than A1), but its per-call floor is about 3× the default channel's (p50 200 vs
  71 µs), so its throughput is lower than A2's.
- **The current plugin pattern (A1) is the worst case:** two main-looper hops per call plus a
  coroutine dispatch. It has the lowest throughput and the most dropped frames (63 gaps over
  40 ms, 217 ms max gap at 64K).
- **FFI's lead exists only if the bytes stay in the helper isolate.** Shipping each chunk to the
  UI isolate over a `SendPort` (C3) brings it back to channel speed and channel jank. So the
  consumer (hash, parse, copy, stream to a socket) must run where the bytes land.
  `TransferableTypedData` was not measured.
- **Do not read on the UI isolate** (C4). At 256K and up it starved frames (5–8 fps, 867 ms
  gaps) even though each call was only 125–550 µs. The cause (GC of large per-chunk
  `Uint8List`s, or event-loop ordering) is unconfirmed; the effect is measured.
- **Reuse one native buffer and consume views** (C1). Allocating a fresh `Uint8List` per chunk
  (C2) halves throughput at 256K and 1M.
- **package:jni is viable, but it is second.** It reaches 730–850 MiB/s with essentially no
  frame gaps, flat across chunk sizes because the copies dominate. It costs an NDK/CMake plugin
  build (it compiled first time here), and it still copies the `byte[]` into Dart. It is the
  right tool for broad Java API access, not for moving bytes.

---

## 3. Engine source trace (why the channel costs what it costs)

Traced in the Flutter 3.47.0 SDK and engine source (`engine/src/flutter/`) for an
`invokeMethod` carrying a `Uint8List` both ways:

1. Dart `StandardMethodCodec` → `WriteBuffer.putUint8List` (`foundation/serialization.dart:117`):
   **copy 1**.
2. `PlatformDispatcher.sendPlatformMessage` → `fml::MallocMapping::Copy`
   (`lib/ui/window/platform_configuration.cc:577-591`): **copy 2**.
3. `platform_view_android_jni_impl.cc` (608-621) → `NewDirectByteBuffer` (no copy) →
   `FlutterJNI.handlePlatformMessage` → `DartMessenger` → default `PlatformTaskQueue`
   (`Handler.post` to the main looper).
4. Java `StandardMessageCodec.readBytes` → `buffer.get(bytes)` into a heap `byte[]`
   (`StandardMessageCodec.java:317-322`): **copy 3**.
5. Reply: `StandardMethodCodec.encodeSuccessEnvelope` → `ByteArrayOutputStream` (**copy 4**) →
   `ByteBuffer.allocateDirect` + `put` (**copy 5**, `StandardMethodCodec.java:59-63`) →
   `invokePlatformMessageResponseCallback` → `MallocMapping::Copy` (**copy 6**,
   `platform_view_android_jni_impl.cc:1356-1383`) → posted to the UI task runner. Replies over
   1000 bytes become external typed data (`platform_message_response_dart.cc:68-99`,
   `dart_byte_data.cc:23`) and `ReadBuffer.getUint8List` is a view, so the reply adds no copy
   on the Dart side.

That is **six memcpy-class copies per chunk**. Flutter's own 2020 post said it used to be four
(https://flutter.dev/blog/improving-platform-channel-performance-in-flutter).

- **Merged threads.** The platform and UI threads have been merged by default on Android and
  iOS since 3.29 (flutter.dev/blog/whats-new-in-flutter-3-29). The opt-out was removed in 3.38
  (flutter/flutter#174408), and the 3.47 engine `FML_CHECK`s against the flag
  (`switches.cc:527-555`). Android's `PlatformMessageHandlerAndroid` handles messages on the UI
  thread directly (`shell.cc:1542`). Consequences:
  - Without a TaskQueue, handler work blocks Dart frames outright.
  - The default `PlatformTaskQueue` hop is a same-thread async `Handler` round trip.
  - A blocking JNI or FFI call on the UI isolate blocks frames the same way.
  - So every transport needs a helper thread or isolate. That erases the plan's asymmetry
    argument against JNI and FFI ("same worker-isolate requirement").
- **TaskQueue.** With `makeBackgroundTaskQueue` the message goes from the JNI upcall straight
  to the executor, without touching the main looper. `invokePlatformMessageResponseCallback`
  is "Called on any thread" (`FlutterJNI.java:1219-1232`). It removes the thread cost; the
  measurement shows it does not remove the per-call cost.
- **`BackgroundIsolateBinaryMessenger`.** A helper isolate can make channel calls itself
  (`_background_isolate_binary_messenger_io.dart:43-84`; send via the same `MallocMapping::Copy`,
  reply via `Dart_PostCObject`, `ui_dart_state.cc:223-236`). "Background isolates do not support
  setMessageHandler()". Useful for the control calls from a helper isolate.

---

## 4. Which providers hand back a real fd (verified in AOSP)

- `ExternalStorageProvider extends FileSystemProvider`. Its `openDocument` returns
  `ParcelFileDescriptor.open(file, …)` for writes, and for reads a MediaStore
  `openTypedAssetFileDescriptor` fd with a `ParcelFileDescriptor.open` fallback: **real file
  fds, no `createPipe` anywhere**. USB drives are roots of the same provider
  (`Root.FLAG_REMOVABLE_USB`).
- `DownloadStorageProvider` and `MediaDocumentsProvider` also hand out MediaStore fds.
- Cloud providers are unverified (closed source); the API allows pipes for "r".
- **Detection is one line:** `ParcelFileDescriptor.getStatSize()` returns -1 for a non-file.
  Report `seekable = statSize >= 0`. Do not infer seekability from `openAssetFileDescriptor`:
  an AFD can wrap a pipe (`UNKNOWN_LENGTH`), and an AFD can also be a *sub-range* with a
  non-zero `startOffset` that positional reads must honor. `openFileDescriptor(uri, "r")` on a
  document avoids that second trap.

So the plan's "provider fds are often pipes… pipes kill the seeking that would justify [FFI]"
is **wrong for every provider the consumer targets**.

---

## 5. The plan's claims, one by one (`doc/large-file-reads-plan.md`)

| claim | verdict |
|---|---|
| §2 "provider and storage throughput (10–100 MB/s) dominates" | **Wrong** for internal storage and USB 3 OTG; true only for cloud/virtual providers and USB 2 sticks |
| §2 "copies are unavoidable and irrelevant" | **Wrong in effect.** The copies are cheap each; the per-call handoffs they come with cap the channel at ~300 MiB/s |
| §3 "Channels *are* JNI plus a thin codec… no cliff" | **Wrong.** Six copies and two queue hops plus JNI crossings per call; measured 5–10× slower than JNI or FFI |
| §3 "~0.1–1 ms per call" | **Holds as a median** (71–200 µs empty, 0.4–2.8 ms with a chunk), with a long tail |
| §3c JNI "same worker-isolate requirement" | **Holds**, and since merged threads it applies to channel handlers too, so it is not an argument between them |
| §3c JNI "machinery weight for identical bytes" | **Partly holds.** Not identical bytes, though: JNI measured 3–10× the channel |
| §3d FFI "pipes kill the seeking" | **Wrong** for ExternalStorageProvider, Downloads and Media (§4 above) |
| §3d FFI "fd lifetime has only GC-driven finalizers" | **Wrong framing.** The fd is closed explicitly, as `closeRead` closes a session; `NativeFinalizer` is the backstop in both designs, and §9's own open question admits the session registry leaks on a forgotten close too |
| §3d "error surface is raw errno" | **True and small.** Map `EBADF`/`EIO`/`ENXIO` after detach to `permission-lost`; everything else stays loud under its own code, per §6's exhaustiveness rule |
| §3 "at ≥256 KB chunks both are memcpy/storage-bound" | **Wrong for the channel**, which is call-bound up to 1 MiB |
| §10 "expected: never [transport-bound] for sequential reads" | **Wrong** (measured) |
| §5 "prefer `openAssetFileDescriptor` (offset + length known ⇒ seekable)" | **Wrong inference.** Use `getStatSize()`, and honor `startOffset` if an AFD is kept |

Other docs in PR #67:

- **`tree-writes-plan.md`, "flush per chunk… crash hygiene":** `OutputStream.flush()` on a
  provider stream does not fsync. With an fd from `openFileDescriptor(uri, "w")` on
  ExternalStorageProvider, an FFI `fsync(fd)` does, which gives the claim substance. Pipes have
  no fsync; say so.
- **`scope-registry-plan.md` and `tree-traversal-plan.md`:** sound as reviewed. Refcounted
  scopes match Apple's balance rule. Batched one-level listing is the right answer to per-child
  call cost, and it stays on the channel.
- **None of the four docs mentions TaskQueue, `BackgroundIsolateBinaryMessenger`, or the
  merged-thread default.** The control verbs should at least use a background TaskQueue, so
  that a slow provider query (listing a USB root) never blocks Dart frames.

---

## 6. Suggested changes to PR #67

For the owner to accept or reject; nothing here is agreed yet.

1. **`large-file-reads-plan.md` §3/§10: flip the recommendation.** New §3a: control over the
   channel (background TaskQueue); bytes over FFI on a plugin-detached fd.
   - Keep the chunked-channel design as the documented rejected alternative, with the numbers
     above.
   - JNI is second: viable, but it copies through a `byte[]` and adds an NDK plugin build.
2. **API shape (sketch):**
   - `openRead({scope})` → `ReadSession { int fd; bool seekable; int? length; }`, where
     `fd = ParcelFileDescriptor.detachFd()` from `openFileDescriptor(uri, "r")`, `seekable =
     statSize >= 0`, `length = statSize >= 0 ? statSize : null`.
   - Dart ships a small `FdReader` (FFI `pread64`/`read`/`close`, `isLeaf: true`) that works in
     any isolate. The fd is a plain int, so it passes to a helper isolate for free.
   - `readChunk(position, length)` becomes an FFI call. It reads into a caller-owned native
     buffer and returns a view, and the doc says to consume views in place (C1 vs C2).
   - `closeRead` becomes an FFI `close`, idempotent, with a `NativeFinalizer` on the Dart
     wrapper as a backstop.
3. **Writes, same shape:** `openWrite` → fd from `openFileDescriptor(uri, "w")` (fail-if-exists
   stays in the create verb); FFI `pwrite`/`write`, and `fsync` where the fd is a file.
   **A bulk copy then needs no native verb:** fd→fd with pread/pwrite in one helper isolate, at
   full speed, off the UI thread. The cycling_storyteller review had asked for a native
   `copyEntry`; this makes it optional.
4. **Ownership trap to document.** `ParcelFileDescriptor.fromFd(fd).fileDescriptor` without
   retaining the PFD lets its finalizer close the fd mid-read (`pread64 interrupted by close()`,
   then `EBADF`); measured in the JNI variant. `detachFd()` transfers ownership to Dart and
   avoids it.
5. **iOS needs none of this.** An acquired scope yields a path; `dart:io` or FFI on that path,
   in a helper isolate, is the whole story. macOS stays stubbed.
6. **§7 benchmarks:** keep the device benchmark as a graduation gate. The emulator numbers here
   are a strong prior, not the answer. The missing measurement is cold-cache, on a physical
   phone, internal storage via ExternalStorageProvider and a USB 3 OTG SSD. Flutter's
   `dev/benchmarks/platform_channels_benchmarks` has a 1 MB binary case and a TaskQueue case.
7. **Separately, the plugin's existing handler** (`FilePickerWritablePlugin.kt:74`,
   `launch(Dispatchers.Main)` then `withContext(Dispatchers.IO)`) is the A1 shape. Moving it to
   a background TaskQueue is a cheap improvement for the existing verbs, independent of this
   plan.

---

## 7. What the consumer actually reads through this path

From cycling_storyteller, so the plan can weight the workload. Decoding and rendering go
native over URIs and never touch this path. Dart reads bytes in these places:

- **Fingerprints:** first and last 1 MiB of every file, at import, move verify and relink. Seek
  required.
- **Clip tags at import:** the MP4 `moov` box plus the Insta360 trailer. Seek required.
- **Gyro on the Sync screen:** the Insta360 IMU record from the trailer, roughly 72 MB per hour
  of footage. One seek plus a contiguous read.
- **Index JSON and FIT/GPX:** small whole-file reads.
- **Moves:** multi-GB clips copied between the app container and the drive.
- **Handoff send:** the LAN server streams whole clips from Dart (`addStream`).

The consumer's own phone plan (`docs/PHONE-TRIP-STORAGE-PLAN.md`, cycling_storyteller PR #397)
is being rewritten to read through FFI in a helper isolate. The owner also wants one exFAT drive
shared between a Mac and an Android phone, with work continuing on either. That puts the
project document on the drive and makes durable writes (fsync on a real fd) matter.

---

## 8. Traps hit while measuring

- The emulator `Pixel_9_API_36` on this machine has a lock-screen PIN, so user 0 stays
  `RUNNING_LOCKED` and every non-direct-boot activity fails with "Activity class … does not
  exist". The bench used a fresh AVD instead.
- `flutter run` dropped the last ~20 lines of `print` output when the app exited 500 ms after
  finishing. Capture `adb logcat -s flutter` in parallel for anything that exits.
- package:jni: see §6 item 4 (the PFD finalizer closing the fd).

---

## 9. Artifacts

[2026-09-30 note: preserved — everything below now lives in this
repo under `bench/` (`chanbench/`, `table_emulator.txt`,
`runs_emulator.txt`, `run_s24.log`, `logcat_s24.log`,
`table_s24.txt`, `table.py`), so this section is historical. The
emulator raw logs (`run_full.log`, `logcat_full.log`) and the AVD
were scratchpad-only and expired with it.]

Everything is in the reviewing session's scratchpad, which is temporary. Copy what you need:
`(reviewer scratchpad, ephemeral)`

- `chanbench/`: the bench app (`lib/main.dart`, `lib/jni_transport.dart`,
  `android/app/src/main/kotlin/dev/bench/chanbench/MainActivity.kt`)
- `table.txt`: the full table, including `jank`, `uiStall` and `worst_ms` columns
- `runs.txt`: per-rep lines
- `run_full.log`, `logcat_full.log`: raw output
- `table.py`: the parser
- `avdhome/`: the AVD used (`bench_api36`)

## 10. Sources

- Flutter 3.47.0 SDK: `packages/flutter/lib/src/foundation/serialization.dart:117,228-229`;
  `packages/flutter/lib/src/services/_background_isolate_binary_messenger_io.dart:43-84`.
- Engine (github.com/flutter/flutter, `engine/src/flutter/`): `DartMessenger.java` (184-221,
  256-330), `PlatformTaskQueue.java`, `FlutterJNI.java` (1127-1156, 1219-1232),
  `StandardMessageCodec.java` (317-322, 383-385), `StandardMethodCodec.java` (59-63),
  `platform_view_android_jni_impl.cc` (608-621, 1356-1383), `platform_configuration.cc`
  (577-591), `platform_message_response_dart.cc` (68-99), `tonic/typed_data/dart_byte_data.cc:23`,
  `shell.cc:1542`, `switches.cc:527-555`, `ui_dart_state.cc:223-236`.
- https://flutter.dev/blog/whats-new-in-flutter-3-29 (merged threads); flutter/flutter#174408
  (opt-out removed);
  https://docs.flutter.dev/release/breaking-changes/macos-windows-merged-threads.
- https://flutter.dev/blog/improving-platform-channel-performance-in-flutter.
- https://flutter.dev/blog/flutters-path-towards-seamless-interop (May 2025; direct interop
  as the direction for synchronous calls; channels are not called deprecated).
- AOSP: `ExternalStorageProvider`, `FileSystemProvider.openDocument`,
  `DownloadStorageProvider`, `MediaDocumentsProvider`, `ParcelFileDescriptor.getStatSize`.
- package:jni 1.0.3 source (pub cache): synchronous calls on the calling thread, lazy thread
  attach, `JByteArray.getRange` as one `GetByteArrayRegion`, and `JByteBuffer.asUint8List`
  zero-copy over a direct buffer.
