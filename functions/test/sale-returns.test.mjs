import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale, SaleError } from '../src/sales.js';
import { CORRECTION_WINDOW_MS } from '../src/corrections-calculation.js';
import * as returns from '../src/sale-returns.js';

const environment = Object.freeze({
  GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
});
const auth = { uid: 'seller-one', token: { role: 'seller', branchId: 'north' } };
const NOW = new Date('2026-06-16T12:00:00Z').getTime();
const DAY = 24 * 60 * 60 * 1000;
const piece = { unit: 'piece', precision: 0 };
const kg = { unit: 'kg', precision: 3 };
const pricing = (listedPriceCentavos) => ({
  currency: 'MXN', listedPriceCentavos, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
});
const clone = (value) => structuredClone(value);

// Line 0: 3 pieces at 1000 (base 3000, IVA 480). Line 1: 1.250 kg at 999
// (base 1249, IVA 200). Independent amounts are hardcoded in the tests.
function saleRecord(saleId, branchId, createdAtMs, invoiceRequested = true) {
  const calculation = clone(calculateSale({ invoiceRequested, lines: [
    { quantity: '3', quantitySpec: piece, pricing: pricing(1000) },
    { quantity: '1.250', quantitySpec: kg, pricing: pricing(999) },
  ] }));
  return {
    receipt: {
      version: 1, saleId, branchId, productIds: ['p1', 'p2'], calculation,
      payment: { method: 'card', amountCentavos: calculation.totalCentavos },
    },
    createdAt: new Date(createdAtMs),
  };
}

function baseRecords() {
  return [
    ['sales/s1', saleRecord('s1', 'north', NOW - DAY)],
    ['sales/plain', saleRecord('plain', 'north', NOW - DAY, false)],
    ['sales/foreign', saleRecord('foreign', 'south', NOW - DAY)],
    ['sales/expired', saleRecord('expired', 'north', NOW - CORRECTION_WINDOW_MS)],
    ['sales/future', saleRecord('future', 'north', NOW + 1)],
    ['products/p1', { quantitySpec: piece, pricing: pricing(1000) }],
    ['products/p2', { quantitySpec: kg, pricing: pricing(999) }],
    ['branches/north/stock/p1', { ...piece, quantityScaled: 5 }],
    ['branches/north/stock/p2', { ...kg, quantityScaled: 2000 }],
  ];
}

// Serial in-memory transactions: buffered writes, create preconditions,
// all-reads-before-writes, and an optional abandoned first callback attempt.
class FakeFirestore {
  constructor(records = baseRecords()) {
    this.records = new Map(records.map(([path, value]) => [path, clone(value)]));
    this.traces = [];
    this.retry = false;
  }

  doc(path) {
    assert.match(path, /^[^/]+\/[^/]+(?:\/[^/]+\/[^/]+)?$/);
    assert.ok(!/cost/i.test(path), `forbidden read: ${path}`);
    return { path };
  }

  async runTransaction(callback) {
    const execute = async () => {
      const writes = [];
      const trace = [];
      this.traces.push(trace);
      const transaction = {
        get: async ({ path }) => {
          assert.equal(writes.length, 0, 'all reads precede every write');
          trace.push(['get', path]);
          const data = this.records.get(path);
          return { exists: this.records.has(path), data: () => clone(data) };
        },
        create: ({ path }, data) => {
          trace.push(['create', path]);
          writes.push({ kind: 'create', path, data: clone(data) });
        },
        set: ({ path }, data) => {
          trace.push(['set', path]);
          writes.push({ kind: 'set', path, data: clone(data) });
        },
      };
      const result = await callback(transaction);
      return { writes, result };
    };
    if (this.retry) {
      this.retry = false;
      await execute(); // Abandon every write from this callback invocation.
    }
    const { writes, result } = await execute();
    const next = new Map(this.records);
    for (const { kind, path, data } of writes) {
      if (kind === 'create' && next.has(path)) throw new Error('create-only conflict');
      next.set(path, data);
    }
    this.records = next;
    return result;
  }
}

function fixture(options = {}, records = undefined) {
  const firestore = new FakeFirestore(records);
  const service = returns.createSaleReturnService({
    firestore, environment, now: () => new Date(NOW), ...options,
  });
  return { firestore, service };
}

function request(data = {}, actor = auth) {
  return {
    auth: clone(actor),
    data: {
      idempotencyKey: 'r1', saleId: 's1', reason: 'change-of-mind',
      lines: [{ lineIndex: 0, quantity: '1', condition: 'good' }],
      ...data,
    },
  };
}

async function rejectsUnchanged(firestore, promise, code, message) {
  const before = clone([...firestore.records]);
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof SaleError, `unexpected ${error}`);
    assert.equal(error.code, code);
    if (message) assert.equal(error.message, message);
    return true;
  });
  assert.deepEqual([...firestore.records], before, 'failure leaves no artifacts');
}

const stock = (firestore, product) => firestore.records.get(`branches/north/stock/${product}`);
const ledger = (firestore, saleId = 's1') => firestore.records.get(`saleReturnLedgers/${saleId}`);
const deepFrozen = (value) => value === null || typeof value !== 'object'
  || (Object.isFrozen(value) && Object.values(value).every(deepFrozen));

test('factory validates injected dependencies', () => {
  assert.throws(() => returns.createSaleReturnService(), TypeError);
  assert.throws(() => returns.createSaleReturnService({ firestore: { doc() {} } }), TypeError);
  assert.throws(() => fixture({ now: 1 }), TypeError);
  assert.equal(typeof fixture().service, 'function');
});

test('the emulator guard and seller authorization run before any read', async () => {
  for (const env of [{}, { ...environment, GCLOUD_PROJECT: 'cloud-project' }]) {
    const { firestore, service } = fixture({ environment: env });
    await rejectsUnchanged(firestore, service(request()), 'failed-precondition');
    assert.deepEqual(firestore.traces, []);
  }
  for (const [actor, code] of [
    [undefined, 'unauthenticated'], [{ uid: '' }, 'unauthenticated'],
    [{ uid: 'x', token: { role: 'administrator', branchId: 'north' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'auditor', branchId: 'north' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller', branchId: '../north' } }, 'permission-denied'],
  ]) {
    const { firestore, service } = fixture();
    await rejectsUnchanged(firestore, service({ ...request(), auth: actor }), code);
    assert.deepEqual(firestore.traces, []);
  }
});

test('requests accept only exact fields, reasons, conditions, notes and canonical quantities', async () => {
  const { firestore, service } = fixture();
  const line = { lineIndex: 0, quantity: '1', condition: 'good' };
  for (const data of [
    { idempotencyKey: '' }, { idempotencyKey: '../r1' }, { idempotencyKey: 'r'.repeat(129) },
    { saleId: '' }, { saleId: 's/1' }, { saleId: 7 },
    { reason: 'damaged' }, { reason: undefined }, { reason: 'Other' },
    { note: '' }, { note: '   ' }, { note: ' padded' }, { note: 'padded ' }, { note: 'x'.repeat(501) },
    { note: null }, { note: 5 },
    { lines: [] }, { lines: 'all' }, { lines: [line, { ...line }] },
    { lines: [{ ...line, condition: 'customer-damage' }] },
    { lines: [{ ...line, condition: undefined }] },
    { lines: [{ ...line, lineIndex: -1 }] }, { lines: [{ ...line, lineIndex: 1.5 }] },
    { lines: [{ ...line, lineIndex: '0' }] },
    { lines: [{ ...line, quantity: '0' }] }, { lines: [{ ...line, quantity: '01' }] },
    { lines: [{ ...line, quantity: '1.' }] }, { lines: [{ ...line, quantity: 1 }] },
    { lines: [{ ...line, quantity: '-1' }] },
    { lines: [{ ...line, productId: 'p1' }] }, { lines: [{ lineIndex: 0, quantity: '1' }] },
    { branchId: 'north' }, { refundMethod: 'cash' },
  ]) {
    await rejectsUnchanged(firestore, service(request(data)), 'invalid-argument');
  }
  const sparse = [];
  sparse.length = 1;
  await rejectsUnchanged(firestore, service(request({ lines: sparse })), 'invalid-argument');
  for (const data of [undefined, null, []]) {
    await rejectsUnchanged(firestore, service({ auth, data }), 'invalid-argument');
  }
  assert.deepEqual(firestore.traces, []);
  // A 500-character trimmed note is the inclusive upper bound.
  const accepted = await service(request({ note: 'x'.repeat(500) }));
  assert.equal(accepted.replayed, false);
});

test('a full return in one step refunds the whole sale and restocks every good line', async () => {
  const { firestore, service } = fixture();
  const sale = clone(firestore.records.get('sales/s1'));
  const result = await service(request({
    note: 'Customer changed plans',
    lines: [
      { lineIndex: 1, quantity: '1.25', condition: 'good' },
      { lineIndex: 0, quantity: '3', condition: 'good' },
    ],
  }));
  assert.equal(result.replayed, false);
  const expected = {
    version: 1, returnId: 'r1', saleId: 's1', branchId: 'north', reason: 'change-of-mind',
    lines: [
      { lineIndex: 1, productId: 'p2', quantity: '1.250', condition: 'good',
        baseCentavos: 1249, additionalIvaCentavos: 200, totalCentavos: 1449 },
      { lineIndex: 0, productId: 'p1', quantity: '3', condition: 'good',
        baseCentavos: 3000, additionalIvaCentavos: 480, totalCentavos: 3480 },
    ],
    refund: { method: 'card', baseCentavos: 4249, additionalIvaCentavos: 680, totalCentavos: 4929 },
    invoiced: true,
  };
  assert.deepEqual(result.receipt, expected);
  assert.equal(result.receipt.refund.totalCentavos, sale.receipt.payment.amountCentavos);
  assert.ok(Object.isFrozen(result) && deepFrozen(result.receipt));

  const at = new Date(NOW);
  assert.deepEqual(firestore.records.get('saleReturns/r1'), { receipt: expected, createdAt: at });
  assert.deepEqual(firestore.records.get('saleReturnAudits/r1'), {
    returnId: 'r1', saleId: 's1', branchId: 'north', actorId: 'seller-one',
    reason: 'change-of-mind', note: 'Customer changed plans', createdAt: at,
  });
  assert.deepEqual(firestore.records.get('inventoryMovements/return-r1-0'), {
    type: 'sale-return', returnId: 'r1', saleId: 's1', lineIndex: 1, branchId: 'north',
    productId: 'p2', quantityScaled: 1250, unit: 'kg', precision: 3,
    actorId: 'seller-one', occurredAt: at,
  });
  assert.deepEqual(firestore.records.get('inventoryMovements/return-r1-1'), {
    type: 'sale-return', returnId: 'r1', saleId: 's1', lineIndex: 0, branchId: 'north',
    productId: 'p1', quantityScaled: 3, unit: 'piece', precision: 0,
    actorId: 'seller-one', occurredAt: at,
  });
  assert.deepEqual(stock(firestore, 'p1'), {
    ...piece, quantityScaled: 8, updatedAt: at, lastMovementId: 'return-r1-1',
  });
  assert.deepEqual(stock(firestore, 'p2'), {
    ...kg, quantityScaled: 3250, updatedAt: at, lastMovementId: 'return-r1-0',
  });
  assert.deepEqual(ledger(firestore), {
    returned: { 0: 3, 1: 1250 }, lastReturnId: 'r1', updatedAt: at,
  });
  const replay = firestore.records.get('saleReturnSubmissionReceipts/r1');
  assert.deepEqual(Object.keys(replay).sort(),
    ['actorId', 'branchId', 'completedAt', 'fingerprint', 'result']);
  assert.deepEqual(replay.result, expected);
  assert.equal(replay.actorId, 'seller-one');
  assert.ok(!JSON.stringify(firestore.records.get('saleReturns/r1')).includes('Customer'),
    'the free-text note stays out of the receipt');
  // The original sale is immutable and nothing is ever written under sales/.
  assert.deepEqual(firestore.records.get('sales/s1'), sale);
  const writes = firestore.traces.flat().filter(([kind]) => kind !== 'get');
  assert.ok(writes.every(([, path]) => !path.startsWith('sales/')));
  assert.deepEqual(writes.filter(([kind]) => kind === 'set').map(([, path]) => path).sort(), [
    'branches/north/stock/p1', 'branches/north/stock/p2', 'saleReturnLedgers/s1',
  ]);
});

test('three partial returns complete a line with exact cumulative refunds and ledger', async () => {
  const { firestore, service } = fixture();
  const steps = [
    ['r1', '0.333', 333, 53, 333], ['r2', '0.333', 332, 54, 666], ['r3', '0.584', 584, 93, 1250],
  ];
  let base = 0;
  let iva = 0;
  for (const [key, quantity, lineBase, lineIva, cumulative] of steps) {
    const { receipt } = await service(request({
      idempotencyKey: key, lines: [{ lineIndex: 1, quantity, condition: 'good' }],
    }));
    assert.deepEqual(receipt.lines, [{
      lineIndex: 1, productId: 'p2', quantity, condition: 'good',
      baseCentavos: lineBase, additionalIvaCentavos: lineIva, totalCentavos: lineBase + lineIva,
    }]);
    assert.deepEqual(receipt.refund, {
      method: 'card', baseCentavos: lineBase, additionalIvaCentavos: lineIva,
      totalCentavos: lineBase + lineIva,
    });
    assert.deepEqual(ledger(firestore), {
      returned: { 1: cumulative }, lastReturnId: key, updatedAt: new Date(NOW),
    });
    base += lineBase;
    iva += lineIva;
  }
  assert.equal(base, 1249);
  assert.equal(iva, 200);
  assert.equal(stock(firestore, 'p2').quantityScaled, 3250);
  await rejectsUnchanged(firestore, service(request({
    idempotencyKey: 'r4', lines: [{ lineIndex: 1, quantity: '0.001', condition: 'good' }],
  })), 'out-of-range');
});

test('an over-return after partial returns is out-of-range and writes nothing', async () => {
  const { firestore, service } = fixture();
  await service(request({ lines: [{ lineIndex: 0, quantity: '2', condition: 'good' }] }));
  await rejectsUnchanged(firestore, service(request({
    idempotencyKey: 'r2', lines: [{ lineIndex: 0, quantity: '2', condition: 'factory-defect' }],
  })), 'out-of-range');
  await rejectsUnchanged(firestore, service(request({
    idempotencyKey: 'r3',
    lines: [{ lineIndex: 1, quantity: '0.5', condition: 'good' },
      { lineIndex: 0, quantity: '2', condition: 'good' }],
  })), 'out-of-range');
  const { receipt } = await service(request({ idempotencyKey: 'r4' }));
  assert.equal(receipt.lines[0].totalCentavos, 1160);
  assert.deepEqual(ledger(firestore).returned, { 0: 3 });
});

test('mixed good and factory-defect lines restock only good units with distinct movement types', async () => {
  const { firestore, service } = fixture();
  const { receipt } = await service(request({
    reason: 'factory-defect',
    lines: [{ lineIndex: 0, quantity: '2', condition: 'factory-defect' },
      { lineIndex: 1, quantity: '0.5', condition: 'good' }],
  }));
  assert.deepEqual(receipt.lines.map((line) => line.condition), ['factory-defect', 'good']);
  assert.equal(receipt.refund.totalCentavos, 2320 + 500 + 80);
  assert.deepEqual(stock(firestore, 'p1'), { ...piece, quantityScaled: 5 });
  assert.equal(stock(firestore, 'p2').quantityScaled, 2500);
  const defect = firestore.records.get('inventoryMovements/return-r1-0');
  assert.equal(defect.type, 'sale-return-defect');
  assert.equal(defect.quantityScaled, 2);
  assert.equal(firestore.records.get('inventoryMovements/return-r1-1').type, 'sale-return');
  // Defective units neither read nor touch sellable stock.
  const paths = firestore.traces.flat().map(([, path]) => path);
  assert.ok(!paths.includes('branches/north/stock/p1') && !paths.includes('products/p1'));
  assert.deepEqual(ledger(firestore).returned, { 0: 2, 1: 500 });
});

test('an invoiced sale refunds charged IVA and is flagged; a plain sale refunds no IVA', async () => {
  const { service } = fixture();
  const invoiced = await service(request());
  assert.equal(invoiced.receipt.invoiced, true);
  assert.deepEqual(invoiced.receipt.refund,
    { method: 'card', baseCentavos: 1000, additionalIvaCentavos: 160, totalCentavos: 1160 });
  const plain = await service(request({ idempotencyKey: 'r2', saleId: 'plain' }));
  assert.equal(plain.receipt.invoiced, false);
  assert.deepEqual(plain.receipt.refund,
    { method: 'card', baseCentavos: 1000, additionalIvaCentavos: 0, totalCentavos: 1000 });
});

test('replay is exact and duplicates no write, even after an abandoned attempt', async () => {
  const { firestore, service } = fixture();
  firestore.retry = true;
  const first = await service(request({ note: 'once' }));
  assert.equal(firestore.records.get('branches/north/stock/p1').quantityScaled, 6);
  const before = clone([...firestore.records]);
  const traces = firestore.traces.length;
  const second = await service(request({ note: 'once' }));
  assert.equal(second.replayed, true);
  assert.deepEqual(second.receipt, first.receipt);
  assert.ok(Object.isFrozen(second) && deepFrozen(second.receipt));
  assert.deepEqual([...firestore.records], before);
  assert.deepEqual(firestore.traces.slice(traces),
    [[['get', 'saleReturnSubmissionReceipts/r1']]]);
});

test('a reused key with a different payload, actor or branch is already-exists', async () => {
  const { firestore, service } = fixture();
  await service(request());
  const other = { uid: 'seller-two', token: { role: 'seller', branchId: 'north' } };
  const south = { uid: 'seller-one', token: { role: 'seller', branchId: 'south' } };
  for (const input of [
    request({ lines: [{ lineIndex: 0, quantity: '2', condition: 'good' }] }),
    request({ reason: 'other' }), request({ note: 'late note' }),
    request({ lines: [{ lineIndex: 0, quantity: '1', condition: 'factory-defect' }] }),
    request({}, other), request({ saleId: 'foreign' }, south),
  ]) {
    await rejectsUnchanged(firestore, service(input), 'already-exists');
  }
});

test('a sale key and a return key share no idempotency namespace', async () => {
  const { firestore, service } = fixture();
  firestore.records.set('saleSubmissionReceipts/r1', { actorId: 'someone-else' });
  const { replayed } = await service(request());
  assert.equal(replayed, false);
});

test('foreign and missing sales are the same not-found; expired and future sales are refused', async () => {
  const { firestore, service } = fixture();
  const message = 'sale was not found in this branch';
  await rejectsUnchanged(firestore, service(request({ saleId: 'foreign' })), 'not-found', message);
  await rejectsUnchanged(firestore, service(request({ saleId: 'missing' })), 'not-found', message);
  await rejectsUnchanged(firestore, service(request({ saleId: 'expired' })), 'failed-precondition');
  await rejectsUnchanged(firestore, service(request({ saleId: 'future' })), 'failed-precondition');
  const south = { uid: 'seller-two', token: { role: 'seller', branchId: 'south' } };
  const records = [...baseRecords(), ['branches/south/stock/p1', { ...piece, quantityScaled: 0 }]];
  const own = fixture({}, records);
  const { receipt } = await own.service(request({ saleId: 'foreign' }, south));
  assert.equal(receipt.branchId, 'south');
  assert.equal(stock(own.firestore, 'p1').quantityScaled, 5, 'another branch stock is untouched');
});

test('an unknown line or a precision mismatch is invalid-argument', async () => {
  const { firestore, service } = fixture();
  await rejectsUnchanged(firestore, service(request({
    lines: [{ lineIndex: 2, quantity: '1', condition: 'good' }],
  })), 'invalid-argument');
  await rejectsUnchanged(firestore, service(request({
    lines: [{ lineIndex: 0, quantity: '0.5', condition: 'good' }],
  })), 'invalid-argument');
  await rejectsUnchanged(firestore, service(request({
    lines: [{ lineIndex: 1, quantity: '0.0001', condition: 'good' }],
  })), 'invalid-argument');
});

test('malformed persisted sale, ledger, product, stock or replay fails closed', async () => {
  const cost = saleRecord('s1', 'north', NOW - DAY);
  cost.receipt.calculation.lines[0].pricing.unitCostCentavos = 400;
  const tampered = saleRecord('s1', 'north', NOW - DAY);
  tampered.receipt.calculation.lines[0].totalCentavos += 1;
  const cases = [
    [['sales/s1', cost]], [['sales/s1', tampered]],
    [['saleReturnLedgers/s1', { returned: { 0: 4 }, lastReturnId: 'x', updatedAt: new Date(NOW) }]],
    [['saleReturnLedgers/s1', { returned: [], lastReturnId: 'x', updatedAt: new Date(NOW) }]],
    [['saleReturnLedgers/s1', { returned: { 0: 1 }, lastReturnId: 'x', updatedAt: 'today' }]],
    [['saleReturnLedgers/s1', { returned: { 0: 1 }, lastReturnId: 'x', updatedAt: new Date(NOW),
      unitCostCentavos: 1 }]],
    [['products/p1', { quantitySpec: kg, pricing: pricing(1000) }]],
    [['products/p1', { pricing: pricing(1000) }]],
    [['branches/north/stock/p1', { ...piece, quantityScaled: -1 }]],
    [['branches/north/stock/p1', { ...kg, quantityScaled: 1 }]],
    [['saleReturnSubmissionReceipts/r1', null]],
  ];
  for (const overrides of cases) {
    const records = new Map(baseRecords());
    for (const [path, value] of overrides) records.set(path, value);
    const { firestore, service } = fixture({}, [...records]);
    if (overrides[0][0].startsWith('saleReturnSubmission')) {
      // Owned by this actor and fingerprint, but with a malformed result.
      const probe = fixture();
      await probe.service(request());
      const replay = clone(probe.firestore.records.get('saleReturnSubmissionReceipts/r1'));
      replay.result.refund.totalCentavos += 1;
      firestore.records.set('saleReturnSubmissionReceipts/r1', replay);
    }
    await rejectsUnchanged(firestore, service(request()), 'failed-precondition');
  }
  const missingProduct = new Map(baseRecords());
  missingProduct.delete('products/p1');
  const { firestore, service } = fixture({}, [...missingProduct]);
  await rejectsUnchanged(firestore, service(request()), 'failed-precondition');
});

test('a missing stock projection starts from zero for a returned good unit', async () => {
  const records = new Map(baseRecords());
  records.delete('branches/north/stock/p1');
  const { firestore, service } = fixture({}, [...records]);
  await service(request());
  assert.equal(stock(firestore, 'p1').quantityScaled, 1);
});

test('an invalid clock fails new returns but never historical replay', async () => {
  const { firestore, service } = fixture();
  await service(request());
  for (const clock of [() => new Date(NaN), () => 'now', () => { throw new Error('clock'); }]) {
    const broken = returns.createSaleReturnService({ firestore, environment, now: clock });
    assert.equal((await broken(request())).replayed, true);
    await rejectsUnchanged(firestore, broken(request({ idempotencyKey: 'r2' })), 'failed-precondition');
  }
});

test('no written document carries cost fields and caller mutation cannot alter the submission', async () => {
  const { firestore, service } = fixture();
  const input = request({ lines: [{ lineIndex: 0, quantity: '1', condition: 'good' }] });
  const pending = service(input);
  input.data.lines[0].quantity = '3';
  input.data.reason = 'other';
  const { receipt } = await pending;
  assert.equal(receipt.lines[0].quantity, '1');
  assert.equal(receipt.reason, 'change-of-mind');
  for (const [path, value] of firestore.records) {
    if (path.startsWith('products/') || path.startsWith('sales/')) continue;
    assert.ok(!/cost/i.test(JSON.stringify(value)), `cost field written at ${path}`);
  }
});

// Two lines of one product; the second line may carry a different spec.
function sameProductSale(saleId, secondSpec, secondQuantity) {
  const calculation = clone(calculateSale({ invoiceRequested: false, lines: [
    { quantity: '3', quantitySpec: piece, pricing: pricing(1000) },
    { quantity: secondQuantity, quantitySpec: secondSpec, pricing: pricing(1000) },
  ] }));
  return {
    receipt: {
      version: 1, saleId, branchId: 'north', productIds: ['p1', 'p1'], calculation,
      payment: { method: 'cash', amountCentavos: calculation.totalCentavos },
    },
    createdAt: new Date(NOW - DAY),
  };
}

test('stock is read only in a known projection shape; unknown fields fail closed', async () => {
  const at = new Date(NOW - DAY);
  for (const projection of [
    { ...piece, quantityScaled: 5, reserved: 1 },
    { ...piece, quantityScaled: 5, updatedAt: at },
    { ...piece, quantityScaled: 5, lastMovementId: 'sale-s0-0' },
    { ...piece, quantityScaled: 5, updatedAt: 'today', lastMovementId: 'sale-s0-0' },
    { ...piece, quantityScaled: 5, updatedAt: at, lastMovementId: 7 },
    { ...piece, quantityScaled: 5, demoSeedVersion: 1, updatedAt: at, lastMovementId: 'sale-s0-0' },
  ]) {
    const records = new Map(baseRecords());
    records.set('branches/north/stock/p1', projection);
    const { firestore, service } = fixture({}, [...records]);
    await rejectsUnchanged(firestore, service(request()), 'failed-precondition',
      'stock projection is invalid');
  }
  // The sale/intake writer shape and the demo seed shape are both accepted.
  for (const projection of [
    { ...piece, quantityScaled: 5, updatedAt: at, lastMovementId: 'sale-s0-0' },
    { ...piece, quantityScaled: 5, demoSeedVersion: 1 },
  ]) {
    const records = new Map(baseRecords());
    records.set('branches/north/stock/p1', projection);
    const { firestore, service } = fixture({}, [...records]);
    await service(request());
    assert.deepEqual(stock(firestore, 'p1'), {
      ...piece, quantityScaled: 6, updatedAt: new Date(NOW), lastMovementId: 'return-r1-0',
    });
  }
});

test('replay binds every stored line quantity to the request', async () => {
  const { firestore, service } = fixture();
  await service(request());
  const replay = firestore.records.get('saleReturnSubmissionReceipts/r1');
  replay.result.lines[0].quantity = '2';
  await rejectsUnchanged(firestore, service(request()), 'failed-precondition',
    'persisted return replay is invalid');
  // A stored scale-padded decimal still equals the shorter request decimal.
  const kgReturn = fixture();
  const input = request({ lines: [{ lineIndex: 1, quantity: '0.5', condition: 'good' }] });
  const first = await kgReturn.service(input);
  assert.equal(first.receipt.lines[0].quantity, '0.500');
  assert.equal((await kgReturn.service(input)).replayed, true);
});

test('two sale lines of one product aggregate into one stock write', async () => {
  const { firestore, service } = fixture({}, [
    ...baseRecords(), ['sales/dup', sameProductSale('dup', piece, '2')],
  ]);
  await service(request({ saleId: 'dup', lines: [
    { lineIndex: 0, quantity: '3', condition: 'good' },
    { lineIndex: 1, quantity: '2', condition: 'good' },
  ] }));
  assert.deepEqual(stock(firestore, 'p1'), {
    ...piece, quantityScaled: 10, updatedAt: new Date(NOW), lastMovementId: 'return-r1-1',
  });
  const sets = firestore.traces.flat().filter(([kind, path]) => kind === 'set'
    && path === 'branches/north/stock/p1');
  assert.equal(sets.length, 1);
});

test('two sale lines of one product with different specifications fail closed', async () => {
  const { firestore, service } = fixture({}, [
    ...baseRecords(), ['sales/mixed', sameProductSale('mixed', kg, '1.500')],
  ]);
  await rejectsUnchanged(firestore, service(request({ saleId: 'mixed', lines: [
    { lineIndex: 0, quantity: '1', condition: 'good' },
    { lineIndex: 1, quantity: '1', condition: 'good' },
  ] })), 'failed-precondition', 'sale lines disagree on a product specification');
});

test('an orphaned return, audit or movement document without a receipt is a stable collision', async () => {
  for (const path of ['saleReturns/r1', 'saleReturnAudits/r1', 'inventoryMovements/return-r1-0']) {
    const { firestore, service } = fixture({}, [...baseRecords(), [path, { orphan: true }]]);
    await rejectsUnchanged(firestore, service(request()), 'already-exists',
      'idempotency key collides with existing correction records');
  }
});
