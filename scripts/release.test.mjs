import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import {
  bumpFromUnreleased,
  bumpSemver,
  hasUnreleasedNotes,
  latestChangelogVersion,
  notesForRelease,
  ciShouldContinue,
  planRelease,
  promoteUnreleased,
  withGitIdent,
} from "./release.mjs";

const SAMPLE = `# Changelog

## [Unreleased]

- Packer scripts run via bash.

## [1.1.2] - 2026-09-02

Fix missing execute bit.
`;

describe("release notes", () => {
  it("reads the newest versioned heading past Unreleased", () => {
    assert.equal(latestChangelogVersion(SAMPLE), "1.1.2");
    assert.equal(latestChangelogVersion("## [2.0.0] - 2026-01-01\n\n## [1.0.0]\n"), "2.0.0");
  });

  it("rejects a changelog with no version heading", () => {
    assert.throws(() => latestChangelogVersion("## [Unreleased]\n\n- notes\n"), /no \[X\.Y\.Z\]/);
  });

  it("treats an empty Unreleased as no notes", () => {
    assert.equal(hasUnreleasedNotes("# Changelog\n\n## [Unreleased]\n\n## [1.1.2]\n\nFix.\n"), false);
    assert.equal(hasUnreleasedNotes(SAMPLE), true);
  });

  it("ignores bump comments when deciding if Unreleased has notes", () => {
    const changelog = `# Changelog\n\n## [Unreleased]\n\n<!-- release: minor -->\n\n## [1.1.2]\n\nFix.\n`;
    assert.equal(hasUnreleasedNotes(changelog), false);
    assert.equal(bumpFromUnreleased("<!-- release: minor -->\n", "auto"), "minor");
  });

  it("defaults auto bump to patch and honors markers", () => {
    assert.equal(bumpFromUnreleased("- a fix\n", "auto"), "patch");
    assert.equal(bumpFromUnreleased("<!-- release: minor -->\n- feature\n", "auto"), "minor");
    assert.equal(bumpFromUnreleased("<!-- release: major -->\n- break\n", "auto"), "major");
    assert.equal(bumpFromUnreleased("<!-- release: major -->\n- break\n", "patch"), "patch");
  });

  it("bumps semver", () => {
    assert.equal(bumpSemver("1.1.2", "patch"), "1.1.3");
    assert.equal(bumpSemver("1.1.2", "minor"), "1.2.0");
    assert.equal(bumpSemver("1.4.2", "major"), "2.0.0");
  });

  it("promotes Unreleased into the next version heading", () => {
    const next = promoteUnreleased(SAMPLE, "1.1.3", "2026-09-02");
    assert.equal(hasUnreleasedNotes(next), false);
    assert.match(next, /## \[1\.1\.3\] - 2026-09-02/);
    assert.match(next, /- Packer scripts run via bash\./);
    assert.ok(next.indexOf("## [Unreleased]") < next.indexOf("## [1.1.3]"));
    assert.ok(next.indexOf("## [1.1.3]") < next.indexOf("## [1.1.2]"));
  });

  it("plans a first tag when Unreleased is empty and v1.1.2 is unpublished", () => {
    const changelog = `# Changelog\n\n## [Unreleased]\n\n## [1.1.2] - 2026-09-02\n\nFix missing execute bit.\n`;
    const plan = planRelease({ changelog, version: "1.1.2", tagExists: false });
    assert.equal(plan.kind, "tag-current");
    assert.equal(plan.version, "1.1.2");
    assert.equal(plan.notes, "Fix missing execute bit.");
  });

  it("plans a patch promote when Unreleased has notes", () => {
    const plan = planRelease({
      changelog: SAMPLE,
      version: "1.1.2",
      tagExists: true,
      releaseExists: true,
      date: "2026-09-02",
    });
    assert.equal(plan.kind, "promote");
    assert.equal(plan.to, "1.1.3");
    assert.equal(plan.bump, "patch");
    assert.equal(plan.notes, "- Packer scripts run via bash.");
    assert.equal(hasUnreleasedNotes(plan.changelog), false);
  });

  it("tags the current version first, then CI continues to promote Unreleased", () => {
    const first = planRelease({ changelog: SAMPLE, version: "1.1.2", tagExists: false });
    assert.equal(first.kind, "tag-current");
    assert.equal(first.version, "1.1.2");
    assert.equal(first.notes, "Fix missing execute bit.");
    assert.equal(ciShouldContinue(first), true);

    const second = planRelease({
      changelog: SAMPLE,
      version: "1.1.2",
      tagExists: true,
      releaseExists: true,
      date: "2026-09-02",
    });
    assert.equal(second.kind, "promote");
    assert.equal(second.to, "1.1.3");
    assert.equal(ciShouldContinue(second), false);
  });

  it("continues CI after publishing a missing GitHub release", () => {
    const plan = planRelease({
      changelog: SAMPLE,
      version: "1.1.2",
      tagExists: true,
      releaseExists: false,
    });
    assert.equal(plan.kind, "publish-release");
    assert.equal(ciShouldContinue(plan), true);
  });

  it("does not continue CI after promote or noop", () => {
    const promote = planRelease({
      changelog: SAMPLE,
      version: "1.1.2",
      tagExists: true,
      releaseExists: true,
      date: "2026-09-02",
    });
    const noop = planRelease({
      changelog: `# Changelog\n\n## [Unreleased]\n\n## [1.1.2]\n\nFix.\n`,
      version: "1.1.2",
      tagExists: true,
      releaseExists: true,
    });
    assert.equal(ciShouldContinue(promote), false);
    assert.equal(ciShouldContinue(noop), false);
  });

  it("no-ops when the current version is already tagged and Unreleased is empty", () => {
    const changelog = `# Changelog\n\n## [Unreleased]\n\n## [1.1.2]\n\nFix.\n`;
    const plan = planRelease({ changelog, version: "1.1.2", tagExists: true, releaseExists: true });
    assert.deepEqual(plan, { kind: "noop", version: "1.1.2", reason: "already-released" });
  });

  it("publishes a missing GitHub release before promote or noop", () => {
    const changelog = `# Changelog\n\n## [Unreleased]\n\n- next fix\n\n## [1.1.2] - 2026-09-02\n\nFix missing execute bit.\n`;
    const plan = planRelease({ changelog, version: "1.1.2", tagExists: true, releaseExists: false });
    assert.equal(plan.kind, "publish-release");
    assert.equal(plan.version, "1.1.2");
    assert.equal(plan.notes, "Fix missing execute bit.");
  });

  it("strips HTML comments from published notes", () => {
    assert.equal(notesForRelease("<!-- release: minor -->\n\n- feature\n"), "- feature");
  });

  it("annotated tags succeed with the CI ident when the runner has none", () => {
    const root = mkdtempSync(join(tmpdir(), "meow-release-tag-"));
    const gitIn = (args) =>
      execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
    gitIn(["init"]);
    gitIn([
      "-c",
      "commit.gpgsign=false",
      "-c",
      "user.name=seed",
      "-c",
      "user.email=seed@example.com",
      "commit",
      "--allow-empty",
      "-m",
      "seed",
    ]);
    assert.throws(
      () => gitIn(["-c", "user.name=", "-c", "user.email=", "tag", "-a", "v1.1.2", "-m", "v1.1.2"]),
      /empty ident|Please tell me who you are/,
    );
    gitIn(withGitIdent(["-c", "commit.gpgsign=false", "tag", "-a", "v1.1.2", "-m", "v1.1.2"]));
    assert.match(gitIn(["rev-parse", "-q", "--verify", "refs/tags/v1.1.2"]), /\w+/);
  });
});
