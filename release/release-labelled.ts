// Whether a release is wanted, given which merged pull requests carry the release label. Run by the
// plan job, after release-needed.ts has said something shipped changed:
//
//   bun release/release-labelled.ts --since v0.12.0 --label release --repo owner/name   # prints true or false
//
// A merged pull request adds 1 to the minor (next-version.ts), and it used to be released the moment
// it merged. Now it is released only when it carries the label; an unlabelled one waits, and the
// release the next labelled one makes covers it, notes and all, because notes run from the previous
// release. Anything that is not a pull request merge (a commit pushed to main, a revert) is an
// ordinary patch commit and still releases, as before.
//
// The label can go on after the merge: the daily run asks again and finds it. The version is not
// affected by labels (an unlabelled merge still counts +1 to the minor, so a commit has one version
// whatever its labels say, and a label added later cannot change a number already published); the cost
// is that the minor can skip a number.
//
// `workflow_dispatch` does not ask: a person starting a run wants it built.

import { parseArgs } from 'node:util';
import { isPullRequestMerge } from './next-version.ts';

export const DEFAULT_LABEL = 'release';

/** The number of the pull request a merge subject names, or null for an ordinary commit. */
export function pullRequestNumber(subject: string): number | null {
  if (!isPullRequestMerge(subject)) return null;
  const match = /^Merge pull request #(\d+)\b/.exec(subject) ?? /\(#(\d+)\)\s*$/.exec(subject);
  return match ? Number(match[1]) : null;
}

export interface Decision {
  wanted: boolean;
  commits: number;
  /** Commits that are not pull request merges: each is a patch release in its own right. */
  ordinary: number;
  pullRequests: number[];
  labelled: number[];
}

/**
 * `subjects` are the first-parent commits since the latest release. A release is wanted when one of
 * them is an ordinary commit, or a pull request merge whose pull request `isLabelled`.
 */
export function decide(subjects: readonly string[], isLabelled: (pullRequest: number) => boolean): Decision {
  const pullRequests: number[] = [];
  const labelled: number[] = [];
  let ordinary = 0;
  for (const subject of subjects) {
    const number = pullRequestNumber(subject);
    if (number === null) {
      ordinary += 1;
    } else {
      pullRequests.push(number);
      if (isLabelled(number)) labelled.push(number);
    }
  }
  return { wanted: ordinary > 0 || labelled.length > 0, commits: subjects.length, ordinary, pullRequests, labelled };
}

function git(args: string[], cwd?: string): string {
  const result = Bun.spawnSync(['git', ...args], { cwd, stdout: 'pipe', stderr: 'pipe' });
  if (!result.success) throw new Error(`git ${args[0] ?? ''} failed: ${result.stderr.toString().trim()}`);
  return result.stdout.toString();
}

/** The subjects of main's first-parent commits after `since`, oldest first, as next-version.ts counts them. */
export function subjectsSince(since: string, cwd?: string): string[] {
  // %x1e ends each subject, so an empty subject is still one commit and cannot be lost to a split.
  return git(['log', '--first-parent', '--format=%s%x1e', `${since}..HEAD`], cwd)
    .split('\x1e')
    .slice(0, -1)
    .map((subject) => subject.replace(/^\r?\n/, ''))
    .reverse();
}

/** Whether pull request `number` of `repo` carries `label`, asked of the `gh` the runner provides (`gh` is the command, for a test to swap). */
export function hasLabel(repo: string, number: number, label: string, gh: readonly string[] = ['gh']): boolean {
  const result = Bun.spawnSync([...gh, 'pr', 'view', String(number), '--repo', repo, '--json', 'labels'], { stdout: 'pipe', stderr: 'pipe' });
  if (!result.success) throw new Error(`gh pr view #${number} failed: ${result.stderr.toString().trim()}`);
  const parsed = JSON.parse(result.stdout.toString()) as { labels?: { name: string }[] };
  return (parsed.labels ?? []).some((entry) => entry.name === label);
}

function main(): void {
  const { values } = parseArgs({
    options: {
      since: { type: 'string' },
      label: { type: 'string', default: DEFAULT_LABEL },
      repo: { type: 'string', default: process.env.GITHUB_REPOSITORY },
    },
  });
  if (!values.since) {
    // No release yet: the first one is not waiting for a label.
    process.stderr.write('release-labelled: no previous release, so there is one to make\n');
    process.stdout.write('true\n');
    return;
  }
  const label = values.label ?? DEFAULT_LABEL;
  try {
    if (!values.repo) throw new Error('no --repo and no GITHUB_REPOSITORY');
    const repo = values.repo;
    const decision = decide(subjectsSince(values.since), (number) => hasLabel(repo, number, label));
    const list = (numbers: number[]): string => (numbers.length > 0 ? numbers.map((n) => `#${n}`).join(', ') : 'none');
    process.stderr.write(
      `release-labelled: ${decision.commits} commit(s) since ${values.since}: ${decision.ordinary} ordinary, ` +
        `${decision.pullRequests.length} pull request(s) (${list(decision.pullRequests)}), labelled "${label}": ${list(decision.labelled)}; ` +
        `${decision.wanted ? 'a release is wanted' : 'no release is wanted'}\n`,
    );
    process.stdout.write(`${decision.wanted}\n`);
  } catch (error) {
    // Unknown: build rather than guess that nobody wanted one.
    process.stderr.write(`release-labelled: ${error instanceof Error ? error.message : error}; releasing to be safe\n`);
    process.stdout.write('true\n');
  }
}

if (import.meta.main) main();
