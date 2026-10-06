import { createQuantitySpec, formatQuantity, parseQuantity } from './quantity.js';

const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER);
const PRICING_FIELDS = [
  'currency', 'ivaRateBasisPoints', 'ivaTreatment', 'listedPriceCentavos', 'priceMode',
];
const CALCULATION_POLICY = Object.freeze({
  version: 1,
  rounding: 'half-up',
  roundingScope: 'per-line',
  additionalIvaBase: 'rounded-line-base',
  includedIvaExtraction: 'not-calculated',
});

/**
 * Pure authoritative calculation, not authorization or a catalog lookup.
 * Callers supply trusted published pricing and stable quantity specifications.
 * Input: { invoiceRequested: Boolean, lines: [{ quantity: decimal string,
 * quantitySpec: { unit, precision }, pricing: the published pricing schema }] }.
 *
 * Every result is a detached, deeply frozen, JSON-compatible v1 snapshot.
 * baseCentavos is the rounded listed charge (gross in included mode), NOT a
 * fiscal net base. additionalIvaCentavos is always the actual extra charge.
 * includedIvaCentavos remains null: no included component is calculated here,
 * even for exempt/zero-rated policies. It must never be interpreted as zero.
 * No product identity, costs, actor metadata, payment or SDK state is accepted.
 */
export function calculateSale(input) {
  exactFields(input, ['invoiceRequested', 'lines'], 'sale');
  if (typeof input.invoiceRequested !== 'boolean') {
    throw new TypeError('invoiceRequested must be an explicit Boolean');
  }
  if (!Array.isArray(input.lines) || input.lines.length === 0) {
    throw new TypeError('sale lines must be a nonempty array');
  }

  const lines = [];
  let base = 0n;
  let additionalIva = 0n;
  let total = 0n;
  // Iteration deliberately visits sparse entries so they fail validation.
  for (const inputLine of input.lines) {
    const line = calculateLine(inputLine, input.invoiceRequested);
    base += BigInt(line.baseCentavos);
    additionalIva += BigInt(line.additionalIvaCentavos);
    total += BigInt(line.totalCentavos);
    safeNumber(total, 'sale total');
    lines.push(line);
  }

  return Object.freeze({
    version: 1,
    currency: 'MXN',
    invoiceRequested: input.invoiceRequested,
    calculationPolicy: CALCULATION_POLICY,
    lines: Object.freeze(lines),
    baseCentavos: safeNumber(base, 'sale base'),
    additionalIvaCentavos: safeNumber(additionalIva, 'sale additional IVA'),
    totalCentavos: safeNumber(total, 'sale total'),
  });
}

function calculateLine(input, invoiceRequested) {
  exactFields(input, ['pricing', 'quantity', 'quantitySpec'], 'line');
  exactFields(input.quantitySpec, ['precision', 'unit'], 'quantity specification');
  const spec = createQuantitySpec(input.quantitySpec);
  const scaled = parseQuantity(input.quantity, spec);
  if (scaled <= 0) throw new RangeError('sale quantity must be positive');
  const pricing = snapshotPricing(input.pricing);
  const scale = 10n ** BigInt(spec.precision);
  const base = halfUp(BigInt(scaled) * BigInt(pricing.listedPriceCentavos), scale);
  const baseCentavos = safeNumber(base, 'line base');

  const chargeIva = invoiceRequested
    && pricing.priceMode === 'iva-additional-on-invoice'
    && pricing.ivaTreatment === 'taxable';
  const additionalIva = chargeIva
    ? halfUp(base * BigInt(pricing.ivaRateBasisPoints), 10_000n)
    : 0n;

  return Object.freeze({
    quantity: Object.freeze({
      version: 1,
      spec,
      scaled,
      decimal: formatQuantity(scaled, spec),
    }),
    pricing,
    baseCentavos,
    additionalIvaCentavos: safeNumber(additionalIva, 'line additional IVA'),
    includedIvaCentavos: null,
    totalCentavos: safeNumber(base + additionalIva, 'line total'),
  });
}

// pricing.js keeps its stored-policy validator private. Mirror that published
// schema here without importing its service factory or relaxing its policies.
function snapshotPricing(value) {
  exactFields(value, PRICING_FIELDS, 'pricing');
  const { currency, listedPriceCentavos, priceMode, ivaTreatment, ivaRateBasisPoints } = value;
  if (currency !== 'MXN') throw new TypeError('pricing currency must be MXN');
  if (!Number.isSafeInteger(listedPriceCentavos) || listedPriceCentavos < 0) {
    throw new RangeError('listed price must be a nonnegative safe integer');
  }
  if (!['iva-included', 'iva-additional-on-invoice'].includes(priceMode)) {
    throw new TypeError('unsupported price mode');
  }
  if (!['taxable', 'zero-rated', 'exempt'].includes(ivaTreatment)) {
    throw new TypeError('unsupported IVA treatment');
  }
  if (
    (ivaTreatment === 'exempt' && ivaRateBasisPoints !== null)
    || (ivaTreatment === 'zero-rated' && ivaRateBasisPoints !== 0)
    || (ivaTreatment === 'taxable' && (
      !Number.isInteger(ivaRateBasisPoints)
      || ivaRateBasisPoints < 1 || ivaRateBasisPoints > 10_000
    ))
  ) {
    throw new RangeError('IVA rate must match its treatment and published bounds');
  }
  return Object.freeze({
    version: 1, currency, listedPriceCentavos, priceMode, ivaTreatment, ivaRateBasisPoints,
  });
}

function exactFields(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${label} must be an object`);
  }
  const fields = Reflect.ownKeys(value);
  if (fields.length !== expected.length || fields.some((field) => !expected.includes(field))) {
    throw new TypeError(`${label} contains missing or unsupported fields`);
  }
}

// All operands are nonnegative integers; double the numerator to implement
// nearest-integer rounding with exact half ties up, without floating point.
function halfUp(numerator, denominator) {
  return (2n * numerator + denominator) / (2n * denominator);
}

function safeNumber(value, label) {
  if (value < 0n || value > MAX_SAFE) {
    throw new RangeError(`${label} must fit in a nonnegative safe integer`);
  }
  return Number(value);
}
