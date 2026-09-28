/**
 * Exact fixed-point quantities for the inventory domain.
 *
 * A product owns one immutable quantity specification: a lowercase unit key and
 * a precision from 0 through 6 decimal places. Persist quantities as scaled
 * safe integers together with that specification. Every later movement must
 * carry the same unit and precision; changing either requires an explicit
 * product migration outside this contract.
 *
 * Decimal input is accepted only as a canonical string. JavaScript numbers are
 * deliberately rejected so binary floating-point values can never be rounded
 * into stock. Values with more fractional digits than the product precision
 * are unrepresentable and are rejected, even when the extra digits are zero.
 * Input is capped at 18 characters before pattern matching or BigInt parsing.
 * That accommodates the longest signed representation of a safe scaled integer
 * at the supported precisions while bounding work for untrusted input.
 */

export const MAX_DECIMAL_PRECISION = 6;
export const MAX_QUANTITY_INPUT_LENGTH = 18;

const UNIT_PATTERN = /^[a-z][a-z0-9_-]{0,31}$/;
const DECIMAL_PATTERN = /^-?(?:0|[1-9]\d*)(?:\.(\d+))?$/;
const MAX_SAFE_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);

/**
 * Create a validated, immutable product quantity specification.
 *
 * Unit keys are domain identifiers rather than display labels. They must be
 * lowercase ASCII and may contain digits, underscores, or hyphens after the
 * first letter.
 */
export function createQuantitySpec({ unit, precision } = {}) {
  if (typeof unit !== 'string' || !UNIT_PATTERN.test(unit)) {
    throw new TypeError('unit must be a lowercase identifier of 1 to 32 characters');
  }

  if (
    !Number.isInteger(precision)
    || precision < 0
    || precision > MAX_DECIMAL_PRECISION
  ) {
    throw new RangeError(
      `precision must be an integer from 0 through ${MAX_DECIMAL_PRECISION}`,
    );
  }

  return Object.freeze({ unit, precision });
}

/**
 * Convert a canonical decimal string to the product's exact scaled integer.
 */
export function parseQuantity(quantity, spec) {
  const validSpec = validateSpec(spec);

  if (typeof quantity !== 'string') {
    throw new TypeError('quantity must be supplied as a decimal string');
  }
  if (quantity.length > MAX_QUANTITY_INPUT_LENGTH) {
    throw new RangeError(
      `quantity must contain at most ${MAX_QUANTITY_INPUT_LENGTH} characters`,
    );
  }

  const match = DECIMAL_PATTERN.exec(quantity);
  if (!match || isNegativeZero(quantity)) {
    throw new TypeError('quantity must be a canonical finite decimal string');
  }

  const fraction = match[1] ?? '';
  if (fraction.length > validSpec.precision) {
    throw new RangeError(
      `quantity exceeds the product precision of ${validSpec.precision} decimal places`,
    );
  }

  const negative = quantity.startsWith('-');
  const unsigned = negative ? quantity.slice(1) : quantity;
  const [whole, fractional = ''] = unsigned.split('.');
  const scale = 10n ** BigInt(validSpec.precision);
  const paddedFraction = fractional.padEnd(validSpec.precision, '0');
  const magnitude = BigInt(whole) * scale + BigInt(paddedFraction || '0');
  const scaled = negative ? -magnitude : magnitude;

  assertSafeBigInt(scaled, 'quantity');
  return Number(scaled);
}

/**
 * Render a scaled integer without losing precision.
 *
 * Fractional products always include exactly their configured decimal places,
 * making the stored scale explicit in serialized representations.
 */
export function formatQuantity(scaledQuantity, spec) {
  const validSpec = validateSpec(spec);
  assertSafeInteger(scaledQuantity, 'quantity');

  const negative = scaledQuantity < 0;
  const magnitude = BigInt(Math.abs(scaledQuantity));

  if (validSpec.precision === 0) {
    return `${negative ? '-' : ''}${magnitude}`;
  }

  const scale = 10n ** BigInt(validSpec.precision);
  const whole = magnitude / scale;
  const fraction = String(magnitude % scale).padStart(validSpec.precision, '0');
  return `${negative ? '-' : ''}${whole}.${fraction}`;
}

/**
 * Apply one already-scaled movement while preserving the product's quantity
 * specification, safe-integer storage bounds, and non-negative stock invariant.
 */
export function addStockMovement(
  currentScaledStock,
  movementScaledQuantity,
  productSpec,
  movementSpec,
) {
  const product = validateSpec(productSpec);
  const movement = validateSpec(movementSpec);
  assertStableSpec(product, movement);
  assertSafeInteger(currentScaledStock, 'current stock');
  assertSafeInteger(movementScaledQuantity, 'movement quantity');

  if (currentScaledStock < 0) {
    throw new RangeError('current stock cannot be negative');
  }

  const result = BigInt(currentScaledStock) + BigInt(movementScaledQuantity);
  if (result < 0n) {
    throw new RangeError('movement would produce negative stock');
  }

  assertSafeBigInt(result, 'stock result');
  return Number(result);
}

function validateSpec(spec) {
  if (spec === null || typeof spec !== 'object') {
    throw new TypeError('quantity specification is required');
  }

  return createQuantitySpec({ unit: spec.unit, precision: spec.precision });
}

function assertStableSpec(productSpec, movementSpec) {
  if (productSpec.unit !== movementSpec.unit) {
    throw new RangeError('movement unit must remain stable for the product');
  }
  if (productSpec.precision !== movementSpec.precision) {
    throw new RangeError('movement precision must remain stable for the product');
  }
}

function assertSafeInteger(value, label) {
  if (!Number.isSafeInteger(value)) {
    throw new RangeError(`${label} must be a safe integer`);
  }
}

function assertSafeBigInt(value, label) {
  if (value > MAX_SAFE_BIGINT || value < -MAX_SAFE_BIGINT) {
    throw new RangeError(`${label} must fit in a safe integer`);
  }
}

function isNegativeZero(quantity) {
  if (!quantity.startsWith('-')) {
    return false;
  }

  const digits = quantity.slice(1).replace('.', '');
  return /^0+$/.test(digits);
}
