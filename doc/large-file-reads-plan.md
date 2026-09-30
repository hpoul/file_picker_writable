# Large-file reads without temp copies: evaluation & plan

Status: proposal, for review. No commitments.
Date: 2026-09-30.
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
footprint, cancellable, with random access where the provider allows it.

## 2. Platform realities (constraints, not choices)

- Android SAF tree/document URIs have no filesystem path. `dart:io`
  File access is impossible, permanently.
- Provider file descriptors are often pipes or sockets: sequential-only,
  short reads, no seek. This varies by provider (local vs USB-OTG vs
  cloud). Seekability is a runtime property to report, never an
  assumption.
- iOS: scoped URLs *are* directly readable once the scope is held
  (open-in-place grant, app-scope bookmark). `dart:io` works; the only
  work is scope lifetime plus stale handling. (macOS is stubbed for
  these gaps — see the Gap-1a plan.) Gap 1a therefore exposes the
  path on Apple, so small one-shot reads use `dart:io` directly and
  chunk sessions are reserved for large reads.
- Copies are unavoidable and irrelevant. Every transport copies each
  byte 1–4 times at ~10–20 GB/s memory bandwidth; provider and storage
  throughput (10–100 MB/s) dominates wall time. Optimize for
  non-blocking behavior and debuggability, not copy count. True
  zero-copy needs `mmap` on real files — fails on pipes, needs length
  up front, `SIGBUS` risk on truncation — explicitly out of scope.

## 3. Options evaluated

### 3a. Pull-model chunks over MethodChannel (RECOMMENDED)

Dart pulls fixed-size chunks by explicit position; native serves them
from the provider (Android) or a scoped slice read (iOS).
Backpressure is structural (no pulls, no bytes); cancellation is
`closeRead`; multiplexing is session ids. No new dependencies, stable
APIs only, all Android complexity in one Kotlin file with coroutines.

### 3b. EventChannel push stream (rejected)

A push stream buffers behind a slow reader with no backpressure —
gigabytes queued in memory is the failure mode this whole proposal
exists to avoid.

### 3c. package:jni direct interop (not recommended)

Same bytes as 3a with the same worker-isolate requirement (calls block
the Dart thread), plus generated bindings checked into the repo and
Java-exception mapping. (An earlier draft cited 0.x API churn;
corrected 2026-09-30 after checking pub.dev: `package:jni` is at
1.0.3 and stable, so that objection is withdrawn. The remaining case
against JNI is machinery weight for identical bytes.) It removes ~100
lines of Kotlin at the cost of a heavier Dart side. Revisit if the
plugin ever needs *broad* Java interop (driving libraries with no
Dart equivalent) rather than byte shoveling.

### 3d. dart:ffi fd handoff (rejected)

Pipes kill the seeking that would justify it; blocking still needs
isolate machinery; fd lifetime has no destructors behind it (leak =
fd-table exhaustion in a media library); error surface is raw `errno`;
and the plugin would own a reimplemented file API. Fewest copies,
worst everything else.

### Overhead note (why 3a over 3c despite JNI's lower call cost)

Per-call overhead is ~µs (JNI) vs ~0.1–1ms (channel) — real, roughly
100x relative. It does not change throughput here: at ≥256KB chunks
both are memcpy/storage-bound, and the provider runs an order of
magnitude below either transport. Channels *are* JNI plus a thin codec
under the hood; there is no cliff. Where small-call overhead would
bite (e.g. per-child metadata across a large tree) the cure is API
design — batch it in one call — not transport choice. If a benchmark
ever implicates the transport, the pull-model API below is
transport-agnostic and the backend can move without touching callers.

## 4. Proposed API (experimental)

```dart
@experimental
class ReadSession {
  // Opaque native handle plus what the backend reported.
  String get id;
  bool get seekable; // false for pipes: sequential only.
  int? get length;   // null when the provider won't say.
}

@experimental
Future<ReadSession> openRead({required AcquiredScope scope});
// Scope comes from Gap-1a acquire(); openRead never acquires internally.

@experimental
Future<Uint8List> readChunk(ReadSession session, int position, int length);
// Empty list signals EOF. Short reads allowed (pipes).

@experimental
Future<void> closeRead(ReadSession session); // Idempotent.
```

Notes:

- Cross-platform from day one: identical Dart verbs; Android serves
  provider chunks, iOS serves scoped `FileHandle` slice reads inside
  the passed-in scope. macOS and other stub platforms throw
  `UnsupportedError` — loud beats silent.
- Small one-shot reads on Apple (index files, fingerprint hashes)
  should use `AcquiredScope.path` plus `dart:io` directly, not an
  `openRead` session. Sessions are for large reads where chunking,
  cancellation, and multiplexing earn their keep.
- Chunk guidance: 256KB–1MB default; document that this amortizes
  call overhead and bounds memory either way.
- Experimental mechanics: `@experimental` annotation plus a CHANGELOG
  notice. Additive API, so no feature flag is needed; the annotation
  keeps breaking the protocol in a minor honest until graduation.

## 5. Native design

### Android (Kotlin)

- Session registry: id → open handle, guarded for concurrent sessions.
- `openRead`: validate the scope token (released ⇒ loud
  `scope-closed`), resolve the scope's identifier to URI; prefer
  `openAssetFileDescriptor` (offset + length known ⇒ seekable);
  fall back to `openInputStream` (sequential). Report `seekable` and
  `length?` honestly per handle.
- `readChunk`: serve up to `length` bytes at `position`. Backward
  seek on a non-seekable handle is a loud `seek-unsupported` error,
  not silent reopen-and-skip: the cost must stay visible.
- `closeRead`: close handle, drop session, idempotent. In-flight
  chunks may still complete; document it (v1 simplicity over
  mid-read cancellation).
- Threading: everything on `Dispatchers.IO`. MethodChannel handlers
  arrive on the platform thread — dispatch, never block it.

### iOS (Swift, inside a Gap-1a scope)

- `openRead` requires a live `AcquiredScope` and stats the file,
  holding a `FileHandle` for the session; `readChunk` seeks + reads
  off main; `closeRead` closes the handle. Scope lifetime stays with
  the caller — sessions never acquire or release. Results/errors hop
  to main per the plugin's existing convention. macOS is stubbed
  (`UnsupportedError`) per the Gap-1a boundary decision.

## 6. Error taxonomy

`permission-lost` (grant revoked, media detached), `not-found`,
`seek-unsupported` (carrying the native message),
`session-closed` (use after close), `scope-closed` (use of a
released Gap-1a scope). Dart carrier (pinned, all gaps):
`PlatformException` with the taxonomy kind as `code` and a details
map carrying the native domain + code where available, so callers
can tell "detached" from "broken". Exhaustiveness rule: anything
outside the taxonomy stays loud under its own native code — unknown
failures are never coerced into a taxonomy kind.

## 7. Testing plan

- Dart unit, mocked channels (existing harness): session lifecycle,
  EOF and short-read semantics, close idempotency, error mapping,
  seekable vs sequential behavior. No native code needed.
- Android device: large files from local + USB-OTG providers;
  assert no temp growth (cache dir size before/after), cancel
  mid-read, detach mid-read and expect `permission-lost`, backward
  seek on a pipe and expect `seek-unsupported`.
- Benchmarks (pre-graduation, decide the transport question with
  numbers): throughput vs file size and provider, per-chunk latency
  distribution, memory ceiling during a 1GB sequential read.
  Expected: provider-bound, not transport-bound.
- iOS backend: scoped-read correctness plus interplay with
  stale-refresh once acquire/release exists.

## 8. Graduation (experimental → stable)

All three, then drop `@experimental` in a minor:

1. One production app ships it for a release cycle with no protocol
   changes.
2. Benchmarks meet targets (suggested: ≥80% of raw provider
   throughput, memory bounded to ~2 chunks in steady state).
3. Observed failures all map into the taxonomy — no new error kinds
   needed in the wild.

## 9. Open questions

- Exact default chunk size? Measure; start at 512KB.
- Dart-side convenience: a `Stream<Uint8List>` wrapper over
  open/read/close for sequential callers? Probably yes, thin.
- Session GC: explicit close only, or phantom-based auto-close as a
  backstop? Lean explicit + idempotent for v1.
- How often is `length` null in practice? Measure during prototype;
  decides whether callers must always handle unknown length.
- Should Gap-1 tree traversal (`listChildren` metadata) share this
  channel? Yes — batch it there and the small-call overhead question
  disappears with it.

## 10. Recommendation

Ship 3a experimental on Android first, prototype-measured, with the
Dart API shaped cross-platform so the iOS backend slots in unchanged
(macOS stubbed). Keep JNI (a closer second since its 1.0) and FFI off
the table unless benchmarks implicate the transport — expected: never
for sequential reads.

## Sources

Exact URLs inspected for this plan (all fetched 2026-09-30,
non-empty results):

- https://pub.dev/api/packages/jni — `package:jni` latest is 1.0.3
  (stable); corrected the draft's 0.x claim.
- https://api.flutter.dev/flutter/services/MethodChannel-class.html —
  async method calls over binary encoding with a MethodCodec;
  framework channels guarantee FIFO ordering.
- https://developer.android.com/reference/android/content/ContentResolver —
  official `ContentResolver` API reference; `openAssetFileDescriptor`
  / `openInputStream` signatures additionally verified in the
  compile SDK (`android-36/android.jar`).
- https://pub.dev/packages/meta — `package:meta` identity;
  `@experimental` verified present in the published artifact
  (pub-cache `meta-1.12.0`).
