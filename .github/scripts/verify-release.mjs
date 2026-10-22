// Pre-publish checks run by .github/workflows/release.yml after `chomp build`.
// Usage: node .github/scripts/verify-release.mjs <tag>
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

// Only 6.x is published to npm until 7.x publishing is enabled (see RELEASING.md).
const PUBLISHED_MAJOR = 6;

const tag = process.argv[2];
if (!tag) {
  console.error('Usage: node .github/scripts/verify-release.mjs <tag>');
  process.exit(2);
}

const errors = [];
const { version } = JSON.parse(readFileSync('package.json', 'utf8'));
const escaped = version.replace(/\./g, '\\.');

if (tag !== version)
  errors.push(`Tag "${tag}" does not match package.json version "${version}".`);

const semver = /^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$/.exec(version);
if (!semver)
  errors.push(`package.json version "${version}" is not valid semver.`);
else if (semver[4])
  errors.push(`Prerelease version "${version}" must not be published as latest.`);
else if (Number(semver[1]) !== PUBLISHED_MAJOR)
  errors.push(`Major version ${semver[1]} is not enabled for npm publishing (expected ${PUBLISHED_MAJOR}).`);

const changelog = readFileSync('CHANGELOG.md', 'utf8');
if (!new RegExp(`^#{2,3} \\[?${escaped}\\]?(?=[\\s(]|$)`, 'm').test(changelog))
  errors.push(`CHANGELOG.md has no heading for ${version}.`);

const extras = readdirSync('src/extras').filter(f => f.endsWith('.js')).map(f => f.slice(0, -3));
const browserBuilds = [
  'dist/system.js', 'dist/system.min.js', 'dist/s.js', 'dist/s.min.js',
  ...extras.flatMap(name => [`dist/extras/${name}.js`, `dist/extras/${name}.min.js`])
];
const required = [...browserBuilds, 'dist/system-node.cjs'];

const [pack] = JSON.parse(execFileSync('npm', ['pack', '--dry-run', '--json', '--ignore-scripts'], { encoding: 'utf8' }));
const packed = new Set(pack.files.map(f => f.path));
for (const file of required) {
  if (!packed.has(file))
    errors.push(`${file} is missing from the npm tarball.`);
}

// system-node.cjs is skipped: it bundles dependency sources verbatim, some of which use CRLF.
for (const file of browserBuilds) {
  if (packed.has(file) && readFileSync(file, 'utf8').includes('\r\n'))
    errors.push(`${file} contains CRLF line endings.`);
}

for (const [file, banner] of [['dist/system.js', `SystemJS ${version}`], ['dist/s.js', `SJS ${version}`]]) {
  if (packed.has(file) && !readFileSync(file, 'utf8').slice(0, 200).includes(banner))
    errors.push(`${file} banner does not read "${banner}".`);
}

if (errors.length) {
  console.error(`Release verification failed for ${tag}:`);
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log(`Release ${version} verified: ${pack.files.length} files, ${(pack.size / 1024).toFixed(1)} kB packed.`);
