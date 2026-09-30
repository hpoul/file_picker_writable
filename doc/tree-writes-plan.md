# Tree writes without whole-file staging: evaluation & plan (Gap 3)

Status: proposal, for review. No commitments.
Date: 2026-09-30.
Transport decision revised 2026-09-30 after measurement (`bench/`, 2b §3).
Context: same consumer as the Gap-1/1a/2b plans — phone-side trip
storage. The move flow needs directory acquisition, folder creation,
progress-reporting stoppable file writes, recursive delete, and
rename/commit. This doc evaluates how `file_picker_writable` could
offer tree writes without the current whole-file stage-and-writeback
lifecycle, and recommends an approach. It also carries the directory
acquisition verb (R1) that all gap prototypes test against.
Companion docs: `tree-traversal-plan.md` (Gap 1),
`scope-registry-plan.md` (Gap 1a), `large-file-reads-plan.md` (Gap 2b).

## 1. Problem

Current contract: writes stage the whole file through temp and push it
back in one `writeFileWithIdentifier` call. Three gaps for a media
library:

- No progress, no stop: a GB clip writeback is an all-or-nothing
  blocking call. Cancellation means killing the whole operation with
  no cleanup contract.
- No tree verbs: no mkdir, no delete, no rename/move. The move flow
  (create tour folder, write clips, index swap, move-back cleanup,
  orphan sweep) cannot be expressed at all.
- No directory acquisition: nothing produces the directory identifier
  Gaps 1/1a/2b consume. (#20 is closed; acquisition is specified here,
  in our own spec — no external dependency.)

Goal: FFI write sessions with progress and abort, single-shot
tree verbs, and a directory picker — all without temp staging on the
write path, all under the Gap-1a scope discipline.

## 2. Platform realities (constraints, not choices)

- Android: `DocumentsContract` offers `createDocument`, `deleteDocument`
  (`deleteDocument` on a directory is recursive at the provider's
  discretion — behavior varies, so recursion is the plugin's job;
  see §5), `renameDocument` (returns a fresh URI), and
  `moveDocument` (same-authority only). Byte output is FFI `pwrite`
  on a detached fd from `openFileDescriptor(uri, "w")` — positional
  writes at explicit offsets, no shared stream position; pipes take
  sequential `write` (same rule as the 2b read side, mirrored).
- The create-then-stream pattern has a crash window: a file created
  but never committed is a partial the app must sweep. Abort deletes
  the partial; crash recovery is the app's orphan sweep (Gap-1
  listing already gives it the enumeration it needs).
- iOS: `FileManager` (`createDirectory`, `removeItem`, `moveItem`
  for rename/commit) for control, all under a held Gap-1a scope;
  bytes are FFI `pwrite` on an fd from `open(2)` — same session
  shape as the 2b read side, mirrored.
- MIME types on create are the caller's statement, not the plugin's
  guess: Android `createDocument` requires one, so the Dart verb takes
  it (with a documented default, not extension sniffing magic).
- Durability is `fsync` on a real fd — `flush()` on a provider
  stream does not fsync. `closeWrite` fsyncs where the fd is a
  file; pipes have no fsync and the session says so up front.
  Durability stops at the file: no `fsync(dirfd)` exists through
  SAF, so a rename may not stick on stick-pull — the consumer's
  swap repair already covers it.

## 3. Options evaluated

### 3a. FFI write sessions + single-shot tree verbs (RECOMMENDED)

`openWrite` hands back a detached fd; a Dart `FdWriter` (FFI `pwrite`/
`write`/`fsync`/`close`) streams bytes with progress as acknowledged
totals and stop as abort — mirroring the 2b read side (same
backpressure-by-construction, same multiplexing via session fds,
same helper-isolate rule: bytes are produced where they land).
mkdir/delete/move stay single-shot control verbs on the channel.
One new state machine (the write session); everything else is
stateless. A bulk copy then needs no native verb: fd→fd with
pread/pwrite in one helper isolate, at full speed, off the UI
thread.

### 3b. Whole-file writeback with progress callbacks (rejected)

Progress reporting on top of the current stage-and-push keeps the
worst parts: full temp staging per write, memory spike for GB clips,
and no meaningful stop (cancelling mid-push leaves provider state
undefined). Progress without bounded memory answers the wrong half.

### 3c. androidx DocumentFile wrapper (rejected)

`DocumentFile` is a thin convenience wrapper over the same
`DocumentsContract` calls §5 uses directly. It would add an AndroidX
dependency and its tree-walk semantics for no new capability — the
plugin needs five calls, not a framework.

### 3d. Push-model write streams (rejected)

Same rejection as 2b's EventChannel: an unbounded push stream buffers
behind a slow provider with no backpressure. Explicit acked writes
(each `writeChunk` FFI call returns the new total) keep the producer
bounded — the write side just inverts who holds the data, not the
control flow.

## 4. Proposed API (experimental)

```dart
@experimental
Future<FileInfo?> openDirectory();
// Picker for a directory. Null on cancel. The returned identifier
// feeds listChildren/acquire directly. Deliberately FileInfo —
// #20's DirectoryInfo/EntityInfo hierarchy is not adopted.
// fileName MUST be the picked folder's display label: callers name
// the pick in retry prompts before any acquire.

@experimental
class WriteSession {
  // Detached native fd owned by Dart, plus write progress.
  int get fd;            // Plain int: passes to a helper isolate for free.
  String get identifier; // Child identifier (abort-delete + close-stat need it).
  int get bytesWritten;  // Acknowledged total. Progress numerator.
  bool get canFsync;     // False for pipes: no fsync, and it says so.
}
// Handoff crosses fd + identifier; after handoff the sender's copy
// is dead (StateError on use — sync Dart, like ArgumentError);
// bytesWritten is meaningful on the owning copy only. Within one
// isolate, fromSession links wrapper↔session close-state (same as 2b).

@experimental
Future<WriteSession> openWrite({
  required AcquiredScope scope, // Scope of the PARENT directory.
  required String name,         // Created (fail-if-exists).
  String mimeType = 'application/octet-stream',
});
// Control call (channel): creates, opens, detaches the fd into Dart
// ownership. Never writes bytes.

@experimental
class FdWriter {
  FdWriter.fromSession(WriteSession session, {int bufferLength = 1 << 20});
  // Sync FFI pwrite at bytesWritten (positional; sequential write()
  // for pipes); stages through a reusable native buffer; returns the
  // new acknowledged total.
  int writeChunk(Uint8List bytes);
  // FFI fsync (iff requested && canFsync) + close, then channel stat.
  Future<ChildEntry> closeWrite({bool fsync = true});
  // FFI close, then channel delete of the partial. Idempotent.
  Future<void> abort();
}

@experimental
Future<ChildEntry> closeWrite(WriteSession session, {bool fsync = true}); // Commit, no-writer path.
@experimental
Future<void> abortWrite(WriteSession session, {bool closeFd = true}); // Delete partial, no-writer path. Idempotent.

@experimental
Future<ChildEntry> createDirectory({
  required AcquiredScope scope, // Scope of the parent directory.
  required String name,
});

@experimental
Future<void> deleteEntry({
  required String identifier, // Single-shot: scope handled internally.
  bool recursive = false,     // Non-recursive: checked-by-listing (best-effort).
});

@experimental
Future<ChildEntry> moveEntry({
  required String identifier,
  required AcquiredScope sourceParent, // Caller knows it from listing.
  required AcquiredScope newParent,
  String? newName,            // Null keeps the name (pure move).
});
// Rename is moveEntry with the same scope twice + newName. Returns a
// fresh entry: identifiers may change across the move.
```

Notes:

- Cross-platform from day one: identical Dart verbs; control on the
  channel (background TaskQueue), bytes via FFI on detached fds
  (Android: ContentResolver + `detachFd`; iOS: `open(2)` under the
  held scope). macOS and other stub platforms throw
  `UnsupportedError` — loud beats silent.
- Session/split discipline, same as 1/1a/2b: repeated byte access
  (`openWrite`…) takes a live scope; `deleteEntry` manages scope
  internally per call (single-shot). `createDirectory` takes the
  parent scope because callers creating N folders in a loop should
  not pay N acquires; `moveEntry` takes source + new parent scopes
  because the native move needs the source parent (see §5).
- Leaf-name rule (peer-confirmed): `name`/`newName` reject empty,
  `.`/`..`, and any `/` or NUL — one rule, both platforms (Android
  display names and iOS path components alike). Dart pre-checks
  and throws `ArgumentError`; native enforces with loud
  `invalid-name`. Violation is a caller bug, never provider
  variance. Providers may still clean legal names (Android FAT
  set): a create/rename whose returned name mismatches re-lists
  the parent — taken ⇒ `already-exists`, else `invalid-name`
  carrying the provider's actual name. The rule stays narrow so
  iOS (APFS allows the FAT set) is not over-restricted.
- Concurrency: `pwrite` is positional with no shared stream offset,
  so overlapping `writeChunk` calls cannot interleave — the
  per-session mutex question dissolves (same as the 2b read side).
  Totals stay deterministic because each call writes at and
  returns an explicit offset. (Pipe sessions use sequential
  `write` + Dart-tracked offset and serialize per-writer; pipes
  are the rare path. Control calls still complete FIFO.)
- Writes stage through a reusable native buffer (Dart heap bytes
  cannot pass to FFI directly): one user-space copy per chunk,
  ~C2 profile — still multiples of channel speed on device.
  Same single-owner fd rule as 2b reads (ownership transfers to
  the helper isolate; idempotent close per wrapper).
- Durability: `closeWrite` fsyncs iff requested AND `canFsync`
  (regular files); pipes skip fsync and the session says so up
  front. `fsync` defaults true — a forgotten flag costs slowness,
  not durability; bulk copies may pass `false` where
  verify-after-copy is the guarantee (exFAT flush cost is real) —
  the driving consumer keeps the default even for bulk.
- Kill story (same as 2b §4, write half): after kill, the dead
  helper's finalizer closed the fd — pass `closeFd: false` so
  `abortWrite` runs the delete-partial half only. `closeWrite`
  after kill is meaningless: abort, don't commit. The `closeFd` /
  `fsync` escape hatches live on the session-level verbs only;
  `FdWriter` methods run in the owning isolate and always take
  the full path.
- Fail-if-exists is the documented `openWrite` rule (peer
  re-confirmed, superseding truncate): an existing name is loud
  `already-exists`, so abort can never destroy an overwrite
  victim and crash partials stay identifiable for the orphan
  sweep. Callers needing overwrite delete first, deliberately.
  Atomic on iOS (`O_CREAT|O_EXCL`); best-effort on Android — no
  exclusive-create primitive exists, so a concurrent same-name
  create may slip past list-first when the provider returns the
  existing URI. Documented, not hidden.
- Non-recursive delete is best-effort on both platforms:
  emptiness is checked by listing first, but no atomic
  delete-if-empty primitive exists — a concurrently created
  child may be deleted anyway. Callers needing strictness must
  quiesce writers. The race window is disclosed, not hidden.
- Loud-on-taken-name is the documented `createDirectory` and
  `moveEntry` rule (peer-pinned): creating a folder or moving onto
  an existing sibling name throws `already-exists` — never a silent
  provider auto-rename. For create, a provider-renamed residue is
  an empty fresh entry and is deleted before throwing, so the loud
  outcome leaves no litter. For rename, a provider-renamed residue
  IS the user's file under a new name (`FileSystemProvider`
  renames the source onto it) — never deleted: rename it back,
  and if the rename-back fails throw `move-partial` (actual
  identifier in details). The returned `ChildEntry` always
  carries the actual name.
- `moveEntry` replace/atomicity contract (peer-pinned): no atomic
  replace exists on SAF — move onto a taken name is loud
  (`already-exists`), so callers implement delete-then-rename
  deliberately; the rename itself is best-effort atomic with a crash
  window (momentarily missing target) that the caller recovers
  through its own damaged state. Combined move+rename (parent
  change with `newName`): pre-check BOTH the intermediate and the
  final name, move, then rename; on rename failure attempt
  rollback (move back) and throw the rename failure; if rollback
  fails, throw loud `move-partial` carrying the actual identifier
  in details so the caller can locate and recover.
- `moveEntry` in v1 is same-provider only (what `moveDocument` and
  `FileManager.moveItem` both guarantee). Cross-provider move is
  copy + delete choreography — explicitly out of v1.
- Experimental mechanics: `@experimental` annotation plus a CHANGELOG
  notice, same as the other gaps. Additive API, no feature flag.

## 5. Native design

### Android (Kotlin)

- `openDirectory`: `ACTION_OPEN_DOCUMENT_TREE` (already verified
  present), `takePersistableUriPermission` on the tree URI (existing
  pattern), return `FileInfo` with the tree URI as identifier. No temp,
  no copies — acquisition never touches a byte.
- Control threading (all Android verbs here): one shared
  CONCURRENT background TaskQueue (TaskQueue is per-channel; a
  serial queue would stall control behind a slow listing), so
  slow provider calls never block frames. iOS keeps manual
  off-main dispatch (TaskQueue is Android-only).
- `openWrite` (control): validate the scope token (released ⇒ loud
  `scope-closed`); resolve parent scope → tree URI + parent
  document ID; list the parent first: an exact existing child ⇒
  loud `already-exists`, not attempted; otherwise `createDocument`
  (MIME type + name as passed) and verify the returned display
  name (mismatch ⇒ re-list: taken means auto-rename → delete the
  fresh residue, loud `already-exists`; not taken means
  FAT-cleaned → delete the residue, loud `invalid-name` with the
  actual name).
  `openFileDescriptor(uri, "w")`, `getStatSize` for `canFsync`,
  `detachFd()` into Dart ownership (never `fromFd` without
  retaining — finalizer trap, see 2b §5). Residual race (no
  exclusive-create primitive): a concurrent same-name create may
  slip past list-first when the provider returns the existing URI
  instead of auto-renaming — verify-after only catches the
  auto-rename case.
- `writeChunk`: pure Dart FFI (`pwrite` at `bytesWritten`, looped
  to full length; sequential `write` for pipes) — no channel, no
  native code. Staging copy into the reusable native buffer.
- `closeWrite`: FFI `fsync` (iff requested and `canFsync`) +
  `close`, then a channel control call stats the child into a
  `ChildEntry`. `abortWrite`: FFI `close` (skipped with
  `closeFd: false` on the kill path — the finalizer closed it),
  then a channel control call `deleteDocument`s the partial. Both
  idempotent; use-after-either is loud `session-closed`.
- `createDirectory`: list the parent first (taken name ⇒ loud
  `already-exists`, not attempted); `createDocument` with
  `MIME_TYPE_DIR`, then verify the returned display name matches
  the request: a mismatch re-lists — taken means auto-rename →
  delete the fresh residue, loud `already-exists`; not taken
  means FAT-cleaned → delete the residue, loud `invalid-name`
  with the actual name. The returned entry always carries the
  actual name.
- `deleteEntry`: resolve identifier; `deleteDocument`. Recursion is
  the plugin's own walk (list children via the Gap-1 path, delete
  depth-first), because provider-side recursive delete is
  discretionary — never trust it. Non-recursive on a non-empty
  directory is loud `directory-not-empty`, checked by listing first.
  Best-effort: no atomic delete-if-empty primitive — a child created
  after the listing may be deleted anyway (see §4).
- `moveEntry`: source parent comes from the passed scope — no
  `findDocumentPath` needed on any API level. List the target
  parent first; taken name is loud `already-exists`, not
  attempted. Same parent + new name → `renameDocument` (fresh URI
  returned); parent change → `moveDocument` (safe: the provider
  throws on collision, never renames), then `renameDocument`
  when `newName` is also given (combined case pre-checks both the
  intermediate and the final name; documented crash window between
  the two ops; rename failure attempts rollback, rollback failure
  throws `move-partial` with the actual identifier). After any
  rename, verify the returned name: mismatch ⇒ re-list. Taken
  (collision race) ⇒ rename back to the original — never delete,
  the residue is the user's file; rename-back failure ⇒
  `move-partial`. Not taken (provider cleaned the request, e.g.
  FAT set) ⇒ loud `invalid-name` with the actual name +
  identifier in details; the file stays at the cleaned name
  (rename-back would re-mangle). Always re-stat into a fresh
  `ChildEntry`. Cross-provider is loud `unsupported-move`, not
  attempted. The rename is best-effort atomic (no SAF replace
  primitive).

### iOS (Swift, inside Gap-1a scopes; needs the 1a registry)

- `openDirectory`: document picker in folder mode, bookmark the
  directory, same `FileInfo` encoding as file picks.
- `openWrite`: resolve parent scope URL + name, create the file
  atomically with exclusive semantics (`O_CREAT|O_EXCL` — taken
  name ⇒ loud `already-exists`, no TOCTOU); the fd IS the session
  payload (no `FileHandle` wrapper), `canFsync` always true
  (regular files). `writeChunk`/`closeWrite`/
  `abortWrite` are the same Dart FFI as Android (`pwrite`,
  `fsync`, `close`; abort removes the partial via `FileManager`).
  Off main; results hop to main per convention.
- `createDirectory`: `FileManager.createDirectory` under the
  passed-in parent scope (not per-call — §4). `deleteEntry` /
  `moveEntry`: `FileManager` under a per-call scope (single-shot
  verbs), with the plugin's own recursive walk for
  `deleteEntry(recursive: true)` — same rule as Android: never
  trust provider-side recursion. Non-recursive checks emptiness
  by listing first with the same best-effort race as Android
  (`FileManager.removeItem` is itself recursive). `FileManager` file-exists errors
  map to loud `already-exists` (nothing is created, so no residue
  cleanup); target names are pre-checked before `moveItem`, and
  move-then-rename is sequenced like Android (source parent from
  the passed scope, both names pre-checked, rollback attempt,
  `move-partial` on rollback failure). iOS `moveItem` throws on
  collision instead of auto-renaming, so no verify/rename-back
  is needed there.

## 6. Error taxonomy

Shared with Gaps 1/1a/2b: `permission-lost` (incl. mapped write
`errno` after detach, same rule as 2b), `not-found`,
`not-a-directory` (write/create under a file identifier),
`session-closed` (use after close/abort — same kind as 2b's read
sessions), `scope-closed`. New in this gap: `directory-not-empty`
(non-recursive delete of a non-empty directory),
`unsupported-move` (cross-provider move attempt),
`already-exists` (create/move/write onto a taken name),
`invalid-name` (leaf-name rule violation, or provider-cleaned
name — actual name in details), and `move-partial`
(combined move+rename with failed rollback; actual identifier in
details). Dart carrier
(pinned, all gaps): `PlatformException` with the taxonomy kind as
`code` and a details map carrying the native domain + code where
available. Exhaustiveness rule: anything outside the taxonomy stays
loud under its own native code. New kinds need a taxonomy review
before graduation.

## 7. Testing plan

- Dart unit, mocked control channels + real temp files (FFI runs
  in VM tests): session lifecycle, progress totals, abort
  idempotency, close-after-abort and write-after-close errors,
  fail-if-exists rule, rename-is-move shape with source parent,
  leaf-name `ArgumentError` pre-check, error mapping. No device
  needed.
- Android device: mkdir → chunked write with progress asserts →
  close → read back via Gap-2b fd reads (cross-gap round trip,
  mirroring the consumer's delete→write→close+fsync→verify order);
  abort mid-write and assert the partial is gone; delete recursive
  on a nested tree; move + rename incl. fresh-identifier use;
  create-after-pick visibility (R4 interplay); revoke mid-write and
  expect `permission-lost`; create a folder twice, open-write an
  existing name, and move onto a taken name, all expecting loud
  `already-exists` with no residue; pass `../x` and expect loud
  `invalid-name`; create `12:30 ride.mp4` on a FAT-backed provider
  and expect loud `invalid-name` with the actual name (not
  `already-exists`) and no residue; rename to a FAT-mangled name
  and expect loud `invalid-name` with the file intact at the
  cleaned name; move onto a taken name and expect the source
  untouched; force rename failure after a cross-parent move
  and expect rollback to the source or loud `move-partial`
  carrying the actual identifier; fsync durability (write, close,
  kill, read back intact); close with `fsync: false` honors the
  opt-out; kill the helper mid-write and abort with
  `closeFd: false`, asserting single close via `/proc/self/fd`;
  assert no temp growth on the write path and memory bounded to
  one native buffer during a 1GB write.
- iOS backend: same matrix once the 1a registry exists, plus
  stale-refresh interplay (move a file mid-session via Files).
- Acquisition: cancel returns null; picked tree feeds listChildren,
  acquire, and the write verbs without re-picking.

## 8. Graduation (experimental → stable)

Same bar as the other gaps, evaluated independently:

1. One production app ships it for a release cycle with no protocol
   changes.
2. 1GB write completes with memory bounded to one native buffer
   and returned totals arriving steadily — no stalls longer than
   the provider's own variance.
3. Observed failures all map into the taxonomy — no new error kinds
   needed in the wild.

## 9. Open questions

- Fail-if-exists for `openWrite` (RE-CONFIRMED 2026-09-30,
  peer-verified, superseding truncate): abort can never destroy
  an overwrite victim; same compatibility for the move flow.
- `fsync` cadence (RESOLVED direction, tuning open): fsync-on-close
  only for v1 — per-chunk fsync was specified when `flush` was
  thought free, but real fsync per chunk would serialize on
  storage. Opt-out flag (peer-confirmed): `fsync` defaults true;
  bulk copies pass false. Revisit if durability needs tighten.
- MIME-type default (CONFIRMED 2026-09-30, peer-verified):
  `application/octet-stream` dumb fallback; callers pass real MIMEs.
- Cross-provider move as a plugin verb (copy + delete choreography
  with progress)? Out of v1 by design — app-side fd→fd in a helper
  isolate covers it; revisit if a plugin verb is still wanted.
- `closeWrite` returns `ChildEntry` (CONFIRMED 2026-09-30,
  peer-verified): listing-shaped; the grant is the tree's.

## 10. Recommendation

Land the acquisition verb first — it unblocks every gap's
prototype — then single-shot tree verbs, then write sessions, all
experimental on Android first with iOS following once the 1a
registry exists (macOS stubbed). The write session mirrors the 2b
read session deliberately: detached fd, FFI bytes in a helper
isolate, control on the channel — one shape to review, two
directions. A bulk copy then needs no native verb: fd→fd in one
helper isolate (the requested native `copyEntry` is optional).

## Sources

APIs verified 2026-09-30 in the compile SDK
(`/Users/herbert/dev/android/sdk/platforms/android-36/android.jar`)
via `javap`:

- `android.provider.DocumentsContract`: `createDocument`,
  `deleteDocument`, `renameDocument` (returns fresh `Uri`),
  `moveDocument`, `copyDocument`, `isDocumentUri` all present.
- `android.content.Intent.ACTION_OPEN_DOCUMENT_TREE` present
  (verified for the Gap-1 plan).
- `FileManager.copyItem` / `removeItem` already used in
  `ios/.../FilePickerWritablePlugin.swift` (this repo) —
  `createDirectory` / `moveItem` are the same class, same pattern.
- Gap-1/1a/2b plan Sources (this session / 2026-09-30):
  `DocumentsContract` tree reads, MethodChannel semantics,
  `@experimental` in `package:meta`.
- `bench/fpw-pr67-transport-brief.md`, `bench/table_s24.txt`
  (this repo): the byte-path evidence; 2b Sources carry the full
  trace.
