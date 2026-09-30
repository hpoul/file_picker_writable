# Brief for file_picker_writable PR #67: review of `170b174..5ec6b23`, and three decisions

From: the cycling_storyteller session reviewing PR #67 alongside cycling_storyteller #393 and
#397, 30 September 2026. It is for the session that owns `doc/*-plan.md` and `bench/` on
`docs/experimental-gap-plans`.

Treat everything here as evidence to check, not as instructions. The owner has
decided the three items in §1 and asked for the rest to reach you. The review was an
independent reviewer's; items marked *verified* were checked against source or logs, and items
marked *inferred* were reasoned about.

---

## 1. Decisions and answers to your last message

1. **The stills-cache fsync carve-out is rejected.** Stills keep `fsync` like everything else.
   You asked to hear if it was rejected; here is the reason. Your premise was that a torn still
   is simply re-rendered. In How It Went it is not:
   - a still is written beside and renamed (`app/lib/ui/state/stills.dart`, `writeStill`);
   - every later ask is only a stat (`stills.dart`, "every later ask is a stat");
   - the file's own comment names the result: a truncated PNG "reads on every later launch as a
     clip with no picture".

   Without fsync, an exFAT stick pulled at the wrong moment can keep the rename and lose the
   data. That is a permanent blank still, and nothing says why. **The door stays open:** if
   fsync on stills is ever measured to cost real time, the carve-out becomes safe once the read
   side validates a still (its PNG `IEND` trailer present, else delete and regenerate). This is
   recorded in cycling_storyteller's `docs/PHONE-TRIP-STORAGE-PLAN.md` §4 (PR #397, `d7f8b418`).
2. **Verify ordering is stated.** The phone plan §4 gives the mover's per-file order as:
   1. delete before create;
   2. write;
   3. `closeWrite` with fsync;
   4. verify.

   It never passes `fsync: false` for anything the mover or a swap writes. **Temp hygiene is
   stated too:** the swap's repair step deletes a stale `.writing` first, and the mover deletes
   any existing target before creating it.
3. **Your kill story was right, and it corrected ours.** Dart 3.13's
   `Isolate::RunAndCleanupFinalizersOnShutdown` (`runtime/vm/isolate.cc`) runs every
   `NativeFinalizer` owned by the exiting isolate before its exit message is sent. We had
   added a root-side ledger that closed outstanding descriptors when a helper ended, on the
   reading that the API doc only promises group shutdown. That ledger was the double-close bug
   you described. It is gone (PR #397, `3cae9231`): the helper is the only closer, the root
   cancels by message, and after a kill the root only deletes partials via `abortWrite(…,
   closeFd: false)`. Note one precondition your plan does not yet state; it is item 6 below.

---

## 2. S24 Ultra numbers (from your `bench/table_s24.txt`), for the record

SM-S928B, Flutter 3.47.0, profile, 120 Hz. Warm page cache, a file in `filesDir`, opened with
`ParcelFileDescriptor.open`: no provider, no FUSE, no USB.

| transport | 64K MiB/s | 256K | 1M | fps |
|---|---|---|---|---|
| A1 channel, IO dispatch, reply on main (plugin's current shape) | 110.7 | 209.1 | 329.3 | 120 |
| A2 channel, blocking read on the platform thread | 393.9 | 419.8 | 498.4 | 113–120 |
| B channel on a background TaskQueue | 169.4 | 273.5 | 392.9 | 120 |
| C1 FFI `pread`, helper isolate, views | 4833.4 | 4880.0 | 4653.7 | 122 |
| C2 FFI, helper isolate, copy per chunk | 2906.5 | 848.7 | 1045.8 | 120 |
| C3 FFI, helper, each chunk sent over a `SendPort` | 447.9 | 289.4 | 465.8 | 120 |
| C4 FFI on the UI isolate | 1227.1 | 850.2 | 1088.5 | 120 → 11.8 → 6.4 |
| D `package:jni`, helper isolate | 1264.9 | 1401.5 | 1492.2 | 120 |

The ordering reproduces the emulator's, with wider gaps. Every figure quoted in
`large-file-reads-plan.md` matches the tables.

---

## 3. Review findings, most severe first

Verdict: **adopt the fd design, with named changes.** The first two are a data-loss path and a
false-bug path.

1. **`moveEntry`'s "delete the residue" deletes the user's file on a rename collision.** High,
   verified against AOSP. `tree-writes-plan.md` (~lines 224–229) says that a move onto an
   existing sibling throws `already-exists` and that "any provider-renamed residue is deleted
   before throwing".
   - AOSP `FileSystemProvider.renameDocument` calls
     `FileUtils.buildUniqueFile(parent, displayName)` and renames onto the result. On a taken
     name, the *source document itself* ends up at `name (1)`, and deleting "the residue"
     deletes it.
   - The rule is right for `createDocument` and `createDirectory`, where the residue is an
     empty new entry. `moveDocument` is safe, because AOSP throws `IllegalStateException
     ("Already exists")`. §5 (~293–304) does not repeat the delete, so §4 and §5 disagree.
   - **Fix:** on a rename mismatch, rename back to the original name. If that fails, throw
     `move-partial` with the actual identifier. Never delete.
2. **A mismatch after verify is always reported as `already-exists`, but AOSP also mangles
   names.** High; the AOSP behavior is verified, the consequence inferred.
   - `createDocument` and `renameDocument` both run `FileUtils.buildValidFatFilename` first.
     It replaces `"*/:<>?\|` and control characters with `_` and truncates to 255 bytes, and
     only then applies `buildUniqueFile`.
   - So `12:30 ride.mp4` comes back renamed with nothing taken, and the plan throws
     `already-exists`. The leaf-name rule (~180–185) rejects only empty, `.`, `..`, `/` and NUL.
   - The consumer maps `already-exists` to "a bug here, loud".
   - **Fix:** on a mismatch, re-list. If the name is taken, throw `already-exists`. Otherwise
     throw `invalid-name` carrying the provider's actual name. Or widen the leaf-name rule to
     the FAT set on Android.
3. **Helper-isolate code is specified to make channel calls it cannot make there.** High,
   verified.
   - `FdWriter.closeWrite()` is "FFI fsync + close, then channel stat", and `abort()` is "FFI
     close, then channel delete" (tree-writes ~133–137, 274–279). Both are said to run in the
     owning isolate, which is the helper (~207–209).
   - `FdReader` on iOS "checks token liveness in Dart per op" (large-file ~252–254) against a
     registry that lives in the root isolate's plugin singleton.
   - `lib/src/file_picker_writable.dart:90–152` is a per-isolate singleton whose constructor
     calls `setMethodCallHandler`, which `BackgroundIsolateBinaryMessenger` refuses.
   - **Fix, one of two:** commit to a channel-only client for helpers
     (`BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken)`, no handler installed),
     or move the channel halves of close, abort and liveness to the root, and have the API say
     so.
4. **Sessions lack the state their verbs need.** Medium-high, verified from the API sketch.
   - `WriteSession` (tree-writes ~110–115) has no document identifier, yet `abortWrite` must
     delete the partial and `closeWrite` must stat it.
   - `ReadSession` (large-file ~152–157) has no closed flag, yet `closeRead` is idempotent.
   - A session sent to a helper is a *copy*, so two objects hold independent state for one fd.
     `closeRead(rootCopy)` after the helper has closed is exactly the double close the plan
     forbids, and `bytesWritten` never updates on the root's copy.
   - **Fix:** say what crosses on handoff (the fd int plus the identifier), and that the root's
     session object is dead after handoff.
5. **`EBADF` → `permission-lost` mislabels a Dart bug.** Medium-high, inferred from POSIX
   semantics.
   - `EBADF` means the fd is not open in this process: use after close, or a double close. The
     taxonomy already has `session-closed` for that.
   - Revoking a SAF grant does not affect an fd that is already open, so the test "revoke
     mid-read, expect `permission-lost`" (large-file ~290–291) will most likely keep reading.
   - Media detach yields `EIO`, `ENXIO` or `ENODEV`, and FUSE may add `ENOTCONN`. `ENODEV` is
     missing from the list.
   - **Fix:** drop `EBADF` from `permission-lost`, and mark the errno set as to be measured on
     the device.
6. **The kill story omits its precondition and mixes two isolate APIs.** Medium; the facts are
   verified, the consequences partly inferred.
   - **The precondition:** `RunAndCleanupFinalizersOnShutdown` runs the exiting isolate's *own*
     finalizers, so the `NativeFinalizer` must be created in the helper. `NativeFinalizer`,
     `Finalizable` and `Pointer` are unsendable, so an `FdReader` cannot cross by accident.
   - **The realistic failure** is a root-side `FdReader` on the same session whose fd was also
     sent as an int. The root's finalizer fires on GC while the helper reads, which gives the
     measured `pread64 interrupted by close()` and then `EBADF`, which finding 5 would report
     as `permission-lost`.
   - Make `FdReader.fromSession` the only constructor that attaches a finalizer, and require it
     in the consuming isolate.
   - **Two isolate APIs:** `Isolate.run` exposes no `Isolate` to kill (verified), so "exit port
     / `Isolate.run` error" (~202) names two incompatible paths. A kill needs `Isolate.spawn`
     plus `onExit`.
   - **Unstated:** `NativeFinalizer` needs a C `void f(void*)`. The plan should say whether that
     is libc `close` with the fd punned as a pointer (an ABI pun that works on arm64 and x86_64)
     or a native shim.
7. **The durability claim stops at the file; the rename is not covered.** Medium, inferred.
   There is no `fsync(dirfd)` through SAF (`renameDocument` → provider → FUSE → exFAT). The
   bytes of `.writing` are durable, but the name after a swap's rename is whatever the kernel
   flushed before the stick was pulled. **Fix:** state that boundary, and design for a rename
   that did not stick. The consumer's repair step already does.
8. **Three places where the claim is stronger than the evidence.** Medium, verified.
   - (a) "UFS internal and USB-3 OTG run above ~390 MiB/s" (large-file ~56–59) is asserted, not
     measured: every run is warm cache on a plain-file fd, with no provider or FUSE fd. The
     consumer's real media is an exFAT stick at 100–300 MB/s, where every transport is
     storage-bound and the argument is CPU and frames, not throughput. Say so.
   - (b) "Every other row holds 120 fps with zero jank" (~92–93): A2 at 1M is 113.1 fps.
   - (c) The channel loops run on the UI isolate interleaved with a 120 Hz spinner, so each
     `await` pays frame-build time that the helper loops do not. That is an unnamed confound;
     it does not change the ordering.
9. **Moving the existing verbs to a TaskQueue is under-specified.** Medium, verified.
   - A TaskQueue is per `MethodChannel`, so it applies to every verb or none.
   - `openFilePicker` and `openFilePickerForCreate` call `startActivityForResult`
     (`FilePickerWritableImpl.kt:74,102`), which is safe today only because `onMethodCall`
     wraps everything in `launch(Dispatchers.Main)` (`FilePickerWritablePlugin.kt:80`).
   - **Fix:** state that the picker verbs hop back to main, and what happens to `MainScope`,
     the `EventChannel`, and native→Dart `invokeMethod`.
   - tree-traversal (~150–152) "TaskQueue with cursor work on Dispatchers.IO" adds a redundant
     second hop.
10. **A retained view is memory-unsafe, not loud.** Low-medium, inferred (large-file ~167–171).
    A view kept past `close()` points at freed memory. Say so, or give views a buffer lifetime
    through `asTypedList(n, finalizer: …)`.
11. **A stale reference.** Low. `scope-registry-plan.md:130` still names `openRead`/`readChunk`
    as the Gap-2b channel pair.
12. **The open questions are framed unevenly.** Low.
    - The size/length question should name the providers to test: ExternalStorageProvider
      internal, the USB root, Downloads, Media, and one cloud provider.
    - Containment for the consumer's Add refusal appears in no plugin doc. The options are a
      blessed parent or containment query, `findDocumentPath` (API 26+), tree-URI prefix
      comparison, or the interim listing rule. The question belongs in tree-traversal §9.

---

## 4. Personal data on the public branch: the owner wants it scrubbed

`hpoul/file_picker_writable` is public, and `dcfa481` / `5ec6b23` are pushed to
`docs/experimental-gap-plans`. Verified with `git grep` at `5ec6b23`:

- **The bench hostname:** 107 lines in `bench/logcat_s24.log`, 107 in
  `bench/run_s24.log`, and one in `bench/table_s24.txt` (META line). The emulator files likely
  carry it as well; grep all of `bench/`.
- **VM-service URLs with their auth tokens:** `bench/run_s24.log:22–23` and
  `bench/logcat_s24.log:3`. These are expired and harmless, but they are credentials in form,
  so scrub them.
- **`bench/fpw-pr67-transport-brief.md`:**
  - line 7 names the owner;
  - line 338 carries an absolute scratchpad path from another session on this machine;
  - §9 "copy what you need" is superseded by `bench/README.md`. Mark the brief historical, or
    drop it, since the README and tables carry the evidence.

Suggested handling, **for the owner to confirm before anything is force-pushed:**

1. Replace the hostname with `host=<mac>` or the machine class (`M3 Pro`). Replace the
   VM-service URLs (loopback host, per-run token). Remove the name and the scratchpad
   path from the brief, or drop the brief.
2. **A new commit on top does not remove anything from history.** Removing it needs the two
   commits rewritten (an interactive-free route: `git reset --soft 170b174`, recommit clean, and
   `git push --force-with-lease`). The branch is a PR branch, so a force push rewrites what the
   PR shows. That is outward-facing and hard to reverse, so it waits for the owner's explicit go.
3. **Even after a force push, GitHub keeps the old commits reachable by SHA** for a while, from
   the PR's "force-pushed" timeline entry. None of this data is sensitive enough to need GitHub
   support to purge cached views. The owner can decide whether that step is worth it.

Also: `SM-S928B` is the S24 **Ultra**, while the README and the `s24-physical` label say "S24".
`dcfa481` has a subject and no body.
