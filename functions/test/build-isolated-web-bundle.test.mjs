/**
 * Tests for the isolated web-bundle generator.
 *
 * Nothing here runs Flutter, installs anything or touches build/web: the build
 * child is an injected double and every directory lives in a temp folder. The
 * important test is the round trip: what the generator writes must satisfy the
 * runner's own assertWebBuild contract, because that is what gates a real run.
 */
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import {
  BUNDLE_ROOT_RELATIVE,
  BundleError,
  FROZEN_BUILD_ARGS,
  REQUIRED_BUNDLE_FILES,
  assertIsolatedOutput,
  buildIsolatedWebBundle,
  bundleStamp,
  hashSourceTree,
} from '../scripts/build-isolated-web-bundle.mjs';
import { assertWebBuild } from '../scripts/transfer-notice-e2e.mjs';

function tempRepository() {
  const root = mkdtempSync(join(tmpdir(), 'lda-bundle-'));
  mkdirSync(join(root, 'lib', 'auth'), { recursive: true });
  writeFileSync(join(root, 'lib', 'auth', 'emulator_login.dart'), 'void main() {}\n');
  writeFileSync(join(root, 'lib', 'main.dart'), 'void main() {}\n');
  writeFileSync(join(root, 'flutter'), '');
  return root;
}

function fakeFlutterBuild({ status = 0 } = {}) {
  const calls = [];
  const spawnSync = (binary, args) => {
    calls.push({ binary, args: [...args] });
    if (status === 0) {
      const webDir = args[args.indexOf('--output') + 1];
      for (const file of REQUIRED_BUNDLE_FILES) writeFileSync(join(webDir, file), `${file} body\n`);
    }
    return { status, stdout: '', stderr: status === 0 ? '' : 'compilation failed\n', flutterVersion: '3.47.5' };
  };
  return { calls, spawnSync };
}

test('the isolated output can never be the demo build directory', () => {
  const root = mkdtempSync(join(tmpdir(), 'lda-output-'));
  try {
    assert.throws(
      () => assertIsolatedOutput(join(root, 'build', 'web'), { repositoryRoot: root }),
      /refusing to write outside/,
    );
    assert.throws(
      () => assertIsolatedOutput(join(root, 'build'), { repositoryRoot: root }),
      /refusing to write outside/,
    );
    assert.throws(() => assertIsolatedOutput('relative/dir', { repositoryRoot: root }), /absolute path/);
    assert.equal(
      assertIsolatedOutput(join(root, BUNDLE_ROOT_RELATIVE, 'stamp-1'), { repositoryRoot: root }),
      join(root, BUNDLE_ROOT_RELATIVE, 'stamp-1'),
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('the source tree hash is sorted, complete and deterministic', () => {
  const root = tempRepository();
  try {
    const first = hashSourceTree({ repositoryRoot: root });
    const second = hashSourceTree({ repositoryRoot: root });
    assert.deepEqual(first.files.map((file) => file.path), ['lib/auth/emulator_login.dart', 'lib/main.dart']);
    for (const file of first.files) assert.equal(file.sha256.length, 64);
    assert.equal(first.treeSha256, second.treeSha256);
    writeFileSync(join(root, 'lib', 'main.dart'), 'void main() { /* changed */ }\n');
    assert.notEqual(hashSourceTree({ repositoryRoot: root }).treeSha256, first.treeSha256);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('the generated bundle and manifest satisfy the runner contract', () => {
  const root = tempRepository();
  try {
    const { calls, spawnSync } = fakeFlutterBuild();
    const outDir = join(root, BUNDLE_ROOT_RELATIVE, bundleStamp(new Date('2026-10-15T16:51:40Z'), 15349));
    const result = buildIsolatedWebBundle({
      flutterPath: join(root, 'flutter'),
      outDir,
      repositoryRoot: root,
      deps: { spawnSync },
    });

    assert.deepEqual(result.manifest.dartDefines, { LDA_LOCAL_EMULATORS: 'true' });
    assert.equal(result.manifest.buildExitCode, 0);
    assert.equal(result.manifest.webResourcesCdn, false);
    assert.equal(result.manifest.output, result.webDir);
    assert.equal(result.manifest.webMainSha256.length, 64);
    assert.equal(result.manifest.sourceFiles.length, 2);
    assert.equal(result.outDir, outDir, 'the stamp directory is the one requested');

    // The frozen arguments are the contract the guide documents.
    assert.deepEqual(calls[0].args.slice(0, FROZEN_BUILD_ARGS.length), [...FROZEN_BUILD_ARGS]);
    assert.deepEqual(calls[0].args.slice(-2), ['--output', result.webDir]);

    // The runner must accept exactly what the generator produced.
    const webBuild = assertWebBuild(result.webDir, { repoRoot: root });
    assert.equal(webBuild.dartDefines.LDA_LOCAL_EMULATORS, 'true');
    assert.equal(webBuild.buildExitCode, 0);
    assert.equal(webBuild.sourceTreeSha256, result.manifest.sourceTreeSha256);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

for (const mutation of ['edit', 'add', 'delete', 'bundle', 'inventory']) {
  test(`the runner refuses changed bundle freshness evidence: ${mutation}`, () => {
    const root = tempRepository();
    try {
      const { spawnSync } = fakeFlutterBuild();
      const result = buildIsolatedWebBundle({
        flutterPath: join(root, 'flutter'),
        outDir: join(root, BUNDLE_ROOT_RELATIVE, 'freshness'),
        repositoryRoot: root, deps: { spawnSync },
      });
      assertWebBuild(result.webDir, { repoRoot: root });
      const sourcePath = join(root, 'lib', 'main.dart');
      if (mutation === 'edit') writeFileSync(sourcePath, 'changed source\n');
      if (mutation === 'add') writeFileSync(join(root, 'lib', 'added.dart'), 'added source\n');
      if (mutation === 'delete') rmSync(sourcePath);
      if (mutation === 'bundle') writeFileSync(join(result.webDir, 'main.dart.js'), Buffer.from([0, 255, 128]));
      if (mutation === 'inventory') {
        writeFileSync(result.manifestPath, JSON.stringify({ ...result.manifest, sourceFiles: [] }));
      }
      const manifestBefore = readFileSync(result.manifestPath);
      const bundleBefore = readFileSync(join(result.webDir, 'main.dart.js'));
      assert.throws(() => assertWebBuild(result.webDir, { repoRoot: root }),
        mutation === 'bundle' ? /main\.dart\.js.*hash/ : /stale/);
      assert.deepEqual(readFileSync(result.manifestPath), manifestBefore, 'validation must not rewrite provenance');
      assert.deepEqual(readFileSync(join(result.webDir, 'main.dart.js')), bundleBefore, 'validation must not rebuild or repair output');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
}

test('a failed or repeated build never leaves a usable manifest', () => {
  const root = tempRepository();
  try {
    const failing = fakeFlutterBuild({ status: 1 });
    const failedOut = join(root, BUNDLE_ROOT_RELATIVE, 'failed-stamp');
    assert.throws(
      () => buildIsolatedWebBundle({
        flutterPath: join(root, 'flutter'),
        outDir: failedOut,
        repositoryRoot: root,
        deps: { spawnSync: failing.spawnSync },
      }),
      /Flutter web build failed/,
    );
    assert.throws(
      () => assertWebBuild(join(failedOut, 'web')),
      /build-manifest\.json is unreadable|missing/,
    );

    const { spawnSync } = fakeFlutterBuild();
    const repeatOut = join(root, BUNDLE_ROOT_RELATIVE, 'repeat-stamp');
    buildIsolatedWebBundle({
      flutterPath: join(root, 'flutter'),
      outDir: repeatOut,
      repositoryRoot: root,
      deps: { spawnSync },
    });
    assert.throws(
      () => buildIsolatedWebBundle({
        flutterPath: join(root, 'flutter'),
        outDir: repeatOut,
        repositoryRoot: root,
        deps: { spawnSync },
      }),
      /already exists/,
    );
    assert.throws(
      () => buildIsolatedWebBundle({
        flutterPath: 'flutter',
        outDir: join(root, BUNDLE_ROOT_RELATIVE, 'x'),
        repositoryRoot: root,
        deps: { spawnSync },
      }),
      /must be absolute/,
    );
    assert.ok(new BundleError('x') instanceof Error);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
