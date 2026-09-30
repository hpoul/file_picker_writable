# Tree writes without whole-file staging: evaluation & plan (Gap 3)

Status: proposal, for review. No commitments.
Date: 2026-09-30.
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

Goal: chunked write sessions with progress and abort, single-shot
tree verbs, and a directory picker — all without temp staging on the
write path, all under the Gap-1a scope discipline.

## 2. Platform realities (constraints, not choices)

- Android: `DocumentsContract` offers `createDocument`, `deleteDocument`
  (`deleteDocument` on a directory is recursive at the provider's
  discretion — behavior varies, so recursion is the plugin's job;
  see §5), `renameDocument` (returns a fresh URI), and
  `moveDocument` (same-authority only). Byte output is a sequential
  `openOutputStream` on a held stream — truncating open, then
  sequential writes advancing the position; never positional writes
  and never append mode (the held stream already advances); pipes
  make seeking as unavailable as on the read path.
- The create-then-stream pattern has a crash window: a file created
  but never committed is a partial the app must sweep. Abort deletes
  the partial; crash recovery is the app's orphan sweep (Gap-1
  listing already gives it the enumeration it needs).
- iOS: `FileManager` (`createDirectory`, `removeItem`, `moveItem`
  for rename/commit) plus `FileHandle` seeks + writes — all under a
  held Gap-1a scope. Same session shape as the 2b read side, mirrored.
- MIME types on create are the caller's statement, not the plugin's
  guess: Android `createDocument` requires one, so the Dart verb takes
  it (with a documented default, not extension sniffing magic).

## 3. Options evaluated

### 3a. Chunked write sessions + single-shot tree verbs (RECOMMENDED)

`openWrite`/`writeChunk`/`closeWrite`/`abortWrite` mirror the 2b read
sessions (same backpressure-by-construction, same multiplexing via
session ids, progress as acknowledged bytes, stop as abort), while
mkdir/delete/move stay single-shot verbs with internal scope — the
same single-shot-vs-session split Gaps 1/1a already run. One new
state machine (the write session); everything else is stateless.

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
behind a slow provider with no backpressure. Pull-model chunks (Dart
pushes explicitly, each acked) keep the producer bounded — the write
side just inverts who holds the data, not the control flow.

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
  String get id;
  int get bytesWritten; // Acknowledged total. Progress numerator.
}

@experimental
Future<WriteSession> openWrite({
  required AcquiredScope scope, // Scope of the PARENT directory.
  required String name,         // Created (fail-if-exists).
  String mimeType = 'application/octet-stream',
});

@experimental
Future<int> writeChunk(WriteSession session, Uint8List bytes);
// Appends; returns the new acknowledged total. Sequential only.

@experimental
Future<ChildEntry> closeWrite(WriteSession session); // Commit.
@experimental
Future<void> abortWrite(WriteSession session); // Deletes partial. Idempotent.

@experimental
Future<ChildEntry> createDirectory({
  required AcquiredScope scope, // Scope of the parent directory.
  required String name,
});

@experimental
Future<void> deleteEntry({
  required String identifier, // Single-shot: scope handled internally.
  bool recursive = false,     // Non-recursive on a non-empty dir is loud.
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

- Cross-platform from day one: identical Dart verbs; Android serves
  `DocumentsContract` + truncating opens with sequential streams,
  iOS serves `FileManager` + `FileHandle` inside the passed-in
  scope. macOS and other stub platforms throw `UnsupportedError` —
  loud beats silent.
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
  variance.
- Concurrency: `writeChunk`/`closeWrite`/`abortWrite` on one session
  are serialized natively (per-session mutex), FIFO — chunk order
  and acknowledged totals stay deterministic even after dispatch
  off the platform thread. Serialization, not rejection.
- Fail-if-exists is the documented `openWrite` rule (peer
  re-confirmed, superseding truncate): an existing name is loud
  `already-exists`, so abort can never destroy an overwrite
  victim and crash partials stay identifiable for the orphan
  sweep. Callers needing overwrite delete first, deliberately.
- Loud-on-taken-name is the documented `createDirectory` and
  `moveEntry` rule (peer-pinned): creating a folder or moving onto
  an existing sibling name throws `already-exists` — never a silent
  provider auto-rename. Any provider-renamed residue is deleted
  before throwing, so the loud outcome leaves no litter. The
  returned `ChildEntry` always carries the actual name.
- `moveEntry` replace/atomicity contract (peer-pinned): no atomic
  replace exists on SAF — move onto a taken name is loud
  (`already-exists`), so callers implement delete-then-rename
  deliberately; the rename itself is best-effort atomic with a crash
  window (momentarily missing target) that the caller recovers
  through its own damaged state.
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
- `openWrite`: resolve parent scope → tree URI + parent document ID;
  list the parent first: an exact existing child ⇒ loud
  `already-exists`, not attempted; otherwise `createDocument`
  (MIME type + name as passed) and verify the returned display
  name (auto-rename ⇒ delete the residue, loud `already-exists`).
  Open the fresh child for writing and hold the `OutputStream` in
  the session registry. Validate the scope token (released ⇒ loud
  `scope-closed`).
- `writeChunk`: append bytes, flush per chunk (provider visibility +
  crash hygiene), return the new total. Everything on
  `Dispatchers.IO`.
- `closeWrite`: flush, close, stat the child into a `ChildEntry`.
  `abortWrite`: close, `deleteDocument` the partial, drop the session.
  Both idempotent; use-after-either is loud `session-closed`.
- `createDirectory`: list the parent first (taken name ⇒ loud
  `already-exists`, not attempted); `createDocument` with
  `MIME_TYPE_DIR`, then verify the returned display name matches
  the request: a mismatch means the provider auto-renamed, so
  delete the residue and throw loud `already-exists`. The returned
  entry always carries the actual name.
- `deleteEntry`: resolve identifier; `deleteDocument`. Recursion is
  the plugin's own walk (list children via the Gap-1 path, delete
  depth-first), because provider-side recursive delete is
  discretionary — never trust it. Non-recursive on a non-empty
  directory is loud `directory-not-empty`, checked by listing first.
- `moveEntry`: source parent comes from the passed scope — no
  `findDocumentPath` needed on any API level. List the target
  parent first; taken name is loud `already-exists`, not
  attempted. Same parent + new name → `renameDocument` (fresh URI
  returned); parent change → `moveDocument`, then `renameDocument`
  when `newName` is also given (documented crash window between
  the two ops). Always re-stat into a fresh `ChildEntry`.
  Cross-provider is loud `unsupported-move`, not attempted. The
  rename is best-effort atomic (no SAF replace primitive).

### iOS (Swift, inside Gap-1a scopes; needs the 1a registry)

- `openDirectory`: document picker in folder mode, bookmark the
  directory, same `FileInfo` encoding as file picks.
- `openWrite`: resolve parent scope URL + name (taken name ⇒ loud
  `already-exists`), create the file, hold a `FileHandle` for
  writing. `writeChunk`: `write` +
  `synchronizeFile` per chunk, return the total.
  `closeWrite`/`abortWrite` mirror Android (abort removes the
  partial). Off main; results hop to main per convention.
- `createDirectory`: `FileManager.createDirectory` under the
  passed-in parent scope (not per-call — §4). `deleteEntry` /
  `moveEntry`: `FileManager` under a per-call scope (single-shot
  verbs), with the plugin's own recursive walk for
  `deleteEntry(recursive: true)` — same rule as Android: never
  trust provider-side recursion. `FileManager` file-exists errors
  map to loud `already-exists` (nothing is created, so no residue
  cleanup); target names are pre-checked before `moveItem`, and
  move-then-rename is sequenced like Android (source parent from
  the passed scope).

## 6. Error taxonomy

Shared with Gaps 1/1a/2b: `permission-lost`, `not-found`,
`not-a-directory` (write/create under a file identifier),
`session-closed` (use after close/abort — same kind as 2b's read
sessions), `scope-closed`. New in this gap: `directory-not-empty`
(non-recursive delete of a non-empty directory),
`unsupported-move` (cross-provider move attempt),
`already-exists` (create/move/write onto a taken name), and
`invalid-name` (leaf-name rule violation). Dart carrier
(pinned, all gaps): `PlatformException` with the taxonomy kind as
`code` and a details map carrying the native domain + code where
available. Exhaustiveness rule: anything outside the taxonomy stays
loud under its own native code. New kinds need a taxonomy review
before graduation.

## 7. Testing plan

- Dart unit, mocked channels (existing harness): session lifecycle,
  progress totals, abort idempotency, close-after-abort and
  write-after-close errors, fail-if-exists rule, rename-is-move
  shape with source parent, leaf-name `ArgumentError` pre-check,
  error mapping. No native code needed.
- Android device: mkdir → chunked write with progress asserts →
  close → read back via Gap-2b chunks (cross-gap round trip);
  abort mid-write and assert the partial is gone; delete recursive
  on a nested tree; move + rename incl. fresh-identifier use;
  create-after-pick visibility (R4 interplay); revoke mid-write and
  expect `permission-lost`; create a folder twice, open-write an
  existing name, and move onto a taken name, all expecting loud
  `already-exists` with no residue; pass `../x` and expect loud
  `invalid-name`; assert no temp growth on the write path and
  memory bounded to ~2 chunks during a 1GB write.
- iOS backend: same matrix once the 1a registry exists, plus
  stale-refresh interplay (move a file mid-session via Files).
- Acquisition: cancel returns null; picked tree feeds listChildren,
  acquire, and the write verbs without re-picking.

## 8. Graduation (experimental → stable)

Same bar as the other gaps, evaluated independently:

1. One production app ships it for a release cycle with no protocol
   changes.
2. 1GB write completes with memory bounded to ~2 chunks and
   progress callbacks (chunk acks) arriving steadily — no stalls
   longer than the provider's own variance.
3. Observed failures all map into the taxonomy — no new error kinds
   needed in the wild.

## 9. Open questions

- Fail-if-exists for `openWrite` (RE-CONFIRMED 2026-09-30,
  peer-verified, superseding truncate): abort can never destroy
  an overwrite victim; same compatibility for the move flow.
- Per-chunk `flush`/`synchronizeFile`: right crash hygiene, but
  measures needed — if a provider turns flush into a round trip,
  make it every-N-chunks with N tuned, not removed.
- MIME-type default (CONFIRMED 2026-09-30, peer-verified):
  `application/octet-stream` dumb fallback; callers pass real MIMEs.
- Cross-provider move (copy + delete choreography with progress)?
  Out of v1 by design; revisit if the move flow needs it.
- `closeWrite` returns `ChildEntry` (CONFIRMED 2026-09-30,
  peer-verified): listing-shaped; the grant is the tree's.

## 10. Recommendation

Land the acquisition verb first — it unblocks every gap's
prototype — then single-shot tree verbs, then write sessions, all
experimental on Android first with iOS following once the 1a
registry exists (macOS stubbed). The write session mirrors the 2b
read session deliberately: one state-machine shape to review, two
directions.

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
