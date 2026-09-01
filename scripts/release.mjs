#!/usr/bin/env node
/**
 * Cut releases from CHANGELOG [Unreleased] after main CI is green.
 *
 *   node scripts/release.mjs plan
 *   node scripts/release.mjs apply --dir <fixture>
 *   node scripts/release.mjs ci
 *
 * Current version is the newest ## [X.Y.Z] heading in CHANGELOG.md.
 * Feature branches write notes under [Unreleased]; do not invent a version heading.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = join(SCRIPT_DIR, "..");
const CHANGELOG_FILE = "CHANGELOG.md";

export const RELEASE_COMMIT_PREFIX = "chore(release):";

/** @typedef {"major" | "minor" | "patch"} SemverBump */
/** @typedef {"auto" | SemverBump} BumpRequest */

/**
 * @param {string} version
 * @returns {{ major: number, minor: number, patch: number }}
 */
export function parseSemver(version) {
  const match = String(version).trim().match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!match) throw new Error(`not a patch-level semver: ${version}`);
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]) };
}

/**
 * @param {string} version
 * @param {SemverBump} bump
 */
export function bumpSemver(version, bump) {
  const parsed = parseSemver(version);
  switch (bump) {
    case "major":
      return `${parsed.major + 1}.0.0`;
    case "minor":
      return `${parsed.major}.${parsed.minor + 1}.0`;
    case "patch":
      return `${parsed.major}.${parsed.minor}.${parsed.patch + 1}`;
    default: {
      const exhausted = /** @type {never} */ (bump);
      throw new Error(`unhandled bump: ${exhausted}`);
    }
  }
}

/**
 * Newest ## [X.Y.Z] heading (Unreleased is ignored).
 * @param {string} changelog
 */
export function latestChangelogVersion(changelog) {
  const match = String(changelog).match(/^## \[(\d+\.\d+\.\d+)\]/m);
  if (!match) throw new Error("CHANGELOG has no [X.Y.Z] section");
  return match[1];
}

/**
 * Body under `## [title]` (optional ` - date` suffix) until the next `## ` or EOF.
 * @param {string} changelog
 * @param {string} title
 */
export function sectionBody(changelog, title) {
  const escaped = title.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`(?:^|\\n)## \\[${escaped}\\](?: [^\\n]*)?\\n([\\s\\S]*?)(?=\\n## |$)`);
  const match = changelog.match(re);
  return match ? match[1] : "";
}

/** @param {string} changelog */
export function unreleasedBody(changelog) {
  return sectionBody(changelog, "Unreleased");
}

/** @param {string} changelog */
export function versionSectionBody(changelog, version) {
  return sectionBody(changelog, version);
}

/** @param {string} text */
export function notesForRelease(text) {
  return String(text)
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/\r\n/g, "\n")
    .trim();
}

/** @param {string} changelog */
export function hasUnreleasedNotes(changelog) {
  return notesForRelease(unreleasedBody(changelog)).length > 0;
}

/**
 * @param {string} unreleased
 * @param {BumpRequest} requested
 * @returns {SemverBump}
 */
export function bumpFromUnreleased(unreleased, requested) {
  if (requested !== "auto") return requested;
  if (/<!--\s*release:\s*major\s*-->/i.test(unreleased)) return "major";
  if (/<!--\s*release:\s*minor\s*-->/i.test(unreleased)) return "minor";
  return "patch";
}

/**
 * @param {string} changelog
 * @param {string} nextVersion
 * @param {string} date
 */
export function promoteUnreleased(changelog, nextVersion, date) {
  const body = unreleasedBody(changelog).replace(/\s+$/, "\n");
  const notes = notesForRelease(body);
  if (!notes) throw new Error("Unreleased is empty");
  const promoted = `## [Unreleased]\n\n## [${nextVersion}] - ${date}\n\n${notes}\n\n`;
  const next = changelog.replace(/^## \[Unreleased\]\s*\n[\s\S]*?(?=^## )/m, promoted);
  if (next === changelog) throw new Error("could not promote [Unreleased]");
  return next;
}

/**
 * @param {{ changelog: string, version: string, tagExists: boolean, releaseExists?: boolean, bump?: BumpRequest, date?: string }} input
 */
export function planRelease(input) {
  const version = parseSemver(input.version) && input.version;
  const date = input.date ?? new Date().toISOString().slice(0, 10);
  const bumpRequest = input.bump ?? "auto";
  const releaseExists = input.releaseExists ?? true;
  if (!input.tagExists) {
    const notes = notesForRelease(versionSectionBody(input.changelog, version));
    if (!notes) throw new Error(`CHANGELOG has no [${version}] section to publish`);
    return { kind: "tag-current", version, notes };
  }
  if (!releaseExists) {
    const notes = notesForRelease(versionSectionBody(input.changelog, version));
    if (!notes) throw new Error(`CHANGELOG has no [${version}] section to publish`);
    return { kind: "publish-release", version, notes };
  }
  if (hasUnreleasedNotes(input.changelog)) {
    const bump = bumpFromUnreleased(unreleasedBody(input.changelog), bumpRequest);
    const to = bumpSemver(version, bump);
    const notes = notesForRelease(unreleasedBody(input.changelog));
    return {
      kind: "promote",
      from: version,
      to,
      bump,
      notes,
      changelog: promoteUnreleased(input.changelog, to, date),
    };
  }
  return { kind: "noop", version, reason: "already-released" };
}

/**
 * @param {string} root
 * @param {ReturnType<typeof planRelease>} plan
 */
export function applyPlan(root, plan) {
  if (plan.kind === "noop" || plan.kind === "tag-current" || plan.kind === "publish-release") return;
  if (plan.kind !== "promote") {
    const exhausted = /** @type {never} */ (plan);
    throw new Error(`unhandled plan: ${JSON.stringify(exhausted)}`);
  }
  writeFileSync(join(root, CHANGELOG_FILE), plan.changelog);
}

/** Annotated tags and commits need an ident; Actions runners have none. */
export const RELEASE_GIT_IDENT = [
  "-c",
  "user.name=github-actions[bot]",
  "-c",
  "user.email=41898282+github-actions[bot]@users.noreply.github.com",
];

/** @param {string[]} args */
export function withGitIdent(args) {
  return [...RELEASE_GIT_IDENT, ...args];
}

function repoRoot(dir = process.env.RELEASE_ROOT || DEFAULT_ROOT) {
  return dir;
}

function git(root, args, opts = {}) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", ...opts }).trim();
}

function gitIdent(root, args, opts = {}) {
  return git(root, withGitIdent(args), opts);
}

function tagExists(root, version) {
  const tag = `v${version}`;
  try {
    git(root, ["rev-parse", "-q", "--verify", `refs/tags/${tag}`]);
    return true;
  } catch {
    return false;
  }
}

function githubReleaseExists(root, version) {
  const tag = `v${version}`;
  try {
    execFileSync("gh", ["release", "view", tag], { cwd: root, stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function createGithubRelease(tag, title, notes) {
  execFileSync("gh", ["release", "create", tag, "--title", title, "--notes", notes], {
    stdio: "inherit",
  });
}

function runPlan(root, bump) {
  const changelog = readFileSync(join(root, CHANGELOG_FILE), "utf8");
  const version = latestChangelogVersion(changelog);
  const exists = tagExists(root, version);
  return planRelease({
    changelog,
    version,
    tagExists: exists,
    releaseExists: exists ? githubReleaseExists(root, version) : false,
    bump,
    date: new Date().toISOString().slice(0, 10),
  });
}

function runCi(root, bump) {
  const plan = runPlan(root, bump);
  if (plan.kind === "noop") {
    console.log(`release: ${plan.reason} (v${plan.version})`);
    return;
  }
  if (plan.kind === "tag-current") {
    const tag = `v${plan.version}`;
    gitIdent(root, ["tag", "-a", tag, "-m", tag]);
    git(root, ["push", "origin", tag]);
    createGithubRelease(tag, tag, plan.notes);
    console.log(`release: tagged ${tag}`);
    return;
  }
  if (plan.kind === "publish-release") {
    const tag = `v${plan.version}`;
    createGithubRelease(tag, tag, plan.notes);
    console.log(`release: published ${tag}`);
    return;
  }
  applyPlan(root, plan);
  git(root, ["add", CHANGELOG_FILE]);
  git(root, ["status", "--short"]);
  gitIdent(root, ["commit", "-m", `${RELEASE_COMMIT_PREFIX} v${plan.to}`]);
  const tag = `v${plan.to}`;
  gitIdent(root, ["tag", "-a", tag, "-m", tag]);
  git(root, ["push", "origin", "HEAD:refs/heads/main", tag]);
  createGithubRelease(tag, tag, plan.notes);
  console.log(`release: published ${tag}`);
}

function parseArgs(argv) {
  const args = argv.slice(2);
  const cmd = args[0] || "plan";
  /** @type {BumpRequest} */
  let bump = /** @type {BumpRequest} */ (process.env.RELEASE_BUMP || "auto");
  let dir = repoRoot();
  for (let i = 1; i < args.length; i += 1) {
    if (args[i] === "--dir") {
      dir = args[++i];
      continue;
    }
    if (args[i] === "--bump") {
      bump = /** @type {BumpRequest} */ (args[++i]);
      continue;
    }
    throw new Error(`unknown arg: ${args[i]}`);
  }
  if (bump !== "auto" && bump !== "major" && bump !== "minor" && bump !== "patch") {
    throw new Error(`invalid bump: ${bump}`);
  }
  return { cmd, bump, dir };
}

function main() {
  const { cmd, bump, dir } = parseArgs(process.argv);
  switch (cmd) {
    case "plan": {
      const plan = runPlan(dir, bump);
      const printable = { ...plan };
      if ("changelog" in printable) delete printable.changelog;
      console.log(JSON.stringify(printable, null, 2));
      return;
    }
    case "apply": {
      const plan = runPlan(dir, bump);
      applyPlan(dir, plan);
      console.log(JSON.stringify({ kind: plan.kind, to: "to" in plan ? plan.to : plan.version }, null, 2));
      return;
    }
    case "ci":
      runCi(dir, bump);
      return;
    default:
      throw new Error(`unknown command: ${cmd}`);
  }
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) main();
