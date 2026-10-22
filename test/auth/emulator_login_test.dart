import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/backend_environment.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/catalog/product_pricing.dart';
import 'package:lda_inventory/catalog/stock_intake.dart';
import 'package:lda_inventory/firebase/emulator_product_creation_gateway.dart';
import 'package:lda_inventory/firebase/emulator_stock_intake_gateway.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';

class _FakeGateway implements EmulatorSessionGateway {
  _FakeGateway({
    this.restored,
    this.restoreError,
    this.loginResult,
    this.loginError,
    this.loginCompleter,
    this.logoutCompleter,
    this.cleanupBeforeLoginFailure = false,
  });

  final EmulatorSession? restored;
  Object? restoreError;
  final EmulatorSession? loginResult;
  final Object? loginError;
  final bool cleanupBeforeLoginFailure;
  Completer<EmulatorSession>? loginCompleter;
  final Completer<void>? logoutCompleter;
  final StreamController<EmulatorSession?> sessions =
      StreamController<EmulatorSession?>.broadcast();
  var restoreCalls = 0;
  var logoutCalls = 0;
  String? submittedEmail;
  String? submittedPassword;

  @override
  Future<EmulatorSession?> restoreSession() async {
    restoreCalls += 1;
    if (restoreError case final Object error) throw error;
    return restored;
  }

  @override
  Stream<EmulatorSession?> sessionChanges() => sessions.stream;

  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) async {
    submittedEmail = email;
    submittedPassword = password;
    if (loginError case final Object error) throw error;
    if (loginCompleter case final Completer<EmulatorSession> completer) {
      try {
        return await completer.future;
      } catch (_) {
        if (cleanupBeforeLoginFailure) {
          // Model SDK signOut delivering null before gateway.login rejects.
          sessions.add(null);
          await Future<void>.delayed(Duration.zero);
        }
        rethrow;
      }
    }
    return loginResult!;
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
    await logoutCompleter?.future;
  }
}

// A local SDK double: no Firebase initialization, endpoints, or Auth requests.
class _FailingSdkAuth implements FirebaseAuth {
  _FailingSdkAuth({
    required this.validationFailure,
    this.signInError,
    this.tokenError,
  });

  final bool validationFailure;
  Object? signInError;
  Completer<UserCredential>? pendingSignIn;
  Object? tokenError;
  final StreamController<User?> events = StreamController<User?>.broadcast();
  int cleanupCalls = 0;

  @override
  User? get currentUser => null;

  @override
  Stream<User?> idTokenChanges() => events.stream;

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    if (pendingSignIn case final Completer<UserCredential> pending) {
      return pending.future;
    }
    if (signInError case final Object error) throw error;
    if (validationFailure) {
      return _InvalidSdkCredential(tokenError: tokenError);
    }
    throw StateError('private SDK failure');
  }

  @override
  Future<void> signOut() async {
    cleanupCalls += 1;
    events.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InvalidSdkCredential implements UserCredential {
  _InvalidSdkCredential({this.tokenError});
  final Object? tokenError;

  @override
  User get user => _InvalidSdkUser(tokenError: tokenError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InvalidSdkUser implements User {
  _InvalidSdkUser({this.tokenError});
  final Object? tokenError;

  @override
  String get uid => 'test-sdk-user';

  @override
  String get email => 'test-sdk@demo.invalid';

  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async {
    expect(forceRefresh, isTrue);
    if (tokenError case final Object error) throw error;
    throw StateError('private token validation failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Object _syntheticTypeError() {
  try {
    final Object value = 'synthetic-private-value';
    return value as int;
  } catch (error) {
    return error;
  }
}

class _HostileSdkError implements Exception {
  @override
  String toString() => throw StateError('must not inspect error contents');
}

class _FakePricingGateway implements ProductPricingGateway {
  _FakePricingGateway(this.onSetPrice);

  final Future<ProductPricingResult> Function(ProductPricingDraft draft)
  onSetPrice;

  @override
  Future<ProductPricingResult> setPrice(ProductPricingDraft draft) =>
      onSetPrice(draft);
}

class _FakeStockIntakeGateway extends EmulatorStockIntakeGateway {
  _FakeStockIntakeGateway(this.onSubmit)
    : super(
        expectedSession: _administrator,
        sessionChecker: () async => null,
        invoke: (_) async => <String, Object?>{},
      );

  final Future<StockIntakeResult> Function(StockIntakeDraft draft) onSubmit;

  @override
  Future<StockIntakeResult> submitIntake(StockIntakeDraft draft) =>
      onSubmit(draft);
}

class _FakeProductGateway implements ProductCreationGateway {
  _FakeProductGateway([this.onCreate]);

  final Future<ProductCreationResult> Function(ProductCreationDraft draft)?
  onCreate;

  @override
  Future<ProductCreationResult> create(ProductCreationDraft draft) =>
      onCreate?.call(draft) ??
      Future<ProductCreationResult>.value(
        const ProductCreationResult(
          productId: 'PRD-TEST-0001',
          internalCode: 'PRD-TEST-0001',
          replayed: false,
        ),
      );
}

const EmulatorSession _administrator = EmulatorSession(
  userId: 'demo-local-administrator',
  email: 'administrator@demo-lda-inventory.invalid',
  role: InventoryRole.administrator,
);

const EmulatorSession _otherAdministrator = EmulatorSession(
  userId: 'demo-local-administrator-2',
  email: 'administrator.2@demo-lda-inventory.invalid',
  role: InventoryRole.administrator,
);

const EmulatorSession _seller = EmulatorSession(
  userId: 'demo-local-seller-north',
  email: 'seller.north@demo-lda-inventory.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Future<CatalogSnapshot> _emptyCatalog(EmulatorSession session) async =>
    CatalogSnapshot(const <CatalogItem>[]);

Widget _app(
  Future<EmulatorSessionGateway> gateway, {
  CatalogSnapshotLoader catalogLoader = _emptyCatalog,
  ProductCreationGatewayLoader? productCreationGatewayLoader,
  ProductPricingGatewayLoader? productPricingGatewayLoader,
  StockIntakeGatewayLoader? stockIntakeGatewayLoader,
  GlobalKey<EmulatorLoginShellState>? shellKey,
  BackendEnvironment environment = BackendEnvironment.localEmulator,
}) => MaterialApp(
  home: EmulatorLoginShell(
    key: shellKey,
    environment: environment,
    sessionGateway: gateway,
    catalogLoader: catalogLoader,
    productCreationGatewayLoader: productCreationGatewayLoader,
    productPricingGatewayLoader: productPricingGatewayLoader,
    stockIntakeGatewayLoader: stockIntakeGatewayLoader,
  ),
);

Future<void> _enterProduct(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Crear producto'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey<String>('create-product-name')),
    'Coffee',
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('create-product-unit')),
    'piece',
  );
  // Precision is now a dropdown of 0 through 6 with no default; select 0.
  await tester.tap(
    find.byKey(const ValueKey<String>('create-product-precision')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('0').last);
  await tester.pumpAndSettle();
  final Finder create = find.widgetWithText(FilledButton, 'Crear');
  await tester.ensureVisible(create);
  await tester.tap(create);
}

const CatalogProduct _pricedCoffee = CatalogProduct(
  internalCode: 'PRD-COFFEE-001',
  name: 'Coffee',
  quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
  pricing: CatalogPricing(
    listedPriceCentavos: 12900,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);

Future<CatalogSnapshot> _coffeeCatalog(EmulatorSession session) async =>
    CatalogSnapshot(<CatalogItem>[
      CatalogItem(product: _pricedCoffee, holdings: const <CatalogHolding>[]),
    ]);

Future<CatalogSnapshot> _intakeCatalog(EmulatorSession session) async =>
    CatalogSnapshot(
      <CatalogItem>[
        CatalogItem(product: _pricedCoffee, holdings: const <CatalogHolding>[]),
      ],
      branchChoices: const <CatalogBranchChoice>[
        CatalogBranchChoice(
          branchId: 'branch-north',
          branchName: 'North Demo Branch',
        ),
        CatalogBranchChoice(
          branchId: 'branch-south',
          branchName: 'South Demo Branch',
        ),
      ],
    );

/// Opens the product detail sheet (T5) and then the pricing flow from it.
Future<void> _openProductSheet(WidgetTester tester, String code) async {
  await tester.ensureVisible(
    find.byKey(ValueKey<String>('product-details-$code')),
  );
  await tester.tap(find.byKey(ValueKey<String>('product-details-$code')));
  await tester.pumpAndSettle();
}

Future<void> _submitExistingPricing(WidgetTester tester) async {
  await _openProductSheet(tester, 'PRD-COFFEE-001');
  final Finder configure = find.byKey(
    const ValueKey<String>('configure-price-PRD-COFFEE-001'),
  );
  await tester.ensureVisible(configure);
  await tester.tap(configure);
  await tester.pumpAndSettle();
  final Finder save = find.widgetWithText(FilledButton, 'Guardar precio / IVA');
  await tester.ensureVisible(save);
  await tester.tap(save);
}

Future<void> _signIn(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('login-email')),
    'administrator@demo-lda-inventory.invalid',
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('login-password')),
    'Demo-Only-Administrator-2026!',
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
  await tester.pumpAndSettle();
}

StockIntakeDraft _intakeDraft({String? quantity}) => StockIntakeDraft(
  idempotencyKey: createStockIntakeUuidV4(),
  branchId: 'branch-north',
  productId: 'PRD-COFFEE-001',
  quantity: quantity ?? '3',
  unitCostMxn: '12.50',
  quantitySpec: const StockIntakeQuantitySpec(unit: 'piece', precision: 0),
);

StockIntakeResult _intakeResult(
  StockIntakeDraft draft, {
  required bool replayed,
}) => StockIntakeResult.fromCallable(<String, Object?>{
  'entryId': draft.idempotencyKey,
  'movementId': draft.idempotencyKey,
  'quantityScaled': draft.quantityScaled,
  'stockQuantityScaled': draft.quantityScaled,
  'unitCostCentavos': draft.unitCostCentavos,
  'lineTotalCentavos': draft.lineTotalCentavos,
  'replayed': replayed,
}, request: draft);

/// In-process fake of both notice streams; no Firebase, backend, or emulator.
class _FakeNoticeStreams implements TransferNoticeStreamSource {
  final StreamController<TransferNoticeStreamEnvelope> movementsCtrl =
      StreamController<TransferNoticeStreamEnvelope>.broadcast();
  final StreamController<TransferNoticeStreamEnvelope> markersCtrl =
      StreamController<TransferNoticeStreamEnvelope>.broadcast();

  @override
  Stream<TransferNoticeStreamEnvelope> movements({required String branchId}) =>
      movementsCtrl.stream;

  @override
  Stream<TransferNoticeStreamEnvelope> markers() => markersCtrl.stream;
}

void main() {
  testWidgets('shows a safe loading state while bootstrap is pending', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSessionGateway> completer =
        Completer<EmulatorSessionGateway>();

    await tester.pumpWidget(_app(completer.future));

    expect(
      find.text('Conectando con el emulador local de autenticación'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  group('production environment copy', () {
    testWidgets('loading names the server, not the emulator', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Completer<EmulatorSessionGateway>().future,
          environment: BackendEnvironment.production,
        ),
      );

      expect(find.text('Conectando con el servidor'), findsOneWidget);
      expect(find.textContaining('emulador'), findsNothing);
    });

    testWidgets('login and its failure never mention the emulator', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Future.value(_FakeGateway(loginError: StateError('network'))),
          environment: BackendEnvironment.production,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Inicio de sesión'), findsOneWidget);
      expect(
        find.text('Los datos del catálogo no están conectados.'),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-email')),
        'seller@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-password')),
        'secret',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
      await tester.pumpAndSettle();

      expect(find.text('No se pudo iniciar sesión.'), findsOneWidget);
      expect(find.textContaining('emulador'), findsNothing);
    });

    testWidgets('the signed-in app bar shows the session without the email', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Future.value(_FakeGateway(loginResult: _seller)),
          environment: BackendEnvironment.production,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-email')),
        'seller@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-password')),
        'secret',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('session-status')),
        findsOneWidget,
      );
      expect(find.textContaining('Emulador local'), findsNothing);
      expect(find.textContaining('Vendedor'), findsOneWidget);
      expect(find.text('seller@example.com'), findsNothing);
    });
  });

  testWidgets('shows login after an unauthenticated restore', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(Future.value(_FakeGateway())));
    await tester.pumpAndSettle();

    expect(find.text('Inicio de sesión en el emulador local'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(
      find.text('Los datos del catálogo no están conectados.'),
      findsOneWidget,
    );
  });

  testWidgets('logs in and loads catalog for the validated session', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(loginResult: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      ' seller.north@demo-lda-inventory.invalid ',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pumpAndSettle();

    expect(gateway.submittedEmail, 'seller.north@demo-lda-inventory.invalid');
    expect(gateway.submittedPassword, 'Demo-Only-Seller-2026!');
    expect(
      find.text('Emulador local · Vendedor · Sucursal North'),
      findsOneWidget,
    );
    expect(find.text('Aún no hay productos'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
  });

  testWidgets('shows a safe error and no authenticated content on failure', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      loginError: StateError('secret network details'),
    );
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'user@example.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'password',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pumpAndSettle();

    expect(
      find.text('No se pudo iniciar sesión en el emulador local.'),
      findsOneWidget,
    );
    expect(find.textContaining('secret network details'), findsNothing);
    expect(find.byKey(const ValueKey<String>('session-status')), findsNothing);
  });

  testWidgets('logs out to the login form', (WidgetTester tester) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
    await tester.pumpAndSettle();

    expect(gateway.logoutCalls, 1);
    expect(find.text('Inicio de sesión en el emulador local'), findsOneWidget);
  });

  testWidgets('seller session never receives or initializes product creation', (
    WidgetTester tester,
  ) async {
    var gatewayLoads = 0;
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(
      MaterialApp(
        home: EmulatorLoginShell(
          sessionGateway: Future<EmulatorSessionGateway>.value(gateway),
          catalogLoader: _emptyCatalog,
          productCreationGatewayLoader: (EmulatorSession session) async {
            gatewayLoads += 1;
            return _FakeProductGateway();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Crear producto'), findsNothing);
    expect(gatewayLoads, 0);
  });

  testWidgets(
    'unknown draft survives close and logout for exact same-admin replay',
    (WidgetTester tester) async {
      final _FakeGateway auth = _FakeGateway(
        restored: _administrator,
        loginResult: _administrator,
      );
      final List<ProductCreationDraft> attempts = <ProductCreationDraft>[];
      var gatewayLoads = 0;
      Future<ProductCreationGateway> loadProductGateway(
        EmulatorSession session,
      ) async {
        gatewayLoads += 1;
        final int load = gatewayLoads;
        return _FakeProductGateway((ProductCreationDraft draft) async {
          attempts.add(draft);
          if (load == 1) throw const ProductCreationUncertainException();
          return const ProductCreationResult(
            productId: 'PRD-COFFEE-001',
            internalCode: 'PRD-COFFEE-001',
            replayed: true,
          );
        });
      }

      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          productCreationGatewayLoader: loadProductGateway,
        ),
      );
      await tester.pumpAndSettle();
      await _enterProduct(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('resultado es incierto'), findsOneWidget);

      final Finder close = find.widgetWithText(FilledButton, 'Cerrar');
      await tester.ensureVisible(close);
      await tester.tap(close);
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
      await tester.pumpAndSettle();
      await _signIn(tester);

      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('create-product-name')),
            )
            .controller
            ?.text,
        'Coffee',
      );
      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(gatewayLoads, 2);
      expect(attempts, hasLength(2));
      expect(attempts[1], attempts[0]);
      expect(attempts[1].idempotencyKey, attempts[0].idempotencyKey);
      expect(find.text('Producto creado correctamente'), findsOneWidget);
    },
  );

  testWidgets(
    'failed precondition keeps exact request locked for same-admin reentry',
    (WidgetTester tester) async {
      final _FakeGateway auth = _FakeGateway(
        restored: _administrator,
        loginResult: _administrator,
      );
      final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
      var gatewayLoads = 0;
      Future<ProductCreationGateway> loadProductGateway(
        EmulatorSession session,
      ) async {
        gatewayLoads += 1;
        final int load = gatewayLoads;
        return EmulatorProductCreationGateway(
          expectedSession: session,
          sessionChecker: () async => session,
          invoke: (Map<String, Object?> request) async {
            requests.add(request);
            if (load == 1) {
              throw const ProductCreationCallableException(
                code: 'failed-precondition',
              );
            }
            return <String, Object?>{
              'productId': 'PRD-COFFEE-001',
              'internalCode': 'PRD-COFFEE-001',
              'replayed': true,
            };
          },
        );
      }

      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          productCreationGatewayLoader: loadProductGateway,
        ),
      );
      await tester.pumpAndSettle();
      await _enterProduct(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('resultado es incierto'), findsOneWidget);
      expect(find.textContaining('failed-precondition'), findsNothing);
      final Map<String, Object?> originalRequest = requests.single;

      final Finder close = find.widgetWithText(FilledButton, 'Cerrar');
      await tester.ensureVisible(close);
      await tester.tap(close);
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
      await tester.pumpAndSettle();
      await _signIn(tester);

      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('create-product-name')),
            )
            .controller
            ?.text,
        'Coffee',
      );
      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(gatewayLoads, 2);
      expect(requests, hasLength(2));
      expect(requests[1], originalRequest);
      expect(requests[1]['idempotencyKey'], originalRequest['idempotencyKey']);
      expect(find.text('Producto creado correctamente'), findsOneWidget);
    },
  );

  testWidgets(
    'seller and another administrator cannot inspect or resolve stored draft',
    (WidgetTester tester) async {
      final _FakeGateway auth = _FakeGateway(restored: _administrator);
      var gatewayLoads = 0;
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          productCreationGatewayLoader: (EmulatorSession session) async {
            gatewayLoads += 1;
            return _FakeProductGateway(
              (_) => throw const ProductCreationUncertainException(),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await _enterProduct(tester);
      await tester.pumpAndSettle();

      auth.sessions.add(_seller);
      await tester.pumpAndSettle();
      expect(find.text('Crear producto'), findsNothing);
      expect(find.text('Coffee'), findsNothing);

      auth.sessions.add(_otherAdministrator);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Crear producto'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('create-product-name')),
            )
            .controller
            ?.text,
        isEmpty,
      );
      final Finder close = find.widgetWithText(FilledButton, 'Cerrar');
      await tester.ensureVisible(close);
      await tester.tap(close);
      await tester.pump();

      auth.sessions.add(_administrator);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('create-product-name')),
            )
            .controller
            ?.text,
        'Coffee',
      );
      expect(gatewayLoads, 1);
    },
  );

  testWidgets(
    'logout during pending late failure retains exact request for fresh gateway',
    (WidgetTester tester) async {
      final Completer<ProductCreationResult> first =
          Completer<ProductCreationResult>();
      final _FakeGateway auth = _FakeGateway(
        restored: _administrator,
        loginResult: _administrator,
      );
      final List<ProductCreationDraft> attempts = <ProductCreationDraft>[];
      var gatewayLoads = 0;
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          productCreationGatewayLoader: (EmulatorSession session) async {
            gatewayLoads += 1;
            final int load = gatewayLoads;
            return _FakeProductGateway((ProductCreationDraft draft) {
              attempts.add(draft);
              if (load == 1) return first.future;
              return Future<ProductCreationResult>.value(
                const ProductCreationResult(
                  productId: 'PRD-COFFEE-001',
                  internalCode: 'PRD-COFFEE-001',
                  replayed: true,
                ),
              );
            });
          },
        ),
      );
      await tester.pumpAndSettle();
      await _enterProduct(tester);
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
      await tester.pumpAndSettle();

      first.completeError(StateError('late transport detail'));
      await tester.pump();
      await _signIn(tester);
      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(gatewayLoads, 2);
      expect(attempts, hasLength(2));
      expect(attempts[1], attempts[0]);
      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expect(find.textContaining('late transport detail'), findsNothing);
    },
  );

  for (final bool checkPending in <bool>[true, false]) {
    testWidgets(
      'same-identity session frames preserve two creations (pending checks: $checkPending)',
      (WidgetTester tester) async {
        final _FakeGateway auth = _FakeGateway(restored: _administrator);
        final List<ProductCreationDraft> attempts = <ProductCreationDraft>[];
        final List<Completer<ProductCreationResult>> results =
            <Completer<ProductCreationResult>>[];
        await tester.pumpWidget(
          _app(
            Future<EmulatorSessionGateway>.value(auth),
            productCreationGatewayLoader: (_) async =>
                _FakeProductGateway((ProductCreationDraft draft) {
                  attempts.add(draft);
                  final Completer<ProductCreationResult> result =
                      Completer<ProductCreationResult>();
                  results.add(result);
                  return result.future;
                }),
          ),
        );
        await tester.pumpAndSettle();

        for (int index = 0; index < 2; index += 1) {
          await _enterProduct(tester);
          await tester.pump();
          expect(attempts, hasLength(index + 1));
          // A new validated session object models a token lifecycle event. The
          // real shell supplies its already-frozen draft before gateway success.
          auth.sessions.add(
            EmulatorSession(
              userId: _administrator.userId,
              email: _administrator.email,
              role: _administrator.role,
            ),
          );
          await tester.pump();
          if (checkPending) {
            expect(find.textContaining('resultado es incierto'), findsNothing);
            expect(find.text('Reintentar misma solicitud'), findsNothing);
            expect(
              tester
                  .widget<FilledButton>(
                    find.ancestor(
                      of: find.byType(CircularProgressIndicator),
                      matching: find.byType(FilledButton),
                    ),
                  )
                  .onPressed,
              isNull,
            );
            expect(find.byType(CircularProgressIndicator), findsWidgets);
            expect(
              tester
                  .widget<TextFormField>(
                    find.byKey(const ValueKey<String>('create-product-name')),
                  )
                  .enabled,
              isFalse,
            );
          }
          final String code = 'PRD-SESSION-000$index';
          results[index].complete(
            ProductCreationResult(
              productId: code,
              internalCode: code,
              replayed: false,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Producto creado correctamente'), findsOneWidget);
          expect(find.textContaining('resultado es incierto'), findsNothing);
          expect(attempts, hasLength(index + 1));
        }
        expect(attempts[1].idempotencyKey, isNot(attempts[0].idempotencyKey));
        for (final ProductCreationDraft draft in attempts) {
          expect(
            draft.idempotencyKey,
            matches(
              RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              ),
            ),
          );
          expect(draft.name, 'Coffee');
          expect(draft.unit, 'piece');
          expect(draft.precision, 0);
        }
      },
    );
  }

  testWidgets(
    'resolved self-owned draft null echo preserves success and delayed pricing',
    (WidgetTester tester) async {
      final _FakeGateway auth = _FakeGateway(restored: _administrator);
      final Completer<ProductCreationResult> result =
          Completer<ProductCreationResult>();
      final Completer<CatalogSnapshot> refresh = Completer<CatalogSnapshot>();
      int loads = 0;
      int calls = 0;
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          catalogLoader: (_) {
            loads += 1;
            return loads == 1 ? _emptyCatalog(_administrator) : refresh.future;
          },
          productCreationGatewayLoader: (_) async => _FakeProductGateway((_) {
            calls += 1;
            return result.future;
          }),
          productPricingGatewayLoader: (_) async => _FakePricingGateway(
            (_) => throw StateError('pricing must not auto-submit'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _enterProduct(tester);
      await tester.pump();
      auth.sessions.add(
        EmulatorSession(
          userId: _administrator.userId,
          email: _administrator.email,
          role: _administrator.role,
        ),
      );
      await tester.pump();
      result.complete(
        const ProductCreationResult(
          productId: 'PRD-COFFEE-001',
          internalCode: 'PRD-COFFEE-001',
          replayed: false,
        ),
      );
      await tester.pump();
      expect(find.text('Producto creado correctamente'), findsOneWidget);
      // The shell has now resolved the store; a later same-identity frame
      // changes the observed draft to null during the catalog refresh await.
      auth.sessions.add(
        EmulatorSession(
          userId: _administrator.userId,
          email: _administrator.email,
          role: _administrator.role,
        ),
      );
      await tester.pump();
      expect(find.text('Producto creado correctamente'), findsOneWidget);
      refresh.complete(
        CatalogSnapshot(<CatalogItem>[
          CatalogItem(
            product: const CatalogProduct(
              internalCode: 'PRD-COFFEE-001',
              name: 'Coffee',
              quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
            ),
            holdings: const <CatalogHolding>[],
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        findsOneWidget,
      );
      expect(find.textContaining('resultado es incierto'), findsNothing);
      expect(calls, 1);
    },
  );

  testWidgets('expired success preserves late self-null echo and pricing', (
    WidgetTester tester,
  ) async {
    final _FakeGateway auth = _FakeGateway(restored: _administrator);
    final Completer<ProductCreationResult> result =
        Completer<ProductCreationResult>();
    final Completer<CatalogSnapshot> refresh = Completer<CatalogSnapshot>();
    int loads = 0;
    int calls = 0;
    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(auth),
        catalogLoader: (_) =>
            ++loads == 1 ? _emptyCatalog(_administrator) : refresh.future,
        productCreationGatewayLoader: (_) async => _FakeProductGateway((_) {
          calls += 1;
          return result.future;
        }),
        productPricingGatewayLoader: (_) async => _FakePricingGateway(
          (_) => throw StateError('pricing must not auto-submit'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _enterProduct(tester);
    await tester.pump();
    void sameIdentityFrame() => auth.sessions.add(
      EmulatorSession(
        userId: _administrator.userId,
        email: _administrator.email,
        role: _administrator.role,
      ),
    );
    sameIdentityFrame();
    await tester.pump();
    result.complete(
      const ProductCreationResult(
        productId: 'PRD-COFFEE-001',
        internalCode: 'PRD-COFFEE-001',
        replayed: false,
      ),
    );
    await tester.pump();
    expect(find.text('Producto creado correctamente'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    // The notice leaves through a short exit at its deadline.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Producto creado correctamente'), findsNothing);
    sameIdentityFrame();
    await tester.pump();
    expect(find.textContaining('resultado es incierto'), findsNothing);
    refresh.complete(
      CatalogSnapshot(<CatalogItem>[
        CatalogItem(
          product: const CatalogProduct(
            internalCode: 'PRD-COFFEE-001',
            name: 'Coffee',
            quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
          ),
          holdings: const <CatalogHolding>[],
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Producto creado correctamente'), findsNothing);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('pricing-listed-price')),
          )
          .controller!
          .text,
      isEmpty,
    );
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'self-owned pending echo still becomes genuine uncertainty and exact manual retry',
    (WidgetTester tester) async {
      final _FakeGateway auth = _FakeGateway(restored: _administrator);
      final Completer<ProductCreationResult> result =
          Completer<ProductCreationResult>();
      final List<ProductCreationDraft> attempts = <ProductCreationDraft>[];
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          productCreationGatewayLoader: (_) async =>
              _FakeProductGateway((ProductCreationDraft draft) {
                attempts.add(draft);
                return attempts.length == 1
                    ? result.future
                    : Future<ProductCreationResult>.value(
                        const ProductCreationResult(
                          productId: 'PRD-COFFEE-001',
                          internalCode: 'PRD-COFFEE-001',
                          replayed: true,
                        ),
                      );
              }),
        ),
      );
      await tester.pumpAndSettle();
      await _enterProduct(tester);
      await tester.pump();
      auth.sessions.add(
        EmulatorSession(
          userId: _administrator.userId,
          email: _administrator.email,
          role: _administrator.role,
        ),
      );
      await tester.pump();
      expect(find.textContaining('resultado es incierto'), findsNothing);
      result.completeError(const ProductCreationUncertainException());
      await tester.pumpAndSettle();
      expect(find.textContaining('resultado es incierto'), findsOneWidget);
      expect(attempts, hasLength(1));
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('create-product-name')),
            )
            .enabled,
        isFalse,
      );
      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(attempts, hasLength(2));
      expect(identical(attempts[0], attempts[1]), isTrue);
      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expect(find.textContaining('resultado es incierto'), findsNothing);
    },
  );

  for (final String authority in <String>[
    'logout',
    'null',
    'seller',
    'other UID',
  ]) {
    testWidgets('pending self-owned echo respects shell $authority authority', (
      WidgetTester tester,
    ) async {
      final _FakeGateway auth = _FakeGateway(restored: _administrator);
      final Completer<ProductCreationResult> result =
          Completer<ProductCreationResult>();
      int calls = 0;
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          productCreationGatewayLoader: (_) async => _FakeProductGateway((_) {
            calls += 1;
            return result.future;
          }),
        ),
      );
      await tester.pumpAndSettle();
      await _enterProduct(tester);
      await tester.pump();
      auth.sessions.add(
        EmulatorSession(
          userId: _administrator.userId,
          email: _administrator.email,
          role: _administrator.role,
        ),
      );
      await tester.pump();
      expect(find.textContaining('resultado es incierto'), findsNothing);
      if (authority == 'logout') {
        await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
      } else {
        auth.sessions.add(switch (authority) {
          'seller' => _seller,
          'other UID' => _otherAdministrator,
          _ => null,
        });
      }
      await tester.pumpAndSettle();
      result.complete(
        const ProductCreationResult(
          productId: 'PRD-STALE-001',
          internalCode: 'PRD-STALE-001',
          replayed: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Producto creado correctamente'), findsNothing);
      expect(find.textContaining('resultado es incierto'), findsNothing);
      expect(calls, 1);
    });
  }

  testWidgets('remote sign-out immediately clears authenticated content', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    gateway.sessions.add(null);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('session-status')), findsNothing);
    expect(find.text('Inicio de sesión en el emulador local'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
  });

  testWidgets('token claim changes replace role and branch presentation', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    gateway.sessions.add(
      const EmulatorSession(
        userId: 'demo-local-administrator',
        email: 'administrator@demo-lda-inventory.invalid',
        role: InventoryRole.administrator,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Emulador local · Administrador'), findsOneWidget);
    expect(find.textContaining('Sucursal North'), findsNothing);

    gateway.sessions.add(
      const EmulatorSession(
        userId: 'demo-local-seller-south',
        email: 'seller.south@demo-lda-inventory.invalid',
        role: InventoryRole.seller,
        branchId: 'branch-south',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Emulador local · Vendedor · Sucursal South'),
      findsOneWidget,
    );
  });

  testWidgets('remote disablement clears session and fails closed', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    gateway.sessions.addError(const UntrustedSessionException());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('session-status')), findsNothing);
    expect(find.text('Sesión rechazada'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
  });

  testWidgets('cancels the auth lifecycle subscription when disposed', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();
    expect(gateway.sessions.hasListener, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(gateway.sessions.hasListener, isFalse);
  });

  testWidgets('rejected restored session is not labeled as bootstrap failure', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      restoreError: const UntrustedSessionException(),
    );
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    expect(find.text('Sesión rechazada'), findsOneWidget);
    expect(
      find.text('Emulador local de autenticación no disponible'),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('session-status')), findsNothing);
  });

  testWidgets('connection retry reuses the initialized gateway', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      restoreError: const EmulatorSessionConnectionException(),
    );
    var loaderCalls = 0;
    Future<EmulatorSessionGateway> loader() async {
      loaderCalls += 1;
      return gateway;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: EmulatorLoginShell(
          sessionGateway: loader(),
          retryLoader: loader,
          catalogLoader: _emptyCatalog,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No se pudo verificar la sesión'), findsOneWidget);
    expect(loaderCalls, 1);

    gateway.restoreError = null;
    await tester.tap(find.widgetWithText(FilledButton, 'Reintentar'));
    await tester.pumpAndSettle();

    expect(loaderCalls, 1);
    expect(gateway.restoreCalls, 2);
    expect(find.text('Inicio de sesión en el emulador local'), findsOneWidget);
  });

  testWidgets('authenticated catalog auto-loads once for harmless notices', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      return CatalogSnapshot(<CatalogItem>[
        CatalogItem(
          product: const CatalogProduct(
            internalCode: 'PRD-LIVE-001',
            name: 'Live product',
            quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
          ),
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 1),
          ],
        ),
      ]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    expect(find.text('Live product'), findsOneWidget);
    expect(catalogCalls, 1);

    gateway.sessions.add(_seller);
    await tester.pumpAndSettle();
    expect(catalogCalls, 1);
  });

  testWidgets('user role and branch changes recreate and clear catalog', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    final List<EmulatorSession> requested = <EmulatorSession>[];
    final List<Completer<CatalogSnapshot>> requests =
        <Completer<CatalogSnapshot>>[];
    Future<CatalogSnapshot> load(EmulatorSession session) {
      requested.add(session);
      final Completer<CatalogSnapshot> completer = Completer<CatalogSnapshot>();
      requests.add(completer);
      return completer.future;
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pump();
    expect(requested, hasLength(1));

    const List<EmulatorSession> replacements = <EmulatorSession>[
      EmulatorSession(
        userId: 'seller-north',
        email: 'seller@demo.invalid',
        role: InventoryRole.seller,
        branchId: 'branch-south',
      ),
      EmulatorSession(
        userId: 'seller-north',
        email: 'seller@demo.invalid',
        role: InventoryRole.administrator,
      ),
      EmulatorSession(
        userId: 'another-admin',
        email: 'other@demo.invalid',
        role: InventoryRole.administrator,
      ),
    ];
    for (final EmulatorSession replacement in replacements) {
      gateway.sessions.add(replacement);
      await tester.pump();
      expect(find.bySemanticsLabel('Cargando catálogo'), findsOneWidget);
    }
    expect(requested, hasLength(4));
    expect(requested.last.userId, 'another-admin');
  });

  testWidgets('delayed logout rejects stale nonnull session events', (
    WidgetTester tester,
  ) async {
    final Completer<void> signOut = Completer<void>();
    final _FakeGateway gateway = _FakeGateway(
      restored: _seller,
      logoutCompleter: signOut,
    );
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      return CatalogSnapshot(<CatalogItem>[
        CatalogItem(
          product: const CatalogProduct(
            internalCode: 'PRD-LIVE-001',
            name: 'Live product',
            quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
          ),
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 1),
          ],
        ),
      ]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    expect(find.text('Live product'), findsOneWidget);
    expect(catalogCalls, 1);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
    await tester.pump();
    gateway.sessions.add(_seller);
    await tester.pump();

    expect(gateway.logoutCalls, 1);
    expect(find.text('Live product'), findsNothing);
    expect(find.text('Inicio de sesión en el emulador local'), findsOneWidget);
    expect(catalogCalls, 1);
    signOut.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'remote null invalidates delayed login and a new login can succeed',
    (WidgetTester tester) async {
      final Completer<EmulatorSession> staleLogin =
          Completer<EmulatorSession>();
      final _FakeGateway gateway = _FakeGateway(loginCompleter: staleLogin);
      var catalogCalls = 0;
      Future<CatalogSnapshot> load(EmulatorSession session) async {
        catalogCalls += 1;
        return CatalogSnapshot(const <CatalogItem>[]);
      }

      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(gateway),
          catalogLoader: load,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-email')),
        'seller.north@demo-lda-inventory.invalid',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-password')),
        'Demo-Only-Seller-2026!',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
      await tester.pump();

      gateway.sessions.add(null);
      await tester.pump();
      staleLogin.complete(_seller);
      await tester.pumpAndSettle();

      expect(
        find.text('Inicio de sesión en el emulador local'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('session-status')),
        findsNothing,
      );
      expect(catalogCalls, 0);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Iniciar sesión'),
            )
            .onPressed,
        isNotNull,
      );

      final Completer<EmulatorSession> newLogin = Completer<EmulatorSession>();
      gateway.loginCompleter = newLogin;
      await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
      await tester.pump();
      newLogin.complete(_seller);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('session-status')),
        findsOneWidget,
      );
      expect(catalogCalls, 1);
    },
  );

  test(
    'lifecycle validation keeps the original error identity and cleanup',
    () async {
      final auth = _FailingSdkAuth(validationFailure: true);
      addTearDown(auth.events.close);
      final original = _syntheticTypeError();
      final caught = Completer<Object>();
      final sessions = <EmulatorSession?>[];
      final subscription = FirebaseEmulatorSessionGateway(auth)
          .sessionChanges()
          .listen(
            sessions.add,
            onError: (Object error) => caught.complete(error),
          );
      addTearDown(subscription.cancel);
      auth.events.add(_InvalidSdkUser(tokenError: original));
      expect(await caught.future, same(original));
      await Future<void>.delayed(Duration.zero);
      expect(auth.cleanupCalls, 1);
      expect(sessions.whereType<EmulatorSession>(), isEmpty);
      expect(sessions, <EmulatorSession?>[null]);
    },
  );

  test('gateway keeps Firebase classification, identity, and cleanup counts', () async {
    // SDK sign-in failure: original identity, exactly one cleanup.
    final Object signInError = FirebaseAuthException(
      code: 'network-request-failed',
      message: 'synthetic-private-message',
    );
    var auth = _FailingSdkAuth(
      validationFailure: false,
      signInError: signInError,
    );
    addTearDown(auth.events.close);
    await expectLater(
      FirebaseEmulatorSessionGateway(
        auth,
      ).login(email: 'test-sdk@demo.invalid', password: 'test-only-password'),
      throwsA(same(signInError)),
    );
    expect(auth.cleanupCalls, 1);

    // Refresh rejection remaps to UntrustedSessionException with double cleanup.
    auth = _FailingSdkAuth(
      validationFailure: true,
      tokenError: FirebaseAuthException(
        code: 'user-disabled',
        message: 'synthetic-private-message',
      ),
    );
    addTearDown(auth.events.close);
    await expectLater(
      FirebaseEmulatorSessionGateway(
        auth,
      ).login(email: 'test-sdk@demo.invalid', password: 'test-only-password'),
      throwsA(same(const UntrustedSessionException())),
    );
    expect(auth.cleanupCalls, 2);

    // Refresh connection failure remaps to EmulatorSessionConnectionException.
    auth = _FailingSdkAuth(
      validationFailure: true,
      tokenError: FirebaseAuthException(
        code: 'network-request-failed',
        message: 'synthetic-private-message',
      ),
    );
    addTearDown(auth.events.close);
    await expectLater(
      FirebaseEmulatorSessionGateway(
        auth,
      ).login(email: 'test-sdk@demo.invalid', password: 'test-only-password'),
      throwsA(isA<EmulatorSessionConnectionException>()),
    );
    expect(auth.cleanupCalls, 2);
  });

  test('lifecycle source errors keep their original identity', () async {
    final auth = _FailingSdkAuth(validationFailure: true);
    addTearDown(auth.events.close);
    final original = _syntheticTypeError();
    final caught = Completer<Object>();
    final subscription = FirebaseEmulatorSessionGateway(auth)
        .sessionChanges()
        .listen((_) {}, onError: (Object error) => caught.complete(error));
    addTearDown(subscription.cancel);
    auth.events.addError(original);
    expect(await caught.future, same(original));
    expect(auth.cleanupCalls, 0);
  });

  testWidgets(
    'hostile lifecycle error shows sanitized failure cleared by session change',
    (tester) async {
      final auth = _FailingSdkAuth(validationFailure: true);
      addTearDown(auth.events.close);
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(
            FirebaseEmulatorSessionGateway(auth),
          ),
        ),
      );
      await tester.pumpAndSettle();
      auth.events.addError(_HostileSdkError());
      await tester.pumpAndSettle();
      expect(find.text('No se pudo verificar la sesión'), findsOneWidget);
      expect(find.textContaining('Temporary local diagnostic:'), findsNothing);
      auth.events.add(null);
      await tester.pumpAndSettle();
      expect(find.text('No se pudo verificar la sesión'), findsNothing);
      expect(
        find.text('Inicio de sesión en el emulador local'),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic-private'), findsNothing);
    },
  );

  for (final bool validationFailure in <bool>[false, true]) {
    testWidgets(
      'SDK ${validationFailure ? 'validation' : 'sign-in'} failure cleanup null shows safe feedback',
      (WidgetTester tester) async {
        final _FailingSdkAuth auth = _FailingSdkAuth(
          validationFailure: validationFailure,
        );
        addTearDown(auth.events.close);
        var catalogCalls = 0;
        await tester.pumpWidget(
          _app(
            Future<EmulatorSessionGateway>.value(
              FirebaseEmulatorSessionGateway(auth),
            ),
            catalogLoader: (EmulatorSession session) async {
              catalogCalls += 1;
              return CatalogSnapshot(const <CatalogItem>[]);
            },
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('login-email')),
          'test-sdk@demo.invalid',
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('login-password')),
          'test-only-password',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
        await tester.pumpAndSettle();
        expect(auth.cleanupCalls, validationFailure ? 2 : 1);
        expect(
          find.text('No se pudo iniciar sesión en el emulador local.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Temporary local diagnostic:'),
          findsNothing,
        );
        expect(find.textContaining('private'), findsNothing);
        expect(
          find.byKey(const ValueKey<String>('session-status')),
          findsNothing,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(catalogCalls, 0);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Iniciar sesión'),
              )
              .onPressed,
          isNotNull,
        );
      },
    );
  }

  testWidgets('cleanup null preserves safe login failure and successful retry', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSession> login = Completer<EmulatorSession>();
    final _FakeGateway gateway = _FakeGateway(
      loginCompleter: login,
      cleanupBeforeLoginFailure: true,
    );
    var catalogCalls = 0;
    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(gateway),
        catalogLoader: (EmulatorSession session) async {
          catalogCalls += 1;
          return CatalogSnapshot(const <CatalogItem>[]);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller@demo.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'test-only-password',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pump();
    login.completeError(StateError('private Firebase detail/token'));
    await tester.pumpAndSettle();
    expect(
      find.text('No se pudo iniciar sesión en el emulador local.'),
      findsOneWidget,
    );
    expect(find.textContaining('private Firebase'), findsNothing);
    expect(find.byKey(const ValueKey<String>('session-status')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(catalogCalls, 0);
    final Semantics announcement = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.text('No se pudo iniciar sesión en el emulador local.'),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(announcement.properties.liveRegion, isTrue);

    // An unclassified coincident/external null has the same fail-closed policy.
    gateway.sessions.add(null);
    await tester.pumpAndSettle();
    expect(
      find.text('No se pudo iniciar sesión en el emulador local.'),
      findsOneWidget,
    );
    gateway.loginCompleter = Completer<EmulatorSession>();
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pump();
    expect(
      find.text('No se pudo iniciar sesión en el emulador local.'),
      findsNothing,
    );
    gateway.loginCompleter!.complete(_seller);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('session-status')),
      findsOneWidget,
    );
    expect(catalogCalls, 1);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
    await tester.pumpAndSettle();
    expect(
      find.text('No se pudo iniciar sesión en el emulador local.'),
      findsNothing,
    );
  });

  for (final String boundary in <String>[
    'external null',
    'actor replacement',
    'role replacement',
    'logout',
    'disposal',
    'lifecycle rejection',
  ]) {
    testWidgets('login failure feedback fence respects $boundary', (
      WidgetTester tester,
    ) async {
      final Completer<EmulatorSession> login = Completer<EmulatorSession>();
      final _FakeGateway gateway = _FakeGateway(loginCompleter: login);
      await tester.pumpWidget(
        _app(Future<EmulatorSessionGateway>.value(gateway)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-email')),
        'old-actor@demo.invalid',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-password')),
        'old-private-password',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
      await tester.pump();
      gateway.sessions.add(null);
      await tester.pump();
      switch (boundary) {
        case 'actor replacement':
          gateway.sessions.add(_administrator);
        case 'role replacement':
          gateway.sessions.add(
            EmulatorSession(
              userId: _seller.userId,
              email: _seller.email,
              role: InventoryRole.administrator,
            ),
          );
        case 'logout':
          gateway.sessions.add(_seller);
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(OutlinedButton, 'Cerrar sesión'),
          );
        case 'disposal':
          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        case 'lifecycle rejection':
          gateway.sessions.addError(const UntrustedSessionException());
        case 'external null':
          break;
      }
      await tester.pumpAndSettle();
      login.completeError(StateError('old-private-password/token'));
      await tester.pumpAndSettle();
      expect(
        find.text('No se pudo iniciar sesión en el emulador local.'),
        boundary == 'external null' ? findsOneWidget : findsNothing,
      );
      expect(find.textContaining('old-private-password/token'), findsNothing);
      if (boundary == 'logout') {
        expect(
          find.text('Inicio de sesión en el emulador local'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey<String>('login-email')),
              )
              .controller!
              .text,
          isEmpty,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey<String>('login-password')),
              )
              .controller!
              .text,
          isEmpty,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stale login failure cannot cancel a newer attempt', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSession> staleLogin = Completer<EmulatorSession>();
    final _FakeGateway gateway = _FakeGateway(loginCompleter: staleLogin);
    var catalogCalls = 0;

    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(gateway),
        catalogLoader: (EmulatorSession session) async {
          catalogCalls += 1;
          return CatalogSnapshot(const <CatalogItem>[]);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pump();

    gateway.sessions.add(null);
    await tester.pump();
    final Completer<EmulatorSession> newLogin = Completer<EmulatorSession>();
    gateway.loginCompleter = newLogin;
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pump();

    staleLogin.completeError(StateError('stale login failure detail'));
    await tester.pump();
    expect(find.textContaining('stale login failure detail'), findsNothing);
    expect(
      find.text('No se pudo iniciar sesión en el emulador local.'),
      findsNothing,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    newLogin.complete(_seller);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('session-status')),
      findsOneWidget,
    );
    expect(catalogCalls, 1);
  });

  testWidgets('normal login notification does not duplicate catalog loading', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSession> login = Completer<EmulatorSession>();
    final _FakeGateway gateway = _FakeGateway(loginCompleter: login);
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      return CatalogSnapshot(const <CatalogItem>[]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pump();

    gateway.sessions.add(_seller);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('session-status')),
      findsOneWidget,
    );
    expect(catalogCalls, 1);

    login.complete(_seller);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('session-status')),
      findsOneWidget,
    );
    expect(catalogCalls, 1);
  });

  testWidgets('pending login is superseded by a newer lifecycle error', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSession> login = Completer<EmulatorSession>();
    final _FakeGateway gateway = _FakeGateway(loginCompleter: login);
    var catalogCalls = 0;

    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(gateway),
        catalogLoader: (EmulatorSession session) async {
          catalogCalls += 1;
          return CatalogSnapshot(const <CatalogItem>[]);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pump();

    gateway.sessions.addError(const UntrustedSessionException());
    await tester.pumpAndSettle();
    expect(find.text('Sesión rechazada'), findsOneWidget);

    login.complete(_seller);
    await tester.pumpAndSettle();
    expect(find.text('Sesión rechazada'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('session-status')), findsNothing);
    expect(catalogCalls, 0);
  });

  testWidgets('stale pending login cannot override a newer logout', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSession> login = Completer<EmulatorSession>();
    final _FakeGateway gateway = _FakeGateway(loginCompleter: login);
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      return CatalogSnapshot(const <CatalogItem>[]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pump();

    gateway.sessions.add(_seller);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('session-status')),
      findsOneWidget,
    );
    expect(catalogCalls, 1);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
    await tester.pumpAndSettle();
    login.complete(_seller);
    await tester.pumpAndSettle();

    expect(find.text('Inicio de sesión en el emulador local'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('session-status')), findsNothing);
    expect(catalogCalls, 1);
  });

  testWidgets('failed logout stays signed out until explicit login succeeds', (
    WidgetTester tester,
  ) async {
    final Completer<void> signOut = Completer<void>();
    final _FakeGateway gateway = _FakeGateway(
      restored: _seller,
      loginResult: _seller,
      logoutCompleter: signOut,
    );
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      if (session.role == InventoryRole.administrator) {
        return CatalogSnapshot(const <CatalogItem>[]);
      }
      return CatalogSnapshot(<CatalogItem>[
        CatalogItem(
          product: const CatalogProduct(
            internalCode: 'PRD-LIVE-001',
            name: 'Live product',
            quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
          ),
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 1),
          ],
        ),
      ]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
    await tester.pump();

    signOut.completeError(StateError('sanitized logout failure'));
    gateway.sessions.add(_seller);
    await tester.pumpAndSettle();

    expect(find.text('Inicio de sesión en el emulador local'), findsOneWidget);
    expect(find.text('Live product'), findsNothing);
    expect(find.textContaining('sanitized logout failure'), findsNothing);
    expect(catalogCalls, 1);

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Iniciar sesión'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Iniciar sesión'));
    await tester.pumpAndSettle();

    expect(find.text('Live product'), findsOneWidget);
    expect(catalogCalls, 2);

    gateway.sessions.add(
      const EmulatorSession(
        userId: 'demo-local-administrator',
        email: 'administrator@demo-lda-inventory.invalid',
        role: InventoryRole.administrator,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Emulador local · Administrador'), findsOneWidget);
    expect(catalogCalls, 3);
  });

  testWidgets('late old pricing success cannot clear a newer same-UUID retry', (
    WidgetTester tester,
  ) async {
    final Completer<ProductPricingResult> first =
        Completer<ProductPricingResult>();
    final _FakeGateway auth = _FakeGateway(
      restored: _administrator,
      loginResult: _administrator,
    );
    final List<ProductPricingDraft> attempts = <ProductPricingDraft>[];
    var gatewayLoads = 0;
    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(auth),
        catalogLoader: _coffeeCatalog,
        productPricingGatewayLoader: (EmulatorSession session) async {
          gatewayLoads += 1;
          final int load = gatewayLoads;
          return _FakePricingGateway((ProductPricingDraft draft) {
            attempts.add(draft);
            if (load == 1) return first.future;
            return Future<ProductPricingResult>.value(
              ProductPricingResult.fromCallable(<String, Object?>{
                'auditId': draft.idempotencyKey,
                'productId': draft.productId,
                'pricing': <String, Object?>{
                  'listedPriceCentavos': draft.listedPriceCentavos,
                  'currency': 'MXN',
                  'priceMode': draft.priceMode,
                  'ivaTreatment': draft.ivaTreatment,
                  'ivaRateBasisPoints': draft.ivaRateBasisPoints,
                },
                'replayed': true,
              }, request: draft),
            );
          });
        },
      ),
    );
    await tester.pumpAndSettle();
    await _submitExistingPricing(tester);
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
    await tester.pumpAndSettle();
    await _signIn(tester);

    final Finder retry = find.widgetWithText(
      FilledButton,
      'Reintentar misma solicitud',
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(attempts, hasLength(2));
    expect(attempts[1], attempts[0]);

    final ProductPricingDraft oldDraft = attempts.first;
    first.complete(
      ProductPricingResult.fromCallable(<String, Object?>{
        'auditId': oldDraft.idempotencyKey,
        'productId': oldDraft.productId,
        'pricing': <String, Object?>{
          'listedPriceCentavos': oldDraft.listedPriceCentavos,
          'currency': 'MXN',
          'priceMode': oldDraft.priceMode,
          'ivaTreatment': oldDraft.ivaTreatment,
          'ivaRateBasisPoints': oldDraft.ivaRateBasisPoints,
        },
        'replayed': false,
      }, request: oldDraft),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('resultado es incierto'), findsNothing);
    expect(
      find.textContaining('Auditoría ${oldDraft.idempotencyKey}'),
      findsOneWidget,
    );
    expect(gatewayLoads, 2);
  });

  testWidgets('gateway initialization failure freezes request before retry', (
    WidgetTester tester,
  ) async {
    var loads = 0;
    ProductPricingDraft? retried;
    final _FakeGateway auth = _FakeGateway(restored: _administrator);
    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(auth),
        catalogLoader: _coffeeCatalog,
        productPricingGatewayLoader: (EmulatorSession session) async {
          loads += 1;
          if (loads == 1) throw StateError('functions unavailable');
          return _FakePricingGateway((ProductPricingDraft draft) async {
            retried = draft;
            return ProductPricingResult.fromCallable(<String, Object?>{
              'auditId': draft.idempotencyKey,
              'productId': draft.productId,
              'pricing': <String, Object?>{
                'listedPriceCentavos': draft.listedPriceCentavos,
                'currency': 'MXN',
                'priceMode': draft.priceMode,
                'ivaTreatment': draft.ivaTreatment,
                'ivaRateBasisPoints': draft.ivaRateBasisPoints,
              },
              'replayed': true,
            }, request: draft);
          });
        },
      ),
    );
    await tester.pumpAndSettle();
    await _submitExistingPricing(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('resultado es incierto'), findsOneWidget);

    final String frozenPrice = tester
        .widget<TextFormField>(
          find.byKey(const ValueKey<String>('pricing-listed-price')),
        )
        .controller!
        .text;
    final Finder retry = find.widgetWithText(
      FilledButton,
      'Reintentar misma solicitud',
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(retried?.listedPriceMxn, frozenPrice);
    expect(find.textContaining('Precio guardado. Auditoría'), findsOneWidget);
  });

  testWidgets('seller never receives or initializes product pricing', (
    WidgetTester tester,
  ) async {
    var pricingGatewayLoads = 0;
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(gateway),
        catalogLoader: (EmulatorSession session) async =>
            CatalogSnapshot(<CatalogItem>[
              CatalogItem(
                product: _pricedCoffee,
                holdings: const <CatalogHolding>[
                  CatalogHolding(branchId: 'branch-north', quantityScaled: 0),
                ],
              ),
            ]),
        productPricingGatewayLoader: (EmulatorSession session) async {
          pricingGatewayLoads += 1;
          return _FakePricingGateway((_) => throw StateError('not allowed'));
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Configure price / IVA'), findsNothing);
    expect(find.text('Agotado'), findsOneWidget);
    expect(pricingGatewayLoads, 0);
  });

  testWidgets(
    'pricing uncertainty survives other product views and retries exact draft',
    (WidgetTester tester) async {
      const CatalogProduct tea = CatalogProduct(
        internalCode: 'PRD-TEA-002',
        name: 'Tea',
        quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
        pricing: CatalogPricing(
          listedPriceCentavos: 7500,
          currency: 'MXN',
          priceMode: 'iva-additional-on-invoice',
          ivaTreatment: 'exempt',
          ivaRateBasisPoints: null,
        ),
      );
      Future<CatalogSnapshot> catalog(EmulatorSession session) async =>
          CatalogSnapshot(<CatalogItem>[
            CatalogItem(
              product: _pricedCoffee,
              holdings: const <CatalogHolding>[],
            ),
            CatalogItem(product: tea, holdings: const <CatalogHolding>[]),
          ]);
      final _FakeGateway auth = _FakeGateway(restored: _administrator);
      final List<ProductPricingDraft> attempts = <ProductPricingDraft>[];
      var gatewayLoads = 0;
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          catalogLoader: catalog,
          productPricingGatewayLoader: (EmulatorSession session) async {
            gatewayLoads += 1;
            final int load = gatewayLoads;
            return _FakePricingGateway((ProductPricingDraft draft) async {
              attempts.add(draft);
              if (load == 1) throw const ProductPricingUncertainException();
              return ProductPricingResult.fromCallable(<String, Object?>{
                'auditId': draft.idempotencyKey,
                'productId': draft.productId,
                'pricing': <String, Object?>{
                  'listedPriceCentavos': draft.listedPriceCentavos,
                  'currency': 'MXN',
                  'priceMode': draft.priceMode,
                  'ivaTreatment': draft.ivaTreatment,
                  'ivaRateBasisPoints': draft.ivaRateBasisPoints,
                },
                'replayed': true,
              }, request: draft);
            });
          },
        ),
      );
      await tester.pumpAndSettle();

      await _submitExistingPricing(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('resultado es incierto'), findsOneWidget);
      final ProductPricingDraft original = attempts.single;

      Finder close = find.widgetWithText(OutlinedButton, 'Cerrar');
      await tester.ensureVisible(close);
      await tester.tap(close);
      await tester.pumpAndSettle();
      await _openProductSheet(tester, 'PRD-TEA-002');
      final Finder configureTea = find.byKey(
        const ValueKey<String>('configure-price-PRD-TEA-002'),
      );
      await tester.ensureVisible(configureTea);
      await tester.tap(configureTea);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('pricing-listed-price')),
            )
            .controller
            ?.text,
        '75.00',
      );
      expect(find.text('Tasa de IVA: No requerida'), findsOneWidget);

      close = find.widgetWithText(OutlinedButton, 'Cerrar');
      await tester.ensureVisible(close);
      await tester.tap(close);
      await tester.pumpAndSettle();
      await _openProductSheet(tester, 'PRD-COFFEE-001');
      final Finder configureCoffee = find.byKey(
        const ValueKey<String>('configure-price-PRD-COFFEE-001'),
      );
      await tester.ensureVisible(configureCoffee);
      await tester.tap(configureCoffee);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('pricing-listed-price')),
            )
            .controller
            ?.text,
        original.listedPriceMxn,
      );
      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(gatewayLoads, 2);
      expect(attempts, hasLength(2));
      expect(attempts[1], same(original));
      expect(attempts[1].idempotencyKey, original.idempotencyKey);
      expect(attempts[1].productId, 'PRD-COFFEE-001');
      expect(
        find.textContaining('Auditoría ${original.idempotencyKey}'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'pricing uncertainty survives logout only for same uid with fresh gateway',
    (WidgetTester tester) async {
      final _FakeGateway auth = _FakeGateway(
        restored: _administrator,
        loginResult: _administrator,
      );
      final List<ProductPricingDraft> attempts = <ProductPricingDraft>[];
      var gatewayLoads = 0;
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          catalogLoader: _coffeeCatalog,
          productPricingGatewayLoader: (EmulatorSession session) async {
            gatewayLoads += 1;
            final int load = gatewayLoads;
            return _FakePricingGateway((ProductPricingDraft draft) async {
              attempts.add(draft);
              if (load == 1) throw const ProductPricingUncertainException();
              return ProductPricingResult.fromCallable(<String, Object?>{
                'auditId': draft.idempotencyKey,
                'productId': draft.productId,
                'pricing': <String, Object?>{
                  'listedPriceCentavos': 12900,
                  'currency': 'MXN',
                  'priceMode': 'iva-included',
                  'ivaTreatment': 'taxable',
                  'ivaRateBasisPoints': 1600,
                },
                'replayed': true,
              }, request: draft);
            });
          },
        ),
      );
      await tester.pumpAndSettle();
      await _submitExistingPricing(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('resultado es incierto'), findsOneWidget);

      final Finder close = find.widgetWithText(OutlinedButton, 'Cerrar');
      await tester.ensureVisible(close);
      await tester.tap(close);
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
      await tester.pumpAndSettle();
      await _signIn(tester);

      expect(find.textContaining('resultado es incierto'), findsOneWidget);
      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(gatewayLoads, 2);
      expect(attempts, hasLength(2));
      expect(attempts[1], same(attempts[0]));
      expect(
        find.textContaining('Auditoría ${attempts[0].idempotencyKey}'),
        findsOneWidget,
      );
    },
  );

  testWidgets('other actors cannot observe or resolve pricing uncertainty', (
    WidgetTester tester,
  ) async {
    final _FakeGateway auth = _FakeGateway(
      restored: _administrator,
      loginResult: _otherAdministrator,
    );
    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(auth),
        catalogLoader: _coffeeCatalog,
        productPricingGatewayLoader: (EmulatorSession session) async =>
            _FakePricingGateway(
              (_) => throw const ProductPricingUncertainException(),
            ),
      ),
    );
    await tester.pumpAndSettle();
    await _submitExistingPricing(tester);
    await tester.pumpAndSettle();
    final Finder close = find.widgetWithText(OutlinedButton, 'Cerrar');
    await tester.ensureVisible(close);
    await tester.tap(close);
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
    await tester.pumpAndSettle();
    await _signIn(tester);

    expect(find.textContaining('resultado es incierto'), findsNothing);
    expect(find.text('Reintentar misma solicitud'), findsNothing);
  });

  testWidgets(
    'unresolved intake survives logout and same-uid reentry with fresh gateway',
    (WidgetTester tester) async {
      final _FakeGateway auth = _FakeGateway(
        restored: _administrator,
        loginResult: _administrator,
      );
      final List<StockIntakeDraft> attempts = <StockIntakeDraft>[];
      var gatewayLoads = 0;
      Future<EmulatorStockIntakeGateway> loadIntakeGateway(
        EmulatorSession session,
      ) async {
        gatewayLoads += 1;
        final int load = gatewayLoads;
        return _FakeStockIntakeGateway((StockIntakeDraft draft) async {
          attempts.add(draft);
          if (load == 1) throw const StockIntakeUncertainException();
          return _intakeResult(draft, replayed: true);
        });
      }

      final GlobalKey<EmulatorLoginShellState> shellKey =
          GlobalKey<EmulatorLoginShellState>();
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          stockIntakeGatewayLoader: loadIntakeGateway,
          shellKey: shellKey,
        ),
      );
      await tester.pumpAndSettle();
      final EmulatorLoginShellState shell = shellKey.currentState!;
      final StockIntakeDraft draft = _intakeDraft();

      await expectLater(
        shell.submitStockIntake(draft),
        throwsA(isA<StockIntakeUncertainException>()),
      );
      expect(gatewayLoads, 1);
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _administrator,
          draft.productId,
          draft.branchId,
        ),
        same(draft),
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
      await tester.pumpAndSettle();
      await _signIn(tester);

      expect(
        shell.unresolvedStockIntakeDraftFor(
          _administrator,
          draft.productId,
          draft.branchId,
        ),
        same(draft),
      );

      final StockIntakeResult retried = await shell.submitStockIntake(draft);
      expect(gatewayLoads, 2);
      expect(attempts, hasLength(2));
      expect(attempts[1], same(draft));
      expect(attempts[1].idempotencyKey, draft.idempotencyKey);
      expect(retried.replayed, isTrue);
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _administrator,
          draft.productId,
          draft.branchId,
        ),
        isNull,
      );
    },
  );

  testWidgets('seller cannot initialize, submit, or observe stock intake', (
    WidgetTester tester,
  ) async {
    var gatewayLoads = 0;
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    final GlobalKey<EmulatorLoginShellState> shellKey =
        GlobalKey<EmulatorLoginShellState>();
    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(gateway),
        stockIntakeGatewayLoader: (EmulatorSession session) async {
          gatewayLoads += 1;
          throw StateError('sellers never initialize intake');
        },
        shellKey: shellKey,
      ),
    );
    await tester.pumpAndSettle();
    final EmulatorLoginShellState shell = shellKey.currentState!;
    final StockIntakeDraft draft = _intakeDraft();

    await expectLater(
      shell.submitStockIntake(draft),
      throwsA(isA<StockIntakeSessionException>()),
    );
    expect(gatewayLoads, 0);
    expect(
      shell.unresolvedStockIntakeDraftFor(
        _seller,
        draft.productId,
        draft.branchId,
      ),
      isNull,
    );
  });

  testWidgets(
    'another administrator cannot read the intake draft; original owner retains it',
    (WidgetTester tester) async {
      final _FakeGateway auth = _FakeGateway(
        restored: _administrator,
        loginResult: _otherAdministrator,
      );
      var gatewayLoads = 0;
      final GlobalKey<EmulatorLoginShellState> shellKey =
          GlobalKey<EmulatorLoginShellState>();
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          stockIntakeGatewayLoader: (EmulatorSession session) async {
            gatewayLoads += 1;
            return _FakeStockIntakeGateway(
              (_) => throw const StockIntakeUncertainException(),
            );
          },
          shellKey: shellKey,
        ),
      );
      await tester.pumpAndSettle();
      final EmulatorLoginShellState shell = shellKey.currentState!;
      final StockIntakeDraft draft = _intakeDraft();

      await expectLater(
        shell.submitStockIntake(draft),
        throwsA(isA<StockIntakeUncertainException>()),
      );
      expect(gatewayLoads, 1);
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _administrator,
          draft.productId,
          draft.branchId,
        ),
        same(draft),
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cerrar sesión'));
      await tester.pumpAndSettle();
      await _signIn(tester);

      expect(
        shell.unresolvedStockIntakeDraftFor(
          _otherAdministrator,
          draft.productId,
          draft.branchId,
        ),
        isNull,
      );

      auth.sessions.add(_administrator);
      await tester.pumpAndSettle();
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _administrator,
          draft.productId,
          draft.branchId,
        ),
        same(draft),
      );
      expect(gatewayLoads, 1);
    },
  );

  testWidgets('late old intake completion cannot resolve a newer attempt', (
    WidgetTester tester,
  ) async {
    final Completer<StockIntakeResult> first = Completer<StockIntakeResult>();
    final _FakeGateway auth = _FakeGateway(restored: _administrator);
    var gatewayLoads = 0;
    final GlobalKey<EmulatorLoginShellState> shellKey =
        GlobalKey<EmulatorLoginShellState>();
    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(auth),
        stockIntakeGatewayLoader: (EmulatorSession session) async {
          gatewayLoads += 1;
          final int load = gatewayLoads;
          return _FakeStockIntakeGateway((StockIntakeDraft draft) async {
            if (load == 1) return first.future;
            return _intakeResult(draft, replayed: true);
          });
        },
        shellKey: shellKey,
      ),
    );
    await tester.pumpAndSettle();
    final EmulatorLoginShellState shell = shellKey.currentState!;
    final StockIntakeDraft draft = _intakeDraft();

    final Future<StockIntakeResult> oldAttempt = shell.submitStockIntake(draft);
    await tester.pump();
    expect(gatewayLoads, 1);
    expect(
      shell.unresolvedStockIntakeDraftFor(
        _administrator,
        draft.productId,
        draft.branchId,
      ),
      same(draft),
    );

    final StockIntakeResult newResult = await shell.submitStockIntake(draft);
    expect(gatewayLoads, 2);
    expect(newResult.replayed, isTrue);
    expect(
      shell.unresolvedStockIntakeDraftFor(
        _administrator,
        draft.productId,
        draft.branchId,
      ),
      isNull,
    );

    first.complete(_intakeResult(draft, replayed: false));
    await expectLater(oldAttempt, throwsA(isA<StockIntakeStaleException>()));
    expect(
      shell.unresolvedStockIntakeDraftFor(
        _administrator,
        draft.productId,
        draft.branchId,
      ),
      isNull,
    );
  });

  testWidgets(
    'intake gateway initialization failure freezes the exact request for retry',
    (WidgetTester tester) async {
      var loads = 0;
      final List<StockIntakeDraft> attempts = <StockIntakeDraft>[];
      final _FakeGateway auth = _FakeGateway(restored: _administrator);
      final GlobalKey<EmulatorLoginShellState> shellKey =
          GlobalKey<EmulatorLoginShellState>();
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          stockIntakeGatewayLoader: (EmulatorSession session) async {
            loads += 1;
            if (loads == 1) throw StateError('functions unavailable');
            return _FakeStockIntakeGateway((StockIntakeDraft draft) async {
              attempts.add(draft);
              return _intakeResult(draft, replayed: true);
            });
          },
          shellKey: shellKey,
        ),
      );
      await tester.pumpAndSettle();
      final EmulatorLoginShellState shell = shellKey.currentState!;
      final StockIntakeDraft draft = _intakeDraft();

      await expectLater(
        shell.submitStockIntake(draft),
        throwsA(isA<StateError>()),
      );
      expect(loads, 1);
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _administrator,
          draft.productId,
          draft.branchId,
        ),
        same(draft),
      );

      await shell.submitStockIntake(draft);
      expect(loads, 2);
      expect(attempts, hasLength(1));
      expect(attempts.single, same(draft));
      expect(attempts.single.idempotencyKey, draft.idempotencyKey);
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _administrator,
          draft.productId,
          draft.branchId,
        ),
        isNull,
      );
    },
  );

  testWidgets(
    'a different intake draft cannot replace or resolve the frozen request',
    (WidgetTester tester) async {
      var gatewayLoads = 0;
      final _FakeGateway auth = _FakeGateway(restored: _administrator);
      final GlobalKey<EmulatorLoginShellState> shellKey =
          GlobalKey<EmulatorLoginShellState>();
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          stockIntakeGatewayLoader: (EmulatorSession session) async {
            gatewayLoads += 1;
            return _FakeStockIntakeGateway(
              (_) => throw const StockIntakeUncertainException(),
            );
          },
          shellKey: shellKey,
        ),
      );
      await tester.pumpAndSettle();
      final EmulatorLoginShellState shell = shellKey.currentState!;
      final StockIntakeDraft frozen = _intakeDraft();
      final StockIntakeDraft replacement = _intakeDraft(quantity: '7');

      await expectLater(
        shell.submitStockIntake(frozen),
        throwsA(isA<StockIntakeUncertainException>()),
      );
      await expectLater(
        shell.submitStockIntake(replacement),
        throwsA(isA<StockIntakeUnresolvedException>()),
      );
      expect(gatewayLoads, 1);
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _administrator,
          frozen.productId,
          frozen.branchId,
        ),
        same(frozen),
      );

      await expectLater(
        shell.submitStockIntake(frozen),
        throwsA(isA<StockIntakeUncertainException>()),
      );
      expect(gatewayLoads, 2);
    },
  );

  testWidgets(
    'intake UI submits through the shell and isolates unresolved drafts by actor',
    (WidgetTester tester) async {
      final _FakeGateway auth = _FakeGateway(restored: _administrator);
      final List<StockIntakeDraft> attempts = <StockIntakeDraft>[];
      var gatewayLoads = 0;
      Future<EmulatorStockIntakeGateway> loadIntakeGateway(
        EmulatorSession session,
      ) async {
        gatewayLoads += 1;
        final int load = gatewayLoads;
        return _FakeStockIntakeGateway((StockIntakeDraft draft) async {
          attempts.add(draft);
          if (load == 1) throw const StockIntakeUncertainException();
          return _intakeResult(draft, replayed: true);
        });
      }

      final GlobalKey<EmulatorLoginShellState> shellKey =
          GlobalKey<EmulatorLoginShellState>();
      await tester.pumpWidget(
        _app(
          Future<EmulatorSessionGateway>.value(auth),
          catalogLoader: _intakeCatalog,
          stockIntakeGatewayLoader: loadIntakeGateway,
          shellKey: shellKey,
        ),
      );
      await tester.pumpAndSettle();
      final EmulatorLoginShellState shell = shellKey.currentState!;

      // The administrator opens the visible intake form and submits, through
      // the product detail sheet (T5).
      await _openProductSheet(tester, 'PRD-COFFEE-001');
      await tester.tap(
        find.byKey(const ValueKey<String>('intake-PRD-COFFEE-001')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('intake-branch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('North Demo Branch').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('intake-quantity')),
        '3',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('intake-unit-cost')),
        '12.50',
      );
      final Finder record = find.widgetWithText(
        FilledButton,
        'Registrar entrada',
      );
      await tester.ensureVisible(record);
      await tester.tap(record);
      await tester.pumpAndSettle();

      expect(attempts, hasLength(1));
      final String frozenKey = attempts.single.idempotencyKey;
      expect(find.textContaining('resultado es incierto'), findsOneWidget);
      expect(find.text('Reintentar misma solicitud'), findsOneWidget);

      // A seller session receives no intake control and cannot read the draft.
      auth.sessions.add(_seller);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('intake-PRD-COFFEE-001')),
        findsNothing,
      );
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _seller,
          'PRD-COFFEE-001',
          'branch-north',
        ),
        isNull,
      );

      // Another administrator cannot read or resolve it either.
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _otherAdministrator,
          'PRD-COFFEE-001',
          'branch-north',
        ),
        isNull,
      );

      // The originating administrator returns and resolves the same request
      // through the visible form with a fresh gateway.
      auth.sessions.add(_administrator);
      await tester.pumpAndSettle();
      await _openProductSheet(tester, 'PRD-COFFEE-001');
      await tester.tap(
        find.byKey(const ValueKey<String>('intake-PRD-COFFEE-001')),
      );
      await tester.pumpAndSettle();
      expect(find.text('North Demo Branch'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('intake-quantity')),
            )
            .controller
            ?.text,
        '3',
      );
      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(gatewayLoads, 2);
      expect(attempts, hasLength(2));
      expect(attempts[1], same(attempts[0]));
      expect(attempts[1].idempotencyKey, frozenKey);
      expect(find.text('Entrada registrada. Folio $frozenKey'), findsOneWidget);
      expect(
        shell.unresolvedStockIntakeDraftFor(
          _administrator,
          'PRD-COFFEE-001',
          'branch-north',
        ),
        isNull,
      );
    },
  );

  testWidgets('bootstrap failure is fail-closed and retryable', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSessionGateway> first =
        Completer<EmulatorSessionGateway>();
    final _FakeGateway retryGateway = _FakeGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: EmulatorLoginShell(
          sessionGateway: first.future,
          retryLoader: () async => retryGateway,
          catalogLoader: _emptyCatalog,
        ),
      ),
    );
    first.completeError(StateError('host unavailable'));
    await tester.pumpAndSettle();

    expect(
      find.text('Emulador local de autenticación no disponible'),
      findsOneWidget,
    );
    expect(find.textContaining('host unavailable'), findsNothing);
    expect(find.text('No se cargaron los datos del catálogo.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Reintentar'));
    await tester.pumpAndSettle();
    expect(find.text('Inicio de sesión en el emulador local'), findsOneWidget);
  });

  group('seller transfer notices shell wiring', () {
    Widget shellApp(
      _FakeGateway gateway, {
      TransferNoticeBackendSessionLoader? noticeLoader,
    }) => MaterialApp(
      home: EmulatorLoginShell(
        sessionGateway: Future<EmulatorSessionGateway>.value(gateway),
        catalogLoader: _emptyCatalog,
        transferNoticeBackendLoader: noticeLoader,
      ),
    );

    testWidgets('exact seller gets the live notice entry with a closed inbox', (
      WidgetTester tester,
    ) async {
      final _FakeNoticeStreams streams = _FakeNoticeStreams();
      var backendLoads = 0;
      final _FakeGateway gateway = _FakeGateway(restored: _seller);
      await tester.pumpWidget(
        shellApp(
          gateway,
          noticeLoader: (EmulatorSession session) async {
            backendLoads += 1;
            expect(session.userId, _seller.userId);
            return TransferNoticeBackend(
              streams: streams,
              markRead: (_) async => null,
            );
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // Notices live in the overflow menu (T10/S10); its items are built at
      // open time.
      await tester.tap(find.byKey(const ValueKey<String>('shell-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey<String>('notices-open')),
        findsOneWidget,
      );
      // The badge exists without any confirmed event yet (unknown state),
      // and the backend binds exactly once for this session.
      await tester.pump();
      expect(backendLoads, 1);
    });

    testWidgets('administrator never gets the notice entry', (
      WidgetTester tester,
    ) async {
      final _FakeGateway gateway = _FakeGateway(restored: _administrator);
      await tester.pumpWidget(
        shellApp(
          gateway,
          noticeLoader: (EmulatorSession session) async =>
              TransferNoticeBackend(
                streams: _FakeNoticeStreams(),
                markRead: (_) async => null,
              ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('notices-open')), findsNothing);
    });

    testWidgets('seller without a notice loader gets no entry', (
      WidgetTester tester,
    ) async {
      final _FakeGateway gateway = _FakeGateway(restored: _seller);
      await tester.pumpWidget(shellApp(gateway));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('notices-open')), findsNothing);
    });
  });

  testWidgets('the login form meets tap target guidelines', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(Future.value(_FakeGateway())));
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
