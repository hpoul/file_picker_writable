# Brief for file_picker_writable PR #67: review 4, head `be607b3`

From the cycling_storyteller session, 30 September 2026. It follows `bench/fpw-pr67-review-3.md`.
An independent reviewer read from git refs only. Items are marked *verified* (read in docs or
source) or *inferred* (AOSP semantics from memory, to confirm on the device). Treat all of it as
evidence to check; the owner decides.

## Where this stands, and the owner's direction

**N1–N11 are resolved.** N12, the SDK path with the username, is fixed in the tree.

**Owner's call: the username is not personal data worth chasing.** It is already public in
`LICENSE` and in `.idea/dictionaries/herbert.xml` on `main`. So there is no history rewrite for
it, and the `herbert.xml` mention in `bench/fpw-pr67-review-3.md:157` is not a finding. The
hostname and VM-URL scrubs were the ones that mattered, and they are done.

**Direction: no further review round on the plans.** The owner is moving to implementation. The
remaining unknowns are empirical, so the right answer for them is device runs, not document
review. Fold the items below into the plans as you start, and expect review on the code PRs, one
reviewer per PR.

## Fix before the consumer builds against it

**F1. The fd is orphaned between `handoff()` and the helper's `fromHandoff`.** Medium, inferred.
- `handoff()` kills the root copy in the same call (`large-file-reads-plan.md:165-170`,
  `tree-writes-plan.md:119-124`), so closing that copy throws.
- Finalizers attach only in the consuming isolate (`large-file-reads-plan.md:244-249`).
- So if `Isolate.spawn` throws after `handoff()`, or the helper dies before constructing its
  wrapper, nobody may close the fd. The consumer hands off one descriptor per file, so this
  window recurs on every file.

**Fix:** allow `fromHandoff` on the root as the recovery path (the root is then the consuming
isolate), or add `closeHandoff(record)`. State that a kill before the helper's wrapper exists
leaks the fd.

**F2. Nothing forbids `handoff()` after a wrapper exists or after bytes were written.**
Medium-low, inferred.
- `WriteHandoff` carries no `bytesWritten` (`tree-writes-plan.md:128-133`), so a helper would
  `pwrite` from 0 over what the root wrote.
- A root wrapper left alive after handoff would close the live fd when it is garbage-collected.

**Fix:** `handoff()` throws `StateError` once a wrapper has been constructed on that copy.

**F3. The `impl` main-hop rule lists two fields and misses two.** Low-medium, verified.
- `FilePickerWritableImpl.kt:58-59` also holds `isInitialized` and `initOpenUrl`.
- `init()` (`:414-419`) sets and consumes them, and `onNewIntent` (`:401-404`, on main) writes
  `initOpenUrl`.
- Under the TaskQueue, `init` moves off main and races `onNewIntent`: a launch URL can be
  dropped or handled twice.

**Fix:** state the rule as "every `impl` field is touched on the main hop only", and hop `init`
too.

**S1. Add a by-name lookup, because the per-save listing cost is real.** Medium, verified by
reading.
- No plan has a lookup-by-name or stat verb, and identifiers are opaque, so every read of
  `trip.json` or `.howitwent` starts with `listChildren` of the parent.
- A trip folder holds every media file and the stills cache.
- With `openWrite`'s list-first (N10, no opt-out), each `moveEntry`'s list-first, and the
  consumer's repair listing, one autosave on Android is **four full listings of a media
  folder**. At the traversal plan's own 10k-child target (p95 under 5 s,
  `tree-traversal-plan.md:207-209`), a photo-heavy trip could spend tens of seconds listing per
  save. A section scan is one listing per trip folder, not one small read.

**Fix:** `lookupChild({identifier, name}) → ChildEntry?`, one query on the derived child URI,
with not-found returning null. It makes the scan O(trips), answers "does `.prev` exist" without
a listing, and turns `openWrite`'s list-first into one query.

**S2. The MIME-extension rule contradicts "callers pass real MIMEs".** Medium, inferred (confirm
on device).
- `FileSystemProvider.createDocument` appends the MIME's own extension when the display name's
  extension does not map to it. So `openWrite(name: '.howitwent', mimeType: 'application/json')`
  lands as `.howitwent.json`, and `trip.json.writing` as `trip.json.writing.json`.
- Verify-after makes the mismatch loud (`invalid-name`), so nothing is silent.
- But `tree-writes-plan.md:509-510` advises passing real MIMEs, which is wrong for every
  suffixed file the consumer's swap writes.

**Fix:** name this rule beside the FAT-set rule. Tell callers writing `.writing`, `.part` or
marker files to pass `application/octet-stream`, the plan's own default (`:146`), under which
names survive.

## One-sentence additions

- **F4, and the same ask for `deleteEntry`: say whether a gone identifier is `not-found` or a
  no-op.** A cancel racing a kill makes the root's post-kill `abortWrite(closeFd: false)` delete
  a document the helper already removed. The consumer's "delete `.prev` if present" has the same
  shape. The consumer maps `not-found` to "section damaged", so the delete half should treat
  `not-found` as success.
- **F5.** `close()` whose liveness check fails should still run the native cleanup (fd and
  buffer), then throw. Today it is unspecified, and the leak depends on where the throw lands
  relative to the finalizer detach.
- **F7.** Give the zero-byte write a carrier: a synthesized `ENOSPC` under the native domain in
  the details map, or a named kind.
- **F9.** Say what `scopeToken` in the handoff records is for (plausibly the helper's control
  calls, for writes), or drop it from `ReadHandoff`.
- **Dotfiles.** Add "names starting with `.` are ordinary names; nothing filters them", both for
  the leaf-name rule and for `listChildren`. The consumer's section marker is `.howitwent`, and
  its swap uses `.writing` and `.prev`. They all pass today by omission, and a hidden-file filter
  added later (the Android picker hides them) would break the marker silently.

## Wording

- **F6.** `large-file-reads-plan.md:74-75` still says `isLeaf`, and `:322-327` now mandates
  non-leaf shim bindings. Fix `:75`, and put the "measured with leaf calls" caveat beside the §3a
  table.
- **F8.** "The rename-back cannot re-mangle" (`tree-writes-plan.md:380-382`) is true only for
  names the provider stored. Say "verified, `move-partial` if it does not land".
- **F11.** `large-file-reads-plan.md:448` is the last FIFO sentence. Qualify it: per channel on
  the platform thread, and the concurrent TaskQueue gives that up.

## Consumer side, for the record

cycling_storyteller's `docs/PHONE-TRIP-STORAGE-PLAN.md` will be corrected on its side in two
places:
- the root calls `handoff()` and sends the record, rather than "sends the int";
- the byte path is a small C shim with a build step, rather than "leaf FFI calls into libc".

Checked against the consumer's sections plan (§3, §4, §5, §7, §8, §9): **nothing is impossible**.
- A tree grant covers `createDirectory` for a new trip folder with no picker
  (`tree-traversal-plan.md:41-43`, `scope-registry-plan.md:173-177`).
- `closeWrite(fsync: true)` covers `.writing` before the renames.
- The two renames onto just-freed names work.

S1 and S2 above are the two awkward parts.
