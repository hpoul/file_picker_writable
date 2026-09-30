# Held native scope across calls: evaluation & plan (Gap 1a)

Status: proposal, for review. No commitments.
Date: 2026-09-30.
Context: same consumer as the Gap-1 and Gap-2b plans — phone-side trip
storage with repeated reads across relaunches. This doc evaluates how
`file_picker_writable` could hold native access scope across Dart calls
(an acquire/release registry), and recommends an approach. It is the
prerequisite Gap-2b chunk reads need on Apple platforms, and the scope
owner Gap-1 listings rely on.
Companion docs: `large-file-reads-plan.md` (Gap 2b),
`tree-traversal-plan.md` (Gap 1).

## 1. Problem

Current contract: every verb manages scope internally and releases it
before returning. On Apple platforms that means each `readFile` /
`writeFile` resolves the bookmark, `startAccessing…`, copies, and
`stopAccessing…` — fine for one-shot copies, unusable for repeated
access:

- Gap-2b chunk reads would pay bookmark-resolve + scope
  acquire/release per chunk (hundreds of round trips per file) and
  could not hold an open fd across chunks.
- Stale bookmarks are detected but never repaired: the plugin reads
  `bookmarkDataIsStale` today and drops it on the floor, so a moved
  file silently keeps working until it doesn't, and the app never gets
  a fresh identifier to re-persist.
- On Android the persisted-URI-permission model already survives
  relaunches with no per-call cost — but there is no verb that answers
  "is this grant still alive?" without doing a full copy read.

Goal: explicit, cross-platform scope lifetime — acquire once, use many
times, release once — with stale-identifier repair surfaced to Dart so
the app can re-persist.

Out of scope: the `openDirectory` picker (R1, specified in our own
spec — the Gap-3 plan) and any change to one-shot verbs.
`readFile`/`writeFile` keep their internal scope handling untouched.

## 2. Platform realities (constraints, not choices)

- Apple security scope is process-local and balanced: every successful
  `startAccessingSecurityScopedResource` needs exactly one
  `stopAccessing…`. Unbalanced starts leak kernel assertions; the
  registry must refcount, not just remember.
- Apple bookmarks go stale (file moved/renamed outside the app) and
  only re-resolve into a *new* bookmark. Repair means new bytes, which
  means the Dart side must receive a replacement identifier — the app
  owns persistence, the plugin cannot re-persist for it.
- The path is just an address; the scope hold is the work. Exposing
  the file path in the acquire record (R6) costs nothing once the
  scope is held, and lets small reads bypass plugin verbs for
  `dart:io` directly.
- Android persisted URI permissions survive relaunches and need no
  per-call ceremony; acquire there is validation ("grant still held?")
  plus a scope token for API symmetry. The cost is one
  `persistedUriPermissions` scan, not a copy.
- macOS boundary: folder-scope primitives are being factored toward
  the `macos_secure_bookmarks` sibling package, with picking staying
  app-side. This plan must not duplicate that work — see §9.

## 3. Options evaluated

### 3a. Explicit acquire/release registry with repair-on-acquire (RECOMMENDED)

Dart acquires a scope token per identifier, uses it across calls, and
releases it. Acquire repairs stale bookmarks and returns the (possibly
fresh) identifier alongside the token. Native refcounts per identifier
so double-acquire is safe. Small, explicit, debuggable: leaks show up
as unreleased scopes, not as flaky reads three calls later.

### 3b. Implicit hold with phantom-based auto-close (rejected)

Hiding lifetime behind Dart GC (`Finalizer`) makes release timing
nondeterministic — scope could drop mid-sequence under memory pressure
or linger for the whole process. The failure modes are exactly the
flaky kind §1 complains about, and a media library holding hundreds of
scopes deserves determinism.

### 3c. Per-call scope inside every new verb, no registry (rejected)

Pushes the acquire/release cost into every chunk read and every
listing, and leaves stale repair with no home (each call would repair
independently and disagree about the current identifier). Works for
single-shot ops — which is why Gap-1 `listChildren` does exactly this
internally — but fails the repeated-access case this doc exists for.

### 3d. Long-lived process-wide scope held at `init` (rejected)

Holding every grant for the process lifetime wastes kernel resources,
defeats the OS's ability to reclaim, and still needs a repair path.
Explicit pairing keeps the steady-state footprint at "what this screen
is using".

## 4. Proposed API (experimental)

```dart
@experimental
class AcquiredScope {
  // Opaque native hold plus the identifier to use (and re-persist).
  String get id;          // Scope token for release().
  String get identifier;  // Fresh when repair happened; else echo.
  bool get repaired;      // True when identifier differs from input.
  String? get path;       // Usable file path on Apple, null on Android (R6).
  String get displayName; // Re-read every acquire (attach prompts).
}

@experimental
Future<AcquiredScope> acquire({required String identifier});

@experimental
Future<void> release(AcquiredScope scope); // Idempotent.
```

Notes:

- Cross-platform from day one: identical Dart verbs; the iOS backend
  holds real scope, Android validates the grant and returns a token.
  macOS and other stub platforms throw `UnsupportedError` — loud
  beats silent.
- Pairing rule: one `release` per `acquire`; native refcounts per
  identifier so acquire-acquire-release still holds. `release` is
  idempotent per token — double-release is a no-op, never a crash.
- Repair flow: when acquire repairs, the app MUST persist
  `scope.identifier` (replacing the old string) — docs say so loudly,
  and `repaired` makes it checkable. Old identifier keeps working
  until the app drops it; no flag day.
- Single-shot vs repeated split (peer-confirmed): `listChildren`
  (Gap 1) manages scope internally per call; 2b's `openRead` takes
  the scope, never a raw identifier, and `FdReader` checks token
  liveness at construction and close, not per op (reads are FFI,
  not channel verbs). Small one-shot
  reads on Apple (index files, fingerprint hashes) skip sessions
  entirely: `path` plus `dart:io` under the held scope.
- `path` is null on Android by design (no filesystem path exists for
  provider URIs); Dart branches on null, never on platform checks.
  `displayName` is re-read from the provider/file on every acquire
  so attach prompts never show a stale name.
- Experimental mechanics: `@experimental` annotation plus a CHANGELOG
  notice, same as Gaps 1 and 2b. Additive API, no feature flag.

## 5. Native design

### iOS (Swift)

- Registry: resolved file path → (the URL access was started on,
  active tokens); token → path. Keyed by the file, not the
  identifier string: two resolutions of one bookmark (or an old and
  a repaired bookmark) are different strings for one scope, and the
  stop must balance the instance the start ran on. Guarded by a
  lock for concurrent acquires.
- `acquire`: base64-decode → resolve bookmark, capturing
  `isStale`. If stale, re-create `bookmarkData()` from the resolved
  URL and return its base64 as the fresh identifier with
  `repaired: true`. Return `url.path` as `path` plus a re-read
  display name. First hold on an identifier calls
  `startAccessingSecurityScopedResource`; a `false` return is a loud
  `permission-lost`, never a silent proceed. A held scope on a path
  that is no longer reachable is `not-found`, and the hold is
  dropped again. So is a path with a whole component equal to
  `.Trash`, with `reason: trashed` in details: a Files delete moves
  the folder into the provider's `.Trash` and the bookmark follows
  it, so deleted would otherwise read as a live folder the app lists
  and writes into. There is no public resource key for "in the
  trash", and `FileManager.url(for: .trashDirectory…)` likely names a
  different trash, so this is a narrow path guard, provider-specific
  by nature. Results hop to main per the plugin's existing
  convention.
- `release`: drop the token; last token on an identifier calls
  `stopAccessing…`. Unknown token is a no-op (idempotent), logged at
  fine level for leak debugging.
- Teardown: plugin detach/deinit balances every started URL and
  clears all tokens and holds — covers engine teardown, where
  Dart-side `release` never runs. A hot restart (or other loss of
  the root isolate) does NOT detach the plugin, so detach alone
  misses it: each root isolate sends a random session id with
  `acquire`, and the first acquire from a new session balances
  every hold of the old one. Old tokens are then unknown, so they
  fail loud in the verbs that take a scope, never silently rebind.
  Holds left by a dead session linger until that first acquire or
  detach. Session-carrying verbs are root-isolate verbs; a helper
  must never `acquire`. The rule is stated in the `acquire` dartdoc
  but not enforced: an acquire from a second isolate silently
  releases the first one's holds, so native logs every session flip
  that drops live tokens at warning level (expected once per hot
  restart, a bug otherwise).
- Leak backstop: none in v1 — `release` explicit + idempotent only.
  A debug-mode "scopes still held" dump can come later if leaks prove
  hard to find.
- macOS is stubbed (`UnsupportedError`) per the §9 boundary decision:
  macOS scope resolves through the `macos_secure_bookmarks` sibling,
  so a backend here would be dead code.

### Android (Kotlin)

- `acquire`: parse URI, scan `persistedUriPermissions` for a live
  grant (read, or read+write as taken): exact-URI match, or
  same-authority descendant of a persisted tree URI (tree-ID
  comparison — the grant lives on the root, not the child).
  Absent grant is a loud `permission-lost`. Query the display name
  (existing `readFileInfo` pattern; a bare tree URI is queried as
  its root document via `buildDocumentUriUsingTree`) and return
  `path: null`. A null or empty cursor is `not-found`
  (`DocumentsProvider.query` returns null on a missing document;
  confirmed for ExternalStorageProvider on an API 36 emulator,
  2026-09-30) — except a detached volume. ExternalStorageProvider
  drops an unmounted volume's root, `getRootFromDocId` throws, and
  `DocumentsProvider.query` swallows that into a null cursor while
  the grant survives, so a pulled stick would read as a deleted
  folder. For `com.android.externalstorage.documents` only, the
  document ID's tag before `:` (`primary`/`home`, or the volume's
  fsUuid) is matched against `StorageManager.getStorageVolumes()`;
  no match, or a state other than `MEDIA_MOUNTED` /
  `MEDIA_MOUNTED_READ_ONLY`, is `permission-lost` with
  `reason: volume-absent`. (Querying the provider's roots would be
  cleaner but needs `MANAGE_DOCUMENTS`.) Other authorities are
  opaque and keep `not-found`. No native resource is
  held, so refcounting is trivially satisfied.
- `openDirectory` takes a read+write grant and falls back to
  read-only, reporting `persistable` honestly, so a read-only tree
  is still a successful pick rather than a coerced
  `permission-lost`.
- Persisted grants are capped (512 per app on current Android, the
  oldest trimmed silently), and file picks share the cap with tree
  grants. One grant per section folder keeps this far away, but an
  app that also persists many file picks should dispose the ones it
  no longer needs.
- `release`: drop the token. No-op by design, kept for API symmetry
  so Dart code paths stay identical across platforms. The token set
  is still kept (same session rule as iOS) so the verbs that take a
  scope can answer `scope-closed`.
- Control threading: the shared concurrent background TaskQueue
  (uniform rule for every Android control verb).

## 6. Error taxonomy

Shared with Gaps 1 and 2b: `permission-lost` (grant revoked, media
detached, scope start refused), `not-found`, plus `scope-closed`
(use of a released scope token — the 1a analogue of 2b's
`session-closed`). Stale-but-unresolvable is `permission-lost` with
the native code attached, not a new kind: from the caller's view the
grant is gone. Dart carrier (pinned, all gaps): `PlatformException`
with the taxonomy kind as `code` and a details map carrying the
native domain + code where available. Exhaustiveness rule: anything
outside the taxonomy stays loud under its own native code — unknown
failures are never coerced into a taxonomy kind. Two mappings on
Android are deliberate, not coercions of unknowns: a
`SecurityException` is the platform refusing a grant
(`permission-lost`), and a `FileNotFoundException` the platform
reporting a missing document (`not-found`). A `reason` in details
(`trashed`, `volume-absent`) says which guard produced a kind. Rule
stands: new kinds need a taxonomy review before graduation.

## 7. Testing plan

- Dart unit, mocked channels (existing harness): acquire/release
  pairing, double-release idempotency, repair echo vs fresh
  identifier, `repaired` flag semantics, error mapping, scope token
  passed through to 2b verbs (mock-level interplay, no native code).
- Apple device: acquire → kill app → relaunch → acquire same
  identifier (grant survives); move/rename the file via Files, then
  acquire; revoke (remove provider, or empty Recently Deleted) and
  expect `permission-lost`; acquire-acquire-release-release
  refcount check via the logged hold counts.
  Observed on the iOS 26.5 simulator, "On My iPad" (2026-09-30,
  R1/1a PR): relaunch, refcount (1 file / 2 tokens → 0) and cancel
  all as specified. But a Files rename and a move to another folder
  both resolved with `isStale == false` — the bookmark followed the
  file, with `path` and `displayName` updated — so `repaired: true`
  was not produced; the repair branch stays unexercised until some
  device reports staleness. And a Files delete moves the folder to
  `.Trash`, where the bookmark follows it too: acquire succeeds with
  a `.Trash` path instead of `permission-lost`. So acquire now
  guards `.Trash` explicitly (§5, §9); re-run, the same trashed
  folder reads as `not-found` with `reason: trashed`.
- Android device: acquire on live vs revoked grants (revoke via app
  settings); assert no temp growth (acquire must never copy).
  Observed on an API 36 emulator (2026-09-30, R1/1a PR): cancel →
  null; tree pick → `fileName` is the folder label; acquire after
  force-stop + relaunch holds; `disposeAllIdentifiers` →
  `permission-lost`; folder removed under a live grant →
  `not-found`; cache size unchanged across acquires; a cold-launch
  and a warm VIEW intent each reached Dart exactly once.
- Cross-doc interplay: Gap-1 listing then Gap-2b chunk reads under
  one scope, on each platform, once all three exist.

## 8. Graduation (experimental → stable)

Same bar as Gaps 1 and 2b, evaluated independently:

1. One production app ships it for a release cycle with no protocol
   changes.
2. No scope leaks in steady state (suggested: debug counter returns
   to zero on screen close across the ship cycle).
3. Observed failures all map into the taxonomy — no new error kinds
   needed in the wild.

## 9. Open questions

- macOS boundary (RESOLVED 2026-09-30, peer-verified): (c) stub with
  `UnsupportedError`. macOS scope resolves through the
  `macos_secure_bookmarks` sibling, so a backend here would be dead
  code for the driving consumer — not built on their behalf.
- 2b's `openRead` takes `AcquiredScope` (CONFIRMED 2026-09-30,
  peer-verified): it keeps repair visible and avoids hidden per-open
  acquire cost. All three docs now say take-scope.
- Debug leak tooling: is a "scopes held" introspection verb worth the
  API surface, or is fine-level logging enough? Lean logging for v1.
- Repair storm: an app acquiring hundreds of moved files pays one
  re-bookmark each — acceptable, but measure during prototype.
- Trashed folders (RESOLVED 2026-09-30, owner + #68 review): a Files
  delete is a move into `.Trash`, and acquire follows it. Deleted
  reads as `not-found` (`reason: trashed`) via a whole-component
  path guard (§5). Rejected: a public "in trash" resource key (none
  exists), `.trashDirectory` (likely a different trash), and a flag
  on the scope (the silent state §6 avoids).
- Detached volumes on Android (RESOLVED 2026-09-30, owner + #68
  review): read as `permission-lost` (`reason: volume-absent`) for
  ExternalStorageProvider via `StorageManager` (§5). Same principle
  as the trash guard: two separate provider-specific guards, each
  making the provider's real state loud. Other providers stay
  `not-found`.

## 10. Recommendation

Ship 3a experimental on iOS first (the platform where it does real
work), Android validation alongside for API symmetry, macOS stubbed
(boundary decision, §9). Land before Gap-2b native code starts, since
2b's backends open fds under these scopes — but the
Dart API review for all three gaps can run in parallel. The
acquisition verb (Gap-3 plan) lands first of all; #20 is closed and
no external spec gates native code.

## Sources

No new platform APIs beyond what the repo already uses and what the
Gap-1/2b plans cite. Grounding, all inspected 2026-09-30:

- `ios/file_picker_writable/Sources/file_picker_writable/FilePickerWritablePlugin.swift`
  (this repo): bookmark resolve + `isStale`, `startAccessing…` /
  `stopAccessing…` pairing, `_fileInfoResult` identifier encoding —
  the per-call handling §1 proposes to lift into a registry.
- `android/.../FilePickerWritableImpl.kt` (`disposeAllIdentifiers`,
  this repo): `persistedUriPermissions` scan pattern reused for
  Android acquire validation.
- Gap-1 plan Sources (this session): `DocumentsContract` tree APIs
  verified via `javap` in the android-36 compile SDK.
- Gap-2b plan Sources (2026-09-30): MethodChannel semantics,
  `ContentResolver`, `@experimental` in `package:meta`.
