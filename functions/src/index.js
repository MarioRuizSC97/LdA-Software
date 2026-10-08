import { getApps, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';

import {
  CatalogError,
  assertLocalCatalogEmulator,
  createProductCreationService,
} from './catalog.js';
import {
  InventoryError,
  assertLocalInventoryEmulator,
  createStockIntakeService,
} from './inventory.js';
import {
  PricingError,
  assertLocalPricingEmulator,
  createProductPricingService,
} from './pricing.js';

import { createSaleExchangeService } from './sale-exchanges.js';
import { createSaleLookupService } from './sale-lookup.js';
import { createSaleReplacementService } from './sale-replacements.js';
import { createSaleReturnService } from './sale-returns.js';
import {
  SaleError,
  assertLocalSalesEmulator,
  createSaleQuoteService,
  createSaleService,
} from './sales.js';

export const LOCAL_WEB_ORIGINS = [
  /^https?:\/\/localhost(?::\d{1,5})?$/,
  /^https?:\/\/127\.0\.0\.1(?::\d{1,5})?$/,
];

/**
 * Emulator-only callable. The guard runs before Admin SDK initialization so a
 * copied or accidentally deployed function cannot connect to cloud Firestore.
 */
export const createProduct = onCall(
  { region: 'us-south1', cors: LOCAL_WEB_ORIGINS },
  async (request) => {
    try {
      assertLocalCatalogEmulator();
    } catch {
      throw new HttpsError(
        'failed-precondition',
        'product creation is restricted to the local demo emulator',
      );
    }

    try {
      if (getApps().length === 0) {
        initializeApp();
      }
      const create = createProductCreationService({ firestore: getFirestore() });
      return await create(request);
    } catch (error) {
      if (error instanceof CatalogError) {
        throw new HttpsError(error.code, error.message);
      }
      throw new HttpsError(
        'internal',
        'product creation is temporarily unavailable',
      );
    }
  },
);

export const setProductPrice = onCall(
  { region: 'us-south1', cors: LOCAL_WEB_ORIGINS },
  async (request) => {
    try {
      assertLocalPricingEmulator();
    } catch {
      throw new HttpsError(
        'failed-precondition',
        'product pricing is restricted to the local demo emulator',
      );
    }

    try {
      if (getApps().length === 0) {
        initializeApp();
      }
      const setPrice = createProductPricingService({ firestore: getFirestore() });
      return await setPrice(request);
    } catch (error) {
      if (error instanceof PricingError) {
        throw new HttpsError(error.code, error.message);
      }
      throw new HttpsError(
        'internal',
        'product pricing is temporarily unavailable',
      );
    }
  },
);

export const submitSale = onCall(
  { region: 'us-south1', cors: LOCAL_WEB_ORIGINS },
  async (request) => {
    try {
      assertLocalSalesEmulator();
    } catch {
      throw new HttpsError(
        'failed-precondition',
        'sales are restricted to the local demo emulator',
      );
    }

    try {
      if (getApps().length === 0) {
        initializeApp();
      }
      const submit = createSaleService({ firestore: getFirestore() });
      return await submit(request);
    } catch (error) {
      if (error instanceof SaleError) {
        throw new HttpsError(error.code, error.message);
      }
      throw new HttpsError(
        'internal',
        'sale submission is temporarily unavailable',
      );
    }
  },
);

/** Read-only cart quote: exactly what submitSale would charge right now. */
export const quoteSale = localSaleCallable(
  'sales are restricted to the local demo emulator',
  (firestore) => createSaleQuoteService({ firestore }),
  'sale quote is temporarily unavailable',
);

export const stockIntake = onCall(
  { region: 'us-south1', cors: LOCAL_WEB_ORIGINS },
  async (request) => {
    try {
      assertLocalInventoryEmulator();
    } catch {
      throw new HttpsError(
        'failed-precondition',
        'stock intake is restricted to the local demo emulator',
      );
    }

    try {
      if (getApps().length === 0) {
        initializeApp();
      }
      const intake = createStockIntakeService({ firestore: getFirestore() });
      return await intake(request);
    } catch (error) {
      if (error instanceof InventoryError) {
        throw new HttpsError(error.code, error.message);
      }
      throw new HttpsError(
        'internal',
        'stock intake is temporarily unavailable',
      );
    }
  },
);

/**
 * Emulator-only seller callable. The sales guard runs before Admin SDK
 * initialization; the service receives the whole request, so only trusted
 * request.auth assigns the seller and branch. Services translate calculation
 * errors into SaleError, so anything else is an internal fault and is masked.
 */
function saleCorrectionCallable(createOperation, unavailableMessage) {
  return localSaleCallable(
    'sale corrections are restricted to the local demo emulator',
    createOperation,
    unavailableMessage,
  );
}

function localSaleCallable(guardMessage, createOperation, unavailableMessage) {
  return onCall(
    { region: 'us-south1', cors: LOCAL_WEB_ORIGINS },
    async (request) => {
      try {
        assertLocalSalesEmulator();
      } catch {
        throw new HttpsError('failed-precondition', guardMessage);
      }

      try {
        if (getApps().length === 0) {
          initializeApp();
        }
        const operation = createOperation(getFirestore());
        return await operation(request);
      } catch (error) {
        if (error instanceof SaleError) {
          throw new HttpsError(error.code, error.message);
        }
        throw new HttpsError('internal', unavailableMessage);
      }
    },
  );
}

export const findCorrectableSale = saleCorrectionCallable(
  (firestore) => createSaleLookupService({ firestore }).findSale,
  'sale lookup is temporarily unavailable',
);

export const listRecentCorrectableSales = saleCorrectionCallable(
  (firestore) => createSaleLookupService({ firestore }).listRecentSales,
  'recent sales lookup is temporarily unavailable',
);

export const submitSaleReturn = saleCorrectionCallable(
  (firestore) => createSaleReturnService({ firestore }),
  'sale return is temporarily unavailable',
);

export const submitSaleReplacement = saleCorrectionCallable(
  (firestore) => createSaleReplacementService({ firestore }),
  'sale replacement is temporarily unavailable',
);

export const submitSaleExchange = saleCorrectionCallable(
  (firestore) => createSaleExchangeService({ firestore }),
  'sale exchange is temporarily unavailable',
);
