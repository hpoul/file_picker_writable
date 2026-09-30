# Brief for file_picker_writable PR #67: re-review of head `7fb2c31`

From the cycling_storyteller session, 30 September 2026. It follows `bench/fpw-pr67-review-2.md`.
An independent reviewer read everything from git refs (head `7fb2c31`, compared with `5ec6b23`).
Items are marked *verified* (read in the docs, source or logs) or *inferred* (reasoned from
platform semantics, not run). Treat all of it as evidence to check; the owner decides.

## Verdict: adopt with named changes

Every finding from review-2 is addressed or acknowledged. The scrub of the bench logs, the
brief and the rewritten commit messages is complete. Seven items remain before this branch is
the contract the consumer builds against:
- N1: the kill path throws;
- N2: the FIFO promise;
- N3: the rename mangle;
- N4 and N5: errno and zero-length writes;
- N6, N7 and N9: one-liners.

N8, N10 and N11 are wording.

## Review-2 status in brief

| Item | Status |
|---|---|
| §1 stills keep fsync, verify ordering, kill story | Resolved |
| moveEntry never deletes a renamed source | Resolved |
| Helper channel client, finalizer precondition, `Isolate.spawn` | Resolved |
| Durability boundary, evidence claims | Resolved |
| TaskQueue, view lifetime, stale refs, open questions | Resolved |
| Changed name ≠ `already-exists` | Resolved for create; partly for rename (N3) |
| Session state and handoff | Partly resolved (N1) |
| EBADF mapping | Resolved in 2b; the Gap 3 test is stale (N7) |
| Hostname, VM URLs, owner's name, serials, commit messages | Scrubbed |
| **Absolute paths** | **Not scrubbed** (see the end of this brief) |

Also partly done: "S24" versus "S24 Ultra" labels, and brief §9 not yet marked historical.

## Findings, most severe first

**N1. The "dead after handoff" rule breaks the kill path the docs prescribe.** High, verified.
- `tree-writes-plan.md:120-122` and `large-file-reads-plan.md:202-204` say the sender's copy is
  dead after handoff: any use throws `StateError`.
- `tree-writes-plan.md:216-219` has the root call `abortWrite(session, closeFd: false)` after a
  kill. The root's only session object is that dead copy, so the prescribed call throws before
  it deletes the partial.
- Nothing names the mechanism that marks the copy dead, because a `SendPort` send copies
  silently.
- `FdReader.fromSession` and `FdWriter.fromSession` take a session object, while the consumer
  sends ints.

**Fix:** a `session.handoff()` that returns a sendable record (fd, identifier, seekable/length or
canFsync) and flips the local flag; a `fromHandoff` constructor on the receiving side; and
`abortWrite(…, closeFd: false)` exempted from the dead-copy rule, or taking an identifier, with
a statement that it never touches the fd. The consumer depends on that call
(cycling_storyteller `docs/PHONE-TRIP-STORAGE-PLAN.md`, §3 on the one closer).

**N2. "Control calls still complete FIFO" is false on a concurrent TaskQueue.**
Medium-high; verified against the docs' own text.
- `large-file-reads-plan.md:263-266` and `tree-writes-plan.md:273-277` put every control verb
  on one shared concurrent TaskQueue.
- `large-file-reads-plan.md:237-238`, `tree-writes-plan.md:204` and `:395` still promise FIFO.
- A caller that fires a delete and then a create of the same name without awaiting can be
  reordered.

**Fix:** drop the FIFO sentence, and state "no ordering across in-flight control calls; sequence
by awaiting". Add that `impl`'s mutable state (the activity, the pending pick) is only touched on
the main hop.

**N3. A rename mangle leaves the user's file at a new name while throwing.** Medium, inferred.
- `tree-writes-plan.md:331-334`: on a FAT-cleaned rename the plan throws `invalid-name`, and
  the file stays at the cleaned name, on the reasoning that a rename-back would re-mangle.
- It would not. The rename-back target is the original name, which the file already had.
- As written, an exception path silently changes the entry's identifier.

**Fix:** rename back and verify in both mismatch branches, and throw `move-partial` if that fails,
as the collision branch at `:328-331` already does.

**N4. Nothing says how `errno` is captured.** Medium, inferred.
- A second FFI call to `__errno` runs after Dart code has resumed, where a safepoint can
  intervene. A stale value mis-maps the taxonomy kind and fools an `EINTR` retry.
- `EINTR` appears nowhere in `doc/`.
- cycling_storyteller #393's `app/lib/durable_copy.dart` has the same pattern, and its reviewer
  flagged it.

**Fix:** since the plan already adds a native close shim (`large-file-reads-plan.md:288-290`),
route `pread`, `pwrite` and `fsync` through shims that return `-errno`, and state that `EINTR`
retries.

**N5. `pwrite` returning 0 is not handled.** Medium, inferred.
- `tree-writes-plan.md:294-296`: "looped to full length". A loop that treats 0 as progress spins
  forever on a FUSE or network volume that returns 0 when full, and never reaches its cancel
  check. Android external storage is FUSE-backed.
- cycling_storyteller #393 fixed the same bug in `durable_copy.dart`.

**Fix:** 0 from `write` or `pwrite` is a loud ENOSPC-shaped failure, tested with a stubbed fd.

**N6. Token liveness is specified two ways.** Low-medium, verified.
- `large-file-reads-plan.md:277-278` says "per op".
- `:302-305` says "at reader construction and close, not per op".
- `scope-registry-plan.md:131-132` and `:185` (`closeRead` is plain FFI close) disagree with
  each other.

**Fix:** keep the construction-and-close version everywhere.

**N7. Gap 3 still expects `permission-lost` from a revoke mid-write.** Low-medium, verified.
`tree-writes-plan.md:400-401` contradicts `large-file-reads-plan.md:291-293, 330-333`: revoked
grants do not fail open fds. **Fix:** use the 2b wording. The next `closeWrite` stat or
`openWrite` fails `permission-lost`.

**N8. The fsync durability test cannot fail for a missing fsync.** Low-medium, inferred.
`tree-writes-plan.md:411-412`, "write, close, kill, read back intact". Killing the process does
not drop the page cache, and there is no `F_NOCACHE` or `O_DIRECT` through a provider fd, so the
read-back passes with or without fsync. **Fix:** state that the read-back proves the bytes, not
the durability, which only a stick pull tests. The consumer's plan was corrected the same way
(cycling_storyteller `9874f1b4`).

**N9. The "No native code" claims are stale.** Low, verified.
- `large-file-reads-plan.md:191-195` ("reads are pure Dart FFI") and `:260-262` predate the
  close shim, and after N4 the errno shims too.

**Fix:** say once that a C shim needs a build step in the podspec and in the Android plugin.

**N10. `openWrite` list-first is quadratic for bulk writes.** Low, inferred.
- `tree-writes-plan.md:280-281`: every `openWrite` lists the whole parent
  (`queryChildDocuments` has no name filter), so a move of N clips into one folder costs N full
  listings.
- The verify-after path already catches a taken name, so list-first is an optimization.

**Fix:** say so, or allow an opt-out for bulk.

**N11. "FAT-backed provider" is the wrong precondition.** Low. This comes from memory of AOSP,
not re-fetched. `FileSystemProvider.createDocument` and `renameDocument` call
`buildValidFatFilename` unconditionally, so ext4 and f2fs internal storage also rewrite `12:30
ride.mp4`. **Fix:** say "every `FileSystemProvider`-based provider", and do not gate the test on
FAT media.

## Consumer-side items, already handled on cycling_storyteller PR #397 (`9874f1b4`)

- The phone plan still said `EBADF` ⇒ `permission-lost`. It now says `session-closed`, matching
  the plugin.
- The phone plan now records the plugin's handler-free helper channel client, and keeps opening
  on the root isolate.
- The ≤1 MiB whole-file read exemption on the root isolate stands on the consumer's side. The
  plugin could name that exemption, so that "load-bearing, not advisory"
  (`large-file-reads-plan.md:79-80`) and the consumer agree.

## Personal data still on the public branch

`doc/tree-traversal-plan.md:246` and `doc/tree-writes-plan.md:466` carry
`$ANDROID_HOME/platforms/android-36/android.jar` [scrubbed: owner's username in path]. That is the owner's username
in a path. It has been on the public branch since `170b174`, the first push, so this rewrite did
not introduce it; it is not on `origin/main`.

Suggested replacement: `$ANDROID_HOME/platforms/android-36/android.jar`. A plain commit on top
fixes the files. Removing it from history would mean rewriting commits older than the PR's own
first push and force-pushing again, and it is low-sensitivity, so that waits for the owner's
explicit go. (`LICENSE:3` and `.idea/dictionaries/herbert.xml` carry the name on `main` already,
which is expected.)
