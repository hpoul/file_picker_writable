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
provider fd into Dart ownership; a small Dart `FdReader` (non-leaf
calls into the shared C shim, §5) reads into a caller-owned native
buffer and returns views consumed in place; `closeRead` closes the fd
with a `NativeFinalizer` backstop. Backpressure is structural (no
calls, no bytes); cancellation is `close`; multiplexing is session
fds. The isolate rule is load-bearing, not advisory: bytes must be
consumed in the helper isolate where they land (rows C3/C4 below).
Bounded exemption, shared with the driving consumer: one-shot reads
of ≤1MiB total may run on the root isolate (milliseconds of views,
no frame risk); anything larger MUST use a helper. Enforced in
debug mode: a reader on the root isolate (`RootIsolateToken`
present) that reads past 1 MiB fails an assertion.

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
handicap, ordering does not. The FFI rows ran with leaf libc
bindings; §5 prescribes non-leaf shim bindings instead — re-run
the FFI rows to confirm the delta is noise. Full tables plus
per-call latencies:
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
  // Explicit handoff: validates the scope is still acquired (loud
  // `scope-closed` otherwise — the last root-side check), returns
  // the sendable record, and kills the local copy in one call (a
  // SendPort send copies silently, so the dead-marking must be
  // explicit, never incidental). Throws StateError once a wrapper
  // was constructed on this copy (bytes already flow here — hand
  // off before wrapping, never after).
  ReadHandoff handoff();
}
// Plain ints + bools + strings: crosses isolates for free, in the
// same shape the driving consumer already sends. Private
// constructor: only handoff() makes one, so no forged record can
// adopt (and later close) a descriptor the VM owns.
class ReadHandoff {
  int get fd;
  bool get seekable;
  int? get length;
  String get scopeToken; // AcquiredScope.id, opaque; validated at handoff().
  // Provenance for errors/debug + attribution for helper control
  // calls. The helper performs no live check on it (see §5).
}

@experimental
Future<ReadSession> openRead({required AcquiredScope scope});
// Control call (channel): opens the provider fd, detaches it into Dart
// ownership, reports seekability + length. Never reads bytes.

@experimental
class FdReader {
  FdReader.fromSession(ReadSession session, {int bufferLength = 1 << 20}); // Same-isolate path.
  FdReader.fromHandoff(ReadHandoff handoff, {int bufferLength = 1 << 20}); // Helper-isolate path (also the root recovery path — see §4).
  // Sync FFI pread into the reader's buffer; returns a VIEW valid
  // until the next call (call-counted, never time-bound — awaits
  // between calls are safe). Consume in place (C1); copy only to
  // retain (C2 cost, documented). Empty view signals EOF. The
  // buffer is Dart-owned memory (`asTypedList` with a native free
  // as its finalizer), not part of the fd's cleanup record, so
  // every view keeps it alive: a view retained past the next call
  // or past close() shows later bytes, never freed memory.
  // (Corrected in review: the first sketch freed the buffer at
  // close and called a finalizer on the view impossible — that
  // only holds while one record owns both fd and buffer. Splitting
  // them removes the use-after-free on every path: close, GC of
  // the reader, and the self-close on the first EIO.)
  // Bounds: negative position/length ⇒ sync ArgumentError;
  // length > bufferLength ⇒ sync ArgumentError (single fixed
  // buffer — no silent clamp or resize); position at/past EOF ⇒
  // empty view (the EOF signal, not an error).
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
  C shim (close finalizer + `-errno` wrappers). Its build step is
  a Dart native-assets build hook (`hook/build.dart`, `CBuilder`
  from `native_toolchain_c`), not the podspec, the Swift package
  or Gradle: one build for every platform, bound with `@Native`,
  and it also runs under `flutter test`, so the VM tests exercise
  the real shim. (Implementation correction: the plan named a
  podspec and an Android plugin step. A gotcha found on the way:
  an app built before the hook existed can keep its cached
  `build_hooks` target even after `pub get`, and ship without the
  shim until `flutter clean`.) macOS and other stub platforms
  throw `UnsupportedError` — loud beats silent. Stubbed must also
  mean "builds": the hook skips Windows (the shim is POSIX C;
  `flutter test` on a Windows host runs the hook too), and every
  FFI type sits behind a conditional import (`dart.library.ffi`),
  since dart2js has no `dart:ffi` and one unconditional import
  would break every consumer's web build.
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
  other. Across isolates the shim enforces it too: adopted fds sit
  in a mutex-guarded table, so a second wrapper on a record that
  is still owned (consumed twice) is a `StateError`, not a second
  owner.
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
  a closed flag; a close whose liveness check fails still runs
  the native cleanup, then throws — the throw never skips the
  release. Recovery: only if the spawn itself throws
  (`IsolateSpawnException`) after `handoff()` does the root
  recover with `fromHandoff` on its own copy — the root is then
  the consuming isolate — and close normally. Any other failure
  is never recovered: the root cannot tell "the helper died
  before building its wrapper" from "it was killed after, and its
  finalizer already closed the fd", and adopting in the second
  case reads or closes a reused number. (Corrected in review: the
  first draft also recovered when the helper died early.) A kill
  before the helper's wrapper exists therefore leaks the fd —
  the accepted cost of never double-closing. If kill is ignored
  (no terminate capability) the helper stays owner —
  message-cancel, never the kill path.
- Finalizer placement: the `NativeFinalizer` MUST
  be attached by the wrapper constructed in the consuming isolate
  (finalizers run for the exiting isolate's own — verified in
  `isolate.cc`). Construct at most one `FdReader`/`FdWriter` per
  session, in the consumer; bare sessions never attach (a
  root-side wrapper GC'd mid-helper-read would close the live fd).
  Killable helpers use `Isolate.spawn` + `onExit` death
  confirmation (`Isolate.run` exposes no `Isolate` to kill; its
  errors are the non-kill path, finalizers already run). The
  finalizer token owns the fd's native owner record; the C shim
  releases it (unregister, close), and explicit close performs
  the same release after detaching the finalizer. The buffer has
  its own finalizer (see `readChunk`), so neither path leaks it.
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
  interrupted by close()`, then `EBADF`). Errors follow the
  directory verbs (implementation detail, settled in code): the
  persisted grant is checked first (revoked ⇒ `permission-lost`);
  any exception from the open runs the volume check first (a
  pulled stick is `volume-absent` whatever the provider threw);
  below the tree root the provider's `IllegalArgumentException`
  is the missing file (`not-found`). A directory is `not-a-file`
  (§6), however the provider answers: ExternalStorageProvider
  hands out a directory's fd, and `getStatSize` would call it a
  pipe, so `openRead` `fstat`s it; other providers refuse to open
  a directory, so after a failed open the row's MIME type is
  queried (no extra query on the happy path). (Corrected in
  review: the first implementation reported `errno-21` from the
  `fstat` only, so the answer depended on the provider.)
- No native handle registry: nothing is held past the call, so
  there is no session map, no native mutex, no leak surface. All
  Android complexity is fd acquisition + error mapping.
- Threading: control on one shared CONCURRENT background TaskQueue
  (uniform rule for every Android control verb, existing verbs
  included as a companion change — TaskQueue is per-channel, and
  a serial queue would stall control behind a slow listing).
  No ordering across in-flight control calls — callers sequence
  by awaiting. Rule: every `impl` field is touched on the main hop
  only — the pending pick, and the launch URLs that `init` drains
  and `onNewIntent` (on main) fills. So picker verbs
  (`openFilePicker`, `openFilePickerForCreate`, `openDirectory`)
  hop back to main for `startActivityForResult`, and `init` hops
  to main too (review-4 F3: off main it races `onNewIntent`, and a
  launch URL is dropped or handled twice). Background verbs use the
  application context, never the activity binding. The
  event-queue drain stays on main as today; MainScope is retained
  for the main-hop + drain. Bytes never touch the channel.

### iOS (Swift, inside a Gap-1a scope)

- `openRead` requires a live `AcquiredScope`, opens the path with
  `open(2)` `O_RDONLY`, `fstat`s for length, returns the fd. The
  registry keeps each token's target next to its hold (holds are
  on the root's scope, so a child's token would otherwise not
  know its file). Only a regular file is seekable with a length,
  as on Android; a directory is `not-a-file`; a failed `open` is
  `not-found` (ENOENT), `permission-lost` (EACCES/EPERM), else
  `errno-<n>`. The target is resolved at acquire: a file renamed
  between acquire and `openRead` is `not-found` (re-acquire after
  a listing).
  Reads are Dart FFI afterwards — but the scope discipline
  stays uniform: `FdReader` checks token liveness in Dart at
  construction and close, not per op (same-isolate path; the
  helper path validates at `handoff()`, see below), and use
  after release is loud
  `scope-closed` (the kernel would not re-check an open fd; the
  plugin does). Off main; results hop
  to main per the plugin's existing convention (TaskQueue is
  Android-only). macOS is stubbed (`UnsupportedError`) per the
  Gap-1a boundary decision.

### Dart FFI reader (both platforms)

- Dart binds the shared C shim's entry points (non-leaf — a
  cold-storage read can block, which strains the `isLeaf`
  contract; the transition cost is ~0.1% of a 192µs read); one
  reusable buffer per reader, Dart-owned (`asTypedList` with the
  shim's free as finalizer); views valid until the next call,
  memory-safe after it. The bench FFI rows used
  leaf libc bindings — re-run them against the non-leaf shim to
  confirm the delta is noise. The shim wraps `pread` / `read` /
  `pwrite` / `fsync` as `-errno` functions (one shared C shim,
  both gaps; `EINTR` retried inside): a separate `__errno` FFI
  call runs after Dart code has resumed, where a safepoint can
  intervene and hand back a stale value. The shim selects the
  read symbol per platform (`pread64` on Android, `pread` on
  Darwin — one Dart signature). The finalizer callback is a tiny
  native close entry (`void f(void*)`), not punned libc `close`
  (works on LP64, ABI-fragile).
- `errno` mapping: `EIO`/`ENXIO`/`ENODEV` after detach ⇒
  `permission-lost` (media detached — revoked grants do NOT fail
  open fds); `EBADF` ⇒ `session-closed` (use after close / double
  close — never a live fd). The set is to-be-confirmed on device
  (FUSE transports may surface `ENOTCONN`). Everything else stays
  loud under its own code per the exhaustiveness rule, as
  `errno-<n>` with `{domain: errno, code: n}` in details — n is
  the platform's own number, not portable (ENOTCONN is 107 on
  Linux/Android, 57 on Darwin). The first `permission-lost`
  closes the reader's fd at once, before throwing: a pulled
  volume can get the processes still holding descriptors on it
  killed (vold's unmount kills holders), so a dead read must not
  keep its fd for the caller's eventual `close`. Reads are
  synchronous and a reader never crosses isolates, so this cannot
  race. Every later call is `session-closed`, never an empty view
  that would read as a complete file: the consumer treats the
  first `permission-lost` as final for that reader. Other readers
  on the same volume keep their fds until their own next read.
- Helper channel access: the `FilePickerWritable()` singleton
  installs a Dart-side handler, which
  `BackgroundIsolateBinaryMessenger` refuses — so helpers that
  need control calls use a dedicated handler-free channel client
  (`ensureInitialized(rootToken)` + raw `MethodChannel` invoke, no
  listen) shipped by the plugin. Reads need none (implementation
  finding): `handoff()` checks the scope root-side and the helper
  only makes FFI calls, so the client moves to Gap 3, whose
  helper does make control calls. Token liveness is a Dart-side
  live-set of unreleased scope ids. Same-isolate `fromSession`
  checks membership at construction and close, not per op (a
  per-op round trip would add 20–80% per read); a mid-session
  release surfaces at close on that path. `handoff()` validates
  the scope root-side and carries the opaque token in the record
  (catches already-released); the helper performs no live check
  — its copy is a handoff-time snapshot, blind to a root-side
  mid-session release. The scope should stay acquired until
  close. (Softened in review from MUST: an open fd survives a
  release on both platforms, since neither kernel re-checks
  access on one, so an early release breaks no read. What it ends
  is the plugin's own bookkeeping, e.g. the iOS security scope
  behind any other access to those files.)

## 6. Error taxonomy

`permission-lost` (media detached incl. mapped `errno`; revoked
grants fail new opens while open fds keep reading), `not-found`,
`not-a-file` (`openRead` on a directory: the mirror of Gap 1's
`not-a-directory`, added in review), `seek-unsupported` (carrying
the native message), `session-closed` (use after close),
`scope-closed` (use after Gap-1a release; checked in Dart), and
`errno-<n>` for an unmapped errno (the platform's own n). Dart
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
- Results of the first implementation (2026-10-01):
  - VM tests (`test/fd_reading_test.dart`, real fds from libc,
    the real shim via the build hook): lifecycle, views, EOF,
    bounds, single owner, `fromSession` ↔ `closeRead` linkage, a
    helper reading through `Isolate.run`, the kill path
    (`Isolate.spawn` + kill, then the fd is closed — probed with
    `fcntl(F_GETFD)`, which never closes a reused number), and
    pipes (forward skip, backward `seek-unsupported`). After
    review also: a view read after close (Dart-owned buffer), a
    record consumed twice (`StateError`), short reads looped
    mid-stream (a pipe written in three timed parts), `errno-29`
    from a pipe reported seekable, the root-isolate budget
    assertion, and close detaching the finalizer (a closed reader
    collected by GC must not close the number a second reader got;
    verified to fail with the detach removed). The `EINTR` retry is
    not stubbed: it sits inside the C shim, below what Dart can
    inject.
  - The example's device run (`example/lib/device_checks.dart`,
    `FPW_AUTOCHECK`) on a 32 MiB fixture, iOS simulator and an API
    36 emulator (fixture pushed with adb): spot reads and a full
    helper read verified byte for byte, `closeRead` twice,
    `scope-closed` for an open and for a reader close after
    release, `not-a-file` for a directory, and on Android
    `/proc/self/fd` the same before and after (159/159), re-run on
    the review fixes. The same run on a physical iPhone XR (iOS
    18.7, debug build of the example, signed, so `fpw_fd.framework`
    embedding and signing hold on a device), at 086a6db: all of the
    above passed. Its timed reads (~10 GiB/s) are the page cache of
    a file written seconds before, not storage. The fixture was
    removed afterwards (`FPW_CLEANUP`).
  - The emulator caught what host and simulator could not: the
    first fix encoded the owner record's address as an int64, and
    Android heap pointers carry a tag in the top byte (negative as
    an int64), so every adopt read as a failure. Pointers now only
    ever cross FFI as pointers.
  - Throughput, warm cache, 1 MiB chunks through the non-leaf
    shim, emulator: 1.7–2.5 GiB/s on a quiet host (spawn
    included), in line with the C1 emulator row (2.2 GiB/s at 1M).
    A re-run under host load (load average ~8) gave 0.7–1.7 GiB/s
    timed inside the helper, with the pure-Dart verify loop slowed
    by the same factor: noise, not the shim. Emulator numbers are
    a prior only; the S24 re-run §3a asks for is still open, and
    so is the cold-cache gate.
  - Not run yet: media detach mid-read, revoked grant with an
    open fd, a pipe-backed provider, a Windows build. The last
    means the review's M3 fix (the hook returns early for
    Windows) is reasoned, not verified: it has never been compiled
    on Windows (skipped for now by the owner's decision), unlike
    M2's web fix, which a probe app built.

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
  over open/read/close for in-helper callers? RESOLVED yes
  (owner, 2026-10-02): `FdReader.readStream({start, end,
  chunkLength})` yields chunks the listener OWNS (one copy each:
  ~0.3 ms per MiB, 3–12% of a USB stick's pread, ~30% of a warm
  flash read), because a stream of views is a silent-wrong-output
  trap: the #74 review collected views through `toList`, `fold`,
  `expand`, `asyncMap`, broadcast streams, `listen(list.add)`,
  first/last-chunk fingerprints and slow sinks, and every one gave
  the right length with the wrong bytes. `FdReader.readViews` keeps
  the zero-copy stream as an opt-in, named apart so a search finds
  every consumer (in-place hashing, `writeStream`). Both run
  through a sync controller, read the first chunk after `listen()`
  returns and each next one only once the listener is ready (after
  `onData`, or after an `await for` body), yield to the event loop
  between chunks (a timer, not a microtask: a microtask loop
  starves a cancel message; 15–27 µs per chunk), and close the
  reader at the end, on an error, or on cancel (awaiting
  `cancel()` waits for the close). A stream owns its reader:
  `readChunk` or a second stream meanwhile is a `StateError`. The
  write half is `FdWriter.writeStream(Stream<List<int>>)`, which
  writes each chunk as it arrives and does not commit.
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
  framework channels guarantee FIFO ordering per channel on the
  platform thread; the shared concurrent TaskQueue gives that up
  (see §5).
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
