# Contributing to SystemJS

Bug fixes and changes are welcome for discussion, provided the project footprint remains minimal.

## Which branch?

- **`main`**: fixes and non-breaking features for SystemJS 6.x. Released to npm as `latest`.
- **`7.x`**: breaking changes for the next major version. Not published to npm yet; see [Trying a build](#trying-a-build).

If your change breaks existing behaviour, open the PR against `7.x`.

## Pull request titles

PRs are squash-merged, and the PR title becomes the commit message. Releases and `CHANGELOG.md` are generated from these titles, so they must follow [Conventional Commits](https://www.conventionalcommits.org/):

| Title | Effect on the next 6.x release |
|---|---|
| `fix: avoid double instantiation of named registers` | patch (6.15.1 → 6.15.2) |
| `feat: support fetchPriority with external import maps` | minor (6.15.1 → 6.16.0) |
| `docs: …`, `test: …`, `ci: …`, `build: …`, `chore: …`, `refactor: …` | no release |
| `feat!: …` or a `BREAKING CHANGE:` line in the description | only allowed on `7.x` |

A scope is optional: `fix(amd): …`. The `PR` workflow checks the title. Edit the title to re-run the check.

Don't change `version` in `package.json` or add entries to `CHANGELOG.md`; the release automation does both. See [RELEASING.md](RELEASING.md).

## Building and testing

Task running is handled by [Chomp](https://chompbuild.com). Use the exact Node.js version in `.nvmrc` with the npm it bundles. `npm ci` refuses to run on other Node.js versions, so the lockfile is always written by the same toolchain CI uses.

```sh
nvm use          # or fnm use / volta, any tool that reads .nvmrc
npm install -g chomp
npm ci
chomp build   # writes dist/ (not committed to git)
chomp test
```

To upgrade Node.js (for example for a security release), change `.nvmrc` in a `ci:` pull request; every workflow reads it. Keep the major in line with `devEngines` in `package.json`.

The `.nvmrc` version is the **build toolchain only**. It says nothing about which Node.js versions SystemJS users need: `dist/` is identical whatever Node.js builds it, the browser builds target ES5, and the `node-compat` CI job runs the built `dist/system-node.cjs` on Node.js 10 through 24. Don't drop a Node.js version from that matrix without treating it as a breaking change.

`package-lock.json` is committed. If you change dependencies, update them with `npm install <pkg>` and commit the updated lockfile in the same PR.

## Trying a build

Every PR, and every commit pushed to `7.x`, is built and published to [pkg.pr.new](https://pkg.pr.new). These builds aren't on npm.

- **PR builds:** a bot comments on the PR with an install command such as `npm i https://pkg.pr.new/systemjs@<sha>`.
- **`7.x` builds:** open the `PR` workflow run for the commit and see the `preview` job output.
