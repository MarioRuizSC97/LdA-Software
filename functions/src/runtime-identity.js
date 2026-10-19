import { DEPLOYED_PROJECT_ID } from './runtime-project.js';

// Planned identities only. Provisioning and deployment require separate approval;
// see ../iam/README.md. This module never creates credentials or contacts IAM.
const ACCOUNT_BY_FUNCTION = Object.freeze({
  quoteSale: 'reader',
  findCorrectableSale: 'reader',
  listRecentCorrectableSales: 'reader',
  previewSaleReturn: 'reader',
  previewSaleExchange: 'reader',
  createProduct: 'writer',
  setProductPrice: 'writer',
  stockIntake: 'writer',
  transferInventory: 'writer',
  submitSale: 'writer',
  submitSaleReturn: 'writer',
  submitSaleReplacement: 'writer',
  submitSaleExchange: 'writer',
  markTransferNoticeRead: 'writer',
  setSellerProfile: 'profiles',
});

/** Explicit identity per callable; an unmapped export must never inherit one. */
export function callableRuntimeOptions(functionName, cors) {
  if (typeof functionName !== 'string' || !Object.hasOwn(ACCOUNT_BY_FUNCTION, functionName)) {
    throw new TypeError('unknown callable runtime identity');
  }
  return {
    region: 'us-south1',
    cors,
    serviceAccount: `lda-functions-${ACCOUNT_BY_FUNCTION[functionName]}@${DEPLOYED_PROJECT_ID}.iam.gserviceaccount.com`,
  };
}
