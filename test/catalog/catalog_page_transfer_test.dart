import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const EmulatorSession _administrator = EmulatorSession(
  userId: 'admin-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);
const EmulatorSession _branchAdministrator = EmulatorSession(
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
const EmulatorSession _otherAdministrator = EmulatorSession(
  userId: 'admin-2',
  email: 'other@demo.invalid',
  role: InventoryRole.administrator,
);

const CatalogProduct _coffee = CatalogProduct(
  internalCode: 'PRD-COFFEE-001',
  name: 'Café',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
);
const CatalogProduct _ribbon = CatalogProduct(
  internalCode: 'DEMO-RIBBON-01',
  name: 'Cinta',
  quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
);

/// Cinta is held only in the north branch, so the visible list shows a
/// per-branch view while the form must still receive the whole global snapshot.
CatalogSnapshot _snapshot() => CatalogSnapshot(
  <CatalogItem>[
    CatalogItem(
      product: _coffee,
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
    CatalogItem(
      product: _ribbon,
      holdings: const <CatalogHolding>[
        CatalogHolding(
          branchId: 'branch-north',
          branchName: 'Norte',
          quantityScaled: 7,
        ),
      ],
    ),
  ],
  branchChoices: const <CatalogBranchChoice>[
    CatalogBranchChoice(branchId: 'branch-north', branchName: 'Norte'),
    CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sur'),
  ],
);

final CatalogSnapshot _emptySnapshot = CatalogSnapshot(const <CatalogItem>[]);

/// Seller snapshots are branch-scoped: one holding per product and no branch
/// choices, so a seller page can be pumped without tripping snapshot checks.
CatalogSnapshot _sellerSnapshot() => CatalogSnapshot(<CatalogItem>[
  CatalogItem(
    product: _coffee,
    holdings: const <CatalogHolding>[
      CatalogHolding(branchId: 'branch-north', quantityScaled: 5000),
    ],
  ),
]);

/// Strict fake: answers the exact six-field callable shape through the AF01
/// contract, so a drifted payload can never be reported as success.
TransferResult _resultFor(TransferDraft request, {bool replayed = false}) =>
    TransferResult.fromCallable(<String, Object?>{
      'transferId': request.idempotencyKey,
      'sourceBranchId': request.sourceBranchId,
      'destinationBranchId': request.destinationBranchId,
      'occurredAt': 1767225600000,
      'replayed': replayed,
      'lines': request.lines
          .map(
            (TransferLine line) => <String, Object?>{
              'productId': line.productId,
              'quantity': line.quantity,
              'quantityScaled': line.quantityScaled,
              'unit': line.quantitySpec.unit,
              'precision': line.quantitySpec.precision,
              'sourceQuantityScaled': 900000,
              'destinationQuantityScaled': line.quantityScaled,
            },
          )
          .toList(),
    }, request: request);

class _Loader {
  int calls = 0;
  CatalogSnapshot snapshot = _snapshot();
  bool hold = false;
  final List<Completer<CatalogSnapshot>> _held = <Completer<CatalogSnapshot>>[];

  Future<CatalogSnapshot> call(EmulatorSession session) async {
    calls += 1;
    if (!hold) return snapshot;
    final Completer<CatalogSnapshot> pending = Completer<CatalogSnapshot>();
    _held.add(pending);
    return pending.future;
  }

  /// Releases the oldest held read so the test controls the refresh window.
  void release() => _held.removeAt(0).complete(snapshot);
}

class _Backend {
  final List<TransferDraft> drafts = <TransferDraft>[];
  final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];
  final List<Completer<Object?>> _replies = <Completer<Object?>>[];
  TransferDraft? unresolved;
  int lookups = 0;

  int get invocations => drafts.length;

  TransferSubmit get submit => (TransferDraft draft) async {
    drafts.add(draft);
    payloads.add(draft.toRequest());
    final Completer<Object?> reply = Completer<Object?>();
    _replies.add(reply);
    final Object? outcome = await reply.future;
    if (outcome is TransferResult) return outcome;
    throw outcome!;
  };

  TransferDraftLookup get lookup => () {
    lookups += 1;
    return unresolved;
  };

  void succeed({bool replayed = false}) =>
      _replies.last.complete(_resultFor(drafts.last, replayed: replayed));

  void fail(Object error) => _replies.last.completeError(error);
}

String _mintId() => 'key-page-1';

/// Existing administrator action that must keep its place next to transfers.
final AdministratorMovements _movements = AdministratorMovements(
  load: (String? branchId) async => <MovementEntry>[],
  readProfile: (String uid) async => const SellerUnnamed(),
  setSellerName: (String uid, String name) async =>
      SellerProfileResult(uid: uid, replayed: false),
);

Widget _page(
  EmulatorSession session,
  _Loader loader, {
  _Backend? backend,
  TransferIdFactory? idFactory,
  bool withMovements = false,
}) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: session,
    catalogLoader: loader.call,
    onLogout: () async {},
    submitTransfer: backend?.submit,
    unresolvedTransferDraft: backend?.lookup,
    createTransferId: idFactory,
    administratorMovements: withMovements ? _movements : null,
  ),
);

// ---------------------------------------------------------------------------
// Measured narrow layout
// ---------------------------------------------------------------------------

/// One framework overflow report captured during a measured pump: the widget
/// that caused it and the numeric magnitude in test-font pixels. The Ahem
/// test font is not a device font, so only baseline-vs-candidate comparisons
/// of these pixels claim authority, never absolute device layout.
class _OverflowReport {
  const _OverflowReport(this.cause, this.pixels);

  final String cause;
  final double pixels;

  @override
  String toString() => '$cause +${pixels.toStringAsFixed(1)}px';

  @override
  bool operator ==(Object other) =>
      other is _OverflowReport &&
      other.cause == cause &&
      other.pixels == pixels;

  @override
  int get hashCode => Object.hash(cause, pixels);
}

final RegExp _overflowPx = RegExp(
  r'overflowed by ([0-9]+(?:\.[0-9]+)?) pixels',
);
final RegExp _causingWidget = RegExp(
  r'The relevant error-causing widget was:\s*\n\s*(.+)',
);

String _causeOf(String text) =>
    _causingWidget.firstMatch(text)?.group(1)?.trim() ?? text.split('\n').first;

List<_OverflowReport> _overflowReports(List<FlutterErrorDetails> details) =>
    <_OverflowReport>[
      for (final FlutterErrorDetails detail in details)
        if (detail.exception is FlutterError &&
            _overflowPx.hasMatch(detail.exception.toString()))
          _OverflowReport(
            _causeOf(detail.exception.toString()),
            double.parse(
              _overflowPx.firstMatch(detail.exception.toString())!.group(1)!,
            ),
          ),
    ];

/// Fail-closed classification guard for measured pumps: every captured
/// FlutterErrorDetails must classify as a known RenderFlex overflow with
/// numeric pixels. Any other capture — a setState or semantics error, an
/// unexpected exception — must fail with its original reason instead of
/// being silently hidden behind the numeric filter.
void _failIfUnclassifiedOverflow(List<FlutterErrorDetails> details) {
  for (final FlutterErrorDetails detail in details) {
    final Object exception = detail.exception;
    if (exception is! FlutterError ||
        !_overflowPx.hasMatch(exception.toString())) {
      fail(
        'A measured pump captured an error that is not a known RenderFlex '
        'overflow; refusing to hide it behind the numeric filter. '
        'Original reason: $exception\n'
        'Context: ${detail.context}\n'
        'Library: ${detail.library}',
      );
    }
  }
}

/// Pumps a fresh keyed page root and returns every overflow report it
/// produced with its numeric magnitude, instead of asserting a disclosed
/// exception. The caller disposes the previous root between measured pumps,
/// so identical diagnostics between layouts are re-measured, not throttled.
Future<List<_OverflowReport>> _pumpMeasured(
  WidgetTester tester, {
  required String rootKey,
  required EmulatorSession session,
  _Backend? backend,
  bool withMovements = false,
}) async {
  final List<FlutterErrorDetails> details = <FlutterErrorDetails>[];
  final void Function(FlutterErrorDetails)? previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails detail) => details.add(detail);
  try {
    await tester.pumpWidget(
      KeyedSubtree(
        key: ValueKey<String>(rootKey),
        child: _page(
          session,
          _Loader(),
          backend: backend,
          withMovements: withMovements,
        ),
      ),
    );
    await tester.pumpAndSettle();
  } finally {
    FlutterError.onError = previous;
  }
  _failIfUnclassifiedOverflow(details);
  return _overflowReports(details);
}

Widget _sellerPage(_Loader loader, _Backend backend) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _seller,
    catalogLoader: (_) async => _sellerSnapshot(),
    onLogout: () async {},
    submitTransfer: backend.submit,
    unresolvedTransferDraft: backend.lookup,
  ),
);

Future<_Loader> _pump(
  WidgetTester tester,
  EmulatorSession session,
  _Backend backend, {
  TransferIdFactory? idFactory,
  CatalogSnapshot? snapshot,
  bool withMovements = false,
}) async {
  final _Loader loader = _Loader();
  if (snapshot != null) loader.snapshot = snapshot;
  await tester.pumpWidget(
    _page(
      session,
      loader,
      backend: backend,
      idFactory: idFactory,
      withMovements: withMovements,
    ),
  );
  await tester.pumpAndSettle();
  return loader;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('transfer-open')));
  await tester.pumpAndSettle();
}

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Finder _productField() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is DropdownButtonFormField<String> &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('transfer-product'),
);

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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> _fillAndConfirm(WidgetTester tester) async {
  await _pick(tester, _key('transfer-source'), 'Norte');
  await _pick(tester, _key('transfer-destination'), 'Sur');
  await _pick(tester, _productField(), 'Café');
  await tester.enterText(find.byType(TextFormField).last, '2.50');
  await tester.pump();
  await _tap(tester, _key('transfer-submit'));
  await tester.pumpAndSettle();
  // Confirming starts a request that stays in flight until the fake answers,
  // so the in-flight spinner must never be settled.
  await _tap(tester, _key('transfer-confirm-ok'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late _Backend backend;

  setUp(() {
    backend = _Backend();
  });

  group('entry gating', () {
    testWidgets('only the exact administrator with live seams gets the entry', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _administrator, backend);
      expect(find.text('Traslados'), findsOneWidget);

      await tester.pumpWidget(_sellerPage(_Loader(), backend));
      await tester.pumpAndSettle();
      expect(find.text('Traslados'), findsNothing);

      await tester.pumpWidget(
        _page(_branchAdministrator, _Loader(), backend: backend),
      );
      await tester.pumpAndSettle();
      expect(find.text('Traslados'), findsNothing);
    });

    testWidgets('a null submit or lookup seam hides the entry', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_page(_administrator, _Loader()));
      await tester.pumpAndSettle();
      expect(find.text('Traslados'), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: AuthenticatedCatalogPage(
            session: _administrator,
            catalogLoader: _Loader().call,
            onLogout: () async {},
            submitTransfer: backend.submit,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_key('transfer-open'), findsNothing);
      expect(backend.invocations, 0);
    });

    testWidgets('the entry replaces the catalog and closes back to it', (
      WidgetTester tester,
    ) async {
      final _Loader loader = await _pump(tester, _administrator, backend);
      expect(find.text('Catálogo'), findsOneWidget);

      await _open(tester);
      expect(find.text('Traslado entre sucursales'), findsOneWidget);
      expect(find.text('Catálogo'), findsNothing);
      // Opening never reads or writes: the gateway seam is never called.
      expect(backend.invocations, 0);
      expect(backend.lookups, greaterThan(0));
      expect(loader.calls, 1);

      await _tap(tester, _key('transfer-close'));
      await tester.pumpAndSettle();
      expect(find.text('Traslado entre sucursales'), findsNothing);
      expect(find.text('Café'), findsOneWidget);
      expect(loader.calls, 1);
    });

    testWidgets('the form receives the whole global admin snapshot', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _administrator, backend, idFactory: _mintId);
      // The visible list shows the north-only holding for Cinta.
      expect(find.textContaining('Sur: Agotado'), findsOneWidget);

      await _open(tester);
      final AdministratorTransferForm form = tester
          .widget<AdministratorTransferForm>(
            find.byType(AdministratorTransferForm),
          );
      expect(form.ownerUserId, 'admin-1');
      expect(form.branches, hasLength(2));
      expect(form.products.map((CatalogProduct p) => p.internalCode), <String>[
        'PRD-COFFEE-001',
        'DEMO-RIBBON-01',
      ]);
      expect(form.createTransferId(), 'key-page-1');
    });

    testWidgets('an empty snapshot stays with the form Spanish notices', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _administrator, backend, snapshot: _emptySnapshot);
      await _open(tester);
      expect(
        find.textContaining('No hay productos disponibles'),
        findsOneWidget,
      );
      expect(find.textContaining('al menos dos sucursales'), findsOneWidget);
      expect(backend.invocations, 0);
    });
  });

  group('completion and session safety', () {
    testWidgets('a success refreshes the authorized catalog once', (
      WidgetTester tester,
    ) async {
      final _Loader loader = await _pump(tester, _administrator, backend);
      await _open(tester);
      await _fillAndConfirm(tester);
      expect(backend.invocations, 1);

      backend.succeed();
      await tester.pumpAndSettle();

      expect(find.text('Traslado registrado correctamente.'), findsOneWidget);
      expect(loader.calls, 2);

      // The refreshed snapshot is behind the open form until the admin returns
      // to the catalog, and closing never triggers another read.
      await _tap(tester, _key('transfer-close'));
      await tester.pumpAndSettle();
      expect(find.text('Catálogo'), findsOneWidget);
      expect(find.text('Café'), findsOneWidget);
      expect(find.text('Cinta'), findsOneWidget);
      expect(loader.calls, 2);
    });

    testWidgets('the entry handler stays null while editing and pending', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _administrator, backend);
      await _open(tester);
      expect(find.text('Traslado entre sucursales'), findsOneWidget);
      // Editing: the actual TextButton handler is null, not merely a label.
      expect(
        tester.widget<TextButton>(_key('transfer-open')).onPressed,
        isNull,
      );

      // Filling and confirming leaves the request in flight: the fake's reply
      // Completer is still open, so this is an actual pending window, not a
      // post-open disabled state.
      await _fillAndConfirm(tester);
      expect(backend.invocations, 1);
      expect(
        tester.widget<TextButton>(_key('transfer-open')).onPressed,
        isNull,
      );

      backend.succeed();
      await tester.pumpAndSettle();
      expect(find.text('Traslado registrado correctamente.'), findsOneWidget);
    });

    testWidgets('a refresh while the receipt shows keeps the flow readable', (
      WidgetTester tester,
    ) async {
      final _Loader loader = _Loader();
      await tester.pumpWidget(_page(_administrator, loader, backend: backend));
      await tester.pumpAndSettle();
      loader.hold = true;

      await _open(tester);
      await _fillAndConfirm(tester);
      backend.succeed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The page is re-running its own catalog load, so the snapshot is briefly
      // gone. The open flow keeps the snapshot it was opened with.
      expect(loader.calls, 2);
      expect(find.text('Traslado registrado correctamente.'), findsOneWidget);
      expect(find.textContaining('al menos dos sucursales'), findsNothing);
      expect(find.textContaining('No hay productos disponibles'), findsNothing);

      loader.release();
      await tester.pumpAndSettle();
      expect(find.text('Traslado registrado correctamente.'), findsOneWidget);
    });

    testWidgets('a replayed success keeps the Spanish receipt banner', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _administrator, backend);
      await _open(tester);
      await _fillAndConfirm(tester);
      backend.succeed(replayed: true);
      await tester.pumpAndSettle();

      expect(find.textContaining('ya estaba registrado'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
    });

    testWidgets('an unknown outcome is retained, never reported as failed', (
      WidgetTester tester,
    ) async {
      final _Loader loader = await _pump(tester, _administrator, backend);
      await _open(tester);
      await _fillAndConfirm(tester);
      backend.fail(StateError('transport died after sending'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('No se pudo confirmar'), findsOneWidget);
      expect(loader.calls, 1);

      backend.unresolved = backend.drafts.last;
      await _tap(tester, _key('transfer-close'));
      await tester.pumpAndSettle();
      await _open(tester);
      expect(find.text('Reintentar mismo envío'), findsOneWidget);
    });

    testWidgets('a replaced session closes the view without refreshing', (
      WidgetTester tester,
    ) async {
      final _Loader loader = await _pump(tester, _administrator, backend);
      await _open(tester);
      await _fillAndConfirm(tester);
      expect(loader.calls, 1);

      // The session is replaced while the request is in flight, then the old
      // answer arrives: it must not complete or refresh the new session.
      await tester.pumpWidget(
        _page(_otherAdministrator, loader, backend: backend),
      );
      await tester.pump();
      final int callsAfterReplacement = loader.calls;
      backend.succeed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Traslado registrado correctamente.'), findsNothing);
      expect(find.text('Traslado entre sucursales'), findsNothing);
      expect(loader.calls, callsAfterReplacement);
    });

    testWidgets('removing the seams closes the open transfer view', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _administrator, backend);
      await _open(tester);
      expect(find.text('Traslado entre sucursales'), findsOneWidget);

      await tester.pumpWidget(_page(_administrator, _Loader()));
      await tester.pumpAndSettle();
      expect(find.text('Traslado entre sucursales'), findsNothing);
      expect(find.text('Traslados'), findsNothing);
    });
  });

  group('responsive entry', () {
    testWidgets('a narrow viewport keeps the entry a labelled body action', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pump(tester, _administrator, backend);

      // The entry is a labelled body toolbar action at every width, so the
      // AppBar gains no width from transfers; refresh keeps its place and
      // logout stays reachable from the narrow shell's overflow menu.
      expect(tester.takeException(), isNull);
      expect(find.text('Traslados'), findsOneWidget);
      expect(find.byTooltip('Traslados'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: _key('transfer-open'),
        ),
        findsNothing,
      );
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      await tester.tap(_key('shell-more'));
      await tester.pumpAndSettle();
      expect(find.text('Cerrar sesión'), findsOneWidget);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      // The entry is inside the viewport and really opens the form.
      final Rect rect = tester.getRect(_key('transfer-open'));
      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(320.0));
      expect(rect.top, greaterThanOrEqualTo(0.0));
      await tester.tap(_key('transfer-open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Traslado entre sucursales'), findsOneWidget);
      expect(find.text('Sucursal de origen'), findsOneWidget);
      // Desktop/web keeps this narrow-window layout with the refresh button
      // in the bar (S2); the mobile app bar is covered in
      // mobile_app_bar_test.dart.
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the entry adds no overflow beyond the 320px baseline', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Baseline: the same administrator page — Movimientos, refresh, logout —
      // without the transfer seams, so the entry is absent.
      final List<_OverflowReport> baseline = await _pumpMeasured(
        tester,
        rootKey: 'transferless-baseline',
        session: _administrator,
        withMovements: true,
      );
      // Dispose the baseline root so the candidate builds fresh RenderObjects
      // and repeats its diagnostics instead of throttling identical reports.
      await tester.pumpWidget(const SizedBox.shrink());

      final List<_OverflowReport> withEntry = await _pumpMeasured(
        tester,
        rootKey: 'entry-candidate',
        session: _administrator,
        backend: backend,
        withMovements: true,
      );

      // The entry must add neither a report nor a single pixel.
      expect(withEntry, equals(baseline));
      // The shell collapses its text actions when narrow, so neither layout
      // may overflow at all.
      expect(baseline, isEmpty);

      // The entry is inside the viewport and really opens the form.
      final Rect rect = tester.getRect(_key('transfer-open'));
      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(320.0));
      await tester.tap(_key('transfer-open'));
      await tester.pumpAndSettle();
      expect(find.text('Traslado entre sucursales'), findsOneWidget);
    });

    testWidgets(
      'the measured capture guard fails closed on non-overflow errors',
      (WidgetTester tester) async {
        // Regression for the classification guard behind _pumpMeasured: a
        // non-overflow capture (here an explicit sentinel) must FAIL with its
        // own reason, never be silently hidden by the numeric filter.
        const String sentinelReason = 'setState() called during build sentinel';
        final FlutterErrorDetails sentinel = FlutterErrorDetails(
          exception: StateError(sentinelReason),
          library: 'measured-capture-guard',
        );
        expect(
          () => _failIfUnclassifiedOverflow(<FlutterErrorDetails>[sentinel]),
          throwsA(
            isA<TestFailure>().having(
              (TestFailure failure) => failure.message,
              'message',
              contains(sentinelReason),
            ),
          ),
        );
      },
    );

    testWidgets(
      'the entry adds no overflow beyond the baseline at 1.3 text scale',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final List<_OverflowReport> baseline = await _pumpMeasured(
          tester,
          rootKey: 'transferless-baseline-1p3',
          session: _administrator,
          withMovements: true,
        );
        await tester.pumpWidget(const SizedBox.shrink());

        final List<_OverflowReport> withEntry = await _pumpMeasured(
          tester,
          rootKey: 'entry-candidate-1p3',
          session: _administrator,
          backend: backend,
          withMovements: true,
        );

        expect(withEntry, equals(baseline));
        // The shell collapses its text actions when narrow, so neither layout
        // may overflow at all.
        expect(baseline, isEmpty);

        final Rect rect = tester.getRect(_key('transfer-open'));
        expect(rect.left, greaterThanOrEqualTo(0.0));
        expect(rect.right, lessThanOrEqualTo(320.0));
        await tester.tap(_key('transfer-open'));
        await tester.pumpAndSettle();
        expect(find.text('Traslado entre sucursales'), findsOneWidget);
      },
    );

    testWidgets('the entry adds no overflow at the 600px boundary', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final List<_OverflowReport> baseline = await _pumpMeasured(
        tester,
        rootKey: 'transferless-baseline-600',
        session: _administrator,
        withMovements: true,
      );
      await tester.pumpWidget(const SizedBox.shrink());

      final List<_OverflowReport> withEntry = await _pumpMeasured(
        tester,
        rootKey: 'entry-candidate-600',
        session: _administrator,
        backend: backend,
        withMovements: true,
      );

      expect(withEntry, equals(baseline));
      // The shell collapses its text actions when narrow, so neither layout
      // may overflow at all.
      expect(baseline, isEmpty);
      expect(find.text('Traslados'), findsOneWidget);
      final Rect rect = tester.getRect(_key('transfer-open'));
      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(600.0));
      await tester.tap(_key('transfer-open'));
      await tester.pumpAndSettle();
      expect(find.text('Traslado entre sucursales'), findsOneWidget);
    });

    testWidgets('a wide viewport labels the entry in the body toolbar', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pump(tester, _administrator, backend);
      expect(find.text('Traslados'), findsOneWidget);
      expect(find.byTooltip('Traslados'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: _key('transfer-open'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('entry from other admin views', () {
    testWidgets('opening the entry from Movimientos shows the transfer form', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _administrator, backend, withMovements: true);
      await tester.tap(find.text('Movimientos'));
      await tester.pumpAndSettle();
      expect(find.text('No hay movimientos'), findsOneWidget);

      // The visible entry must switch to the transfer form: a localized reset
      // of the other admin views, never a leave-me-hidden dead end.
      await _open(tester);
      expect(find.text('Traslado entre sucursales'), findsOneWidget);
      expect(find.text('No hay movimientos'), findsNothing);
      // Only the other view flags closed; the entry itself remains.
      expect(find.text('Movimientos'), findsOneWidget);
    });
  });
}
