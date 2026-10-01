# Directory listing without copies: evaluation & plan (Gap 1)

Status: proposal, for review. No commitments.
Date: 2026-09-30.
Context: same consumer as the Gap-2b large-reads plan — phone-side trip
storage. The app picks a folder on attached storage once, keeps the
grant across relaunches, and repeatedly enumerates it to find GB-scale
media files. This doc evaluates how `file_picker_writable` could list
a persisted directory's children, and recommends an approach.
Companion docs: `large-file-reads-plan.md` (Gap 2b),
`scope-registry-plan.md` (Gap 1a).

## 1. Problem

Current contract: every verb takes a single-file identifier produced by
a file picker. There is no way to ask "what is inside this folder?" —
so a media library cannot discover files without the user picking each
one individually.

Goal: list one directory level from a persisted directory identifier,
as metadata only (no copies, no temp footprint), with child identifiers
directly usable by `readFile` / the proposed `openRead`.

Out of scope: acquiring the directory identifier in the first place
(the `openDirectory` picker, R1). Gap 1 consumes a directory
identifier; producing one is a separate verb with its own picker UX
and review, specified in our own spec — the Gap-3 plan carries the
acquisition verb, since tree writes need a directory to operate on
too. No external dependency: #20 is closed, and prototypes test
against our own acquisition verb (see §9).

## 2. Platform realities (constraints, not choices)

- Android: a tree URI from `ACTION_OPEN_DOCUMENT_TREE` carries a
  persistable grant that covers the whole subtree. Children are queried
  through `DocumentsContract` (`buildChildDocumentsUriUsingTree`,
  per-child URIs via `buildDocumentUriUsingTree`); each child URI works
  with the existing read/write verbs. Directory-ness is the
  `MIME_TYPE_DIR` MIME type, not a flag. Document IDs are opaque and
  may change on rename/move (path-based providers derive them from
  the path) — callers must use the fresh `ChildEntry` a move/rename
  returns. The persisted tree URI and its grant are stable across
  renames (R3) and cover descendants created after the pick (R4).
- Provider metadata is best-effort: `SIZE` and `LAST_MODIFIED` may be
  missing or 0 depending on provider (cloud, OTG). Nullable in the API,
  never fabricated.
- iOS: directories are `dart:io`-listable once the scope is held
  — `FileManager.contentsOfDirectory` under `startAccessing…`. The only
  work is scope lifetime (Gap 1a) plus per-child identifiers.
  (macOS is stubbed for these gaps — see the Gap-1a plan.)
- Child counts can be large (10k+ photos in one folder). One batched
  call, not one call per child — this is the case the 2b plan's
  overhead note was written for.

## 3. Options evaluated

### 3a. Single batched `listChildren` returning metadata + identifiers (RECOMMENDED)

One call, one level, metadata only. Children arrive with identifiers
that work directly in `readFile`/`openRead`. Recursion, filtering, and
sorting live in Dart, where they are testable without native code.
Batching answers the small-call overhead question by construction.

### 3b. Recursive native listing (rejected)

Native recursion hides cost (a deep tree becomes one unbounded call),
complicates cancellation, and duplicates in Kotlin/Swift what Dart does
in ten lines over 3a. No transport saving: the bytes are identical.

### 3c. Per-child stat calls (rejected)

`listNames` plus N `stat` calls multiplies channel round trips by the
directory size — exactly the overhead profile §2 warns about. The
provider already returns the metadata in the listing query; dropping it
there and re-fetching it per child is pure waste.

### 3d. Reusing `readFile` copy semantics per child (rejected)

Copying every child to temp just to learn its name reintroduces the
write amplification Gap 2b exists to remove, at directory scale. Listing
must never touch temp.

## 4. Proposed API (experimental)

```dart
@experimental
class ChildEntry {
  // Metadata for one direct child. No copies, no temp files.
  String get name;
  String get identifier; // Usable in readFile/openRead directly.
  bool get isDirectory;
  int? get size;         // Null when the provider won't say.
  DateTime? get lastModified; // Null when the provider won't say.
}

@experimental
class DirectoryListing {
  // One level plus the identifier to use (and re-persist).
  List<ChildEntry> get entries;
  String get identifier; // Fresh when repair happened; else echo.
  bool get repaired;     // True when identifier differs from input.
}

@experimental
Future<DirectoryListing> listChildren({required String identifier});

@experimental
Future<ChildEntry?> lookupChild({required String identifier, required String name});
// Single-shot by-name lookup under one parent. Null when absent —
// for probes ("does `.prev` exist"), not-found is data, not an
// error. Gone parent is loud `not-found`.
```

Notes:

- Cross-platform from day one: identical Dart verbs; Android serves
  `DocumentsContract` rows, iOS serves `FileManager` entries
  (needs a held scope — see Gap 1a for who holds it). macOS and
  other stub platforms throw `UnsupportedError` — loud beats silent.
- Ordering: provider/native order, documented as unspecified. Dart-side
  sorting is the caller's one-liner; the plugin must not impose a sort
  that costs a full metadata pass on providers that stream rows.
- No filtering: names starting with `.` are ordinary names, listed
  like any other; nothing filters hidden files on either platform.
- Scope handling on Apple: `listChildren` manages scope internally
  per call (single-shot op). Repeated-access callers use Gap-1a
  `acquire` + Gap-2b `openRead`, not repeated listings.
- `lookupChild` is the O(1) probe and scan step: one query, not a
  listing. Gap-3 taken-checks (`openWrite`, `createDirectory`,
  `moveEntry`) and create/rename verify-after all use it instead
  of listing the parent — one listing per taken-check at 10k
  children is tens of seconds per save on a media folder.
- `lookupChild` takes a single leaf name (tree-writes-plan §4's rule:
  not empty, `.`, `..`, nor containing `/` or NUL; Dart
  `ArgumentError` first, native `invalid-name` behind it), since
  the derived child ID would otherwise walk the tree. Matching is
  the file system's: on case-insensitive storage (Android shared
  storage, FAT/exFAT) `TRIP.JSON` finds `trip.json`, and
  ExternalStorageProvider echoes the requested case as the name
  (measured, API 36). A hit means "the name is taken"; stored names
  come from `listChildren`.
- Metadata normalization, one rule on both platforms: `size` is
  null for directories (Android reports the block size, iOS
  nothing), and a `lastModified` of 0 is "won't say", so null.
- Repair echo (peer-confirmed): when resolving the parent bookmark
  reports stale, iOS repairs and returns the fresh identifier with
  `repaired: true` — the app MUST persist it, same discipline as
  acquire repair. Android echoes the input with `repaired: false`.
- Experimental mechanics: `@experimental` annotation plus a CHANGELOG
  notice, same as Gap 2b. Additive API, no feature flag.

## 5. Native design

### Android (Kotlin)

- `listChildren`: resolve identifier to tree URI; require
  `DocumentsContract.isTreeUri`, else loud `not-a-directory`.
  Derive the parent document ID by shape: root tree URI ⇒
  `getTreeDocumentId`, child/subdir URIs ⇒ `getDocumentId`.
  Query `buildChildDocumentsUriUsingTree(treeUri, parentDocumentId)`
  for `COLUMN_DOCUMENT_ID`, `COLUMN_DISPLAY_NAME`,
  `COLUMN_MIME_TYPE`, `COLUMN_SIZE`, `COLUMN_LAST_MODIFIED` in one
  cursor pass; build each child URI with
  `buildDocumentUriUsingTree(treeUri, documentId)`. `isDirectory` is
  `mimeType == MIME_TYPE_DIR`. Persisted tree grant already covers
  children — no per-child permission calls.
- Subdirectories: the caller passes a child's identifier back in;
  native derives its document ID (`getDocumentId` — child URIs only;
  the root takes `getTreeDocumentId` above) and lists under it
  with the same tree URI. One code path for every level.
- Identifier encoding (pinned): child identifiers are full document
  URIs from `buildDocumentUriUsingTree`, embedding the tree ID so the
  tree is recoverable from any subdir identifier. Opaque to Dart —
  never parsed there.
- Threading: serve on the shared concurrent background TaskQueue
  and run cursor work directly on queue threads (no second hop —
  the queue is concurrent, so a slow provider does not stall other
  control). Close the cursor in `finally`.
- Both verbs first resolve the parent: a tree URI under a live
  persisted grant (else `permission-lost`), one row query for the
  parent itself (null ⇒ the Gap-1a missing-document rule:
  `not-found`, or `permission-lost` `volume-absent` for an
  unmounted ExternalStorageProvider volume), and a directory MIME
  type (else `not-a-directory`). A gone parent reads as a null
  row only when it is the picked tree's own root; anything below
  the root goes through the provider's tree check
  (`isChildDocument`), which throws `IllegalArgumentException` for
  a missing file (FileSystemProvider wraps the
  `FileNotFoundException`). So for a non-root directory that
  exception from the parent or children query means gone ⇒ the
  missing-document rule, never a raw error. Measured (#69 review
  M1): delete a listed subfolder, then `lookupChild` and
  `listChildren` on it ⇒ `not-found`. Every provider query
  (parent, children, derived child) also runs the volume check on
  any exception, and the derived child's null row runs it too, so
  a stick pulled mid-call reads as `volume-absent`, not as a
  missing child (scope-registry-plan §5; the null-row-mid-call
  race itself is covered by construction, not timed). Measured:
  removing the virtual disk, then calling both verbs with a
  SUBFOLDER identifier, gets the provider's throwing variant
  (`IllegalArgumentException` "… No root for <uuid>", reached
  without `adb root`) and reports `permission-lost`
  `volume-absent`, the raw exception kept in details.
- `lookupChild`: for ExternalStorageProvider only (the one
  provider whose IDs are known to be paths), derive the child
  document ID as parent ID + `/` + name (`<root>:` + name directly
  under a volume root), query the one row via
  `buildDocumentUriUsingTree`, map to `ChildEntry`. A missing
  child does NOT come back as a null row: the tree check throws
  `IllegalArgumentException` ("Failed to determine if … is child
  of …"; measured, API 36). The same exception also comes from a
  canonicalize failure on a failing stick or a parent that
  vanished mid-call, so the plugin never decides on it: it
  re-queries the parent, and only a parent that is still a live
  directory makes the answer null (one extra row query, on a miss
  only); a gone parent is the missing-document rule, and a parent
  replaced by a file is `not-a-directory`. A null that follows any
  message other than "Missing file for" (e.g. a canonicalize
  failure on a failing stick) is logged at warning; the message
  picks the log level, never the answer. The converted `not-found`
  carries the provider's exception as its cause, so details tell
  "Missing file for", "Failed to canonicalize" and "No root for"
  apart. Every other
  provider is opaque and falls back to list-and-scan internally
  (same result, listing cost — the caller can't tell), with an
  exact name match there.
- An unreadable directory on ExternalStorageProvider lists as
  empty (`FileUtils.listFilesOrEmpty`), so an empty listing is not
  proof of an empty folder; the dartdoc says so.

### iOS (Swift, after Gap 1a lands)

- `listChildren`: resolve identifier to URL (bookmark, with
  stale-refresh per 1a), `startAccessing…` on the root,
  `contentsOfDirectory`, `resourceValues` for size/mtime,
  `stopAccessing…`. Return the entries wrapped with the (possibly
  fresh) parent identifier + `repaired` flag. Results hop to main
  per the plugin's existing convention.
- Identifier encoding (REVISED 2026-10-01, #69 review S4/S5): a
  child identifier is the picked root's bookmark plus a relative
  path (`fpwchild1:<root bookmark>:<percent-encoded path>`; a
  listing sends everything up to the child's encoded name once, as
  `identifierPrefix`, and each entry only its `identifierSuffix`,
  which Dart appends — per-character percent-encoding makes the
  concatenation exactly the full identifier, pinned in the host
  tests; `lookupChild` returns its one entry whole), NOT a
  bookmark per child as first pinned. Measured on the iOS 26.5
  simulator, 10k children: a bookmark per child cost 47.3 s of a
  47.8 s listing (~4.7 ms each); root + path costs 52 ms for all
  entries, 164 ms end to end. It also settles where a child's
  access comes from: every verb resolves the root bookmark and
  starts the ROOT's security scope, then works on root + path —
  the same pattern the plugin's create-in-folder pick already
  ships — instead of trusting a child bookmark's own scope, which
  the simulator (no sandbox enforcement) cannot prove. Trade-off,
  same as Android's path-based document IDs: a child identifier
  follows a rename only through its root; persist root
  identifiers, re-derive children by listing. `readFile`,
  `writeFile`, `acquire`, `listChildren` and `lookupChild` all take
  either form. Opaque to Dart — never parsed, never compared (the
  same child can come back under another identifier after a root
  repair or a spelling echo). macOS is stubbed (`UnsupportedError`)
  per the Gap-1a boundary decision.
- The traversal boundary (#69 re-review N1–N3, N7, N9): decoding
  rejects an empty or non-base64 root, an empty path, and any path
  component that breaks the leaf-name rule (empty, `.`, `..`, `/`,
  NUL), checked and split on Unicode scalars so a combining mark
  cannot hide a `/`. `%2F` decodes to a separator and `%252F` to a
  literal. An unknown prefix (`fpwchild2:`) is not parsed as a
  child, and the bookmark decoder then refuses it, so it stays
  loud. After resolving, every verb checks containment: the path
  with all symlinks resolved — the deepest existing ancestor, then
  the rest, since `resolvingSymlinksInPath` leaves a not-yet-existing
  path alone; a dangling symlink at that point is followed by hand
  (`destinationOfSymbolicLink`, loops cut at depth 32), since a
  create through it would land at its target — must stay under the
  resolved root, else `not-found`
  `reason: outside-root`. On a device the sandbox refuses such an
  escape by itself (measured, iPhone XR: raw `dart:io` through a
  `out -> ..` symlink inside the held folder gets `EPERM`), so the
  check is defense in depth there; the simulator does not enforce
  the sandbox, so there it is the only guard. Pinned by
  host tests (`ios/test/ChildIdentifierTests.swift`, run by
  `tool/swift_unit_tests.sh`; red-checked by mutating the
  component check, the scalar split and the ancestor resolution).
- `lookupChild`: resolve parent URL (same stale-refresh),
  `startAccessing…`, `FileManager` attributes query on
  parentURL + name → `ChildEntry` or null when absent,
  `stopAccessing…`. Single-shot scope, like `listChildren`.
- Both run the Gap-1a liveness checks on the parent with the scope
  held: unreachable ⇒ `not-found`, inside `.Trash` ⇒ `not-found`
  `reason: trashed`, not a directory ⇒ `not-a-directory`.
  `contentsOfDirectory` runs without `.skipsHiddenFiles`, so
  dotfiles list.
- `acquire` on a child identifier holds the root's scope (the
  registry refcounts the root) and returns the child's path and
  name, so a caller holds one child without listing again.
  Simulator runs: acquire, `readFile` and a two-levels-down
  `listChildren` all work on child identifiers. On hardware too
  (iPhone XR, iOS 18.7.10, debug build, folder picked in On My
  iPhone, 2026-10-01): in a fresh launch after the pick,
  `readFile` and `writeFile` on a child and a grandchild
  identifier, `lookupChild` and listings all work under the root's
  scope; after a kill and relaunch, the saved child and grandchild
  identifiers acquire through the root's persisted bookmark
  (`repaired: false`) and read back what the previous launch wrote.

## 6. Error taxonomy

Shared with Gap 2b where the meaning matches: `permission-lost`
(grant revoked, media detached — `reason: volume-absent` on
ExternalStorageProvider), `not-found` (`reason: trashed` for an iOS
parent in `.Trash`), plus `not-a-directory` (identifier resolves
but is not listable) and `invalid-name` (a non-leaf `lookupChild`
name that got past the Dart `ArgumentError`, tree-writes-plan §6).
Dart carrier (pinned, all gaps): `PlatformException` with the
taxonomy kind as `code` and a details map carrying the native
domain + code where available. Exhaustiveness rule: anything
outside the taxonomy stays loud under its own native code — unknown
failures are never coerced into a taxonomy kind. New kinds need a
taxonomy review before graduation (see §8).

## 7. Testing plan

- Dart unit, mocked channels (existing harness): wrapper shape
  (entries + identifier echo + `repaired: false`), stale-parent
  repair echo (`repaired: true`, fresh identifier), empty
  directory, null size/mtime passthrough, error mapping,
  subdirectory identifier round-trips back into `listChildren`,
  `lookupChild` null-on-absent vs loud parent `not-found`.
  No native code needed.
- Android device: local + USB-OTG tree URIs; assert no temp growth
  (cache dir size before/after — listing must never copy); 10k-child
  directory for batch latency; revoke grant mid-session and expect
  `permission-lost`; pass a file URI and expect `not-a-directory`;
  create a child after the pick, then list, and expect it visible
  (R4: grant covers later-created children); `lookupChild` hit,
  miss (null), gone parent (loud), and a dotfile by name.
- iOS backend: listing correctness plus interplay with
  stale-refresh once Gap 1a exists.
- Observed 2026-09-30 (the Gap-1 PR), via the example's "Run
  checks" button:
  - Android, API 36 emulator, ExternalStorageProvider: listing
    with a dotfile and a subfolder, one level down through a child
    identifier, a file listed ⇒ `not-a-directory`, lookup hit /
    dotfile / folder / miss ⇒ null / wrong-case hit, a child
    created after the pick is listed (R4), revoke ⇒
    `permission-lost`, gone parent ⇒ `not-found` for both verbs,
    cache size unchanged, and a listed child's identifier acquires
    on its own. 10k children: 3.9–4.6 s in profile mode, all but
    ~0.1 s of it the provider's cursor (native-timed), so
    provider-bound; 5.3 s once in debug mode. Warm emulator, not
    the mid-range-device gate.
  - iOS 26.5 simulator: the same listing, lookup, `not-a-directory`
    and child-acquire results; the wrong-case lookup was a miss
    there (null), and a trashed parent is `not-found`
    `reason: trashed` for both verbs. 10k children: 47.8 s with a
    bookmark per child, 164 ms with root + path identifiers (§5).
  - Both, after the review round (2026-10-01): `readFile` on child
    identifiers, a grandchild listing two levels down, a deleted
    subfolder ⇒ `not-found` (Android M1), and a removed disk with a
    subfolder identifier ⇒ `volume-absent` via the throwing
    variant (Android S2).
  - iPhone XR, iOS 18.7.10, debug build (2026-10-01), via the
    example's `--dart-define=FPW_AUTOCHECK=true` run
    (`example/lib/device_checks.dart`) over a folder picked in On
    My iPhone, with a throwaway tree created inside it and removed
    afterwards:
    - fresh launch after the pick: child and grandchild `readFile`
      / `writeFile` / `lookupChild` work under the root's scope;
      root listing 12 ms, a 2-entry child listing 10 ms;
    - kill + relaunch: saved child and grandchild identifiers
      acquire (`repaired: false`) and read back the last launch's
      writes;
    - 10k children: 329 / 281 / 280 ms end to end in Dart over
      three runs; identifiers 2,575 bytes each, 25.8 MB in total
      (§8);
    - symlink `out -> ..` inside the folder: listed as an entry
      (`isDirectory: false`); `listChildren`, `lookupChild` and
      `readFile` through it ⇒ `not-found` `reason: outside-root`
      (`readFile` keeps its legacy `UnknownError` carrier); raw
      `dart:io` through it ⇒ `EPERM` from the sandbox.
- No new benchmark suite beyond the 10k-child latency check: listing
  throughput is provider-bound by the same argument as 2b §3's
  overhead note.

## 8. Graduation (experimental → stable)

Same bar as Gap 2b, evaluated independently:

1. One production app ships it for a release cycle with no protocol
   changes.
2. 10k-child listing latency acceptable on a mid-range device
   (suggested: p95 under 5s on local storage, provider-bound
   otherwise). The iOS wire size is settled (#69 re-review N5,
   done in #69): with an identifier per entry repeating the root
   bookmark (1–3 KB), a 10k listing carried 25.8 MB on the iPhone
   XR (2,575 bytes each, 280–329 ms end to end). `listChildren`
   now sends the shared identifier prefix once per listing and an
   encoded-name suffix per entry; Dart keeps the prefix once and
   composes `identifier` on read. Simulator, 10k children:
   1.6 KB prefix + 89 KB suffixes ≈ 91 KB instead of 16.5 MB
   (~180×); 91–195 ms end to end over six runs (the simulator
   is too noisy to show a time gain; the device decides).
3. Observed failures all map into the taxonomy — no new error kinds
   needed in the wild.

## 9. Open questions

- R1 sequencing (RESOLVED 2026-09-30, owner-decided): the acquisition
  verb is specified in our own spec (Gap-3 plan) and lands before gap
  prototypes test against it. #20 is closed — no external gating. The
  debug-only acquisition path stays rejected (throwaway URI shapes
  and flags can poison the prototypes).
- `listChildren` takes a raw identifier (CONFIRMED 2026-09-30,
  peer-verified): per-call scope internally, no scope-handle
  overload — the single-shot/repeated split stays clean.
- `size`/`lastModified` null frequency across real providers? Measure
  during prototype; decides how loudly docs must warn.
- Pagination for very large directories (cursor window vs full list)?
  Lean full list for v1; revisit if 10k-child memory or latency
  disappoints. First data point (§7): 10k children ≈ 4 s on a warm
  emulator, almost all of it the provider's cursor, so pagination
  would not make the total faster, only the first page. The
  device gate (§8) decides.
- Containment for untrusted entry points: how does native prove a
  picked directory is inside the blessed parent (the Gap-3 Add
  refusal needs it)? Options: a containment query verb,
  `findDocumentPath` (API 26+, absent below), tree-URI prefix
  comparison, or the interim listing rule (reject anything the
  parent listing doesn't show). Needs a decision before untrusted
  picks are accepted.

## 10. Recommendation

Ship 3a experimental on Android first, same as 2b, with the Dart API
shaped cross-platform so the iOS backend slots in unchanged once Gap
1a lands (macOS stubbed). The acquisition verb (Gap-3 plan) lands
first; no external spec gates native code.

## Sources

APIs verified 2026-09-30 in the compile SDK
(`$ANDROID_HOME/platforms/android-36/android.jar`)
via `javap`:

- `android.provider.DocumentsContract`: `buildChildDocumentsUriUsingTree`,
  `buildDocumentUriUsingTree`, `getDocumentId`, `getTreeDocumentId`,
  `isTreeUri` all present.
- `android.provider.DocumentsContract$Document`: `COLUMN_DISPLAY_NAME`,
  `COLUMN_DOCUMENT_ID`, `COLUMN_MIME_TYPE`, `COLUMN_SIZE`,
  `COLUMN_LAST_MODIFIED`, `MIME_TYPE_DIR` all present.
- `android.content.Intent.ACTION_OPEN_DOCUMENT_TREE` present.
- https://developer.android.com/reference/android/provider/DocumentsContract —
  official reference (fetched; page body is JS-rendered, so signatures
  were confirmed via `javap` instead).
