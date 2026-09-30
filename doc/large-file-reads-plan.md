# Large-file reads without temp copies: evaluation & plan

Status: proposal, for review. No commitments.
Date: 2026-09-30.
Transport decision revised 2026-09-30 after measurement (see `bench/`).
Context: a consumer app needs phone-side trip storage — pick a folder on
attached storage, keep the grant across relaunches, repeatedly read
GB-scale media files. This doc evaluates how `file_picker_writable`
could offer large reads without the current copy-through-temp lifecycle,
and recommends an approach.

## 1. Problem

Current contract: `readFile` copies the whole file to temp, hands over a
`dart:io` File, deletes afterwards; writes stage through temp. Correct
for documents, disqualifying for a media library: write amplification,
temp-space pressure, and full-copy latency on every repeated read.

Goal: read large provider-backed files with bounded memory, no temp
footprint, cancellable, with random access where the provider allows it
— at speeds the target storage (phone internal, USB-OTG SSD) can
actually deliver. An earlier revision recommended pull-model chunks
over MethodChannel; measurement (emulator + physical S24, `bench/`)
showed the channel byte path call-bound below those storage speeds,
so the recommendation flipped to FFI on a detached fd. The channel
design is kept below as a documented rejected alternative with numbers.

## 2. Platform realities (constraints, not choices)

- Android SAF tree/document URIs have no filesystem path — but the
  providers hand out real file descriptors. ExternalStorageProvider
  (which also serves USB drives), DownloadStorageProvider, and
  MediaDocumentsProvider return real file fds with no pipes anywhere
  (AOSP sources, per the transport brief); cloud providers are
  unverified and may pipe. "Often pipes" was wrong for every
  provider the consumer targets — but seekability stays a runtime
  property to report, never an assumption.
- Seekability and length are one call: `ParcelFileDescriptor`
  `.getStatSize()` returns -1 for non-regular files (verified in
  AOSP: it checks `S_ISREG`/`S_ISLNK`). `seekable = statSize >= 0`,
  `length = statSize or null`. Never infer from
  `openAssetFileDescriptor`: an AFD can wrap a pipe
  (`UNKNOWN_LENGTH`) and can be a sub-range with a non-zero
  `startOffset` that positional reads must honor.
  `openFileDescriptor(uri, "r")` on a document avoids the trap.
- iOS: scoped URLs yield paths once the scope is held; the plugin
  opens an fd with `open(2)` under the held scope, so read sessions
  are uniform fds on both platforms. (macOS is stubbed for these
  gaps — see the Gap-1a plan.) Gap 1a exposes the path on Apple, so
  small one-shot reads use `dart:io` directly and sessions are
  reserved for large reads.
- Measured channel cost: six memcpy-class copies plus two queue hops
  plus JNI crossings per chunk (traced in SDK + engine sources —
  see Sources). Per-call floor on the S24: empty ping p50 37µs
  (default) / 162µs (background TaskQueue); 1MB chunk p50 ~2.2ms
  channel vs ~192µs FFI. The usable channel ceiling is ~390 MiB/s
  on the tested path; whether UFS/USB-3 targets exceed it is
  unmeasured — and the consumer's real media (exFAT, ~100–300MB/s)
  is storage-bound under every transport, where the FFI win is CPU
  (fewer copies) and frames, not throughput. FFI `pread` costs
  one syscall plus one kernel→user copy.
- Merged threads (default since Flutter 3.29): every transport needs
  a helper thread or isolate. Android control verbs run on a
  background TaskQueue so slow provider calls never block frames;
  TaskQueue is Android-only, so iOS keeps manual off-main dispatch.

## 3. Options evaluated

### 3a. Control on channel, bytes over FFI on a detached fd (RECOMMENDED)

Control verbs (pick, acquire/release, open a session and hand back a
descriptor, list, create/delete/move, error mapping) stay on the
MethodChannel on a background TaskQueue. `openRead` detaches the
provider fd into Dart ownership; a small Dart `FdReader` (FFI
`pread`/`read`/`close`, `isLeaf`) reads into a caller-owned native
buffer and returns views consumed in place; `closeRead` closes the fd
with a `NativeFinalizer` backstop. Backpressure is structural (no
calls, no bytes); cancellation is `close`; multiplexing is session
fds. The isolate rule is load-bearing, not advisory: bytes must be
consumed in the helper isolate where they land (rows C3/C4 below).
Bounded exemption, shared with the driving consumer: one-shot reads
of ≤1MiB total may run on the root isolate (milliseconds of views,
no frame risk); anything larger MUST use a helper.

```
S24 medians, MiB/s, 1 GiB sequential (emulator in parens):
chunk:          64K          256K         1M
A1 ch/IO        111 (59)     209 (116)    329 (224)
A2 ch/sync      394 (140)    420 (207)    498 (312)
B  ch/TaskQueue 169 (84)     274 (159)    393 (273)
C1 ffi/views    4833 (1150)  4880 (1824)  4654 (2158)
D  jni          1265 (731)   1402 (846)   1492 (798)
```

C3 (chunk ferried to the UI isolate per `SendPort`) falls back to
channel speed (~300–470 MiB/s); C4 (reads on the UI isolate) holds
throughput but collapses frames to 6–12 fps at 256K+. All rows hold
120 fps with zero jank on device except A2 at 1M (113 fps, no jank)
and C4. Caveat: channel loops ran UI-interleaved (each await can pay
frame-build time) while helper loops did not — absolutes carry that
handicap, ordering does not. Full tables plus per-call latencies:
`bench/table_s24.txt`, `bench/table_emulator.txt`.

### 3b. Pull-model chunks over MethodChannel (rejected)

The former recommendation, kept as the documented alternative: Dart
pulls fixed-size chunks by explicit position; native serves them
from the provider. Same backpressure/cancellation/multiplexing story
as 3a — but the transport caps it at ~390 MiB/s usable (row B; row
A2 is faster yet unshippable since it blocks the platform thread),
12–28× behind FFI views at every chunk size, with 2.2–2.5ms per
1MB call. The ceiling sits below the target storage speeds, so the
§8 graduation target (≥80% of provider throughput) would fail on
any fast provider. Revisit never for bulk bytes; the control verbs
are exactly where channels belong.

### 3c. EventChannel push stream (rejected)

A push stream buffers behind a slow reader with no backpressure —
gigabytes queued in memory is the failure mode this whole proposal
exists to avoid. Unchanged by measurement.

### 3d. package:jni direct interop (second place)

Viable: ~1.3–1.5 GiB/s on device with essentially no frame gaps,
flat across chunk sizes. But the measured path copies through a
`byte[]` (`GetByteArrayRegion`; the direct-`ByteBuffer` zero-copy
path is unmeasured), it adds an NDK/CMake plugin build, and calls
run synchronously on the calling thread (helper isolate still
required). (`package:jni` is at 1.0.3 and stable — the old churn
objection stays withdrawn.) The right tool for *broad* Java interop
(driving libraries with no Dart equivalent), not for moving bytes.

### 3e. FFI without isolate discipline (rejected)

Rows C3/C4 above: ferrying each chunk to the UI isolate costs the
whole lead (channel speed, channel jank), and reading on the UI
isolate starves frames (5–12 fps, hundreds-of-ms gaps) even though
each call is only hundreds of µs. The consumer (hash, parse, copy,
stream) must run where the bytes land. `TransferableTypedData` for
large result handoffs is unmeasured — a possible refinement, not a
reason to skip the isolate rule.

### Overhead note (why FFI despite the channel's simplicity)

Per-call floors are measured, not estimated: empty ping p50 37µs
(default) / 162µs (background queue); 1MB chunk p50 ~2.2ms channel
vs ~192µs FFI. The gap is structural (six copies + two hops + JNI
crossings vs one syscall + one copy), so it survives faster
hardware — only the ratio moves. Where small-call overhead would
bite (e.g. per-child metadata across a large tree) the cure is API
design — batch it in one call (Gap 1) — not transport choice; the
control verbs stay on the channel precisely because their payloads
are small and their frequency is low.

## 4. Proposed API (experimental)

```dart
@experimental
class ReadSession {
  // Detached native fd owned by Dart, plus what open reported.
  int get fd;          // Plain int: passes to a helper isolate for free.
  bool get seekable;   // statSize >= 0. False for pipes: sequential only.
  int? get length;     // statSize, or null for pipes.
  // Explicit handoff: returns the sendable record and kills the
  // local copy in one call (a SendPort send copies silently, so the
  // dead-marking must be explicit, never incidental).
  ReadHandoff handoff();
}
// Plain ints + bools: crosses isolates for free, in the same shape
// the driving consumer already sends.
class ReadHandoff {
  int get fd;
  bool get seekable;
  int? get length;
}

@experimental
Future<ReadSession> openRead({required AcquiredScope scope});
// Control call (channel): opens the provider fd, detaches it into Dart
// ownership, reports seekability + length. Never reads bytes.

@experimental
class FdReader {
  FdReader.fromSession(ReadSession session, {int bufferLength = 1 << 20}); // Same-isolate path.
  FdReader.fromHandoff(ReadHandoff handoff, {int bufferLength = 1 << 20}); // Helper-isolate path.
  // Sync FFI pread into the caller-owned native buffer; returns a VIEW
  // valid until the next call or close (call-counted, never
  // time-bound — awaits between calls are safe). Consume in place
  // (C1); copy only to retain (C2 cost, documented). Empty view
  // signals EOF. A retained view past close() is use-after-free
  // (the buffer is freed) — copy to retain. No GC finalizer on
  // the view can fix this: it would double-free against close.
  Uint8List readChunk(int position, int length);
  // FFI close + buffer free. Idempotent within the owning isolate.
  void close();
}

@experimental
Future<void> closeRead(ReadSession session); // FFI close, idempotent.
// For the no-reader path (session opened, never wrapped).
```

Notes:

- Cross-platform from day one: identical Dart verbs; Android fds
  come from ContentResolver + `detachFd`, iOS fds from `open(2)`
  under the held scope. Reads are Dart FFI plus one small shared
  C shim (close finalizer + `-errno` wrappers — needs a build
  step in the podspec and in the Android plugin). macOS and other
  stub platforms throw `UnsupportedError` — loud beats silent.
- Single-owner rule: the fd has exactly one Dart owner at a time.
  `handoff()` transfers ownership to the helper isolate; the
  sender must not close afterwards. Double-close across isolates
  is a caller bug (fd-number reuse), guarded within each wrapper
  by idempotent close plus a `NativeFinalizer` backstop on
  `FdReader`. (Symmetric with `detachFd`, which transferred
  ownership plugin→Dart.) After `handoff()` the sender's copy is
  dead for FD USE (byte ops, `closeRead` / wrapper close ⇒ sync
  `StateError`, like `ArgumentError` — fail-fast beats silent
  double-close); only the owning side closes. Within one isolate,
  `fromSession` links wrapper↔session close-state, so wrapper
  `close` and top-level `closeRead` cannot double-close each
  other.
- Kill/cancel story (peer-confirmed): cancel a live helper by
  message — it aborts and acks; the sender never closes. Kill is
  finalizer-closed: isolate shutdown runs attached
  `NativeFinalizer`s (VM guarantee), so a killed helper's fd
  closes itself — there is NO transfer-back, and closing from the
  sender after kill is the double-close bug. After kill the sender
  confirms death (exit port / `Isolate.run` error) and, for reads,
  does nothing further. (Writes run the control half only — see
  Gap 3 `closeFd: false`.) Explicit close always detaches the
  finalizer first, then closes (standard pattern), idempotent via
  a closed flag. If kill is ignored (no terminate capability) the
  helper stays owner — message-cancel, never the kill path.
- Finalizer placement: the `NativeFinalizer` MUST
  be attached by the wrapper constructed in the consuming isolate
  (finalizers run for the exiting isolate's own — verified in
  `isolate.cc`). Construct at most one `FdReader`/`FdWriter` per
  session, in the consumer; bare sessions never attach (a
  root-side wrapper GC'd mid-helper-read would close the live fd).
  Killable helpers use `Isolate.spawn` + `onExit` death
  confirmation (`Isolate.run` exposes no `Isolate` to kill; its
  errors are the non-kill path, finalizers already run).
- Pipes: `pread` fails on pipes (`ESPIPE`), so a non-seekable
  session reads sequentially (`read`), tracks position in Dart,
  and enforces forward-only. Backward seek on a pipe is a loud
  `seek-unsupported` error, not silent reopen-and-skip: the cost
  must stay visible. Short reads loop to length-or-EOF.
- No serialization needed on the byte path for files: `pread` is
  positional with no shared file offset, so overlapping reads
  cannot interleave — the per-session mutex question dissolves.
  (Pipe sessions use sequential `read` + Dart-tracked position and
  serialize per-reader; pipes are the rare path.) No ordering
  across in-flight control calls on the shared concurrent queue —
  callers sequence by awaiting.
- Small one-shot reads on Apple (index files, fingerprint hashes)
  should use `AcquiredScope.path` plus `dart:io` directly, not a
  session. Sessions are for large reads where fd reads earn it.
- Chunk guidance: throughput is flat from 64K to 1M (C1 row);
  default 1MB in a reused buffer. Views make big buffers cheap.
- Experimental mechanics: `@experimental` annotation plus a CHANGELOG
  notice. Additive API, so no feature flag is needed; the annotation
  keeps it honest to break the protocol in a minor until graduation.

## 5. Native design

### Android (Kotlin)

- `openRead` (control, background TaskQueue): validate the scope
  token (released ⇒ loud `scope-closed`), resolve the scope's
  identifier to URI, `openFileDescriptor(uri, "r")` (never
  `openAssetFileDescriptor` — the sub-range `startOffset` trap),
  `getStatSize` for seekability + length, `detachFd()` to transfer
  ownership to Dart. Never `fromFd` without retaining the PFD —
  its finalizer closes the fd mid-read (measured: `pread64
  interrupted by close()`, then `EBADF`).
- No native handle registry: nothing is held past the call, so
  there is no session map, no native mutex, no leak surface. All
  Android complexity is fd acquisition + error mapping.
- Threading: control on one shared CONCURRENT background TaskQueue
  (uniform rule for every Android control verb, existing verbs
  included as a companion change — TaskQueue is per-channel, and
  a serial queue would stall control behind a slow listing).
  No ordering across in-flight control calls — callers sequence
  by awaiting; `impl`'s mutable state (the activity, the pending
  pick) is only touched on the main hop. Picker verbs
  (`openFilePicker`, `openFilePickerForCreate`) hop
  back to main for `startActivityForResult`; the event-queue drain
  stays on main as today; MainScope is retained for the main-hop +
  drain. Bytes never touch the channel.

### iOS (Swift, inside a Gap-1a scope)

- `openRead` requires a live `AcquiredScope`, opens the path with
  `open(2)` `O_RDONLY`, `fstat`s for length, returns the fd.
  Reads are Dart FFI afterwards — but the scope discipline
  stays uniform: `FdReader` checks token liveness in Dart at
  construction and close, not per op (uniform with the helper
  channel rule below), and use after release is loud
  `scope-closed` (the kernel would not re-check an open fd; the
  plugin does). Off main; results hop
  to main per the plugin's existing convention (TaskQueue is
  Android-only). macOS is stubbed (`UnsupportedError`) per the
  Gap-1a boundary decision.

### Dart FFI reader (both platforms)

- `pread64`/`read`/`close` bindings, `isLeaf: true`; one reusable
  `malloc` buffer per reader; views via `asTypedList`, valid
  until the next call or close. The finalizer callback is a tiny
  native close shim (`void f(void*)`), not punned libc `close`
  (works on LP64, ABI-fragile) — and `pread` / `read` / `pwrite`
  / `fsync` go through the same shim as `-errno` wrappers (one
  shared C shim, both gaps): a separate `__errno` FFI call runs
  after Dart code has resumed, where a safepoint can intervene
  and hand back a stale value. `EINTR` retries inside the shim.
- `errno` mapping: `EIO`/`ENXIO`/`ENODEV` after detach ⇒
  `permission-lost` (media detached — revoked grants do NOT fail
  open fds); `EBADF` ⇒ `session-closed` (use after close / double
  close — never a live fd). The set is to-be-confirmed on device
  (FUSE transports may surface `ENOTCONN`). Everything else stays
  loud under its own code per the exhaustiveness rule.
- Helper channel access: the `FilePickerWritable()` singleton
  installs a Dart-side handler, which
  `BackgroundIsolateBinaryMessenger` refuses — so helpers use a
  dedicated handler-free channel client
  (`ensureInitialized(rootToken)` + raw `MethodChannel` invoke, no
  listen) shipped by the plugin. Token liveness is checked at
  reader construction and close, not per op (a per-op round trip
  would add 20–80% per read); mid-session revoke surfaces at
  close, not mid-read.

## 6. Error taxonomy

`permission-lost` (media detached incl. mapped `errno`; revoked
grants fail new opens while open fds keep reading), `not-found`, `seek-unsupported` (carrying
the native message), `session-closed` (use after close),
`scope-closed` (use after Gap-1a release; checked in Dart). Dart
carrier (pinned, all gaps): `PlatformException` with the taxonomy
kind as `code` and a details map carrying the native domain + code
where available, so callers can tell "detached" from "broken".
Exhaustiveness rule: anything outside the taxonomy stays loud
under its own native code — unknown failures are never coerced
into a taxonomy kind.

## 7. Testing plan

- Dart unit, mocked channels + real temp files (FFI runs in VM
  tests): control lifecycle (`openRead`/`closeRead`, close
  idempotency, error mapping), view-until-next-call semantics,
  EOF and short-read loops, forward-only pipe behavior (stub a
  non-seekable session), single-owner discipline, shim `-errno`
  mapping incl. `EINTR` retry (stubbed). No device needed.
- Android device (S24 matrix in `bench/table_s24.txt` is the
  baseline): large files from named providers (ExternalStorage
  internal, USB-OTG root, Downloads, Media, one cloud); assert
  no temp growth (no temp is involved); detach media mid-read
  and expect `permission-lost`; revoke the grant and expect open
  fds to keep reading (documented) while NEW opens fail
  `permission-lost`; backward seek on a pipe and expect
  `seek-unsupported`; memory bounded to one buffer during a 1GB
  read; zero read-attributable jank at 120Hz.
- Kill path: kill the helper mid-read; assert via `/proc/self/fd`
  that the fd closed exactly once (the finalizer did it — no leak,
  no reuse-close), and that further helper ops fail loudly.
- iOS backend: fd-read correctness plus stale-refresh interplay
  once acquire/release exists.
- Graduation gate (the missing measurement): cold-cache device
  run, internal storage via ExternalStorageProvider plus a USB-3
  OTG SSD. Emulator + warm-cache numbers are a strong prior, not
  the answer.

## 8. Graduation (experimental → stable)

All three, then drop `@experimental` in a minor:

1. One production app ships it for a release cycle with no protocol
   changes.
2. Benchmarks meet targets (suggested: ≥80% of raw provider
   throughput on the cold-cache device gate, memory bounded to
   one buffer in steady state, zero read-attributable jank).
3. Observed failures all map into the taxonomy — no new error kinds
   needed in the wild.

## 9. Open questions

- Chunk default 1MB (C1 row is flat 64K–1M)? Confirm on cold
  flash; views make big buffers cheap either way.
- Dart-side convenience: a thin sequential `Stream<Uint8List>`
  over open/read/close for in-helper callers? Probably yes.
- Single-owner enforcement: discipline plus idempotent close for
  v1; add a debug-mode double-close detector if cross-isolate
  leaks bite in practice?
- `TransferableTypedData` for large result handoffs out of the
  helper (unmeasured)? Measure if results grow past small metadata.
- `length` null in practice: pipes only, rare for targeted
  providers — but callers must still handle null.
- Gap-1 `listChildren` shares this channel (RESOLVED yes):
  same channel on the background TaskQueue; batching answers the
  small-call overhead question with it.

## 10. Recommendation

Ship 3a experimental on Android first with the iOS fd-open
alongside (same Dart code, trivial native open; macOS stubbed).
Keep the channel-chunks design as the documented rejected
alternative with its measured numbers, and JNI in second place
unless the plugin needs broad Java interop. Move every Android
control verb — existing verbs included — to a background TaskQueue
as a companion change: the current main-looper dispatch is the
slowest measured shape.

## Sources

Oldest first; every URL fetched 2026-09-30 with non-empty results
unless noted:

- https://pub.dev/api/packages/jni — `package:jni` latest is 1.0.3
  (stable); corrected the draft's 0.x claim.
- https://api.flutter.dev/flutter/services/MethodChannel-class.html —
  async method calls over binary encoding with a MethodCodec;
  framework channels guarantee FIFO ordering.
- https://developer.android.com/reference/android/content/ContentResolver —
  official `ContentResolver` API reference; `openFileDescriptor`
  / `openInputStream` signatures additionally verified in the
  compile SDK (`android-36/android.jar`).
- https://pub.dev/packages/meta — `package:meta` identity;
  `@experimental` verified present in the published artifact
  (pub-cache `meta-1.12.0`).
- `bench/fpw-pr67-transport-brief.md` (this repo, preserved
  2026-09-30) — the reviewing session's brief: emulator numbers,
  engine trace, AOSP provider analysis, per-claim verdicts.
- `bench/chanbench/` (this repo) — the benchmark app; `bench/
  table_emulator.txt` + `bench/runs_emulator.txt` its numbers.
- `bench/run_s24.log`, `bench/logcat_s24.log`,
  `bench/table_s24.txt` (this repo) — our S24 confirmation run,
  same app and matrix, 2026-09-30.
- https://raw.githubusercontent.com/flutter/engine/main/shell/platform/android/io/flutter/plugin/common/StandardMethodCodec.java —
  `encodeSuccessEnvelope` double copy (stream + direct buffer).
- https://raw.githubusercontent.com/flutter/engine/main/lib/ui/window/platform_configuration.cc —
  send-path `MallocMapping::Copy` (`:506`).
- https://raw.githubusercontent.com/flutter/engine/main/shell/platform/android/platform_view_android_jni_impl.cc —
  reply-path `MallocMapping::Copy` (`:538`).
- `packages/flutter/lib/src/foundation/serialization.dart`
  (Flutter 3.47.0 SDK, local) — `putUint8List` copies
  (`_append`), `getUint8List` is a view.
- https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/main/core/java/android/os/ParcelFileDescriptor.java —
  `getStatSize` returns -1 unless regular file or symlink.
