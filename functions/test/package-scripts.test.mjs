/**
 * MB-02 — registry regression for the package scripts.
 *
 * This test reads functions/package.json and stats plain file paths only: it
 * never imports the isolated runner, the emulator acceptance suite or any
 * application module, so nothing here spawns a child process, opens a socket
 * or requires a service. It pins the public npm contract that packages the
 * isolated transfer acceptance without widening the shared default lanes.
 */
import assert from 'node:assert/strict';
import { readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const packageDirectory = join(dirname(fileURLToPath(import.meta.url)), '..');
const packageJson = JSON.parse(readFileSync(join(packageDirectory, 'package.json'), 'utf8'));
const scripts = packageJson.scripts;

function assertPlainFile(relativePath) {
  const stats = statSync(join(packageDirectory, relativePath));
  assert.equal(stats.isFile(), true, `${relativePath} must be a regular file`);
}

test('registers the isolated transfers acceptance runner without touching the shared emulator lane', () => {
  assert.equal(
    scripts['test:emulator:transfers:isolated'],
    'node scripts/test-transfers-isolated.mjs',
    'the isolated lane must point at the dedicated runner script, not a bare emulator suite',
  );
  assert.equal(
    scripts['test:emulator'],
    'node --test test/inventory.emulator.test.mjs test/catalog.emulator.test.mjs '
      + 'test/pricing.emulator.test.mjs test/provision-demo-identities.emulator.test.mjs',
    'the shared default emulator lane must stay exactly as registered before MB-02',
  );
});

test('keeps the default unit lane pure and appends both mocked unit targets', () => {
  const tokens = scripts.test.split(' ');
  assert.deepEqual(tokens.slice(0, 2), ['node', '--test'], 'the default lane must stay a pure node --test command');

  const unitFiles = tokens.slice(2);
  assert.deepEqual(
    unitFiles.slice(0, 5),
    [
      'test/quantity.test.mjs',
      'test/inventory.test.mjs',
      'test/catalog.test.mjs',
      'test/pricing.test.mjs',
      'test/provision-demo-identities.test.mjs',
    ],
    'the five pre-existing unit targets must keep their exact order',
  );
  assert.equal(unitFiles.includes('test/transfers-isolated-runner.test.mjs'), true);
  assert.equal(unitFiles.includes('test/package-scripts.test.mjs'), true);
  assert.equal(
    unitFiles.includes('test/transfers.test.mjs'),
    true,
    'the committed atomic transfer unit must ride the default pure unit lane',
  );
  assert.deepEqual(
    unitFiles.filter((file) => file.includes('emulator')),
    [],
    'no emulator or integration suite may join the default unit lane',
  );
  for (const file of unitFiles) assertPlainFile(file);
});

test('isolated acceptance surfaces referenced by the registry exist as plain files', () => {
  assertPlainFile('scripts/test-transfers-isolated.mjs');
  assertPlainFile('test/transfers.emulator.test.mjs');
  assertPlainFile('test/transfers-isolated-runner.test.mjs');
});
