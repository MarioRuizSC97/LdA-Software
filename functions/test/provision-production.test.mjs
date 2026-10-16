import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import {
  applyProductionPlan,
  parseProvisionArgs,
  validateProductionPlan,
} from '../scripts/provision-production.mjs';

const PLAN = Object.freeze({
  branches: [
    { id: 'branch-centro', name: 'Sucursal Centro', code: 'CEN' },
    { id: 'branch-norte', name: 'Sucursal Norte', code: 'NTE' },
  ],
  users: [
    { email: 'admin@example.com', role: 'administrator' },
    { email: 'ventas.centro@example.com', role: 'seller', branchId: 'branch-centro' },
  ],
});

class FakeAuth {
  constructor(users) {
    this.users = new Map(users.map((user) => [user.email, structuredClone(user)]));
    this.claimWrites = [];
  }

  async getUserByEmail(email) {
    const user = this.users.get(email);
    if (!user) {
      const error = new Error('no user');
      error.code = 'auth/user-not-found';
      throw error;
    }
    return structuredClone(user);
  }

  async setCustomUserClaims(uid, claims) {
    this.claimWrites.push({ uid, claims });
  }
}

class FakeFirestore {
  constructor(branches = {}) {
    this.branches = new Map(Object.entries(structuredClone(branches)));
    this.creates = [];
  }

  collection(name) {
    assert.equal(name, 'branches');
    return {
      get: async () => ({
        docs: [...this.branches.entries()].map(([id, data]) => ({ id, data: () => structuredClone(data) })),
      }),
    };
  }

  doc(path) {
    return { path };
  }

  batch() {
    const pending = [];
    return {
      create: (reference, data) => pending.push({ path: reference.path, data: structuredClone(data) }),
      commit: async () => {
        for (const write of pending) {
          this.creates.push(write);
          this.branches.set(write.path.split('/')[1], write.data);
        }
      },
    };
  }
}

const accounts = () => new FakeAuth([
  { uid: 'uid-admin', email: 'admin@example.com', customClaims: {} },
  { uid: 'uid-seller', email: 'ventas.centro@example.com' },
]);

test('arguments require the deployed project and a plan, and default to a dry run', () => {
  assert.deepEqual(
    parseProvisionArgs(['--project', 'lda-inventory-dev-mx', '--plan', 'plan.json']),
    { projectId: 'lda-inventory-dev-mx', planPath: 'plan.json', apply: false },
  );
  assert.equal(
    parseProvisionArgs(['--project', 'lda-inventory-dev-mx', '--plan', 'p.json', '--apply']).apply,
    true,
  );
  for (const argv of [
    ['--plan', 'plan.json'],
    ['--project', 'lda-inventory-dev-mx'],
    ['--project', 'demo-lda-inventory', '--plan', 'plan.json'],
    ['--project', 'someone-else', '--plan', 'plan.json'],
    ['--project', 'lda-inventory-dev-mx', '--plan', 'plan.json', '--force'],
  ]) {
    assert.throws(() => parseProvisionArgs(argv), /usage|project|unknown/i, argv.join(' '));
  }
});

test('a valid plan passes validation unchanged', () => {
  assert.deepEqual(validateProductionPlan(PLAN), PLAN);
});

test('plan validation names every rule it enforces', () => {
  const cases = {
    'branch id': [/branch id must look like branch-centro/, { ...PLAN, branches: [{ id: 'Centro', name: 'Centro', code: 'CEN' }], users: [] }],
    'branch code': [/code must be 2 to 4 uppercase letters/, { ...PLAN, branches: [{ id: 'branch-centro', name: 'Centro', code: 'cen' }], users: [] }],
    'branch name': [/needs a name of 1 to 80 characters/, { ...PLAN, branches: [{ id: 'branch-centro', name: ' ', code: 'CEN' }], users: [] }],
    'duplicate branch id': [/duplicate branch id: branch-centro/, {
      branches: [PLAN.branches[0], { ...PLAN.branches[1], id: 'branch-centro' }],
      users: [],
    }],
    'duplicate branch code': [/duplicate branch code: CEN/, {
      branches: [PLAN.branches[0], { ...PLAN.branches[1], code: 'CEN' }],
      users: [],
    }],
    'email': [/user email is invalid/, { ...PLAN, users: [{ email: 'not-an-email', role: 'administrator' }] }],
    'role': [/role must be administrator or seller/, { ...PLAN, users: [{ email: 'a@example.com', role: 'owner' }] }],
    'administrator branch': [/must not have a branchId/, {
      ...PLAN,
      users: [{ email: 'a@example.com', role: 'administrator', branchId: 'branch-centro' }],
    }],
    'seller branch': [/needs a branchId listed in the plan branches/, { ...PLAN, users: [{ email: 'a@example.com', role: 'seller' }] }],
    'unknown seller branch': [/needs a branchId listed in the plan branches/, {
      ...PLAN,
      users: [{ email: 'a@example.com', role: 'seller', branchId: 'branch-sur' }],
    }],
    'duplicate email': [/duplicate user email/, {
      ...PLAN,
      users: [PLAN.users[0], { ...PLAN.users[0] }],
    }],
    'duplicate email in another case': [/duplicate user email/, {
      ...PLAN,
      users: [PLAN.users[0], { email: 'ADMIN@example.com', role: 'seller', branchId: 'branch-centro' }],
    }],
    'unknown field': [/unknown field: password/, { ...PLAN, users: [{ ...PLAN.users[0], password: 'secret' }] }],
  };
  for (const [rule, [message, plan]] of Object.entries(cases)) {
    assert.throws(() => validateProductionPlan(plan), message, rule);
  }
});

test('apply creates missing branches and sets claims, reporting each change', async () => {
  const auth = accounts();
  const firestore = new FakeFirestore();
  const report = await applyProductionPlan(PLAN, { auth, firestore });

  assert.deepEqual(firestore.creates, [
    { path: 'branches/branch-centro', data: { name: 'Sucursal Centro', code: 'CEN' } },
    { path: 'branches/branch-norte', data: { name: 'Sucursal Norte', code: 'NTE' } },
  ]);
  assert.deepEqual(auth.claimWrites, [
    { uid: 'uid-admin', claims: { role: 'administrator' } },
    { uid: 'uid-seller', claims: { role: 'seller', branchId: 'branch-centro' } },
  ]);
  assert.deepEqual(report, [
    'branch branch-centro: created',
    'branch branch-norte: created',
    'user admin@example.com: claims set (administrator)',
    'user ventas.centro@example.com: claims set (seller, branch-centro)',
  ]);
});

test('a second apply is a no-op', async () => {
  const auth = new FakeAuth([
    { uid: 'uid-admin', email: 'admin@example.com', customClaims: { role: 'administrator' } },
    {
      uid: 'uid-seller',
      email: 'ventas.centro@example.com',
      customClaims: { role: 'seller', branchId: 'branch-centro' },
    },
  ]);
  const firestore = new FakeFirestore({
    'branch-centro': { name: 'Sucursal Centro', code: 'CEN' },
    'branch-norte': { name: 'Sucursal Norte', code: 'NTE' },
  });
  const report = await applyProductionPlan(PLAN, { auth, firestore });

  assert.deepEqual(firestore.creates, []);
  assert.deepEqual(auth.claimWrites, []);
  assert.deepEqual(report, [
    'branch branch-centro: unchanged',
    'branch branch-norte: unchanged',
    'user admin@example.com: unchanged',
    'user ventas.centro@example.com: unchanged',
  ]);
});

test('any conflict or missing account refuses the whole apply before writing', async () => {
  const conflicts = {
    'missing account': [
      new FakeAuth([{ uid: 'uid-admin', email: 'admin@example.com' }]),
      new FakeFirestore(),
      /ventas\.centro@example\.com.*Firebase console/,
    ],
    'branch with other data': [
      accounts(),
      new FakeFirestore({ 'branch-centro': { name: 'Otra', code: 'CEN' } }),
      /branch-centro/,
    ],
    'code taken by another branch': [
      accounts(),
      new FakeFirestore({ 'branch-sur': { name: 'Sucursal Sur', code: 'NTE' } }),
      /NTE/,
    ],
  };
  for (const [name, [auth, firestore, message]] of Object.entries(conflicts)) {
    await assert.rejects(applyProductionPlan(PLAN, { auth, firestore }), message, name);
    assert.deepEqual(firestore.creates, [], name);
    assert.deepEqual(auth.claimWrites, [], name);
  }
});

test('changing an existing role or branch is refused, never overwritten', async () => {
  const auth = new FakeAuth([
    { uid: 'uid-admin', email: 'admin@example.com', customClaims: { role: 'seller', branchId: 'branch-norte' } },
    { uid: 'uid-seller', email: 'ventas.centro@example.com' },
  ]);
  const firestore = new FakeFirestore();
  await assert.rejects(applyProductionPlan(PLAN, { auth, firestore }), /admin@example\.com/);
  assert.deepEqual(firestore.creates, []);
  assert.deepEqual(auth.claimWrites, []);
});

const SCRIPT = new URL('../scripts/provision-production.mjs', import.meta.url).pathname;

function runScript(args, environment = {}) {
  return spawnSync(process.execPath, [SCRIPT, ...args], {
    encoding: 'utf8',
    env: { PATH: process.env.PATH, ...environment },
  });
}

function writePlan(plan) {
  const directory = mkdtempSync(join(tmpdir(), 'lda-provision-'));
  const path = join(directory, 'plan.json');
  writeFileSync(path, JSON.stringify(plan));
  return path;
}

test('the command validates a plan as a dry run and writes nothing', () => {
  const result = runScript(['--project', 'lda-inventory-dev-mx', '--plan', writePlan(PLAN)]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Dry run for lda-inventory-dev-mx: 2 branches and 2 users are valid\. Nothing was written/);
});

test('the command refuses an invalid plan with exit code 1', () => {
  const result = runScript([
    '--project', 'lda-inventory-dev-mx',
    '--plan', writePlan({ ...PLAN, users: [{ email: 'a@example.com', role: 'owner' }] }),
  ]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /role must be administrator or seller/);
});

test('the command refuses --apply while emulator variables are set', () => {
  const result = runScript(
    ['--project', 'lda-inventory-dev-mx', '--plan', writePlan(PLAN), '--apply'],
    { FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' },
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /refusing --apply while emulator variables are set: FIRESTORE_EMULATOR_HOST/);
});

test('an account with other custom claims is refused, never overwritten', async () => {
  const auth = new FakeAuth([
    { uid: 'uid-admin', email: 'admin@example.com', customClaims: { beta: true } },
    { uid: 'uid-seller', email: 'ventas.centro@example.com' },
  ]);
  const firestore = new FakeFirestore();
  await assert.rejects(
    applyProductionPlan(PLAN, { auth, firestore }),
    /admin@example\.com has other custom claims/,
  );
  assert.deepEqual(firestore.creates, []);
  assert.deepEqual(auth.claimWrites, []);
});

test('a lookup failure other than a missing account aborts before writing', async () => {
  const auth = accounts();
  auth.getUserByEmail = async () => {
    const error = new Error('permission denied');
    error.code = 'auth/insufficient-permission';
    throw error;
  };
  const firestore = new FakeFirestore();
  await assert.rejects(applyProductionPlan(PLAN, { auth, firestore }), /permission denied/);
  assert.deepEqual(firestore.creates, []);
  assert.deepEqual(auth.claimWrites, []);
});
