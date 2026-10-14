import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/firebase/emulator_transfer_gateway.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const EmulatorSession _admin = EmulatorSession(
  userId: 'admin-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);
const EmulatorSession _otherAdmin = EmulatorSession(
  userId: 'admin-2',
  email: 'other@demo.invalid',
  role: InventoryRole.administrator,
);
const EmulatorSession _branchAdmin = EmulatorSession(
  userId: 'admin-1',
  email: 'branch@demo.invalid',
  role: InventoryRole.administrator,
  branchId: 'branch-north',
);
const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

const QuantitySpec _kg = QuantitySpec(unit: 'kg', precision: 2);
const String _productCode = 'PRD-COFFEE-001';

CatalogSnapshot _snapshot() => CatalogSnapshot(
  <CatalogItem>[
    CatalogItem(
      product: const CatalogProduct(
        internalCode: _productCode,
        name: 'Café',
        quantitySpec: _kg,
      ),
      holdings: const <CatalogHolding>[
        CatalogHolding(
          branchId: 'branch-north',
          branchName: 'Norte',
          quantityScaled: 5000,
        ),
        CatalogHolding(
          branchId: 'branch-south',
          branchName: 'Sur',
          quantityScaled: 1000,
        ),
      ],
    ),
  ],
  branchChoices: const <CatalogBranchChoice>[
    CatalogBranchChoice(branchId: 'branch-north', branchName: 'Norte'),
    CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sur'),
  ],
);

TransferDraft _draft({
  required String idempotencyKey,
  String quantity = '2.50',
}) => TransferDraft(
  idempotencyKey: idempotencyKey,
  sourceBranchId: 'branch-north',
  destinationBranchId: 'branch-south',
  lines: <TransferLine>[
    TransferLine(
      productId: _productCode,
      quantity: quantity,
      quantitySpec: _kg,
    ),
  ],
);

/// Rebuilds the frozen request from the wire payload so the answer is parsed by
/// the real AF01 contract, never by a hand-made success value.
TransferDraft _draftFromRequest(Map<String, Object?> request) {
  final Map<Object?, Object?> line =
      (request['lines']! as List<Object?>).first! as Map<Object?, Object?>;
  return TransferDraft(
    idempotencyKey: request['idempotencyKey']! as String,
    sourceBranchId: request['sourceBranchId']! as String,
    destinationBranchId: request['destinationBranchId']! as String,
    lines: <TransferLine>[
      TransferLine(
        productId: line['productId']! as String,
        quantity: line['quantity']! as String,
        quantitySpec: _kg,
      ),
    ],
  );
}

/// The exact six-field callable shape the server answers with, so the real
/// AF01 parser — not a hand-made success value — decides what counts.
Map<String, Object?> _responseFor(
  Map<String, Object?> request, {
  bool replayed = false,
}) {
  final TransferDraft draft = _draftFromRequest(request);
  return <String, Object?>{
    'transferId': draft.idempotencyKey,
    'sourceBranchId': draft.sourceBranchId,
    'destinationBranchId': draft.destinationBranchId,
    'occurredAt': 1767225600000,
    'replayed': replayed,
    'lines': <Object?>[
      <String, Object?>{
        'productId': draft.lines.single.productId,
        'quantity': draft.lines.single.quantity,
        'quantityScaled': draft.lines.single.quantityScaled,
        'unit': 'kg',
        'precision': 2,
        'sourceQuantityScaled': 900000,
        'destinationQuantityScaled': draft.lines.single.quantityScaled,
      },
    ],
  };
}

class _FunctionsException extends FirebaseFunctionsException {
  _FunctionsException({required super.code}) : super(message: 'server detail');
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Injected transport behind the real [EmulatorTransferGateway], so these tests
/// exercise the production gateway guards and code mapping without the SDK, a
/// backend, or an emulator.
class _Transport {
  final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];
  final List<Completer<Object?>> _replies = <Completer<Object?>>[];
  Object? throwOnInvoke;

  int get invocations => payloads.length;

  TransferCallable get callable => (Map<String, Object?> request) async {
    payloads.add(Map<String, Object?>.of(request));
    if (throwOnInvoke case final Object error) {
      throwOnInvoke = null;
      throw error;
    }
    final Completer<Object?> reply = Completer<Object?>();
    _replies.add(reply);
    return reply.future;
  };

  void succeedAt(int index, {bool replayed = false}) => _replies[index]
      .complete(_responseFor(payloads[index], replayed: replayed));

  void failAt(int index, Object error) => _replies[index].completeError(error);

  void succeed({bool replayed = false}) =>
      succeedAt(_replies.length - 1, replayed: replayed);

  void fail(Object error) => failAt(_replies.length - 1, error);
}

class _SessionGateway implements EmulatorSessionGateway {
  _SessionGateway(this.restored);

  final EmulatorSession? restored;
  final StreamController<EmulatorSession?> sessions =
      StreamController<EmulatorSession?>.broadcast();
  int logouts = 0;

  @override
  Future<EmulatorSession?> restoreSession() async => restored;

  @override
  Stream<EmulatorSession?> sessionChanges() => sessions.stream;

  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) async => _admin;

  @override
  Future<void> logout() async {
    logouts += 1;
  }
}

class _Harness {
  _Harness({this.session = _admin, this.withLoader = true});

  final EmulatorSession? session;
  final bool withLoader;
  final _Transport transport = _Transport();
  final List<EmulatorSession> loaderSessions = <EmulatorSession>[];
  final List<String> minted = <String>[];
  late final _SessionGateway gateway = _SessionGateway(session);

  /// What the gateway's own session checker reports. Kept independent from the
  /// shell so a missing shell guard is still detected as a real invoke.
  EmulatorSession? checkerSession = _admin;
  Completer<void>? loaderGate;
  int loaderCalls = 0;

  TransferGatewayLoader get loader => (EmulatorSession session) async {
    loaderCalls += 1;
    loaderSessions.add(session);
    if (loaderGate case final Completer<void> gate) await gate.future;
    return EmulatorTransferGateway(
      expectedSession: session,
      sessionChecker: () async => checkerSession,
      invoke: transferCallableFromInvoker(transport.callable),
    );
  };

  Widget widget() => MaterialApp(
    home: EmulatorLoginShell(
      sessionGateway: Future<EmulatorSessionGateway>.value(gateway),
      catalogLoader: (EmulatorSession session) async => _snapshot(),
      transferGatewayLoader: withLoader ? loader : null,
    ),
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(widget());
    await tester.pumpAndSettle();
  }

  EmulatorLoginShellState state(WidgetTester tester) =>
      tester.state<EmulatorLoginShellState>(find.byType(EmulatorLoginShell));

  /// Drains the microtask queue without settling an in-flight spinner.
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> changeSession(WidgetTester tester, EmulatorSession? next) async {
    gateway.sessions.add(next);
    await flush(tester);
  }

  Future<void> openForm(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('transfer-open')));
    await tester.pumpAndSettle();
  }

  Future<void> closeForm(WidgetTester tester) async {
    await tester.ensureVisible(_key('transfer-close'));
    await tester.pumpAndSettle();
    await tester.tap(_key('transfer-close'));
    await tester.pumpAndSettle();
  }

  Future<void> fillAndConfirm(WidgetTester tester) async {
    await fillAndOpenDialog(tester);
    // Confirming starts a request that stays in flight until the fake answers,
    // so the in-flight spinner must never be settled.
    await tester.ensureVisible(_key('transfer-confirm-ok'));
    await tester.pumpAndSettle();
    await tester.tap(_key('transfer-confirm-ok'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Fills one line and opens the confirmation dialog without answering it.
  Future<void> fillAndOpenDialog(WidgetTester tester) async {
    await _pick(tester, _key('transfer-source'), 'Norte');
    await _pick(tester, _key('transfer-destination'), 'Sur');
    await _pick(tester, _productField(), 'Café');
    await tester.enterText(find.byType(TextFormField).last, '2.50');
    await tester.pump();
    await _tap(tester, _key('transfer-submit'));
    expect(find.text('Confirmar traslado'), findsOneWidget);
  }
}

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Finder _productField() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is DropdownButtonFormField<String> &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('transfer-product'),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, Finder field, String label) async {
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  final Finder option = find.text(label).last;
  await tester.ensureVisible(option);
  await tester.tap(option);
  await tester.pumpAndSettle();
}

void main() {
  late _Harness harness;

  setUp(() {
    harness = _Harness();
  });

  group('entry gating', () {
    testWidgets('sellers, branch admins, and no loader never get transfers', (
      WidgetTester tester,
    ) async {
      for (final EmulatorSession session in <EmulatorSession>[
        _seller,
        _branchAdmin,
      ]) {
        final _Harness scoped = _Harness(session: session);
        await scoped.pump(tester);
        expect(_key('transfer-open'), findsNothing);
        expect(scoped.loaderCalls, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }

      final _Harness unloaded = _Harness(withLoader: false);
      await unloaded.pump(tester);
      expect(_key('transfer-open'), findsNothing);
      expect(unloaded.transport.invocations, 0);
    });

    testWidgets('the gateway is loaded lazily on submit only', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      await harness.openForm(tester);
      expect(harness.loaderCalls, 0);
      expect(harness.transport.invocations, 0);

      await harness.fillAndConfirm(tester);
      expect(harness.loaderCalls, 1);
      expect(harness.loaderSessions, <EmulatorSession>[_admin]);
      expect(harness.transport.invocations, 1);

      harness.transport.succeed();
      await tester.pumpAndSettle();
      expect(find.text('Traslado registrado correctamente.'), findsOneWidget);
    });
  });

  group('ownership and retention', () {
    testWidgets('a settled key mints a new key for the next transfer', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      await harness.openForm(tester);
      await harness.fillAndConfirm(tester);
      harness.transport.succeed();
      await tester.pumpAndSettle();

      await harness.fillAndConfirm(tester);
      harness.transport.succeed(replayed: true);
      await tester.pumpAndSettle();

      expect(harness.transport.invocations, 2);
      expect(
        harness.transport.payloads[0]['idempotencyKey'],
        isNot(harness.transport.payloads[1]['idempotencyKey']),
      );
      expect(find.textContaining('ya estaba registrado'), findsOneWidget);
    });

    testWidgets('an unknown outcome retries the exact same key and payload', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      await harness.openForm(tester);
      await harness.fillAndConfirm(tester);
      harness.transport.fail(StateError('transport died after sending'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('No se pudo confirmar'), findsOneWidget);
      await harness.closeForm(tester);
      await harness.openForm(tester);
      expect(find.text('Reintentar mismo envío'), findsOneWidget);

      // A retained flow retries its own frozen payload with no new dialog.
      await tester.ensureVisible(_key('transfer-submit'));
      await tester.pumpAndSettle();
      await tester.tap(_key('transfer-submit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(harness.transport.invocations, 2);
      expect(harness.transport.payloads.first, harness.transport.payloads.last);
      harness.transport.succeed();
      await tester.pumpAndSettle();
      expect(find.text('Traslado registrado correctamente.'), findsOneWidget);
    });

    testWidgets('one unresolved flow per owner blocks a different key', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      final EmulatorLoginShellState state = harness.state(tester);

      final Future<TransferResult> first = state.submitTransfer(
        _draft(idempotencyKey: 'key-a', quantity: '1.00'),
      );
      await harness.flush(tester);
      harness.transport.fail(StateError('transport died after sending'));
      await expectLater(first, throwsA(isA<TransferUncertainException>()));
      final int sent = harness.transport.invocations;

      // A different key while one flow is unresolved is refused before the
      // store is touched, so nothing can leave the device.
      await expectLater(
        state.submitTransfer(_draft(idempotencyKey: 'key-b', quantity: '1.00')),
        throwsA(isA<TransferUnresolvedException>()),
      );
      // The same key with a different payload is refused too.
      await expectLater(
        state.submitTransfer(_draft(idempotencyKey: 'key-a', quantity: '9.00')),
        throwsA(isA<TransferUnresolvedException>()),
      );
      expect(harness.transport.invocations, sent);

      // The retained flow can still be retried and then settles.
      final Future<TransferResult> retry = state.submitTransfer(
        _draft(idempotencyKey: 'key-a', quantity: '1.00'),
      );
      await harness.flush(tester);
      harness.transport.succeed();
      await expectLater(retry, completes);
      expect(state.unresolvedTransferDraftFor(_admin), isNull);
    });

    testWidgets('a role loss before the gateway call never reaches invoke', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      final EmulatorLoginShellState state = harness.state(tester);
      harness.loaderGate = Completer<void>();

      final Future<TransferResult> pending = state.submitTransfer(
        _draft(idempotencyKey: 'key-late'),
      );
      await harness.flush(tester);
      // The SDK session disappears while the lazy loader is still awaiting,
      // and the gateway's own checker would still report the administrator.
      await harness.changeSession(tester, null);
      harness.checkerSession = _admin;
      harness.loaderGate!.complete();

      await expectLater(pending, throwsA(isA<TransferUncertainException>()));
      expect(harness.transport.invocations, 0);

      // The frozen payload survives the same-admin re-entry under its own key.
      await harness.changeSession(tester, _admin);
      expect(
        state.unresolvedTransferDraftFor(_admin)?.idempotencyKey,
        'key-late',
      );
      await harness.openForm(tester);
      expect(find.text('Reintentar mismo envío'), findsOneWidget);
    });

    testWidgets('a session change after sending never reports success', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      final EmulatorLoginShellState state = harness.state(tester);
      final Future<TransferResult> pending = state.submitTransfer(
        _draft(idempotencyKey: 'key-flight'),
      );
      await harness.flush(tester);
      expect(harness.transport.invocations, 1);

      await harness.changeSession(tester, _otherAdmin);
      harness.transport.succeed();

      await expectLater(pending, throwsA(isA<TransferUncertainException>()));
      expect(find.text('Traslado registrado correctamente.'), findsNothing);

      // Another owner receives neither the payload nor retry authority.
      expect(state.unresolvedTransferDraftFor(_otherAdmin), isNull);
      await harness.changeSession(tester, _admin);
      expect(
        state.unresolvedTransferDraftFor(_admin)?.idempotencyKey,
        'key-flight',
      );
    });

    testWidgets('a superseded attempt cannot resolve the current revision', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      final EmulatorLoginShellState state = harness.state(tester);
      final TransferDraft draft = _draft(idempotencyKey: 'key-rev');

      final Future<TransferResult> first = state.submitTransfer(draft);
      await harness.flush(tester);
      final Future<TransferResult> second = state.submitTransfer(draft);
      await harness.flush(tester);
      expect(harness.transport.invocations, 2);

      // Both answers are valid, but only the current revision may settle.
      harness.transport.succeedAt(0);
      await expectLater(first, throwsA(isA<TransferStaleException>()));
      harness.transport.succeedAt(1);
      await expectLater(second, completes);
      expect(state.unresolvedTransferDraftFor(_admin), isNull);
    });

    testWidgets('a deterministic rejection settles only its own attempt', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      harness.transport.throwOnInvoke = _FunctionsException(
        code: 'invalid-argument',
      );
      await harness.openForm(tester);
      await harness.fillAndConfirm(tester);

      expect(
        find.text('El servidor rechazó los datos del traslado.'),
        findsOneWidget,
      );
      expect(find.text('Reintentar mismo envío'), findsNothing);

      // The key is settled, so a fresh flow is allowed immediately.
      await harness.fillAndConfirm(tester);
      expect(harness.transport.invocations, 2);
      expect(
        harness.transport.payloads[0]['idempotencyKey'],
        isNot(harness.transport.payloads[1]['idempotencyKey']),
      );
      harness.transport.succeed();
      await tester.pumpAndSettle();
    });

    testWidgets('logout during an in-flight transfer stays human', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      await harness.openForm(tester);
      await harness.fillAndConfirm(tester);
      expect(harness.transport.invocations, 1);

      // A pending request must never trap the administrator in the app.
      await tester.tap(find.text('Log out'));
      await tester.pump();
      expect(find.text('Local emulator sign in'), findsOneWidget);

      // The late answer belongs to the old session: no completion is reported.
      harness.transport.succeed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Traslado registrado correctamente.'), findsNothing);

      // The same uid coming back still owns the frozen key and payload.
      await tester.enterText(_key('login-email'), 'admin@demo.invalid');
      await tester.enterText(_key('login-password'), 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      final TransferDraft? retained = harness
          .state(tester)
          .unresolvedTransferDraftFor(_admin);
      expect(
        retained?.idempotencyKey,
        harness.transport.payloads.first['idempotencyKey'],
      );
      expect(retained?.toRequest(), harness.transport.payloads.first);
    });

    testWidgets('a replaced session cannot confirm the previous dialog', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      await harness.openForm(tester);
      await harness.fillAndOpenDialog(tester);

      await harness.changeSession(tester, _otherAdmin);
      // The stale confirmation still belongs to the administrator that opened
      // it. Answering it must not put a request on the wire for the new one.
      expect(_key('transfer-confirm-ok'), findsOneWidget);
      await tester.tap(_key('transfer-confirm-ok'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(harness.transport.invocations, 0);
      expect(harness.loaderCalls, 0);
      expect(find.text('Traslado registrado correctamente.'), findsNothing);
    });

    testWidgets('logout keeps the retained key for the same uid', (
      WidgetTester tester,
    ) async {
      await harness.pump(tester);
      final EmulatorLoginShellState state = harness.state(tester);
      final Future<TransferResult> pending = state.submitTransfer(
        _draft(idempotencyKey: 'key-out'),
      );
      await harness.flush(tester);
      harness.transport.fail(StateError('unknown'));
      await expectLater(pending, throwsA(isA<TransferUncertainException>()));

      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(harness.gateway.logouts, 1);
      expect(find.text('Local emulator sign in'), findsOneWidget);

      await tester.enterText(_key('login-email'), 'admin@demo.invalid');
      await tester.enterText(_key('login-password'), 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(
        state.unresolvedTransferDraftFor(_admin)?.idempotencyKey,
        'key-out',
      );
      await harness.openForm(tester);
      expect(find.text('Reintentar mismo envío'), findsOneWidget);
    });
  });
}
