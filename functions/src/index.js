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

const LOCAL_WEB_ORIGINS = [
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
