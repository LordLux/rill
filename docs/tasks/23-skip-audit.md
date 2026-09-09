# Task 23 — The skip audit

**Prerequisite:** `CLAUDE.md`, and `app/tool/test_suite_guard.dart`.

`bun test` reports **103 skips** in the sidecar suite. 13 are the F20 retirement
blocks, kept deliberately as the executable record of what was measured. The
other **90 have never been audited.**

This matters because of what happened three weeks ago: 19 Flutter tests stopped
running when a file failed to compile, and nobody noticed for three weeks
because an unloadable file scores as exactly −1 against a suite that already had
two known failures. A skip is the quieter version of the same thing — it reports
as a skip, and everybody reads "skipped" as "fine".

The orphan-process test hid in exactly this state for two tasks: written,
skipped on Windows for a flake, reported as passing in two consecutive task
reports. When it was finally un-skipped it passed — and the mutation check
showed the detector was broken anyway.

**So the default is not "leave it".** Every skip either has a live reason or it
goes.

---

## 1. Find them

Enumerate every skipped test in **both** suites — the sidecar's 103 and whatever
Flutter reports. `bun test` and `flutter test --reporter json` both name them.

Do not work from a grep for `skip`. A test can be skipped by a runtime
condition, an environment variable, a `describe.skip`, an early `return`, or a
guard at module load that skips the whole file. Enumerate from the **runner's
own output**, then trace each back to the mechanism.

## 2. Categorise

For each skip, establish which of these it is:

| Category | Meaning | Action |
|---|---|---|
| **Network-gated** | Needs the live API; opt-in by design | Keep. Confirm the gate still works and the message says how to run it |
| **Fixture-gated** | Needs `sidecar/fixtures/`, which is gitignored | Keep. Confirm it skips rather than throwing on a clean clone |
| **Deliberately retired** | Records a decision, like the F20 blocks | Keep. Confirm a comment says which decision and where it is documented |
| **Environment-gated** | Needs a binary, a DLL, a platform | Keep only if the gate is still true. The orphan test was skipped for a flake that had been fixed |
| **Forgotten** | No live reason. Skipped to get a suite green, never revisited | Un-skip it, or delete it |

**Report the breakdown by category, with counts — not a list of 90.** Name
individual tests only in the last two categories, where a decision is needed.

## 3. Resolve the forgotten ones

For each, one of:

- **Un-skip.** Then run it. If it fails, that is a finding and probably a real
  bug — say so rather than re-skipping.
- **Delete.** If it tests something that no longer exists, or duplicates live
  coverage. Say what it covered and what covers it now.

**Do not re-skip anything to keep the suite green.** If un-skipping surfaces a
failure, report the failure. A red test that describes a real problem is worth
more than a green suite that does not run it — this project has now paid for
that lesson twice.

## 4. Check the gates still hold

For every skip you keep, confirm the *condition* is still true. The orphan test
was skipped for a Windows flake that had already been fixed; nobody re-checked.

Cheapest version: for each gated group, satisfy the gate once and confirm the
tests run and pass. Network gate — run with the env var. Fixture gate — run with
fixtures present. Say which groups you exercised and which you could not.

## 5. Make the count visible

`test_suite_guard.dart` catches a suite producing **zero** tests. It does not
catch a suite whose skip count quietly grows.

Add the sidecar equivalent if `bun test` needs one — the last audit found `bun
test` reports an unloadable file as a separate error and exits 1, so it may
already be covered. Check rather than assume.

Then consider whether a skip count belongs in the guard: not a hard floor, which
gets lowered the first time it is inconvenient, but something that makes an
unexplained rise visible. Propose it; do not build a framework.

---

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- Every remaining skip has a live reason, and a comment saying what it is
- The forgotten ones are un-skipped or deleted, with each named and justified
- Any failure surfaced by un-skipping is reported, not hidden

**Report the category breakdown with counts**, then the individual decisions for
anything forgotten or environment-gated.

## Out of scope

Fixing bugs that un-skipping reveals — report them, do not chase them. New
tests. Any feature work.

## Stop conditions

- **Un-skipping reveals more than a couple of real failures.** Report them and
  stop; a batch of newly-visible bugs is its own task, not a tail on this one.
- **A skip cannot be categorised** — nobody knows why it exists and the history
  does not say. Report it as unexplained rather than guessing; that is a real
  answer.
