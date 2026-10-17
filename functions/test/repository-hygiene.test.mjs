import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, before, test } from 'node:test';

const root = fileURLToPath(new URL('../../', import.meta.url));
const env = {
  PATH: process.env.PATH,
  GIT_CONFIG_NOSYSTEM: '1',
  GIT_CONFIG_GLOBAL: '/dev/null',
};
let fixture;

before(() => {
  mkdirSync(join(root, '.dart_tool'), { recursive: true });
  fixture = mkdtempSync(join(root, '.dart_tool', 'repository-hygiene-'));
  const init = spawnSync('git', ['init', '--quiet', '--template=', fixture], { env, encoding: 'utf8', timeout: 5000 });
  assert.equal(init.status, 0);
  assert.equal(init.stderr, '');
  mkdirSync(join(fixture, 'android'));
  for (const path of ['.gitignore', 'android/.gitignore']) {
    writeFileSync(join(fixture, path), readFileSync(join(root, path)));
  }
});

after(() => {
  if (fixture) rmSync(fixture, { recursive: true, force: true });
});

function assertIgnored(paths, expected) {
  const result = spawnSync('git', [
    '-C', fixture, '-c', 'core.excludesFile=/dev/null',
    'check-ignore', '--no-index', '--stdin', '-z',
  ], { env, encoding: 'utf8', input: `${paths.join('\0')}\0`, timeout: 5000 });
  assert.equal(result.status, expected.length ? 0 : 1);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout, expected.length ? `${expected.join('\0')}\0` : '');
}

test('dotenv secrets are ignored at the root and in nested directories', () => {
  const paths = ['.env', '.env.local', 'functions/.env.production', 'nested/.env'];
  assertIgnored(paths, paths);
});

test('private credentials and signing material are ignored', () => {
  const paths = [
    'service-account.json', 'config/service-account.prod.json', 'serviceAccountKey.json',
    'config/project-firebase-adminsdk-key.json', 'application_default_credentials.json',
    'config/private.pem', 'keys/private.key', 'ios/signing.p12', 'ios/signing.pfx',
    'android/upload.jks', 'upload.keystore', 'ios/profile.mobileprovision',
    'ios/profile.provisionprofile', 'ios/AuthKey.p8', 'keys/id_rsa', 'keys/id_ed25519',
  ];
  assertIgnored(paths, paths);
});

test('existing Android signing and runtime exclusions remain effective', () => {
  const paths = [
    'android/key.properties', 'android/app/upload.keystore', 'android/app/upload.jks',
    '.dart_tool/probe', 'functions/node_modules/probe', 'odd/runtime/probe',
  ];
  assertIgnored(paths, paths);
});

test('sanitized templates and public Firebase configuration remain versionable', () => {
  const paths = [
    '.env.example', '.env.sample', '.env.template', 'functions/.env.example',
    'android/app/google-services.json', 'ios/Runner/GoogleService-Info.plist',
    'lib/firebase_options.dart', '.firebaserc', 'firebase.json', 'pubspec.yaml',
    'functions/scripts/production-plan.example.json', 'keys/id_rsa.pub',
  ];
  assertIgnored(paths, []);
});
