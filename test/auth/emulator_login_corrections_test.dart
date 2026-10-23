import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/corrections/sale_corrections.dart';
import 'package:lda_inventory/firebase/emulator_correction_gateway.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../corrections/correction_fixtures.dart';
import '../sales/sale_fixtures.dart';
import '../sales/sale_ui_fixtures.dart';

class _SessionGateway implements EmulatorSessionGateway {
  _SessionGateway({this.restored});

  final EmulatorSession? restored;
  final StreamController<EmulatorSession?> sessions =
      StreamController<EmulatorSession?>.broadcast();

  @override
  Future<EmulatorSession?> restoreSession() async => restored;

  @override
  Stream<EmulatorSession?> sessionChanges() => sessions.stream;

  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<void> logout() async {}
}

const EmulatorSession _seller = EmulatorSession(
  userId: 'demo-local-seller-north',
  email: 'seller.north@demo-lda-inventory.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _otherSeller = EmulatorSession(
  userId: 'demo-local-seller-north-2',
  email: 'seller.north.2@demo-lda-inventory.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _administrator = EmulatorSession(
  userId: 'demo-local-administrator',
  email: 'administrator@demo-lda-inventory.invalid',
  role: InventoryRole.administrator,
);

Future<CatalogSnapshot> _catalog(EmulatorSession session) async =>
    session.role == InventoryRole.seller
    ? sellerSaleSnapshot(branchId: session.branchId!)
    : CatalogSnapshot(const <CatalogItem>[]);

/// Real correction gateway over fake callables, recording loads and calls.
class _CorrectionBackend {
  final List<EmulatorSession> loads = <EmulatorSession>[];
  final List<Object> loadFailures = <Object>[];
  final List<Map<String, Object?>> finds = <Map<String, Object?>>[];
  int lists = 0;
  Completer<Object?>? pendingFind;
  Completer<Object?>? pendingList;
  Completer<Object?>? pendingReturn;

  /// Answers the next returns in order, ahead of [pendingReturn]: a
  /// [Completer], an error to throw, or a response.
  final List<Object?> returnAnswers = <Object?>[];
  final List<Map<String, Object?>> returns = <Map<String, Object?>>[];
  final List<Map<String, Object?>> previews = <Map<String, Object?>>[];
  final List<Object> returnFailures = <Object>[];
  final List<Map<String, Object?>> replacements = <Map<String, Object?>>[];
  final List<Object?> replacementAnswers = <Object?>[];
  final List<Map<String, Object?>> exchanges = <Map<String, Object?>>[];
  final List<Object?> exchangeAnswers = <Object?>[];

  Future<EmulatorCorrectionGateway> load(EmulatorSession session) async {
    loads.add(session);
    if (loadFailures.isNotEmpty) throw loadFailures.removeAt(0);
    return EmulatorCorrectionGateway(
      expectedSession: session,
      sessionChecker: () async => session,
      findInvoke: (Map<String, Object?> request) async {
        finds.add(request);
        final Completer<Object?>? pending = pendingFind;
        if (pending != null) return pending.future;
        return findResponse();
      },
      listInvoke: (_) async {
        lists += 1;
        final Completer<Object?>? pending = pendingList;
        if (pending != null) return pending.future;
        return <String, Object?>{
          'sales': <Object?>[lookupSaleJson()],
        };
      },
      returnInvoke: (Map<String, Object?> request) async {
        returns.add(request);
        if (returnFailures.isNotEmpty) throw returnFailures.removeAt(0);
        if (returnAnswers.isNotEmpty) {
          final Object? answer = returnAnswers.removeAt(0);
          if (answer is Completer<Object?>) return answer.future;
          if (answer is Exception || answer is Error) throw answer!;
          return answer;
        }
        final Completer<Object?>? pending = pendingReturn;
        if (pending != null) return pending.future;
        return returnResponse();
      },
      replacementInvoke: (Map<String, Object?> request) async {
        replacements.add(request);
        return _answer(replacementAnswers, replacementResponse);
      },
      exchangeInvoke: (Map<String, Object?> request) async {
        exchanges.add(request);
        return _answer(exchangeAnswers, exchangeResponse);
      },
      previewReturnInvoke: (Map<String, Object?> request) async {
        previews.add(request);
        return returnPreviewJson();
      },
      previewExchangeInvoke: (Map<String, Object?> request) async {
        previews.add(request);
        return exchangePreviewJson();
      },
    );
  }

  /// The next queued answer (a [Completer], an error to throw, or a
  /// response), else the default response.
  Future<Object?> _answer(
    List<Object?> answers,
    Object? Function() fallback,
  ) async {
    if (answers.isEmpty) return fallback();
    final Object? answer = answers.removeAt(0);
    if (answer is Completer<Object?>) return answer.future;
    if (answer is Exception || answer is Error) throw answer!;
    return answer;
  }
}

Widget _app(
  _SessionGateway gateway, {
  CorrectionGatewayLoader? correctionLoader,
}) => MaterialApp(
  home: EmulatorLoginShell(
    sessionGateway: Future<EmulatorSessionGateway>.value(gateway),
    catalogLoader: _catalog,
    correctionGatewayLoader: correctionLoader,
  ),
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

const SaleCallableException _overReturn = SaleCallableException(
  code: 'out-of-range',
  message: 'return exceeds the remaining sold quantity',
  reason: 'over-return',
);

/// The default return under another idempotency key.
SaleReturnDraft _newKeyDraft() => SaleReturnDraft.create(
  sale: lookupSale(),
  branchId: saleBranchId,
  reason: CorrectionReason.other,
  lines: const <ReturnLineInput>[
    ReturnLineInput(
      lineIndex: 1,
      quantity: '1',
      condition: ReturnCondition.good,
    ),
  ],
  createKey: () => '22222222-3333-4444-8555-666666666666',
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('only an exact seller with a correction loader gets the entry', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend();
    for (final (
          EmulatorSession session,
          CorrectionGatewayLoader? loader,
          bool entry,
        )
        in <(EmulatorSession, CorrectionGatewayLoader?, bool)>[
          (_seller, backend.load, true),
          (_seller, null, false),
          (_administrator, backend.load, false),
        ]) {
      await tester.pumpWidget(
        _app(_SessionGateway(restored: session), correctionLoader: loader),
      );
      await tester.pumpAndSettle();
      expect(
        _key('corrections-open'),
        entry ? findsOneWidget : findsNothing,
        reason: '${session.role} $loader',
      );
      expect(find.text('Correcciones'), entry ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
    // Showing the entry never initializes the gateway.
    expect(backend.loads, isEmpty);
  });

  testWidgets('the entry opens the lookup, and one gateway serves it all', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend();
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    await _tap(tester, _key('corrections-open'));

    expect(backend.lists, 1);
    expect(_key('correction-sale-$saleKey'), findsOneWidget);
    await tester.enterText(_key('correction-folio'), 'NTE-3F2A-9C1B');
    await _tap(tester, _key('correction-search'));
    expect(backend.finds.single, <String, Object?>{'folio': 'NTE-3F2A-9C1B'});
    // The catalog names the product in the detail.
    expect(
      find.descendant(
        of: _key('correction-line-0'),
        matching: find.text('Ribbon'),
      ),
      findsOneWidget,
    );

    await _tap(tester, _key('correction-detail-back'));
    await _tap(tester, _key('panel-back'));
    expect(_key('correction-folio'), findsNothing);
    await _tap(tester, _key('corrections-open'));
    expect(backend.lists, 2);
    expect(backend.loads, <EmulatorSession>[_seller]);
  });

  testWidgets('a failed gateway initialization is dropped and retried', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend()
      ..loadFailures.add(StateError('functions unavailable'));
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    await _tap(tester, _key('corrections-open'));
    expect(_key('correction-recent-error'), findsOneWidget);

    await _tap(tester, _key('correction-recent-retry'));
    expect(backend.loads, hasLength(2));
    expect(backend.lists, 1);
    expect(_key('correction-sale-$saleKey'), findsOneWidget);
  });

  testWidgets('another seller gets their own gateway and a closed lookup', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend();
    final _SessionGateway sessions = _SessionGateway(restored: _seller);
    await tester.pumpWidget(_app(sessions, correctionLoader: backend.load));
    await tester.pumpAndSettle();
    await _tap(tester, _key('corrections-open'));
    expect(_key('correction-folio'), findsOneWidget);

    sessions.sessions.add(_otherSeller);
    await tester.pumpAndSettle();
    // A session change closes the corrections view.
    expect(_key('correction-folio'), findsNothing);
    await _tap(tester, _key('corrections-open'));
    expect(backend.loads, <EmulatorSession>[_seller, _otherSeller]);
  });

  SaleCorrections corrections(WidgetTester tester) => tester
      .widget<AuthenticatedCatalogPage>(find.byType(AuthenticatedCatalogPage))
      .saleCorrections!;

  testWidgets('a seller change during a pending read fails it closed', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend()
      ..pendingFind = Completer<Object?>()
      ..pendingList = Completer<Object?>();
    final _SessionGateway sessions = _SessionGateway(restored: _seller);
    await tester.pumpWidget(_app(sessions, correctionLoader: backend.load));
    await tester.pumpAndSettle();
    final SaleCorrections original = corrections(tester);
    expect(original.branchId, saleBranchId);

    Object? findError;
    Object? listError;
    bool findReturned = false;
    bool listReturned = false;
    unawaited(
      original
          .find(SaleLookupQuery.bySaleId(saleKey))
          .then(
            (_) => findReturned = true,
            onError: (Object e) => findError = e,
          ),
    );
    unawaited(
      original.listRecent().then(
        (_) => listReturned = true,
        onError: (Object e) => listError = e,
      ),
    );
    await tester.pump();
    expect(backend.finds, hasLength(1));
    expect(backend.lists, 1);

    sessions.sessions.add(_otherSeller);
    await tester.pumpAndSettle();
    // The gateway itself still answers for the first seller; only the
    // shell's check after the read can refuse the result.
    backend.pendingFind!.complete(findResponse());
    backend.pendingList!.complete(<String, Object?>{
      'sales': <Object?>[lookupSaleJson()],
    });
    await tester.pumpAndSettle();
    expect(findReturned, isFalse);
    expect(listReturned, isFalse);
    expect(findError, isA<SaleSessionException>());
    expect(listError, isA<SaleSessionException>());
  });

  testWidgets('the shell previews and submits returns with one stored draft', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend()
      ..returnFailures.add(StateError('offline'));
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    final SaleCorrections seller = corrections(tester);
    expect(seller.unresolvedDraft(), isNull);

    final SaleReturnPreview preview = await seller.previewReturn(
      returnPreviewRequest(),
    );
    expect(preview.totalCentavos, 1410);
    expect(backend.previews.single, returnPreviewRequest().toRequest());

    final SaleReturnDraft draft = returnDraft();
    await expectLater(
      seller.submitReturn(draft),
      throwsA(isA<SaleUncertainException>()),
    );
    expect(seller.unresolvedDraft(), same(draft));
    // A different correction waits until the stored one resolves.
    await expectLater(
      seller.submitReturn(returnDraft(note: 'Other note')),
      throwsA(isA<CorrectionUnresolvedException>()),
    );
    expect(backend.returns, hasLength(1));

    final SaleReturnReceipt receipt = await seller.submitReturn(draft);
    expect(receipt.returnId, returnKey);
    expect(backend.returns, <Object?>[draft.toRequest(), draft.toRequest()]);
    expect(seller.unresolvedDraft(), isNull);
  });

  testWidgets('a seller change during a return keeps it uncertain and stored', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend()
      ..pendingReturn = Completer<Object?>();
    final _SessionGateway sessions = _SessionGateway(restored: _seller);
    await tester.pumpWidget(_app(sessions, correctionLoader: backend.load));
    await tester.pumpAndSettle();
    final SaleCorrections seller = corrections(tester);
    final SaleReturnDraft draft = returnDraft();
    Object? error;
    unawaited(
      seller
          .submitReturn(draft)
          .then<void>((_) {}, onError: (Object e) => error = e),
    );
    await tester.pump();
    sessions.sessions.add(_otherSeller);
    await tester.pumpAndSettle();
    backend.pendingReturn!.complete(returnResponse());
    await tester.pumpAndSettle();
    expect(error, isA<SaleUncertainException>());
    // The other seller never sees the first seller's draft.
    expect(corrections(tester).unresolvedDraft(), isNull);
    sessions.sessions.add(_seller);
    await tester.pumpAndSettle();
    expect(corrections(tester).unresolvedDraft(), same(draft));
  });

  testWidgets('a return draft for another branch is refused before storing', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend();
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    final SaleCorrections seller = corrections(tester);
    final SaleReturnDraft foreign = SaleReturnDraft.create(
      sale: lookupSale(),
      branchId: 'branch-south',
      reason: CorrectionReason.other,
      lines: const <ReturnLineInput>[
        ReturnLineInput(
          lineIndex: 1,
          quantity: '1',
          condition: ReturnCondition.good,
        ),
      ],
      createKey: () => returnKey,
    );
    await expectLater(
      seller.submitReturn(foreign),
      throwsA(isA<SaleSessionException>()),
    );
    expect(seller.unresolvedDraft(), isNull);
    expect(backend.returns, isEmpty);
  });

  testWidgets('a committed return keeps its receipt until acknowledged', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend();
    final _SessionGateway sessions = _SessionGateway(restored: _seller);
    await tester.pumpWidget(_app(sessions, correctionLoader: backend.load));
    await tester.pumpAndSettle();
    final SaleCorrections seller = corrections(tester);
    final SaleReturnDraft draft = returnDraft();

    final SaleReturnReceipt receipt = await seller.submitReturn(draft);
    expect(seller.unresolvedDraft(), isNull);
    final CompletedCorrection? committed = seller.unacknowledged();
    expect(committed?.receipt, same(receipt));
    expect(committed?.draft, same(draft));
    // Until the seller has seen it, no other correction may begin.
    await expectLater(
      seller.submitReturn(_newKeyDraft()),
      throwsA(isA<CorrectionUnresolvedException>()),
    );
    expect(backend.returns, hasLength(1));

    // Another seller can neither see nor acknowledge it.
    sessions.sessions.add(_otherSeller);
    await tester.pumpAndSettle();
    expect(corrections(tester).unacknowledged(), isNull);
    seller.acknowledge(receipt);
    corrections(tester).acknowledge(receipt);
    sessions.sessions.add(_seller);
    await tester.pumpAndSettle();
    final SaleCorrections again = corrections(tester);
    expect(again.unacknowledged()?.receipt, same(receipt));

    // Only the exact receipt acknowledges it.
    again.acknowledge(
      SaleReturnReceipt.fromCallable(returnResponse(), draft: draft),
    );
    expect(again.unacknowledged()?.receipt, same(receipt));
    again.acknowledge(receipt);
    expect(again.unacknowledged(), isNull);

    final SaleReturnDraft next = _newKeyDraft();
    backend.returnAnswers.add(returnResponseFor(next));
    final SaleReturnReceipt nextReceipt = await again.submitReturn(next);
    expect(nextReceipt.returnId, next.idempotencyKey);
  });

  testWidgets('a rejection clears the stored return so a new key can begin', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend()
      ..returnAnswers.add(StateError('offline'))
      ..returnAnswers.add(_overReturn);
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    final SaleCorrections seller = corrections(tester);
    final SaleReturnDraft draft = returnDraft();

    await expectLater(
      seller.submitReturn(draft),
      throwsA(isA<SaleUncertainException>()),
    );
    expect(seller.unresolvedDraft(), same(draft));
    await expectLater(
      seller.submitReturn(draft),
      throwsA(
        isA<SaleRejectedException>().having(
          (SaleRejectedException e) => e.isOverReturn,
          'isOverReturn',
          isTrue,
        ),
      ),
    );
    expect(seller.unresolvedDraft(), isNull);
    expect(seller.unacknowledged(), isNull);

    final SaleReturnDraft next = _newKeyDraft();
    backend.returnAnswers.add(returnResponseFor(next));
    final SaleReturnReceipt receipt = await seller.submitReturn(next);
    expect(receipt.returnId, next.idempotencyKey);
    expect(backend.returns, <Object?>[
      draft.toRequest(),
      draft.toRequest(),
      next.toRequest(),
    ]);
  });

  testWidgets('a seller change during a rejection keeps it uncertain', (
    WidgetTester tester,
  ) async {
    final Completer<Object?> pending = Completer<Object?>();
    final _CorrectionBackend backend = _CorrectionBackend()
      ..returnAnswers.add(pending);
    final _SessionGateway sessions = _SessionGateway(restored: _seller);
    await tester.pumpWidget(_app(sessions, correctionLoader: backend.load));
    await tester.pumpAndSettle();
    final SaleReturnDraft draft = returnDraft();
    Object? error;
    unawaited(
      corrections(tester)
          .submitReturn(draft)
          .then<void>((_) {}, onError: (Object e) => error = e),
    );
    await tester.pump();
    sessions.sessions.add(_otherSeller);
    await tester.pumpAndSettle();
    pending.completeError(_overReturn);
    await tester.pumpAndSettle();
    expect(error, isA<SaleUncertainException>());
    sessions.sessions.add(_seller);
    await tester.pumpAndSettle();
    expect(corrections(tester).unresolvedDraft(), same(draft));
  });

  testWidgets('a superseded attempt is stale and keeps the stored return', (
    WidgetTester tester,
  ) async {
    final Completer<Object?> first = Completer<Object?>();
    final Completer<Object?> second = Completer<Object?>();
    final Completer<Object?> third = Completer<Object?>();
    final _CorrectionBackend backend = _CorrectionBackend()
      ..returnAnswers.addAll(<Object?>[first, second, third]);
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    final SaleCorrections seller = corrections(tester);
    final SaleReturnDraft draft = returnDraft();
    final List<Object?> outcomes = <Object?>[];
    void track(Future<SaleReturnReceipt> submit) =>
        unawaited(submit.then<void>(outcomes.add, onError: outcomes.add));

    track(seller.submitReturn(draft));
    await tester.pump();
    track(seller.submitReturn(draft));
    await tester.pump();
    expect(backend.returns, hasLength(2));

    // The first attempt was superseded: neither its success nor a
    // rejection may settle the stored return.
    first.complete(returnResponse());
    await tester.pumpAndSettle();
    expect(outcomes.single, isA<SaleStaleException>());
    expect(seller.unresolvedDraft(), same(draft));
    expect(seller.unacknowledged(), isNull);

    track(seller.submitReturn(draft));
    await tester.pump();
    second.completeError(_overReturn);
    await tester.pumpAndSettle();
    expect(outcomes.last, isA<SaleStaleException>());
    expect(seller.unresolvedDraft(), same(draft));

    third.complete(returnResponse());
    await tester.pumpAndSettle();
    expect(outcomes.last, isA<SaleReturnReceipt>());
    expect(seller.unresolvedDraft(), isNull);
    expect(seller.unacknowledged()?.receipt, same(outcomes.last));
  });

  testWidgets('replacements and exchanges keep receipts until acknowledged', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend()
      ..replacementAnswers.add(StateError('offline'));
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    final SaleCorrections seller = corrections(tester);

    final SaleReplacementDraft replacement = replacementDraft();
    await expectLater(
      seller.submitReplacement(replacement),
      throwsA(isA<SaleUncertainException>()),
    );
    expect(seller.unresolvedDraft(), same(replacement));
    // Another kind of correction waits for the stored one.
    await expectLater(
      seller.submitExchange(exchangeDraft()),
      throwsA(isA<CorrectionUnresolvedException>()),
    );
    expect(backend.exchanges, isEmpty);

    final SaleReplacementReceipt replaced = await seller.submitReplacement(
      replacement,
    );
    expect(backend.replacements, <Object?>[
      replacement.toRequest(),
      replacement.toRequest(),
    ]);
    expect(seller.unresolvedDraft(), isNull);
    final CompletedCorrection? committed = seller.unacknowledged();
    expect(committed, isA<CompletedReplacement>());
    expect(committed?.receipt, same(replaced));
    await expectLater(
      seller.submitExchange(exchangeDraft()),
      throwsA(isA<CorrectionUnresolvedException>()),
    );
    seller.acknowledge(replaced);
    expect(seller.unacknowledged(), isNull);

    final SaleExchangePreview preview = await seller.previewExchange(
      exchangePreviewRequest(),
    );
    expect(preview.customerPaysCentavos, 2070);
    expect(backend.previews.last, exchangePreviewRequest().toRequest());

    final SaleExchangeDraft exchange = exchangeDraft();
    final SaleExchangeReceipt exchanged = await seller.submitExchange(exchange);
    expect(backend.exchanges.single, exchange.toRequest());
    expect(
      seller.unacknowledged(),
      isA<CompletedExchange>().having(
        (CompletedExchange value) => value.receipt,
        'receipt',
        same(exchanged),
      ),
    );
    seller.acknowledge(exchanged);
    expect(seller.unacknowledged(), isNull);
  });

  testWidgets('a rejected exchange or replacement drops the stored draft', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend()
      ..exchangeAnswers.add(
        const SaleCallableException(
          code: 'invalid-argument',
          message: 'difference payment must equal the amount the customer owes',
          reason: 'payment-mismatch',
        ),
      )
      ..replacementAnswers.add(
        const SaleCallableException(
          code: 'failed-precondition',
          message: 'insufficient stock',
          reason: 'insufficient-stock',
        ),
      );
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    final SaleCorrections seller = corrections(tester);

    await expectLater(
      seller.submitExchange(exchangeDraft()),
      throwsA(
        isA<SaleRejectedException>().having(
          (SaleRejectedException e) => e.isPaymentMismatch,
          'isPaymentMismatch',
          isTrue,
        ),
      ),
    );
    expect(seller.unresolvedDraft(), isNull);
    await expectLater(
      seller.submitReplacement(replacementDraft()),
      throwsA(
        isA<SaleRejectedException>().having(
          (SaleRejectedException e) => e.isOutOfStock,
          'isOutOfStock',
          isTrue,
        ),
      ),
    );
    expect(seller.unresolvedDraft(), isNull);
    expect(seller.unacknowledged(), isNull);
  });

  testWidgets('a seller change during an exchange keeps it uncertain', (
    WidgetTester tester,
  ) async {
    final Completer<Object?> pending = Completer<Object?>();
    final _CorrectionBackend backend = _CorrectionBackend()
      ..exchangeAnswers.add(pending);
    final _SessionGateway sessions = _SessionGateway(restored: _seller);
    await tester.pumpWidget(_app(sessions, correctionLoader: backend.load));
    await tester.pumpAndSettle();
    final SaleExchangeDraft draft = exchangeDraft();
    Object? error;
    unawaited(
      corrections(tester)
          .submitExchange(draft)
          .then<void>((_) {}, onError: (Object e) => error = e),
    );
    await tester.pump();
    sessions.sessions.add(_otherSeller);
    await tester.pumpAndSettle();
    pending.complete(exchangeResponse());
    await tester.pumpAndSettle();
    expect(error, isA<SaleUncertainException>());
    expect(corrections(tester).unresolvedDraft(), isNull);
    sessions.sessions.add(_seller);
    await tester.pumpAndSettle();
    expect(corrections(tester).unresolvedDraft(), same(draft));
    expect(corrections(tester).unacknowledged(), isNull);
  });
}
