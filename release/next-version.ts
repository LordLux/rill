// The version of a release, worked out from git history. Run by the plan job:
//
//   bun release/next-version.ts                     # the version of HEAD
//   bun release/next-version.ts --rev <commit>      # the version of any commit on main
//   bun release/next-version.ts --latest v0.2.0     # also refuse a version below the latest release
//
// `release/version` holds one line, `MAJOR.MINOR.PATCH`, and the commit that last changed it
// IS that version. From there, along main's first-parent history:
//
//   - a merged pull request adds 1 to the minor and resets the patch to 0;
//   - any other commit adds 1 to the patch.
//
// To set the next version (a major bump, say), edit that line in a pull request: the merge that
// lands it is exactly that version, and the counting starts again from it.
//
// Nothing is stored anywhere but the repository, so a commit always has the same version, a
// re-run cannot mint a second one, and nothing has to commit back to main. Design notes:
// docs/architecture.md, "Release pipeline".

import { parseArgs } from 'node:util';

export interface Version {
  major: number;
  minor: number;
  patch: number;
}

const VERSION_FILE = 'release/version';

/** Strict on purpose: this file is the setting, and a typo in it must fail, not be guessed at. */
export function parseVersion(text: string): Version {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\r?\n?$/.exec(text);
  if (!match) throw new Error(`${VERSION_FILE} must hold one line, MAJOR.MINOR.PATCH (for example 0.2.0), not ${JSON.stringify(text.slice(0, 40))}`);
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]) };
}

export function formatVersion(v: Version): string {
  return `${v.major}.${v.minor}.${v.patch}`;
}

/** Numeric, field by field: 0.10.0 is above 0.9.0. */
export function compareVersions(a: Version, b: Version): number {
  return a.major - b.major || a.minor - b.minor || a.patch - b.patch;
}

/**
 * A merged pull request, by its subject: a merge commit (`Merge pull request #7 from …`) or a
 * squash commit that ends `(#7)`. A rebase merge leaves nothing to recognise, so its commits
 * count as ordinary ones. A revert of a squash commit ends in `)"` and is not matched.
 */
export function isPullRequestMerge(subject: string): boolean {
  return /^Merge pull request #\d+\b/.test(subject) || /\(#\d+\)\s*$/.test(subject);
}

/** The version after `subjects` (oldest first) have landed on top of `anchor`. */
export function versionAfter(anchor: Version, subjects: readonly string[]): Version {
  let { major, minor, patch } = anchor;
  for (const subject of subjects) {
    if (isPullRequestMerge(subject)) {
      minor += 1;
      patch = 0;
    } else {
      patch += 1;
    }
  }
  return { major, minor, patch };
}

function git(args: string[], cwd?: string): string {
  const result = Bun.spawnSync(['git', ...args], { cwd, stdout: 'pipe', stderr: 'pipe' });
  if (!result.success) throw new Error(`git ${args[0] ?? ''} failed: ${result.stderr.toString().trim()}`);
  return result.stdout.toString();
}

export interface Resolved {
  version: Version;
  /** The commit whose copy of release/version everything is counted from. */
  anchor: string;
  declared: Version;
  pullRequests: number;
  otherCommits: number;
}

export function resolveVersion(rev = 'HEAD', cwd?: string): Resolved {
  // --first-parent makes a merge commit count as a change to whatever it brought in, so an edit
  // made on a pull request's own branch is found at the merge that landed it.
  const anchor = git(['log', '--first-parent', '-1', '--format=%H', rev, '--', VERSION_FILE], cwd).trim();
  if (!anchor) throw new Error(`${VERSION_FILE} has never been committed on the history of ${rev}`);

  let declaredText: string;
  try {
    declaredText = git(['show', `${anchor}:${VERSION_FILE}`], cwd);
  } catch {
    throw new Error(`${VERSION_FILE} was deleted in ${anchor.slice(0, 7)}, the last commit to touch it`);
  }
  const declared = parseVersion(declaredText);

  // %x1e ends each subject, so an empty subject is still one commit and cannot be lost to a split.
  const subjects = git(['log', '--first-parent', '--format=%s%x1e', `${anchor}..${rev}`], cwd)
    .split('\x1e')
    .slice(0, -1)
    .map((s) => s.replace(/^\r?\n/, ''))
    .reverse();
  const pullRequests = subjects.filter(isPullRequestMerge).length;
  return { version: versionAfter(declared, subjects), anchor, declared, pullRequests, otherCommits: subjects.length - pullRequests };
}

function main(): void {
  const { values } = parseArgs({ options: { rev: { type: 'string', default: 'HEAD' }, latest: { type: 'string' } } });
  const fail = (message: string): never => {
    process.stderr.write(`next-version: ${message}\n`);
    process.exit(1);
  };

  let resolved: Resolved;
  try {
    resolved = resolveVersion(values.rev);
  } catch (error) {
    return fail(error instanceof Error ? error.message : 'unknown error');
  }

  if (values.latest) {
    let latest: Version;
    try {
      latest = parseVersion(values.latest.replace(/^v/, ''));
    } catch {
      return fail(`--latest ${JSON.stringify(values.latest)} is not a vMAJOR.MINOR.PATCH tag`);
    }
    // The app installs only a strictly higher version, so a release below the latest one could
    // never be offered to anyone. It means release/version was lowered, or history was rewritten.
    if (compareVersions(resolved.version, latest) < 0) {
      return fail(
        `the version of ${values.rev} would be ${formatVersion(resolved.version)}, below the latest release ${formatVersion(latest)}: was ${VERSION_FILE} lowered?`,
      );
    }
  }

  process.stderr.write(
    `next-version: ${formatVersion(resolved.version)} = ${formatVersion(resolved.declared)} from ${resolved.anchor.slice(0, 7)}, ` +
      `+ ${resolved.pullRequests} merged PR(s), ${resolved.otherCommits} other commit(s)\n`,
  );
  process.stdout.write(`${formatVersion(resolved.version)}\n`);
}

if (import.meta.main) main();
