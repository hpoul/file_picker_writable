# Tree writes without whole-file staging: evaluation & plan (Gap 3)

Status: proposal, for review. No commitments. In implementation:
R1 (`openDirectory`) shipped with Gap 1a (#68); the single-shot
tree verbs (`createDirectory`, `deleteEntry`, `moveEntry`) are
PR 4; write sessions (`openWrite`, `FdWriter`) follow in PR 5.
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
  // Explicit handoff: validates the scope is still acquired (loud
  // `scope-closed` otherwise — the last root-side check), returns
  // the sendable record, and kills the local copy in one call (a
  // SendPort send copies silently, so the dead-marking must be
  // explicit, never incidental). Throws StateError once a wrapper
  // was constructed on this copy (bytes already flow here — hand
  // off before wrapping, never after).
  WriteHandoff handoff();
}
// Plain ints + strings: crosses isolates for free, in the same shape
// the driving consumer already sends.
class WriteHandoff {
  int get fd;
  String get identifier;
  bool get canFsync;
  String get scopeToken; // AcquiredScope.id, opaque; validated at handoff().
  // Provenance for errors/debug + attribution for helper control
  // calls. The helper performs no live check on it (see 2b §5).
}
// After handoff the sender's copy is dead for FD USE (byte ops, fd
// close ⇒ sync StateError, like ArgumentError — fail-fast beats
// silent double-close); bytesWritten is meaningful on the owning
// copy only. Identifier-keyed control that never touches the fd
// (abortWrite with closeFd: false on the kill path) stays callable
// on the dead copy. Within one isolate, fromSession links
// wrapper↔session close-state (same as 2b).

@experimental
Future<WriteSession> openWrite({
  required AcquiredScope scope, // Scope of the PARENT directory.
  required String name,         // Created (fail-if-exists).
  String mimeType = 'application/octet-stream',
});
// Control call (channel): creates, opens, detaches the fd into Dart
// ownership. Never writes bytes. Keep the default for
// `.writing`/`.part`/marker files — a real MIME may append its
// extension (see §4).

@experimental
class FdWriter {
  FdWriter.fromSession(WriteSession session, {int bufferLength = 1 << 20}); // Same-isolate path.
  FdWriter.fromHandoff(WriteHandoff handoff, {int bufferLength = 1 << 20}); // Helper-isolate path (also the root recovery path — see §4).
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
Future<void> abortWrite(WriteSession session, {bool closeFd = true}); // Delete partial, no-writer path. Idempotent; gone partial is success. Kill path: closeFd: false on the fd-dead copy (identifier-keyed, never touches the fd).

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
- Scope-liveness mechanics, same as 2b: a Dart-side live-set of
  unreleased scope ids; same-isolate `fromSession` checks at
  construction and close. `handoff()` validates root-side and
  carries the opaque token; the helper performs no live check
  (handoff-time snapshot). The scope MUST stay acquired until
  close (caller obligation on the helper path).
- Leaf-name rule (peer-confirmed): `name`/`newName` reject empty,
  `.`/`..`, and any `/` or NUL — one rule, both platforms (Android
  display names and iOS path components alike). Names starting
  with `.` are ordinary names (`.howitwent`, `.writing`, `.prev`
  all pass); nothing filters them. Dart pre-checks
  and throws `ArgumentError`; native enforces with loud
  `invalid-name`. Violation is a caller bug, never provider
  variance. Providers may still clean legal names (AOSP
  FileSystemProvider-based providers sanitize unconditionally,
  regardless of backing fs, so the FAT set is the shape, not the
  precondition — confirmed on device 2026-10-01, API 36 emulator:
  `12:30 ride` is stored as `12_30 ride` on internal storage and
  on a vfat card alike).
  Separately, `createDocument` may append the MIME's own
  extension when the name's suffix doesn't map to it (memory of
  AOSP, confirm on device) — `.howitwent` + `application/json`
  may land as `.howitwent.json`: a create/rename whose returned
  name mismatches looks up the REQUESTED name — taken ⇒
  `already-exists` (the provider auto-renamed after a concurrent
  create), else `invalid-name` carrying the provider's actual
  name. (Corrected in implementation: the draft said "looks up
  the returned name", which always hits — it is the residue
  itself.) Callers writing `.writing`/`.part`/marker files
  keep `application/octet-stream` (the default), under which
  names survive. The rule stays narrow so iOS (APFS allows the
  FAT set) is not over-restricted.
- Concurrency: `pwrite` is positional with no shared stream offset,
  so overlapping `writeChunk` calls cannot interleave — the
  per-session mutex question dissolves (same as the 2b read side).
  Totals stay deterministic because each call writes at and
  returns an explicit offset. (Pipe sessions use sequential
  `write` + Dart-tracked offset and serialize per-writer; pipes
  are the rare path.) No ordering across in-flight control calls
  on the shared concurrent queue — callers sequence by awaiting.
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
  helper's finalizer closed the fd — the root calls `abortWrite`
  on its fd-dead copy with `closeFd: false`, which stays legal
  because that path keys the delete by identifier and never
  touches the fd. `closeWrite`
  after kill is meaningless: abort, don't commit. The `closeFd` /
  `fsync` escape hatches live on the session-level verbs only;
  `FdWriter` methods run in the owning isolate and always take
  the full path. Recovery: if `Isolate.spawn` throws after
  `handoff()` (or the helper dies before its wrapper exists),
  the root recovers with `fromHandoff` on its own copy and
  closes/aborts normally (fd still open — nothing attached a
  finalizer yet). A kill in that window leaks the fd.
- Fail-if-exists is the documented `openWrite` rule (peer
  re-confirmed, superseding truncate): an existing name is loud
  `already-exists`, so abort can never destroy an overwrite
  victim and crash partials stay identifiable for the orphan
  sweep. Callers needing overwrite delete first, deliberately.
  Atomic on iOS (`O_CREAT|O_EXCL`); best-effort on Android — no
  exclusive-create primitive exists, so a concurrent same-name
  create may slip past lookup-first when the provider returns the
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
  pattern), return `FileInfo` with the tree URI as identifier and
  the tree root's display name as `fileName` (queried through
  `buildDocumentUriUsingTree`; a bare tree URI is not queryable).
  No temp, no copies — acquisition never touches a byte.
- Control threading (all Android verbs here): one shared
  CONCURRENT background TaskQueue (TaskQueue is per-channel; a
  serial queue would stall control behind a slow listing), so
  slow provider calls never block frames. No ordering across
  in-flight control calls — callers sequence by awaiting.
  Every `impl` field is touched on the main hop only (the pending
  pick, and the launch URLs `init` drains and `onNewIntent`
  fills), so the pickers and `init` hop to main — see 2b §5.
  iOS keeps manual off-main dispatch (TaskQueue is Android-only).
- `openWrite` (control): validate the scope token (released ⇒ loud
  `scope-closed`); resolve parent scope → tree URI + parent
  document ID; `lookupChild` first (Gap 1 — one query, not a
  listing): a hit ⇒ loud `already-exists`, not attempted;
  otherwise `createDocument`
  (MIME type + name as passed) and verify the returned display
  name (mismatch ⇒ look up the requested name, see §4: hit means
  auto-rename → delete the fresh residue, loud `already-exists`;
  miss means provider-cleaned → delete the residue, loud
  `invalid-name` with the actual name).
  `openFileDescriptor(uri, "w")`, `getStatSize` for `canFsync`,
  `detachFd()` into Dart ownership (never `fromFd` without
  retaining — finalizer trap, see 2b §5). Residual race (no
  exclusive-create primitive): a concurrent same-name create may
  slip past lookup-first when the provider returns the existing
  URI instead of auto-renaming — verify-after only catches the
  auto-rename case.
- `writeChunk`: pure Dart FFI (`pwrite` at `bytesWritten`, looped
  to full length; sequential `write` for pipes) — no channel.
  Staging copy into the reusable native buffer; bytes longer
  than the buffer loop stage+write (no size cap — unlike the read
  side's fixed view, a write chunk is never retained). 0 from
  `write` / `pwrite` is loud under `ENOSPC` (native errno domain,
  code 28, `synthesized: true` in details — the volume returned
  0, never the errno; the failure shape is ENOSPC's), never loop
  progress (a FUSE-full volume returns 0; treating it as progress
  spins past the cancel check forever).
- `errno` capture: `pwrite` / `fsync` go through the 2b §5
  `-errno` shims (one shared native shim, `EINTR` retried
  inside) — never a separate `__errno` FFI call after Dart
  resumes. Maps into the §6 taxonomy.
- `closeWrite`: FFI `fsync` (iff requested and `canFsync`) +
  `close`, then a channel control call stats the child into a
  `ChildEntry`. `abortWrite`: FFI `close` (skipped with
  `closeFd: false` on the kill path — the finalizer closed it),
  then a channel control call `deleteDocument`s the partial. Both
  idempotent; use-after-either is loud `session-closed`. A close
  whose liveness check fails still runs the native cleanup (fd +
  buffer), then throws — same rule as 2b.
  Explicit close/abort and the finalizer backstop all release the
  fd + `malloc` buffer as one native cleanup record (same rule as
  2b — a closing fd alone would leak the buffer on the kill path).
- `createDirectory`: `lookupChild` first (taken name ⇒ loud
  `already-exists`, not attempted); `createDocument` with
  `MIME_TYPE_DIR`, then verify the returned display name matches
  the request: a mismatch looks up the requested name — hit means
  auto-rename → delete the fresh residue, loud `already-exists`;
  miss means provider-cleaned → delete the residue, loud
  `invalid-name` with the actual name. The returned entry always
  carries the actual name. (Implemented in PR 4; on device the
  `invalid-name` path leaves no residue, internal and vfat.) The
  residue is deleted only when provably fresh — a directory with
  no children (#71 review M3): a provider that sanitizes AND hands
  back the existing folder for the cleaned name would otherwise
  get the user's folder deleted. ExternalStorageProvider always
  creates a new one (`buildUniqueFile`, then `mkdir`); anything
  else is kept and named in the details (`residue: kept`).
- `deleteEntry`: resolve identifier; `deleteDocument`. A gone
  identifier is success on every delete path (idempotent; the
  consumer's delete-if-present shape) — never loud `not-found`.
  Recursion is the plugin's own walk (list children via the
  Gap-1 path, delete depth-first), because provider-side
  recursive delete is discretionary — never trust it.
  Non-recursive on a non-empty directory is loud
  `directory-not-empty`, checked by listing first.
  Best-effort: no atomic delete-if-empty primitive — a child created
  after the listing may be deleted anyway (see §4). Gone must be
  PROVEN, because it reports success (#71 review M1): a dead
  provider's query also returns null (`ContentResolver.query`
  swallows the `RemoteException`), and a failing stick throws other
  `IllegalArgumentException`s ("Failed to canonicalize"). So on
  ExternalStorageProvider gone is only the tree check's "Missing
  file for" with the nearest existing ancestor a live directory;
  on other providers a null row counts only while the tree root
  still answers; anything else stays loud, and a detached volume
  is `volume-absent`. The walk visits each document once and stops
  at 256 levels, against an opaque provider whose graph loops
  (review S5; links cannot exist on ExternalStorageProvider's
  volumes, see below, and one pointing out of the pick would fail
  the provider's own canonicalizing tree check, loudly). What the
  proof cannot see (re-review lows, accepted): "Missing file for"
  is `File.exists()` false, which a stat error (EIO on a dying
  stick) also gives, so an entry whose parent still lists but
  whose own stat fails reads as gone; SAF cannot tell the two
  apart. Third-party providers built on FileSystemProvider throw
  the same exception, but the rule keys on ExternalStorageProvider's
  authority (the ancestor walk needs its path-shaped IDs), so a
  gone-delete there is falsely loud — nothing is lost. A walk
  that fails partway (an error, or the 256-level cap) leaves the
  part already deleted; the Dart doc says so. A picked root — a tree's own root, or
  a single-document pick (not a tree URI) — is `root-protected`
  (§6, the owner's decision 2026-10-01): one wrong identifier must
  not take a whole pick with it. "Root" is decided by shape, not by
  string equality: ExternalStorageProvider resolves IDs through the
  file system, so `primary:Trips/`, `primary:Trips/.` or
  `primary:trips` (case-insensitive storage) may name the root
  itself, and a recursive delete of one would empty the pick. An
  entry counts as below the root only as the tree ID, its
  separator, then leaf names (`StorageVolumes.isStrictlyBelow`;
  verified on device: all three spellings refused). A component
  FAT would strip to nothing (`.. `, `. .`, `...`: trailing dots and
  spaces) is refused as well, since `x/.. ` could then name the
  root. On the API 36 emulator `fpw-device-fixture/.. ` lists as
  `not-found` on internal and vfat storage alike (not stripped),
  so this is defense in depth, not an observed escape. Opaque
  providers fall back to ID equality, which is NOT exhaustive:
  DownloadStorageProvider's root `downloads` is also named by
  `raw:<public Download dir>`, and its tree check accepts that.
  The plugin never mints such an ID; a caller would have to build
  it by hand. So `root-protected` is exhaustive on
  ExternalStorageProvider and iOS only (#71 review S3). The other route to the root,
  a symlink inside the tree pointing back at it, cannot arise on
  shared storage: `ln -s` there is refused even to the adb shell
  user, on emulated and vfat volumes alike (API 36 emulator).
- `moveEntry`: source parent comes from the passed scope — no
  `findDocumentPath` needed on any API level. The entry must sit
  directly in it (`not-found`, `reason: not-a-child`; derived
  from the path-shaped ID on ExternalStorageProvider, by listing
  elsewhere), and a picked root is `root-protected`. `lookupChild`
  the target parent first; taken name is loud `already-exists`,
  not attempted. On ExternalStorageProvider that lookup ignores
  case, so a case-only rename (`trip` → `Trip`) is
  `already-exists`: the file system calls the name taken, by the
  entry itself. Same parent + new name → `renameDocument` (fresh URI
  returned); parent change → `moveDocument` (safe: the provider
  throws on collision, never renames), then `renameDocument`
  when `newName` is also given (combined case pre-checks both the
  intermediate and the final name; documented crash window between
  the two ops; rename failure attempts rollback, rollback failure
  throws `move-partial` with the actual identifier). After any
  rename, verify the returned name: mismatch ⇒ look up the
  requested name. Hit (collision race) ⇒ rename back to the
  original — never delete, the residue is the user's file;
  rename-back failure ⇒ `move-partial`. Miss (provider cleaned
  the request, e.g. FAT set) ⇒ rename back to the original as
  well — the original
  name was already stored once, so it should land clean; verify,
  `move-partial` if it does not — then loud `invalid-name` with
  requested + actual (== original) names in details.
  Rename-back failure ⇒
  `move-partial` here too: an exception path must never silently
  move the user's file. In the combined case both branches
  additionally move the file back to the source parent after the
  rename-back (a bare rename-back would leave the source moved,
  contradicting the rollback contract); either restoration step
  failing ⇒ `move-partial` with the actual identifier. The
  rollback moves from wherever the rename back left the entry
  (its URI may change twice on ID-changing providers), and never
  runs on a guess: a volume that goes away while a landed rename
  is verified is `volume-absent` with `state: unknown` and both
  candidate identifiers, not a rollback naming the wrong place
  (#71 review S1/S2). Always re-stat into a fresh
  `ChildEntry`. Cross-provider is loud `unsupported-move`, not
  attempted — and so is a move across ExternalStorageProvider
  volumes (internal ↔ stick: same provider, but `moveDocument`
  there is a `rename(2)` that cannot cross file systems; checked
  by the IDs' volume tags, confirmed on device). The rename is
  best-effort atomic (no SAF replace primitive).

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
  passed-in parent scope (not per-call — §4). `deleteEntry`:
  `FileManager` under a per-call scope (single-shot verb), with
  the plugin's own recursive walk for
  `deleteEntry(recursive: true)` — same rule as Android: never
  trust provider-side recursion. `moveEntry`: `FileManager`
  under the passed source + new parent scopes (same as Android —
  never per-call). Non-recursive checks emptiness
  by listing first with the same best-effort race as Android
  (`FileManager.removeItem` is itself recursive). The walk removes
  symlinks as links and never follows them, pinned by a host test
  (`ios/test/TreeWalkTests.swift`: links out to a sibling with a
  canary, and one back to the root; verified to fail when the walk
  follows links). (Corrected in review S4: an earlier sentence said
  the device fixture's `out -> ../..` proved this; the tree checks
  never reach it.) Before deleting or moving, the entry's real path
  (`realpath(3)`, or for a link its directory's plus its name) must
  lie strictly below the root's (#71 review M2): containment is
  otherwise textual plus symlinks, and this closes any alias the
  file system resolves. A path component FAT would strip to
  nothing is refused as on Android. The scope directories (a
  create's parent, both ends of a move) are asked again by real
  path at the call, not only at acquire: one replaced by a
  symlink pointing out of the root since is `not-found`
  (`outside-root`) (#71 re-review S-B). Accepted windows: a
  directory swapped for a link between the real-path check and
  the walk (only fd-relative `openat`/`unlinkat` with
  `O_NOFOLLOW` would close it), and a new name FAT would strip
  (`a.`) landing under the stripped name on a volume that strips
  — inside the parent, though the returned entry names the
  request. `FileManager` file-exists errors
  map to loud `already-exists` (nothing is created, so no residue
  cleanup); the target name is pre-checked before `moveItem`.
  Implementation correction: a move and a rename are ONE
  `moveItem` to `newParent/newName` — a single `rename(2)` on one
  volume, so there is no intermediate state, no rollback and no
  `move-partial` on iOS (the draft sequenced it like Android).
  A move across volumes is `unsupported-move` (the volume
  identifiers differ): `moveItem` would silently copy and delete
  there. The scope registry keeps each token's resolved
  identifier, so a new entry's identifier is minted from the
  parent's root bookmark and path, exactly as a listing would.
  iOS `moveItem` throws on collision instead of auto-renaming,
  so no verify/rename-back is needed there.

## 6. Error taxonomy

Shared with Gaps 1/1a/2b: `permission-lost` (incl. mapped write
`errno` after detach, same rule as 2b), `not-found`,
`not-a-directory` (write/create under a file identifier),
`session-closed` (use after close/abort — same kind as 2b's read
sessions), `scope-closed`. New in this gap: `directory-not-empty`
(non-recursive delete of a non-empty directory),
`unsupported-move` (cross-provider or cross-volume move attempt),
`already-exists` (create/move/write onto a taken name),
`invalid-name` (leaf-name rule violation, or provider-cleaned
name — `requested` and `actual` in details), `move-partial`
(Android combined move+rename with failed rollback; actual
identifier in details), and `root-protected` (added in PR 4 by
the owner's decision: `deleteEntry`/`moveEntry` on a picked
root). Write verbs on a read-only Android tree grant
(`openDirectory` accepts one) are `permission-lost` with
`reason: read-only`. Dart carrier
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
  expect the write to keep going (open fds survive revoke — same
  as 2b) with `permission-lost` at the next `closeWrite` stat or
  `openWrite`; create a folder twice, open-write an
  existing name, and move onto a taken name, all expecting loud
  `already-exists` with no residue; pass `../x` and expect loud
  `invalid-name`; create `12:30 ride.mp4` on internal storage
  (FileSystemProvider-based providers sanitize regardless of
  backing fs — confirm on device) plus a FAT/USB-OTG variant,
  expecting loud `invalid-name` with the actual name (not
  `already-exists`) and no residue; rename to a provider-mangled
  name and expect loud `invalid-name` with the file intact back
  at the original name (rename-back failure ⇒ `move-partial`);
  move onto a taken name and expect the source
  untouched; force rename failure after a cross-parent move
  and expect rollback to the source or loud `move-partial`
  carrying the actual identifier; fsync read-back (write, close,
  kill, read back intact — proves the bytes, not the durability;
  only a stick pull proves that); close with `fsync: false`
  honors the opt-out; kill the helper mid-write and abort with
  `closeFd: false`, asserting single close via `/proc/self/fd`;
  stub a 0-returning fd and expect loud synthesized `ENOSPC`
  (errno 28 + `synthesized: true`), never a spin; assert no temp
  growth on the write path and memory bounded to one native
  buffer during a 1GB write.
- iOS backend: same matrix once the 1a registry exists, plus
  stale-refresh interplay (move a file mid-session via Files).
- Acquisition: cancel returns null; picked tree feeds listChildren,
  acquire, and the write verbs without re-picking.
- Results for the tree verbs (PR 4, 2026-10-01):
  - Dart unit (`test/tree_verbs_test.dart`, faked channel): what
    each verb sends, the leaf-name `ArgumentError` before any call,
    `scope-closed` for either released scope, error kinds and
    details passed through, stub platforms. JUnit: parent-ID
    derivation (`StorageVolumes.parentDocumentId`). Swift host:
    `ResolvedIdentifier.child` mints what a listing would.
  - Device run (`example/lib/device_checks.dart`, in the fixture's
    `tree/`), on the iOS simulator (two picks on one volume), an
    API 36 emulator's internal storage and a vfat virtual SD card:
    create; create a taken name ⇒ `already-exists`; `12:30 ride` ⇒
    `invalid-name` (`12_30 ride`) with no residue on Android, kept
    as is on APFS; non-recursive delete of a non-empty folder ⇒
    `directory-not-empty`; rename; rename onto a taken name ⇒
    `already-exists`; rename to `x:y` ⇒ `invalid-name` with the
    entry back under its old name on Android; a folder moved into
    another parent with a rename; a file moved out and back, each
    way with a rename; the wrong source parent ⇒ `not-found`
    (`not-a-child`); recursive delete; deleting the gone entry
    again ⇒ success; the picked root ⇒ `root-protected`. Across
    picks: internal → stick ⇒ `unsupported-move`, nothing moved;
    two picks on one volume (simulator) ⇒ moved and moved back.
  - The same tree matrix on a physical iPhone XR (iOS 18.7, debug
    build of the example, sandbox enforced), at efad722: every
    step as on the simulator. Only one folder is picked there, so
    no cross-pick move. The fixture was removed afterwards
    (`FPW_CLEANUP`). Re-run on the XR at 94ed79d, after both review
    rounds: the same matrix, plus the real-path guards active on
    every create, move and delete, and `a/inner` deleted after `a`
    (gone parent) ⇒ success. Fixture removed afterwards.
  - Not run yet: `move-partial` and the `state: unknown` path
    (need a rename that fails after a move, or a detach between a
    landed rename and its check; neither can be forced on the
    emulator), a provider auto-rename racing a create, an opaque
    provider (the listing fallbacks, the "gone" proof via the tree
    root, a residue that is not fresh), a dead provider, a
    read-only grant.
  - After the #71 review fixes (API 36 emulator): the whole matrix
    again on internal and vfat, the repeated delete now through the
    proven-gone path ("Missing file for" plus a live ancestor), and
    a move between two picks on one volume (two tree URIs,
    `FpwTree` → `FpwTree2` and back) on Android too.

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
  `application/octet-stream` dumb fallback; callers pass real
  MIMEs, except suffixed/marker files (`.writing`, `.part`,
  dotfiles), which keep the default — a real MIME may append
  its extension (MIME-extension rule, §4; confirm on device).
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
(`$ANDROID_HOME/platforms/android-36/android.jar`)
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
