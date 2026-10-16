#!/usr/bin/env node
/**
 * Production provisioning for the real project `lda-inventory-dev-mx`.
 *
 * Reads a plan file of branches and users and, only with `--apply`:
 *   - creates each missing `branches/{id}` document as `{ name, code }`;
 *   - sets the `role` / `branchId` custom claims of each listed account.
 *
 * Accounts themselves (email and password) are created by a person in the
 * Firebase console, so this script never handles passwords. Without
 * `--apply` it only validates the plan and touches nothing. Every check runs
 * before the first write: a missing account, a branch whose stored data
 * differs, a branch code already used by another branch, or an account that
 * already has different claims refuses the whole apply with nothing written.
 *
 * Usage:
 *   node scripts/provision-production.mjs --project lda-inventory-dev-mx \
 *     --plan <plan.json> [--apply]
 *
 * Plan file:
 *   {
 *     "branches": [{ "id": "branch-centro", "name": "Sucursal Centro", "code": "CEN" }],
 *     "users": [
 *       { "email": "admin@example.com", "role": "administrator" },
 *       { "email": "ventas@example.com", "role": "seller", "branchId": "branch-centro" }
 *     ]
 *   }
 *
 * `--apply` uses Application Default Credentials for the project (for
 * example `gcloud auth application-default login`), and refuses to run while
 * any Firebase emulator variable is set.
 */
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

import { DEPLOYED_PROJECT_ID } from '../src/runtime-project.js';

const USAGE = 'usage: provision-production.mjs --project lda-inventory-dev-mx --plan <plan.json> [--apply]';
const BRANCH_ID = /^branch-[a-z0-9]+(?:-[a-z0-9]+)*$/;
const BRANCH_CODE = /^[A-Z]{2,4}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const ROLES = new Set(['administrator', 'seller']);
const EMULATOR_VARIABLES = [
  'FIRESTORE_EMULATOR_HOST',
  'FIREBASE_AUTH_EMULATOR_HOST',
  'FIREBASE_STORAGE_EMULATOR_HOST',
  'FUNCTIONS_EMULATOR',
];

export function parseProvisionArgs(argv) {
  const options = { projectId: null, planPath: null, apply: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--apply') {
      options.apply = true;
    } else if (argument === '--project' || argument === '--plan') {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith('--')) throw new Error(USAGE);
      if (argument === '--project') options.projectId = value;
      else options.planPath = value;
      index += 1;
    } else {
      throw new Error(`unknown argument: ${argument}\n${USAGE}`);
    }
  }
  if (options.projectId === null || options.planPath === null) throw new Error(USAGE);
  if (options.projectId !== DEPLOYED_PROJECT_ID) {
    throw new Error(`refusing project ${options.projectId}: only ${DEPLOYED_PROJECT_ID} is provisioned`);
  }
  return options;
}

function assertOnlyFields(value, allowed, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) throw new Error(`${label} has an unknown field: ${key}`);
  }
}

/** Validates the plan and returns it unchanged; throws naming the broken rule. */
export function validateProductionPlan(plan) {
  assertOnlyFields(plan, ['branches', 'users'], 'plan');
  if (!Array.isArray(plan.branches) || !Array.isArray(plan.users)) {
    throw new Error('plan needs "branches" and "users" arrays');
  }
  const branchIds = new Set();
  const codes = new Set();
  for (const branch of plan.branches) {
    assertOnlyFields(branch, ['id', 'name', 'code'], 'branch');
    if (typeof branch.id !== 'string' || !BRANCH_ID.test(branch.id)) {
      throw new Error(`branch id must look like branch-centro: ${String(branch.id)}`);
    }
    if (typeof branch.name !== 'string' || branch.name.trim() === '' || branch.name.length > 80) {
      throw new Error(`branch ${branch.id} needs a name of 1 to 80 characters`);
    }
    if (typeof branch.code !== 'string' || !BRANCH_CODE.test(branch.code)) {
      throw new Error(`branch ${branch.id} code must be 2 to 4 uppercase letters`);
    }
    if (branchIds.has(branch.id)) throw new Error(`duplicate branch id: ${branch.id}`);
    if (codes.has(branch.code)) throw new Error(`duplicate branch code: ${branch.code}`);
    branchIds.add(branch.id);
    codes.add(branch.code);
  }
  const emails = new Set();
  for (const user of plan.users) {
    assertOnlyFields(user, ['email', 'role', 'branchId'], 'user');
    if (typeof user.email !== 'string' || !EMAIL.test(user.email)) {
      throw new Error(`user email is invalid: ${String(user.email)}`);
    }
    if (!ROLES.has(user.role)) throw new Error(`user ${user.email} role must be administrator or seller`);
    if (user.role === 'administrator' && user.branchId !== undefined) {
      throw new Error(`administrator ${user.email} must not have a branchId`);
    }
    if (user.role === 'seller' && !branchIds.has(user.branchId)) {
      throw new Error(`seller ${user.email} needs a branchId listed in the plan branches`);
    }
    if (emails.has(user.email)) throw new Error(`duplicate user email: ${user.email}`);
    emails.add(user.email);
  }
  return plan;
}

function claimsFor(user) {
  return user.role === 'seller'
    ? { role: 'seller', branchId: user.branchId }
    : { role: 'administrator' };
}

function sameClaims(current, wanted) {
  const role = current?.role;
  const branchId = current?.branchId;
  return role === wanted.role && branchId === wanted.branchId;
}

function hasNoRoleClaims(current) {
  return current?.role === undefined && current?.branchId === undefined;
}

/**
 * Applies a validated plan through injected Admin `auth` and `firestore`.
 * All reads and checks happen first; any problem throws before any write.
 * Returns one report line per branch and user.
 */
export async function applyProductionPlan(plan, { auth, firestore }) {
  validateProductionPlan(plan);
  const problems = [];

  const existing = new Map();
  const snapshot = await firestore.collection('branches').get();
  for (const document of snapshot.docs) existing.set(document.id, document.data());

  const branchActions = plan.branches.map((branch) => {
    const stored = existing.get(branch.id);
    if (stored === undefined) {
      for (const [otherId, other] of existing) {
        if (other?.code === branch.code) {
          problems.push(`branch code ${branch.code} is already used by ${otherId}`);
        }
      }
      return { branch, action: 'created' };
    }
    if (stored.name !== branch.name || stored.code !== branch.code) {
      problems.push(`branch ${branch.id} already exists with different name or code`);
    }
    return { branch, action: 'unchanged' };
  });

  const userActions = [];
  for (const user of plan.users) {
    let account;
    try {
      account = await auth.getUserByEmail(user.email);
    } catch (error) {
      if (error?.code !== 'auth/user-not-found') throw error;
      problems.push(`account ${user.email} does not exist: create it in the Firebase console first`);
      continue;
    }
    const wanted = claimsFor(user);
    if (sameClaims(account.customClaims, wanted)) {
      userActions.push({ user, uid: account.uid, wanted, action: 'unchanged' });
    } else if (hasNoRoleClaims(account.customClaims)) {
      userActions.push({ user, uid: account.uid, wanted, action: 'set' });
    } else {
      problems.push(`account ${user.email} already has a different role or branch; change it deliberately`);
    }
  }

  if (problems.length > 0) {
    throw new Error(`nothing was written:\n- ${problems.join('\n- ')}`);
  }

  const created = branchActions.filter(({ action }) => action === 'created');
  if (created.length > 0) {
    const batch = firestore.batch();
    for (const { branch } of created) {
      batch.create(firestore.doc(`branches/${branch.id}`), { name: branch.name, code: branch.code });
    }
    await batch.commit();
  }
  for (const { uid, wanted, action } of userActions) {
    if (action === 'set') await auth.setCustomUserClaims(uid, wanted);
  }

  return [
    ...branchActions.map(({ branch, action }) => `branch ${branch.id}: ${action}`),
    ...userActions.map(({ user, wanted, action }) => (action === 'unchanged'
      ? `user ${user.email}: unchanged`
      : `user ${user.email}: claims set (${[wanted.role, wanted.branchId].filter(Boolean).join(', ')})`)),
  ];
}

async function main(argv, environment) {
  const options = parseProvisionArgs(argv);
  const plan = validateProductionPlan(JSON.parse(readFileSync(options.planPath, 'utf8')));
  if (!options.apply) {
    console.log(`Dry run for ${options.projectId}: ${plan.branches.length} branches and `
      + `${plan.users.length} users are valid. Nothing was written; add --apply to write.`);
    return;
  }
  const emulatorVariables = EMULATOR_VARIABLES.filter((name) => environment[name] !== undefined);
  if (emulatorVariables.length > 0) {
    throw new Error(`refusing --apply while emulator variables are set: ${emulatorVariables.join(', ')}`);
  }
  const { initializeApp } = await import('firebase-admin/app');
  const { getAuth } = await import('firebase-admin/auth');
  const { getFirestore } = await import('firebase-admin/firestore');
  const app = initializeApp({ projectId: options.projectId }, 'lda-production-provisioning');
  const report = await applyProductionPlan(plan, { auth: getAuth(app), firestore: getFirestore(app) });
  for (const line of report) console.log(line);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main(process.argv.slice(2), process.env).catch((error) => {
    console.error(`[provision-production] ${error.message}`);
    process.exitCode = 1;
  });
}
