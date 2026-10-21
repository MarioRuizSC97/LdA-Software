import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../auth/emulator_session.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/product_creation.dart';
import '../catalog/product_pricing.dart';
import '../catalog/product_rename.dart';
import '../firebase_options.dart';
import '../movements/administrator_movements.dart';
import '../transfers/transfer_notice_controller.dart';
import 'emulator_correction_gateway.dart';
import 'emulator_sale_gateway.dart';
import 'emulator_stock_intake_gateway.dart';
import 'emulator_transfer_gateway.dart';
import 'live_firebase_gateways.dart';

/// Production bootstrap: the real Firebase project from
/// [DefaultFirebaseOptions] (`lda-inventory-dev-mx`), with no emulator
/// connection and its own named app, so it can never share state with the
/// local-emulator app. Every loader mirrors [DemoEmulatorBootstrap]'s and
/// builds the same gateways through [LiveFirebaseGateways].
abstract final class ProductionFirebaseBootstrap {
  static const String appName = 'lda-production';
  static const String functionsRegion = 'us-south1';

  /// The real project options for the running platform. Desktop targets have
  /// none and throw [UnsupportedError] before any Firebase work.
  static FirebaseOptions get options => DefaultFirebaseOptions.currentPlatform;

  static Future<FirebaseApp>? _app;

  /// Creates or reuses the production app. Tests may replace it and must
  /// restore it with [resetForTesting]; production never reassigns it.
  @visibleForTesting
  static Future<FirebaseApp> Function() createApp = _createApp;

  @visibleForTesting
  static void resetForTesting() {
    _app = null;
    createApp = _createApp;
  }

  /// One shared start for concurrent loads; a failed start is retried on the
  /// next load instead of being cached.
  @visibleForTesting
  static Future<FirebaseApp> initializeApp() =>
      _app ??= createApp().catchError((Object error, StackTrace stackTrace) {
        _app = null;
        Error.throwWithStackTrace(error, stackTrace);
      });

  static Future<FirebaseApp> _createApp() async {
    final FirebaseOptions expected = options;
    for (final FirebaseApp app in Firebase.apps) {
      if (app.name != appName) continue;
      verifyExistingOptions(app.options);
      return app;
    }
    return Firebase.initializeApp(name: appName, options: expected);
  }

  /// Refuses an existing app with the production name but other options.
  @visibleForTesting
  static void verifyExistingOptions(FirebaseOptions actual) {
    final FirebaseOptions expected = options;
    if (actual.projectId != expected.projectId ||
        actual.appId != expected.appId ||
        actual.apiKey != expected.apiKey) {
      throw StateError('The production Firebase app has unexpected options.');
    }
  }

  static Future<T> _live<T>(
    FutureOr<T> Function(
      FirebaseAuth auth,
      FirebaseFirestore firestore,
      FirebaseFunctions functions,
    )
    create,
  ) async {
    final FirebaseApp app = await initializeApp();
    return await create(
      FirebaseAuth.instanceFor(app: app),
      FirebaseFirestore.instanceFor(app: app),
      FirebaseFunctions.instanceFor(app: app, region: functionsRegion),
    );
  }

  static Future<EmulatorSessionGateway> initialize() =>
      _live((FirebaseAuth auth, _, _) => LiveFirebaseGateways.session(auth));

  static Future<RoleScopedCatalogRepository> initializeCatalogRepository(
    EmulatorSession session,
  ) => _live(
    (FirebaseAuth auth, FirebaseFirestore firestore, _) =>
        LiveFirebaseGateways.catalog(
          auth: auth,
          firestore: firestore,
          session: session,
        ),
  );

  static Future<ProductCreationGateway> initializeProductCreationGateway(
    EmulatorSession session,
  ) => _live(
    (FirebaseAuth auth, _, FirebaseFunctions functions) =>
        LiveFirebaseGateways.productCreation(
          auth: auth,
          functions: functions,
          session: session,
        ),
  );

  static Future<ProductPricingGateway> initializeProductPricingGateway(
    EmulatorSession session,
  ) => _live(
    (FirebaseAuth auth, _, FirebaseFunctions functions) =>
        LiveFirebaseGateways.productPricing(
          auth: auth,
          functions: functions,
          session: session,
        ),
  );

  /// Administrator product rename over the `renameProduct` callable, built
  /// from the production app's own Functions instance for region us-south1,
  /// never the default singleton.
  static Future<ProductRenameGateway> initializeProductRenameGateway(
    EmulatorSession session,
  ) => _live(
    (FirebaseAuth auth, _, FirebaseFunctions functions) =>
        LiveFirebaseGateways.productRename(
          auth: auth,
          functions: functions,
          session: session,
        ),
  );

  static Future<EmulatorStockIntakeGateway> initializeStockIntakeGateway(
    EmulatorSession session,
  ) => _live(
    (FirebaseAuth auth, _, FirebaseFunctions functions) =>
        LiveFirebaseGateways.stockIntake(
          auth: auth,
          functions: functions,
          session: session,
        ),
  );

  static Future<EmulatorTransferGateway> initializeTransferGateway(
    EmulatorSession session,
  ) => _live(
    (FirebaseAuth auth, _, FirebaseFunctions functions) =>
        LiveFirebaseGateways.transfer(
          auth: auth,
          functions: functions,
          session: session,
        ),
  );

  static Future<TransferNoticeBackend> initializeTransferNoticeBackend(
    EmulatorSession session,
  ) {
    LiveFirebaseGateways.requireNoticeSeller(session);
    return _live(
      (_, FirebaseFirestore firestore, FirebaseFunctions functions) =>
          LiveFirebaseGateways.transferNotices(
            firestore: firestore,
            functions: functions,
            session: session,
          ),
    );
  }

  static Future<EmulatorSaleGateway> initializeSaleGateway(
    EmulatorSession session,
  ) => _live(
    (FirebaseAuth auth, _, FirebaseFunctions functions) =>
        LiveFirebaseGateways.sale(
          auth: auth,
          functions: functions,
          session: session,
        ),
  );

  static Future<EmulatorCorrectionGateway> initializeCorrectionGateway(
    EmulatorSession session,
  ) => _live(
    (FirebaseAuth auth, _, FirebaseFunctions functions) =>
        LiveFirebaseGateways.correction(
          auth: auth,
          functions: functions,
          session: session,
        ),
  );

  static Future<AdministratorMovementsBackend> initializeAdministratorMovements(
    EmulatorSession session,
  ) => _live(
    (
      FirebaseAuth auth,
      FirebaseFirestore firestore,
      FirebaseFunctions functions,
    ) => LiveFirebaseGateways.administratorMovements(
      auth: auth,
      firestore: firestore,
      functions: functions,
      session: session,
    ),
  );
}
