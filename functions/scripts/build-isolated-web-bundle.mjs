#!/usr/bin/env node
/**
 * Builds the isolated web bundle used by the emulator E2E runs, completely apart
 * from the developer's demo build.
 *
 * Why it exists: the E2E runner refuses to start without a *provenance* manifest
 * (see assertWebBuild in transfer-notice-e2e.mjs), because a bundle compiled with
 * the wrong defines — or a stale one — would silently test something other than
 * the isolated emulator routing. This script is the only supported way to
 * produce that pair:
 *
 *   .dart_tool/notice-e2e-build/<stamp>/web/                 the Flutter output
 *   .dart_tool/notice-e2e-build/<stamp>/build-manifest.json   its provenance
 *
 * It never touches build/web (the demo bundle), never runs `pub get`, never uses
 * the web-resources CDN and never downloads anything: the Flutter SDK and the
 * pinned runtimes are the ones an operator already authorized.
 *
 * Frozen build args (change only with a new authorization):
 *   build web --release --no-pub --no-web-resources-cdn --no-wasm-dry-run
 *   --dart-define=LDA_LOCAL_EMULATORS=true --output <out>/web
 *
 * Importing this module has no side effects; run it with:
 *   node functions/scripts/build-isolated-web-bundle.mjs --flutter <flutter binary>
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_PATH = fileURLToPath(import.meta.url);
export const REPOSITORY_ROOT = resolve(dirname(MODULE_PATH), '..', '..');
export const BUNDLE_ROOT_RELATIVE = join('.dart_tool', 'notice-e2e-build');
export const REQUIRED_BUNDLE_FILES = Object.freeze(['index.html', 'main.dart.js', 'flutter_bootstrap.js']);
export const ISOLATED_DART_DEFINES = Object.freeze({ LDA_LOCAL_EMULATORS: 'true' });
export const HASHED_SOURCE_DIRECTORIES = Object.freeze(['lib']);
export const FROZEN_BUILD_ARGS = Object.freeze([
  'build',
  'web',
  '--release',
  '--no-pub',
  '--no-web-resources-cdn',
  '--no-wasm-dry-run',
  '--dart-define=LDA_LOCAL_EMULATORS=true',
]);
export const MANIFEST_SCHEMA_VERSION = 1;

export class BundleError extends Error {
  constructor(message) {
    super(message);
    this.name = 'BundleError';
  }
}

function defaultDeps() {
  return {
    spawnSync,
    readdirSync,
    statSync,
    readFileSync,
    writeFileSync,
    mkdirSync,
    existsSync,
    now: () => new Date(),
    sha256: (value) => createHash('sha256').update(value).digest('hex'),
  };
}

export function bundleStamp(date = new Date(), pid = process.pid) {
  const iso = new Date(date).toISOString();
  const compact = `${iso.slice(0, 10).replace(/-/g, '')}T${iso.slice(11, 19).replace(/:/g, '')}Z`;
  return `${compact}-${pid}`;
}

// The demo bundle lives in build/web: writing the isolated bundle there would
// silently replace what the demo serves, so every output path is refused unless
// it stays inside .dart_tool/notice-e2e-build of this repository.
export function assertIsolatedOutput(outDir, { repositoryRoot = REPOSITORY_ROOT } = {}) {
  if (typeof outDir !== 'string' || outDir.length === 0 || !isAbsolute(outDir)) {
    throw new BundleError('the output directory must be an absolute path');
  }
  const bundleRoot = join(repositoryRoot, BUNDLE_ROOT_RELATIVE);
  const target = resolve(outDir);
  if (target !== bundleRoot && !target.startsWith(`${bundleRoot}${sep}`)) {
    throw new BundleError(
      `refusing to write outside ${relative(repositoryRoot, bundleRoot)}: ${target} `
      + '(the demo build directory is never a valid target)',
    );
  }
  return target;
}

function listFiles(directory, deps) {
  const found = [];
  for (const entry of deps.readdirSync(directory, { withFileTypes: true })) {
    const full = join(directory, entry.name);
    if (entry.isDirectory()) found.push(...listFiles(full, deps));
    else if (entry.isFile()) found.push(full);
  }
  return found;
}

export function hashSourceTree({ repositoryRoot = REPOSITORY_ROOT, directories = HASHED_SOURCE_DIRECTORIES, deps = {} } = {}) {
  const d = { ...defaultDeps(), ...deps };
  const files = [];
  for (const directory of directories) {
    const absolute = join(repositoryRoot, directory);
    if (!d.existsSync(absolute)) throw new BundleError(`the source directory is missing: ${absolute}`);
    for (const file of listFiles(absolute, d)) {
      files.push({
        path: relative(repositoryRoot, file),
        sha256: d.sha256(d.readFileSync(file)),
      });
    }
  }
  files.sort((left, right) => (left.path < right.path ? -1 : left.path > right.path ? 1 : 0));
  const treeSha256 = d.sha256(files.map((file) => `${file.path}\0${file.sha256}\0`).join(''));
  return Object.freeze({ files: Object.freeze(files), treeSha256 });
}

export function buildIsolatedWebBundle({
  flutterPath,
  outDir,
  repositoryRoot = REPOSITORY_ROOT,
  fresh = true,
  deps = {},
} = {}) {
  const d = { ...defaultDeps(), ...deps };
  if (typeof flutterPath !== 'string' || flutterPath.length === 0) {
    throw new BundleError('a Flutter binary path is required (--flutter <path>); this script never installs one');
  }
  if (flutterPath === 'flutter' || !isAbsolute(flutterPath)) {
    throw new BundleError(`the Flutter binary path must be absolute, received ${JSON.stringify(flutterPath)}`);
  }
  if (!d.existsSync(flutterPath)) throw new BundleError(`the Flutter binary is missing at ${flutterPath}`);
  const target = assertIsolatedOutput(outDir, { repositoryRoot });
  if (fresh && d.existsSync(target)) {
    throw new BundleError(`the output directory already exists; every bundle needs a fresh directory: ${target}`);
  }
  const webDir = join(target, 'web');

  const startedAt = d.now();
  d.mkdirSync(webDir, { recursive: true });
  const build = d.spawnSync(
    flutterPath,
    [...FROZEN_BUILD_ARGS, '--output', webDir],
    { cwd: repositoryRoot, encoding: 'utf8', env: { ...process.env } },
  );
  const completedAt = d.now();
  const buildExitCode = typeof build?.status === 'number' ? build.status : null;
  if (buildExitCode !== 0) {
    throw new BundleError(
      `the Flutter web build failed (exit ${JSON.stringify(buildExitCode)}): `
      + `${String(build?.stderr ?? '').trim().slice(-400)}`,
    );
  }
  for (const file of REQUIRED_BUNDLE_FILES) {
    const path = join(webDir, file);
    if (!d.existsSync(path)) {
      throw new BundleError(`the build is incomplete: ${file} is missing at ${path}`);
    }
  }

  const source = hashSourceTree({ repositoryRoot, deps: d });
  const manifest = Object.freeze({
    schemaVersion: MANIFEST_SCHEMA_VERSION,
    sourceFiles: source.files,
    sourceTreeSha256: source.treeSha256,
    dartDefines: { ...ISOLATED_DART_DEFINES },
    webResourcesCdn: false,
    mode: 'release',
    flutterVersion: String(build?.flutterVersion ?? '').trim() || null,
    output: webDir,
    startedAt: new Date(startedAt).toISOString(),
    completedAt: new Date(completedAt).toISOString(),
    webMainSha256: d.sha256(d.readFileSync(join(webDir, 'main.dart.js'))),
    buildExitCode,
  });
  const manifestPath = join(target, 'build-manifest.json');
  d.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
  return Object.freeze({ outDir: target, webDir, manifestPath, manifest });
}

export const USAGE = `Build the isolated E2E web bundle (never the demo build).

  node functions/scripts/build-isolated-web-bundle.mjs --flutter <absolute flutter binary> [--out <absolute dir>]

  --flutter <path>  the authorized Flutter SDK binary (no installation happens here)
  --out <dir>       output parent; defaults to .dart_tool/notice-e2e-build/<stamp>
  --help            print this text
`;

export function parseBundleArgs(argv = []) {
  let flutterPath = null;
  let outDir = null;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help') return { mode: 'help' };
    if (arg === '--flutter' || arg === '--out') {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith('--')) throw new BundleError(`${arg} requires a path`);
      if (arg === '--flutter') flutterPath = value;
      else outDir = value;
      index += 1;
      continue;
    }
    throw new BundleError(`unknown argument ${JSON.stringify(arg)}\n\n${USAGE}`);
  }
  if (!flutterPath) throw new BundleError(`--flutter is required\n\n${USAGE}`);
  return { mode: 'build', flutterPath, outDir };
}

function main() {
  const args = parseBundleArgs(process.argv.slice(2));
  if (args.mode === 'help') {
    console.log(USAGE);
    return;
  }
  const outDir = args.outDir ?? join(REPOSITORY_ROOT, BUNDLE_ROOT_RELATIVE, bundleStamp());
  const result = buildIsolatedWebBundle({ flutterPath: args.flutterPath, outDir });
  console.log(`isolated web bundle built: ${relative(REPOSITORY_ROOT, result.webDir)}`);
  console.log(`provenance manifest:       ${relative(REPOSITORY_ROOT, result.manifestPath)}`);
  console.log(`run it with: node functions/scripts/transfer-notice-e2e.mjs --run --web-build ${relative(REPOSITORY_ROOT, result.webDir)}`);
}

if (process.argv[1] && resolve(process.argv[1]) === MODULE_PATH) {
  try {
    main();
  } catch (error) {
    console.error(`[build-isolated-web-bundle] ${error?.message ?? error}`);
    process.exit(1);
  }
}
