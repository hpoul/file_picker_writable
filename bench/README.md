# Transport benchmark evidence (MethodChannel vs JNI vs FFI)

Why this directory exists: the experimental plans in `doc/` recommend
FFI-on-a-detached-fd for the Android byte path. That decision rests on
the measurements and source traces below — kept here so the evidence
does not evaporate with a scratchpad.

## Contents

- `fpw-pr67-transport-brief.md` — the reviewing agent's brief (from the
  cycling_storyteller session that reviewed PR #67 alongside their
  PR #393, 2026-09-30). Verdict, emulator numbers, engine source
  trace, AOSP provider analysis, per-claim verdicts on the 2b plan.
  Read this first.
- `chanbench/` — the benchmark app source (build outputs excluded).
  `lib/main.dart` runs all transports over a 1 GiB file;
  `lib/jni_transport.dart` is the package:jni variant;
  `android/.../MainActivity.kt` holds the channel handlers.
  Re-run: `cd chanbench && flutter run --profile -d <device>
  --dart-define=AVD=<label>` (plus `--dart-define=REPS=n`,
  `--dart-define=ONLY=<prefix>` to subset).
- `table_emulator.txt`, `runs_emulator.txt` — reviewer's emulator
  numbers (fresh API-36 AVD, warm page cache).
- `run_s24.log`, `logcat_s24.log`, `table_s24.txt` — our
  confirmation run on a physical Galaxy S24 Ultra (SM-S928B,
  Android 16, Flutter 3.47.0 profile, 2026-09-30). Same app,
  same matrix. Scrubbed (hostname, VM URLs).
- `table.py` — parses `BENCH` lines from a run log into a table.
- `fpw-pr67-review-2.md` — the followup review (flip re-review,
  12 findings, scrub request), preserved scrubbed.

## What was independently verified here (2026-09-30)

- Bench sources read in full: fair matrix (same file/chunks/
  consumption, anti-DCE sinks, medians over 3 reps).
- The 6-copy channel trace: Dart `putUint8List` copy + `getUint8List`
  view (local SDK `serialization.dart`), send-path
  `MallocMapping::Copy` (`platform_configuration.cc:506`), Java
  `encodeSuccessEnvelope` double copy + reply-path
  `MallocMapping::Copy` (`platform_view_android_jni_impl.cc:538`)
  — all read, all match.
- `ParcelFileDescriptor.getStatSize()` returns -1 for non-regular
  files (AOSP source read) — the one-line seekability/length
  detection is sound.
- Our plugin handler is the slowest measured shape
  (`FilePickerWritablePlugin.kt`: `launch(Dispatchers.Main)` + IO hop).
- S24 run reproduced every structural finding with wider gaps
  (FFI views 12–28× the best viable channel variant; UI-isolate
  reads collapse to 6–12 fps; SendPort handoff falls back to
  channel speed). Emulator frame-gap counts for channel variants
  did not reproduce (all zero at 120 Hz) — noise, as the brief warned.
- Review-2 followups verified: `FileSystemProvider.renameDocument`
  auto-renames the source onto collisions while `moveDocument`
  throws (AOSP read); `buildValidFatFilename` replacement set
  (AOSP read); background TaskQueues come in serial and concurrent
  flavors with per-channel binding (engine `DartMessenger.java`,
  reviewer's copy read); exiting isolates run their own native
  finalizers before the exit message (`isolate.cc`, reviewer's
  copy read).

## Known limits (unchanged from the brief)

Warm page cache (no root for `drop_caches`), so absolutes are
memcpy-ish — ratios are the finding. Provider open-path claims
(real fds, no pipes for local/USB/Downloads/Media) not
independently fetched. JNI direct-ByteBuffer
path and `TransferableTypedData` handoff unmeasured. No cold-cache
USB-OTG run. Channel loops ran UI-interleaved (each await can pay
frame-build time) while helper loops did not — absolutes carry
that handicap, ordering does not.

## Adding runs (scrub before commit)

Run logs capture the bench hostname and ephemeral VM-service URLs.
Before committing a new run: replace `host="…"` with
`host="devbox"`, replace loopback VM-service URLs with
`(redacted-vm-url)`, and grep for owner/machine identifiers.
Committed logs may be reruns — the table files state the run.
