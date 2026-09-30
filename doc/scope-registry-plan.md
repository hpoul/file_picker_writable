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
  liveness (reads are FFI, not channel verbs). Small one-shot
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

- Registry: identifier → (resolved URL, hold count, active tokens).
  Guarded for concurrent acquires.
- `acquire`: base64-decode → resolve bookmark, capturing
  `isStale`. If stale, re-create `bookmarkData()` from the resolved
  URL and return its base64 as the fresh identifier with
  `repaired: true`. Return `url.path` as `path` plus a re-read
  display name. First hold on an identifier calls
  `startAccessingSecurityScopedResource`; a `false` return is a loud
  `permission-lost`, never a silent proceed. Results hop to main per
  the plugin's existing convention.
- `release`: drop the token; last token on an identifier calls
  `stopAccessing…`. Unknown token is a no-op (idempotent), logged at
  fine level for leak debugging.
- Teardown: plugin detach/deinit balances every started URL and
  clears all tokens and holds — covers engine teardown, hot
  restart, and isolate loss where Dart-side `release` never runs.
  Stale tokens after re-attach fail loud, never silently rebind.
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
  (existing `readFileInfo` pattern) and return `path: null`. No
  native resource is held, so refcounting is trivially satisfied.
- `release`: drop the token. No-op by design, kept for API symmetry
  so Dart code paths stay identical across platforms.
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
failures are never coerced into a taxonomy kind. Rule stands: new
kinds need a taxonomy review before graduation.

## 7. Testing plan

- Dart unit, mocked channels (existing harness): acquire/release
  pairing, double-release idempotency, repair echo vs fresh
  identifier, `repaired` flag semantics, error mapping, scope token
  passed through to 2b verbs (mock-level interplay, no native code).
- Apple device: acquire → kill app → relaunch → acquire same
  identifier (grant survives); move/rename the file via Files, then
  acquire and expect `repaired: true` with a working fresh identifier;
  revoke (delete file / remove provider) and expect
  `permission-lost`; acquire-acquire-release-release refcount check
  via a debug counter.
- Android device: acquire on live vs revoked grants (revoke via app
  settings); assert no temp growth (acquire must never copy).
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
