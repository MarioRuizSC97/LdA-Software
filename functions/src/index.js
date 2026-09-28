import { getApps, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';

import {
  InventoryError,
  assertLocalInventoryEmulator,
  createStockIntakeService,
} from './inventory.js';

/**
 * Emulator-only callable. The guard runs before Admin SDK initialization so a
 * copied or accidentally deployed function cannot connect to cloud Firestore.
 */
export const stockIntake = onCall(
  { region: 'us-south1', cors: false },
  async (request) => {
    try {
      assertLocalInventoryEmulator();
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
        'failed-precondition',
        'stock intake is restricted to the local demo emulator',
      );
    }
  },
);
