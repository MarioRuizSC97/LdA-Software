import { getApps, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import * as logger from 'firebase-functions/logger';
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
import { createTransferService } from './transfers.js';
import { createTransferNoticeReadService } from './transfer-notices.js';

import { createSaleExchangePreviewService, createSaleExchangeService } from './sale-exchanges.js';
import { createSaleLookupService } from './sale-lookup.js';
import { createSaleReplacementService } from './sale-replacements.js';
import { createSaleReturnPreviewService, createSaleReturnService } from './sale-returns.js';
import {
  SaleError,
  assertLocalSalesEmulator,
  createSaleQuoteService,
  createSaleService,
} from './sales.js';
import {
  SellerProfileError,
  assertLocalSellerProfilesEmulator,
  createSellerProfileService,
} from './sellerProfiles.js';

/**
 * Creates the default Admin app once. A plain `getApps().length` check is not
 * enough: in a deployed runtime firebase-functions creates its own named app
 * to verify ID tokens before the callable body runs.
 */
export function ensureDefaultApp() {
  if (!getApps().some((app) => app.name === '[DEFAULT]')) {
    initializeApp();
  }
}

/**
 * Logs an unexpected failure (error class, code and message only, never the
 * request) and returns the generic internal error the client sees.
 */
export function unexpectedFailure(error, clientMessage, log = logger) {
  log.error('callable failed unexpectedly', {
    errorName: error?.name,
    errorCode: error?.code,
    errorMessage: error?.message,
  });
  return new HttpsError('internal', clientMessage);
}

export const LOCAL_WEB_ORIGINS = [
  /^https?:\/\/localhost(?::\d{1,5})?$/,
  /^https?:\/\/127\.0\.0\.1(?::\d{1,5})?$/,
];

/**
 * Trusted-runtime callable: the demo emulator or the deployed production
 * project only (see runtime-project.js). The guard runs before Admin SDK
 * initialization, so a function copied to any other project never connects.
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
      ensureDefaultApp();
      const create = createProductCreationService({ firestore: getFirestore() });
      return await create(request);
    } catch (error) {
      if (error instanceof CatalogError) {
        throw new HttpsError(error.code, error.message);
      }
      throw unexpectedFailure(error, 'product creation is temporarily unavailable');
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
      ensureDefaultApp();
      const setPrice = createProductPricingService({ firestore: getFirestore() });
      return await setPrice(request);
    } catch (error) {
      if (error instanceof PricingError) {
        throw new HttpsError(error.code, error.message);
      }
      throw unexpectedFailure(error, 'product pricing is temporarily unavailable');
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
      ensureDefaultApp();
      const submit = createSaleService({ firestore: getFirestore() });
      return await submit(request);
    } catch (error) {
      if (error instanceof SaleError) throw reasonedHttpsError(error);
      throw unexpectedFailure(error, 'sale submission is temporarily unavailable');
    }
  },
);

/**
 * Public code and message, plus details { reason } only when the SaleError or
 * SellerProfileError carries a machine reason. Nothing else from the error
 * reaches the caller.
 */
function reasonedHttpsError(error) {
  return typeof error.reason === 'string'
    ? new HttpsError(error.code, error.message, { reason: error.reason })
    : new HttpsError(error.code, error.message);
}

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
      ensureDefaultApp();
      const intake = createStockIntakeService({ firestore: getFirestore() });
      return await intake(request);
    } catch (error) {
      if (error instanceof InventoryError) {
        throw new HttpsError(error.code, error.message);
      }
      throw unexpectedFailure(error, 'stock intake is temporarily unavailable');
    }
  },
);

/**
 * Trusted-runtime administrator transfer callable. The inventory guard runs
 * before Admin SDK initialization, so a function copied to any other project
 * can never move stock. Domain failures are InventoryErrors and keep their code; any
 * other error is masked as an internal fault.
 */
export const transferInventory = onCall(
  { region: 'us-south1', cors: LOCAL_WEB_ORIGINS },
  async (request) => {
    try {
      assertLocalInventoryEmulator();
    } catch {
      throw new HttpsError(
        'failed-precondition',
        'transfers are restricted to the local demo emulator',
      );
    }

    try {
      ensureDefaultApp();
      const transfer = createTransferService({ firestore: getFirestore() });
      return await transfer(request);
    } catch (error) {
      if (error instanceof InventoryError) {
        throw new HttpsError(error.code, error.message);
      }
      throw unexpectedFailure(error, 'inventory transfer is temporarily unavailable');
    }
  },
);

/**
 * Trusted-runtime seller callable for destination transfer notice
 * acknowledgements (DN-01). The inventory guard runs before Admin SDK
 * initialization, so a function copied to any other project can never write
 * markers. Identity and
 * branch come from the verified token only; the service validates the private
 * transfer audit server-side before writing the per-seller marker.
 */
export const markTransferNoticeRead = onCall(
  { region: 'us-south1', cors: LOCAL_WEB_ORIGINS },
  async (request) => {
    try {
      assertLocalInventoryEmulator();
    } catch {
      throw new HttpsError(
        'failed-precondition',
        'transfer notices are restricted to the local demo emulator',
      );
    }

    try {
      ensureDefaultApp();
      const markRead = createTransferNoticeReadService({ firestore: getFirestore() });
      return await markRead(request);
    } catch (error) {
      if (error instanceof InventoryError) {
        throw new HttpsError(error.code, error.message);
      }
      throw unexpectedFailure(error, 'transfer notice acknowledgement is temporarily unavailable');
    }
  },
);

/**
 * Trusted-runtime seller callable. The sales guard runs before Admin SDK
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
        ensureDefaultApp();
        const operation = createOperation(getFirestore());
        return await operation(request);
      } catch (error) {
        if (error instanceof SaleError) throw reasonedHttpsError(error);
        throw unexpectedFailure(error, unavailableMessage);
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

/**
 * Read-only correction previews (decision 12): exactly what submitSaleReturn
 * and submitSaleExchange would produce right now, without writing. One
 * callable per kind, mirroring the submits and their exact request shapes.
 */
export const previewSaleReturn = saleCorrectionCallable(
  (firestore) => createSaleReturnPreviewService({ firestore }),
  'sale return preview is temporarily unavailable',
);

export const previewSaleExchange = saleCorrectionCallable(
  (firestore) => createSaleExchangePreviewService({ firestore }),
  'sale exchange preview is temporarily unavailable',
);

/**
 * Trusted-runtime administrator callable. The guard runs before Admin SDK
 * initialization, and Admin Auth is imported lazily after it, so a failed
 * guard never loads the Auth SDK and the other callables never depend on it.
 * The branch always comes from the target's trusted Auth claims.
 */
export const setSellerProfile = onCall(
  { region: 'us-south1', cors: LOCAL_WEB_ORIGINS },
  async (request) => {
    try {
      assertLocalSellerProfilesEmulator();
    } catch {
      throw new HttpsError(
        'failed-precondition',
        'seller profiles are restricted to the local demo emulator',
      );
    }

    try {
      ensureDefaultApp();
      const { getAuth } = await import('firebase-admin/auth');
      const setProfile = createSellerProfileService({
        firestore: getFirestore(),
        auth: getAuth(),
      });
      return await setProfile(request);
    } catch (error) {
      if (error instanceof SellerProfileError) throw reasonedHttpsError(error);
      throw unexpectedFailure(error, 'seller profile update is temporarily unavailable');
    }
  },
);
