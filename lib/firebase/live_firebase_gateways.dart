import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../auth/emulator_session.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/firestore_catalog_repository.dart';
import '../movements/administrator_movements.dart';
import '../transfers/transfer_notice_controller.dart';
import 'emulator_correction_gateway.dart';
import 'emulator_product_creation_gateway.dart';
import 'emulator_product_pricing_gateway.dart';
import 'emulator_sale_gateway.dart';
import 'emulator_seller_profile_gateway.dart';
import 'emulator_stock_intake_gateway.dart';
import 'emulator_transfer_gateway.dart';
import 'emulator_transfer_notice_gateway.dart';

/// Builds every app gateway from already-configured Firebase SDK instances.
///
/// Shared by the local-emulator and production bootstraps: they differ only
/// in which Firebase app they create and whether they connect it to the
/// emulators, never in how a gateway is wired.
abstract final class LiveFirebaseGateways {
  static EmulatorSessionGateway session(FirebaseAuth auth) =>
      FirebaseEmulatorSessionGateway(auth);

  /// Refreshes the ID token and re-validates the role and branch claims.
  static ActiveSessionChecker activeSessionChecker(FirebaseAuth auth) {
    return () async {
      final User? user = auth.currentUser;
      if (user == null) return null;
      final IdTokenResult token = await user.getIdTokenResult(true);
      if (auth.currentUser?.uid != user.uid) return null;
      final Map<String, dynamic>? claims = token.claims;
      if (claims == null) throw const UntrustedSessionException();
      return EmulatorSessionClaims.validate(
        userId: user.uid,
        email: user.email,
        claims: claims.cast<String, Object?>(),
      );
    };
  }

  static RoleScopedCatalogRepository catalog({
    required FirebaseAuth auth,
    required FirebaseFirestore firestore,
    required EmulatorSession session,
  }) {
    final FirebaseFirestoreCatalogReadSource source =
        FirebaseFirestoreCatalogReadSource(firestore);
    final ActiveSessionChecker sessionChecker = activeSessionChecker(auth);
    return switch (session.role) {
      InventoryRole.administrator => FirestoreCatalogRepository.administrator(
        source: source,
        session: session,
        sessionChecker: sessionChecker,
      ),
      InventoryRole.seller => FirestoreCatalogRepository.seller(
        source: source,
        session: session,
        sessionChecker: sessionChecker,
      ),
    };
  }

  static EmulatorProductCreationGateway productCreation({
    required FirebaseAuth auth,
    required FirebaseFunctions functions,
    required EmulatorSession session,
  }) => EmulatorProductCreationGateway(
    expectedSession: session,
    sessionChecker: activeSessionChecker(auth),
    invoke: firebaseProductCreationCallable(functions),
  );

  static EmulatorProductPricingGateway productPricing({
    required FirebaseAuth auth,
    required FirebaseFunctions functions,
    required EmulatorSession session,
  }) => EmulatorProductPricingGateway(
    expectedSession: session,
    sessionChecker: activeSessionChecker(auth),
    invoke: firebaseProductPricingCallable(functions),
  );

  static EmulatorStockIntakeGateway stockIntake({
    required FirebaseAuth auth,
    required FirebaseFunctions functions,
    required EmulatorSession session,
  }) => EmulatorStockIntakeGateway(
    expectedSession: session,
    sessionChecker: activeSessionChecker(auth),
    invoke: firebaseStockIntakeCallable(functions),
  );

  static EmulatorTransferGateway transfer({
    required FirebaseAuth auth,
    required FirebaseFunctions functions,
    required EmulatorSession session,
  }) => EmulatorTransferGateway(
    expectedSession: session,
    sessionChecker: activeSessionChecker(auth),
    invoke: firebaseTransferCallable(functions),
  );

  /// Refuses anything but an exact seller session before any SDK work.
  static void requireNoticeSeller(EmulatorSession session) {
    if (session.role != InventoryRole.seller || session.branchId == null) {
      throw ArgumentError('transfer notices belong to an exact seller session');
    }
  }

  static TransferNoticeBackend transferNotices({
    required FirebaseFirestore firestore,
    required FirebaseFunctions functions,
    required EmulatorSession session,
  }) => loadTransferNoticeBackend(
    firestore: firestore,
    functions: functions,
    session: session,
  );

  static EmulatorSaleGateway sale({
    required FirebaseAuth auth,
    required FirebaseFunctions functions,
    required EmulatorSession session,
  }) => saleGateway(
    session: session,
    sessionChecker: activeSessionChecker(auth),
    callable: (String name) => firebaseSaleCallable(functions, name),
  );

  /// Binds the `quoteSale` and `submitSale` callables by name.
  static EmulatorSaleGateway saleGateway({
    required EmulatorSession session,
    required SaleSessionChecker sessionChecker,
    required SaleCallable Function(String name) callable,
  }) => EmulatorSaleGateway(
    expectedSession: session,
    sessionChecker: sessionChecker,
    quoteInvoke: callable('quoteSale'),
    submitInvoke: callable('submitSale'),
  );

  static EmulatorCorrectionGateway correction({
    required FirebaseAuth auth,
    required FirebaseFunctions functions,
    required EmulatorSession session,
  }) => correctionGateway(
    session: session,
    sessionChecker: activeSessionChecker(auth),
    callable: (String name) => firebaseSaleCallable(functions, name),
  );

  /// Binds `findCorrectableSale`, `listRecentCorrectableSales`,
  /// `submitSaleReturn`, `submitSaleReplacement`, `submitSaleExchange`,
  /// `previewSaleReturn` and `previewSaleExchange` by name.
  static EmulatorCorrectionGateway correctionGateway({
    required EmulatorSession session,
    required SaleSessionChecker sessionChecker,
    required SaleCallable Function(String name) callable,
  }) => EmulatorCorrectionGateway(
    expectedSession: session,
    sessionChecker: sessionChecker,
    findInvoke: callable('findCorrectableSale'),
    listInvoke: callable('listRecentCorrectableSales'),
    returnInvoke: callable('submitSaleReturn'),
    replacementInvoke: callable('submitSaleReplacement'),
    exchangeInvoke: callable('submitSaleExchange'),
    previewReturnInvoke: callable('previewSaleReturn'),
    previewExchangeInvoke: callable('previewSaleExchange'),
  );

  /// The Firestore movements and profile reads plus `setSellerProfile`.
  static AdministratorMovementsBackend administratorMovements({
    required FirebaseAuth auth,
    required FirebaseFirestore firestore,
    required FirebaseFunctions functions,
    required EmulatorSession session,
  }) {
    final ActiveSessionChecker sessionChecker = activeSessionChecker(auth);
    return AdministratorMovementsBackend(
      reader: FirestoreMovementRepository(
        source: FirebaseFirestoreMovementReadSource(firestore),
        session: session,
        sessionChecker: sessionChecker,
      ),
      profiles: sellerProfileGateway(
        session: session,
        sessionChecker: sessionChecker,
        callable: (String name) => firebaseSaleCallable(functions, name),
      ),
    );
  }

  /// Binds the `setSellerProfile` callable by name.
  static EmulatorSellerProfileGateway sellerProfileGateway({
    required EmulatorSession session,
    required SaleSessionChecker sessionChecker,
    required SaleCallable Function(String name) callable,
  }) => EmulatorSellerProfileGateway(
    expectedSession: session,
    sessionChecker: sessionChecker,
    invoke: callable('setSellerProfile'),
  );
}
