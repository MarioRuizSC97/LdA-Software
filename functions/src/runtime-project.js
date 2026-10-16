/** The Firebase project the app uses as production (chosen 2026-10-16). */
export const DEPLOYED_PROJECT_ID = 'lda-inventory-dev-mx';

const EMULATOR_MARKERS = [
  'FUNCTIONS_EMULATOR',
  'FIRESTORE_EMULATOR_HOST',
  'FIREBASE_AUTH_EMULATOR_HOST',
  'FIREBASE_STORAGE_EMULATOR_HOST',
];

/**
 * True only inside a deployed Cloud Functions runtime of
 * [DEPLOYED_PROJECT_ID]: the pinned project, every optional project source in
 * agreement, and no emulator marker at all, so a deployed function never mixes
 * with emulator traffic. Pure: environment values are never echoed.
 */
export function isDeployedProjectRuntime(environment = process.env) {
  if (environment?.GCLOUD_PROJECT !== DEPLOYED_PROJECT_ID) return false;
  if (EMULATOR_MARKERS.some((name) => environment[name] !== undefined)) return false;
  if (
    environment.GOOGLE_CLOUD_PROJECT !== undefined
    && environment.GOOGLE_CLOUD_PROJECT !== DEPLOYED_PROJECT_ID
  ) {
    return false;
  }
  if (environment.FIREBASE_CONFIG !== undefined) {
    try {
      // Accept inline JSON only: a config path must never trigger a file read.
      const config = typeof environment.FIREBASE_CONFIG === 'string'
        ? JSON.parse(environment.FIREBASE_CONFIG) : null;
      return config !== null && typeof config === 'object'
        && !Array.isArray(config) && config.projectId === DEPLOYED_PROJECT_ID;
    } catch {
      return false;
    }
  }
  return true;
}
