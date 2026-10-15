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
      if (error instanceof SaleError) throw reasonedHttpsError(error);
      throw new HttpsError(
        'internal',
        'sale submission is temporarily unavailable',
      );
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
 * Emulator-only administrator transfer callable. The inventory guard runs before
 * Admin SDK initialization, so a copied or deployed function can never move
 * cloud stock. Domain failures are InventoryErrors and keep their code; any
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
      if (getApps().length === 0) {
        initializeApp();
      }
      const transfer = createTransferService({ firestore: getFirestore() });
      return await transfer(request);
    } catch (error) {
      if (error instanceof InventoryError) {
        throw new HttpsError(error.code, error.message);
      }
      throw new HttpsError(
        'internal',
        'inventory transfer is temporarily unavailable',
      );
    }
  },
);

/**
 * Emulator-only seller callable for destination transfer notice acknowledgements
 * (DN-01). The inventory guard runs before Admin SDK initialization, so a
 * copied or deployed function can never write cloud markers. Identity and
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
      if (getApps().length === 0) {
        initializeApp();
      }
      const markRead = createTransferNoticeReadService({ firestore: getFirestore() });
      return await markRead(request);
    } catch (error) {
      if (error instanceof InventoryError) {
        throw new HttpsError(error.code, error.message);
      }
      throw new HttpsError(
        'internal',
        'transfer notice acknowledgement is temporarily unavailable',
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
        if (error instanceof SaleError) throw reasonedHttpsError(error);
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
 * Emulator-only administrator callable. The guard runs before Admin SDK
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
      if (getApps().length === 0) {
        initializeApp();
      }
      const { getAuth } = await import('firebase-admin/auth');
      const setProfile = createSellerProfileService({
        firestore: getFirestore(),
        auth: getAuth(),
      });
      return await setProfile(request);
    } catch (error) {
      if (error instanceof SellerProfileError) throw reasonedHttpsError(error);
      throw new HttpsError(
        'internal',
        'seller profile update is temporarily unavailable',
      );
    }
  },
);
