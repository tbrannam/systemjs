# Releasing SystemJS

Releases are automated with [release-please](https://github.com/googleapis/release-please) and published to npm from GitHub Actions using [npm trusted publishing](https://docs.npmjs.com/trusted-publishers) (OIDC, with provenance). Nobody publishes from a laptop.

## Branches and channels

| Branch | Purpose | Distribution |
|---|---|---|
| `main` | 6.x line: fixes and non-breaking features | npm `latest`, via release-please |
| `7.x` | Next major: breaking changes | [pkg.pr.new](https://pkg.pr.new) builds only, never npm (for now) |

Pull requests to either branch also get a pkg.pr.new preview build.

## How a release happens

1. PRs are squash-merged into `main`. The PR title becomes the commit message and must follow [Conventional Commits](https://www.conventionalcommits.org/): `fix:` gives a patch release, `feat:` gives a minor release, and `chore:`/`docs:`/`ci:`/`test:`/`build:`/`refactor:` don't trigger a release.
2. After each merge, the `Release` workflow (`.github/workflows/release.yml`) runs release-please. It opens or updates a **Release PR** titled `chore(main): release X.Y.Z`. That PR bumps `version` in `package.json` and `package-lock.json` and adds the `CHANGELOG.md` entry.
3. Review the Release PR. Check the version and edit the changelog wording if needed. Then merge it.
4. On merge, release-please tags `X.Y.Z` (no `v` prefix) and creates a GitHub Release. The `publish` job then:
   - checks out the tag
   - runs `npm ci`, `chomp build` and the Node tests
   - runs `.github/scripts/verify-release.mjs`, which checks:
     - the tag matches `package.json`
     - `CHANGELOG.md` has an entry for the version
     - the dist files are in the tarball, with LF line endings and the right version banner
     - the version is a stable 6.x
   - runs `npm publish --tag latest` in the `npm-publish` environment

Never edit `version` in `package.json` by hand, and never run `npm publish` locally.

Breaking changes (`feat!:` or a `BREAKING CHANGE:` footer) are rejected on `main`. They belong on `7.x`.

### Re-publishing an existing tag

If the publish job failed after the tag was created (npm outage, misconfiguration), fix the cause. Then run the `Release` workflow manually from `main`: **Actions → Release → Run workflow**, set `tag` to the existing tag, and leave `dry_run` unchecked. The same verification runs before publishing.

### Dry runs

Set the repository variable `NPM_PUBLISH_DRY_RUN` to `true` (**Settings → Secrets and variables → Actions → Variables**). The publish job will then run `npm publish --dry-run`. Use this on forks to rehearse the whole flow. A manual run can also tick `dry_run`.

## Repository settings as code

Branch protection, merge settings and the `npm-publish` environment are described in:

- `.github/rulesets/*.json`: rulesets for `main`, `7.x` and release tags
- `.github/repo-settings/repository.json`: merge settings (squash for `main`, merge commits allowed only so `main` can be merged into `7.x`)
- `.github/repo-settings/environments.json`: deployment environments and allowed branches

To change a setting:

1. Edit those files in a PR and get it reviewed.
2. After it merges, run the script from the merged commit:

```sh
git fetch upstream && git switch --detach upstream/main
.github/repo-settings/apply.sh            # dry run: shows current vs desired
.github/repo-settings/apply.sh --apply    # needs repo admin; asks for confirmation
```

The script is idempotent. It never deletes settings it doesn't describe; it only reports them.

Rollback: `gh api -X DELETE repos/systemjs/systemjs/rulesets/<id>` for a ruleset. Then revert the JSON in a PR and re-apply.

## One-time setup (repo admin + npm owner)

Do these in order, after the PR that adds the release workflow has merged. Each step changes `systemjs/systemjs` or the `systemjs` npm package, so record who did it and when in the tracking issue.

1. **Apply repository settings:** `.github/repo-settings/apply.sh --apply` (see above). This creates the rulesets, the merge settings and the `npm-publish` environment (deployments allowed from `main` only).

2. **`RELEASE_PLEASE_TOKEN` secret:** Release PRs opened with the default `GITHUB_TOKEN` don't trigger CI, so release-please uses its own token. Use either:
   - a GitHub App installed on this repo only, with Contents, Pull requests and Issues set to read & write, or
   - a fine-grained personal access token scoped to `systemjs/systemjs`, with the same permissions and an expiry date you track.

   ```sh
   gh secret set RELEASE_PLEASE_TOKEN --repo systemjs/systemjs
   ```

   Without the secret, the workflow falls back to `GITHUB_TOKEN`. Releases still work, but CI won't run on the Release PR, and **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests** must be enabled.

3. **pkg.pr.new:** install the GitHub App from <https://github.com/apps/pkg-pr-new> and grant it access to `systemjs/systemjs` only.

4. **npm trusted publisher:** on npmjs.com go to the `systemjs` package → **Settings** → **Trusted Publisher** → **GitHub Actions**, and enter:
   - Organization or user: `systemjs`
   - Repository: `systemjs`
   - Workflow filename: `release.yml`
   - Environment name: `npm-publish`

5. **Archive the stale `6.x` branch** (it stopped at 6.8.0; 6.x now lives on `main`):

   ```sh
   sha=$(gh api repos/systemjs/systemjs/git/ref/heads/6.x --jq .object.sha)
   gh api -X POST repos/systemjs/systemjs/git/refs -f ref=refs/heads/archive/6.8 -f sha="$sha"
   gh api -X DELETE repos/systemjs/systemjs/git/refs/heads/6.x
   ```

6. **Require CI checks:** once the `test` (CI) and `lint-title` (PR) checks have run on at least one PR, add them to `protect-main.json` and `protect-7x.json` in a PR. Use a `required_status_checks` rule with `strict_required_status_checks_policy: false`. After it merges, re-apply the settings.

7. **After the first successful publish from CI:**
   - confirm the provenance badge on npmjs.com
   - in the package settings, set **Publishing access** to "Require two-factor authentication and disallow tokens"
   - revoke old automation tokens (`npm token list`, then `npm token revoke <id>`)

## Enabling 7.x on npm later

This isn't enabled yet. When it is, the same `release.yml` is used, so the npm trusted publisher doesn't change. The steps are:

- add a prerelease release-please config on `7.x` (`"prerelease": true`, `"prerelease-type": "alpha"`, `"versioning": "prerelease"`, and a one-time `"release-as": "7.0.0-alpha.0"`)
- add `7.x` to the release workflow with `--tag next`
- allow `7.x` in `environments.json`
- relax the major-version check in `verify-release.mjs`
