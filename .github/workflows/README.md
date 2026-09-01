# Workflows

| Workflow | When | What |
|---|---|---|
| [`ci.yml`](./ci.yml) | PRs and pushes to `main` | Release-script unit tests + `bash -n` on `.sh` files. On `main` (and not a `chore(release):` commit), tag and publish from `CHANGELOG.md`. |

## Release job

Same shape as [ctf-arena](https://github.com/ryokubaka/ctf-arena): notes live under `[Unreleased]`. After tests pass on `main`, `node scripts/release.mjs ci` either:

- tags the newest `## [X.Y.Z]` heading if that tag is missing, or
- promotes Unreleased to the next patch (or minor/major when Unreleased includes `<!-- release: minor -->` / `<!-- release: major -->`), then tags and creates the GitHub Release.

`chore(release):` commits skip the workflow so the bot push does not loop.

Local:

```bash
node --test scripts/release.test.mjs
node scripts/release.mjs plan
```
