import assert from 'node:assert/strict';
import { test } from 'node:test';

// Install before loading SDK modules. No real fetch is ever delegated, including
// the intentional negative control's Google URL. All users/tokens are fake memory.
const requests = [];
globalThis.fetch = async (url) => {
  requests.push(String(url));
  const parsed = new URL(String(url));
  if (parsed.hostname !== '127.0.0.1' || parsed.port !== '9099' ||
      parsed.pathname !== '/identitytoolkit.googleapis.com/v1/accounts:lookup') {
    // Resolve with a synthetic denial so the SDK also clears its fetch timeout;
    // no URL is delegated to a real transport, including this negative control.
    return new Response(JSON.stringify({ error: { message: 'NETWORK_REQUEST_FAILED' } }),
      { status: 400, headers: { 'Content-Type': 'application/json' } });
  }
  return new Response(JSON.stringify({ users: [{
    localId: 'memory-only-user', email: 'memory-only@demo.invalid',
    emailVerified: false, providerUserInfo: [],
  }] }), { status: 200, headers: { 'Content-Type': 'application/json' } });
};

// Exact installed browser Auth implementation, not the Node Auth entry point.
const { initializeApp, deleteApp, SDK_VERSION } = await import('./node_modules/@firebase/app/dist/esm/index.esm.js');
const sdk = await import('./node_modules/@firebase/auth/dist/esm/index.js');
assert.equal(SDK_VERSION, '12.19.0');
const options = {
  apiKey: 'demo-api-key', appId: '1:1234567890:web:demo-lda-inventory',
  messagingSenderId: '1234567890', projectId: 'demo-lda-inventory',
  authDomain: 'demo-lda-inventory.firebaseapp.com',
};
const appName = 'lda-demo-emulators';

// Persistence interface double only: real SDK schedules, parses and reloads the
// user. Browser IndexedDB/window integration is deliberately not claimed.
let persistenceReads = 0;
class MemoryStoredUser {
  type = 'LOCAL';
  _shouldAllowMigration = false;
  async _isAvailable() { return true; }
  async _get(key) {
    if (!key.startsWith('firebase:authUser:')) return null;
    persistenceReads++;
    return {
      uid: 'memory-only-user', email: 'memory-only@demo.invalid',
      emailVerified: false, isAnonymous: false, providerData: [],
      stsTokenManager: { refreshToken: 'fake-memory-refresh',
        accessToken: 'fake-memory-token', expirationTime: Date.now() + 3_600_000 },
    };
  }
  async _set() {}
  async _remove() {}
  _addListener() {}
  _removeListener() {}
}

test('real 12.19 browser SDK connects synchronously before stored-user queue runs', async () => {
  requests.length = 0;
  persistenceReads = 0;
  const app = initializeApp(options, appName);
  try {
    // Test the public SDK boundary chosen by the Dart adapter, not a copied
    // application algorithm. Persistence double forces an existing-user reload.
    const auth = sdk.initializeAuth(app, {
      persistence: [MemoryStoredUser], errorMap: sdk.debugErrorMap,
    });
    assert.equal(auth.app, app);
    assert.equal(auth.app.name, appName);
    assert.equal(persistenceReads, 0);
    sdk.connectAuthEmulator(auth, 'http://127.0.0.1:9099');
    assert.equal(persistenceReads, 0);
    assert.equal(auth.emulatorConfig.protocol, 'http');
    assert.equal(auth.emulatorConfig.host, '127.0.0.1');
    assert.equal(auth.emulatorConfig.port, 9099);
    await auth.authStateReady();
    assert.ok(persistenceReads > 0);
    assert.equal(requests.length, 1);
    assert.equal(new URL(requests[0]).host, '127.0.0.1:9099');
    assert.equal(auth.currentUser.uid, 'memory-only-user');
  } finally { await deleteApp(app); }
});

test('FlutterFire exact dependency hierarchy can reuse preinitialized Auth', async () => {
  requests.length = 0;
  const app = initializeApp(options, appName);
  const dependencies = () => ({
    errorMap: sdk.debugErrorMap,
    persistence: [sdk.indexedDBLocalPersistence,
      sdk.browserLocalPersistence, sdk.browserSessionPersistence],
    popupRedirectResolver: sdk.browserPopupRedirectResolver,
  });
  try {
    const auth = sdk.initializeAuth(app, dependencies());
    assert.equal(auth.app, app);
    sdk.connectAuthEmulator(auth, 'http://127.0.0.1:9099');
    await auth.authStateReady();
    assert.equal(sdk.initializeAuth(app, dependencies()), auth);
    assert.equal(initializeApp(options, appName), app);
    assert.throws(() => sdk.initializeAuth(app, { persistence: [] }),
      { code: 'auth/already-initialized' });
    assert.equal(requests.length, 0);
  } finally { await deleteApp(app); }
});

test('negative control: awaiting stored-user initialization is too late to connect', async () => {
  requests.length = 0;
  const app = initializeApp(options, appName);
  try {
    const auth = sdk.initializeAuth(app, { persistence: [MemoryStoredUser] });
    await auth.authStateReady();
    assert.equal(requests.length, 1);
    assert.equal(new URL(requests[0]).hostname, 'identitytoolkit.googleapis.com');
    assert.equal(auth.emulatorConfig, null);
    assert.throws(() => sdk.connectAuthEmulator(auth, 'http://127.0.0.1:9099'),
      { code: 'auth/emulator-config-failed' });
  } finally { await deleteApp(app); }
});
