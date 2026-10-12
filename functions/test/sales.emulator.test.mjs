// PREPARATION ONLY: do not execute until independent REAL-06 safety inspection.
// This is injected B createSaleService, never callable/Auth transport.
import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale, createSaleService } from '../src/sales.js';
import {
  openRuntime, OwnedRun, canonical, observeTransactions, settleAll,
} from './sales-emulator-support.mjs';

const seedTime = new Date('2026-06-01T12:00:00Z');
const spec1 = { unit: 'kg', precision: 2 };
const spec2 = { unit: 'piece', precision: 0 };
const pricing1 = {
  currency: 'MXN', listedPriceCentavos: 100, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
};
const pricing2 = { ...pricing1, listedPriceCentavos: 200, priceMode: 'iva-included' };

async function snapshot(run) {
  const records = await settleAll([...run.entries.keys()].map(async (path) => {
    const doc = await run.doc(path).get();
    return [path, doc.exists ? canonical(doc.data()) : null];
  }));
  return Object.fromEntries(records);
}

async function assertArtifacts(run, request, result, timestamp) {
  const key = request.data.idempotencyKey;
  const record = async (path) => (await run.doc(path).get()).data();
  const sale = await record(`sales/${key}`);
  const audit = await record(`saleAudits/${key}`);
  const replay = await record(`saleSubmissionReceipts/${key}`);
  assert.equal(typeof sale.createdAt.toDate, 'function', 'actual persisted Timestamp');
  assert.equal(sale.createdAt.toDate().getTime(), timestamp.getTime());
  assert.equal(canonical(sale.receipt), canonical(result.receipt));
  // The response time is the stored sale Timestamp in epoch milliseconds.
  assert.deepEqual(Object.keys(result).sort(), ['createdAt', 'receipt', 'replayed']);
  assert.equal(result.createdAt, sale.createdAt.toDate().getTime());
  for (const path of [`sales/${key}`, `saleAudits/${key}`, `saleSubmissionReceipts/${key}`,
    ...request.data.lines.map((_, index) => `inventoryMovements/sale-${key}-${index}`),
  ]) assert.equal(canonical(await record(path)), canonical(run.entries.get(path).expected));
  assert.equal(audit.actorId, request.auth.uid);
  assert.equal(audit.branchId, request.auth.token.branchId);
  assert.equal(replay.completedAt.toDate().getTime(), timestamp.getTime());
  assert.deepEqual(Object.keys(result.receipt).sort(),
    ['branchCode', 'branchId', 'calculation', 'folio', 'payment', 'productIds', 'saleId', 'version']);
  // Independent folio projection: the owned code and the key's first eight alphanumerics.
  const code = run.entries.get(`branches/${request.auth.token.branchId}`).expected.code;
  const head = key.replace(/[^a-zA-Z0-9]/g, '').slice(0, 8).toUpperCase();
  assert.equal(result.receipt.version, 2);
  assert.equal(result.receipt.branchCode, code);
  assert.equal(result.receipt.folio, `${code}-${head.slice(0, 4)}-${head.slice(4)}`);
  const publicText = JSON.stringify(result.receipt);
  for (const privateField of ['actorId', 'fingerprint', 'cost', 'provenance', 'createdAt']) {
    assert.ok(!publicText.includes(privateField), `private field leaked: ${privateField}`);
  }
}

test('INV05 real isolated atomic Firestore sales (REAL-06 invocation only)', async (t) => {
  const runtime = await openRuntime(); // Strict guard/root validation before installed SDK import.
  const run = new OwnedRun(runtime.firestore);
  // Register before the first create. Teardown is never a global clear or sweep.
  t.after(async () => {
    try { await run.cleanup(); }
    finally { await runtime.dispose(); }
  });
  const [a, b] = run.ns.branches;
  const [p1, p2] = run.ns.products;
  for (const branchId of [a, b]) {
    await run.seed(`branches/${branchId}`, { name: branchId, code: branchId === a ? 'INVA' : 'INVB', createdAt: seedTime });
  }
  for (const [productId, quantitySpec, pricing] of [[p1, spec1, pricing1], [p2, spec2, pricing2]]) {
    await run.seed(`products/${productId}`, {
      internalCode: productId, name: productId, quantitySpec, pricing, createdAt: seedTime,
    });
    for (const branchId of [a, b]) await run.seed(`branches/${branchId}/stock/${productId}`, {
      ...quantitySpec, quantityScaled: 1000, updatedAt: seedTime,
    });
  }
  let clock = seedTime.getTime();
  const request = (label, lines = [{ productId: p1, quantity: '1' }], branchId = a) => {
    const calculation = calculateSale({ invoiceRequested: true, lines: lines.map((line) => {
      const product = run.entries.get(`products/${line.productId}`).expected;
      return { quantity: line.quantity, quantitySpec: product.quantitySpec, pricing: product.pricing };
    }) });
    return {
      auth: { uid: run.ns.actor, token: { role: 'seller', branchId } },
      data: { idempotencyKey: run.ns.key(label), invoiceRequested: true, lines,
        payment: { method: 'cash', amountCentavos: calculation.totalCentavos } },
    };
  };
  function launch(input, observer = observeTransactions()) {
    run.register(input);
    let invocationTime;
    const service = createSaleService({
      firestore: run.scopedFirestore((callback) => observer.wrap(callback)),
      environment: runtime.environment,
      now: () => { invocationTime = new Date(clock += 1000); return invocationTime; },
    });
    return service(input).then((result) => ({ input, result, timestamp: invocationTime }));
  }
  async function accept(outcome) {
    run.confirm(outcome.input, outcome.result, outcome.timestamp);
    if (!outcome.result.replayed) await assertArtifacts(run, outcome.input, outcome.result, outcome.timestamp);
    return outcome.result;
  }
  async function rejectedUnchanged(input, code) {
    run.register(input);
    const before = await snapshot(run);
    await assert.rejects(launch(input), (error) => error.code === code);
    assert.deepEqual(await snapshot(run), before, 'rollback preserves every projection/artifact');
  }
  async function concurrent(inputs) {
    // Advance clock on EVERY genuine SDK callback attempt, not synthetic retries.
    const observer = observeTransactions(inputs.length, 5000, () => { clock += 10_000; });
    // allSettled drains every launched transaction BEFORE any teardown is possible.
    const outcomes = await Promise.allSettled(inputs.map((input) =>
      Promise.resolve().then(() => launch(input, observer))));
    assert.equal(observer.attempts.length, inputs.length);
    assert.ok(observer.attempts.every((record) => record.attempts >= 1), 'first callback overlap at rendezvous');
    const successes = outcomes.filter((outcome) => outcome.status === 'fulfilled').map((outcome) => outcome.value);
    // Confirm original creation before its replay, irrespective of promise completion ordering.
    successes.sort((x, y) => Number(x.result.replayed) - Number(y.result.replayed));
    for (const outcome of successes) await accept(outcome);
    const retriedCreations = outcomes.filter((outcome, index) => outcome.status === 'fulfilled'
      && !outcome.value.result.replayed && observer.attempts[index].attempts > 1).length;
    t.diagnostic(`attempt counts ${observer.attempts.map((record) => record.attempts).join(',')}; `
      + `observed retries ${observer.attempts.reduce((sum, record) => sum + record.attempts - 1, 0)}; `
      + `stable timestamp checked on retried creations ${retriedCreations}`);
    // If true retries occur, assertArtifacts checks original invocation Timestamp
    // despite the advancing callback clock. Zero retries is NOT retry evidence.
    return { outcomes, successes, observer };
  }

  let historical;
  let original;
  await t.test('atomic fractional multi-line taxed full payment, Timestamp and receipt privacy', async () => {
    original = request('success', [{ productId: p1, quantity: '1.25' }, { productId: p2, quantity: '2' }]);
    assert.equal(original.data.payment.amountCentavos, 545);
    historical = await accept(await launch(original));
    assert.equal(historical.replayed, false);
    assert.equal((await run.doc(`branches/${a}/stock/${p1}`).get()).data().quantityScaled, 875);
    assert.equal((await run.doc(`branches/${a}/stock/${p2}`).get()).data().quantityScaled, 998);
  });
  await t.test('owned historical replay after repricing does not write or reprice the sale', async () => {
    const productPath = `products/${p1}`;
    const product = run.entries.get(productPath).expected;
    await run.changeSeed(productPath, { ...product, pricing: { ...product.pricing, listedPriceCentavos: 120 } });
    const before = await snapshot(run);
    const replay = await accept(await launch(original));
    assert.equal(replay.replayed, true);
    assert.equal(canonical(replay.receipt), canonical(historical.receipt));
    assert.equal(replay.createdAt, historical.createdAt, 'a replay keeps the original sale time');
    assert.deepEqual(await snapshot(run), before);
  });
  await t.test('payload, actor and trusted branch key collisions leave all records unchanged', async () => {
    const payload = structuredClone(original);
    payload.data.payment.method = 'card';
    const actor = structuredClone(original);
    actor.auth.uid = `${run.ns.actor}-other`;
    const branch = structuredClone(original);
    branch.auth.token.branchId = b;
    for (const input of [payload, actor, branch]) await rejectedUnchanged(input, 'already-exists');
  });
  await t.test('multi-line invalid quantity, insufficient stock and mismatched payment roll back all artifacts', async () => {
    const invalid = request('invalid', [{ productId: p1, quantity: '1' }, { productId: p2, quantity: '1' }]);
    invalid.data.lines[1].quantity = '0.5'; // piece precision=0; after a valid first line.
    const insufficient = request('insufficient', [{ productId: p1, quantity: '1' }, { productId: p2, quantity: '2000' }]);
    const payment = request('payment', [{ productId: p1, quantity: '1' }, { productId: p2, quantity: '1' }]);
    payment.data.payment.amountCentavos++;
    await rejectedUnchanged(invalid, 'invalid-argument');
    await rejectedUnchanged(insufficient, 'failed-precondition');
    await rejectedUnchanged(payment, 'invalid-argument');
  });
  await t.test('owned create-conflict rolls back projections and all other artifacts', async () => {
    const conflict = request('create-conflict', [{ productId: p1, quantity: '1' }, { productId: p2, quantity: '1' }]);
    run.register(conflict);
    // Deliberate create-only run-owned collision, not an unknown fixture or a forged sale marker.
    await run.seed(`sales/${conflict.data.idempotencyKey}`, {
      receipt: { version: 1, saleId: conflict.data.idempotencyKey, branchId: a }, createdAt: seedTime,
    });
    await rejectedUnchanged(conflict, 6); // Genuine Firestore ALREADY_EXISTS create precondition.
  });
  await t.test('seller/assignment authorization and client-selected branch injection denied', async () => {
    const administrator = request('admin-denied');
    administrator.auth.token.role = 'administrator';
    await rejectedUnchanged(administrator, 'permission-denied');
    const unassigned = request('unassigned');
    delete unassigned.auth.token.branchId;
    // Authorization fails before any transaction; register only the possible artifact paths
    // using the original owned assignment, then remove it from the actual request.
    const planned = structuredClone(unassigned);
    planned.auth.token.branchId = a;
    run.register(planned);
    const before = await snapshot(run);
    const service = createSaleService({ firestore: run.scopedFirestore(), environment: runtime.environment });
    await assert.rejects(service(unassigned), (error) => error.code === 'permission-denied');
    const anonymous = request('anonymous');
    run.register(anonymous);
    const anonymousBefore = await snapshot(run);
    delete anonymous.auth;
    await assert.rejects(service(anonymous), (error) => error.code === 'unauthenticated');
    assert.deepEqual(await snapshot(run), anonymousBefore);
    // Compare earlier manifest entries separately after registering another denied case.
    const after = await snapshot(run);
    for (const [path, data] of Object.entries(before)) assert.equal(after[path], data);
    const injected = request('injected');
    injected.data.branchId = b;
    await rejectedUnchanged(injected, 'invalid-argument');
  });
  await t.test('same-key simultaneous same-payload creates exactly one sale and one replay', async () => {
    const input = request('same-key', [{ productId: p1, quantity: '0.50' }]);
    const before = (await run.doc(`branches/${a}/stock/${p1}`).get()).data().quantityScaled;
    const { outcomes, successes } = await concurrent([input, structuredClone(input)]);
    assert.ok(outcomes.every((outcome) => outcome.status === 'fulfilled'));
    assert.deepEqual(successes.map((outcome) => outcome.result.replayed).sort(), [false, true]);
    assert.equal(canonical(successes[0].result.receipt), canonical(successes[1].result.receipt));
    assert.equal((await run.doc(`branches/${a}/stock/${p1}`).get()).data().quantityScaled, before - 50);
  });
  await t.test('concurrent same-key payload, actor and branch collisions commit exactly one sale', async () => {
    const stockPaths = [a, b].map((branchId) => `branches/${branchId}/stock/${p1}`);
    const stock = () => settleAll(stockPaths.map(async (path) => (await run.doc(path).get()).data()));
    for (const dimension of ['payload', 'actor', 'branch']) {
      const base = request(`collide-${dimension}`, [{ productId: p1, quantity: '0.50' }]);
      const variant = structuredClone(base);
      if (dimension === 'payload') variant.data.payment.method = 'card';
      if (dimension === 'actor') variant.auth.uid = `${run.ns.actor}-other`;
      if (dimension === 'branch') variant.auth.token.branchId = b;
      const before = await stock();
      // concurrent() confirms and byte-checks the winner's artifacts against the exact manifest.
      const { outcomes, successes } = await concurrent([base, variant]);
      assert.equal(successes.length, 1, `${dimension}: exactly one submission commits`);
      assert.equal(successes[0].result.replayed, false, `${dimension}: loser never replays a foreign sale`);
      const rejected = outcomes.filter((outcome) => outcome.status === 'rejected');
      assert.equal(rejected.length, 1);
      assert.equal(rejected[0].reason.code, 'already-exists', `${dimension}: loser rejected by fingerprint`);
      const winner = successes[0].input;
      const key = base.data.idempotencyKey;
      // Every record under the shared key belongs to the winner; nothing carries the loser's identity.
      for (const path of [`saleAudits/${key}`, `saleSubmissionReceipts/${key}`, `inventoryMovements/sale-${key}-0`]) {
        const data = (await run.doc(path).get()).data();
        assert.equal(data.actorId, winner.auth.uid, `${dimension}: ${path} actor`);
        assert.equal(data.branchId, winner.auth.token.branchId, `${dimension}: ${path} branch`);
      }
      assert.equal((await run.doc(`saleSubmissionReceipts/${key}`).get()).data().fingerprint,
        JSON.stringify({ actorId: winner.auth.uid, branchId: winner.auth.token.branchId, ...winner.data }));
      const after = await stock();
      [a, b].forEach((branchId, index) => {
        const decrement = branchId === winner.auth.token.branchId ? 50 : 0;
        assert.equal(after[index].quantityScaled, before[index].quantityScaled - decrement,
          `${dimension}: ${branchId} stock decremented exactly once by the winner only`);
        if (!decrement) assert.equal(canonical(after[index]), canonical(before[index]));
      });
    }
  });
  await t.test('distinct competing keys consume shared stock without negatives or extra successes', async () => {
    const stockPath = `branches/${a}/stock/${p1}`;
    const before = (await run.doc(stockPath).get()).data().quantityScaled;
    const inputs = [1, 2, 3].map((index) => request(`race-${index}`, [{ productId: p1, quantity: '5' }]));
    const { outcomes, successes } = await concurrent(inputs);
    assert.equal(successes.length, Math.min(3, Math.floor(before / 500)));
    assert.ok(successes.every((outcome) => !outcome.result.replayed));
    for (let index = 0; index < outcomes.length; index++) {
      if (outcomes[index].status === 'fulfilled') continue;
      assert.equal(outcomes[index].reason.code, 'failed-precondition');
      const key = inputs[index].data.idempotencyKey;
      for (const path of [`sales/${key}`, `saleAudits/${key}`, `saleSubmissionReceipts/${key}`,
        `inventoryMovements/sale-${key}-0`]) assert.equal((await run.doc(path).get()).exists, false);
    }
    const stock = (await run.doc(stockPath).get()).data();
    assert.ok(stock.quantityScaled >= 0);
    assert.equal(stock.quantityScaled, before - successes.length * 500);
  });
});
