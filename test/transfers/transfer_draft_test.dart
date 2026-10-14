import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

const QuantitySpec _piece = QuantitySpec(unit: 'piece', precision: 0);
const QuantitySpec _meter = QuantitySpec(unit: 'meter', precision: 2);
const QuantitySpec _gram = QuantitySpec(unit: 'g', precision: 6);
const QuantitySpec _millilitre = QuantitySpec(unit: 'ml', precision: 3);

const String _key = '123e4567-e89b-42d3-a456-426614174000';

TransferLine _line({
  String productId = 'DEMO-RIBBON',
  String quantity = '2.50',
  QuantitySpec quantitySpec = _meter,
}) => TransferLine(
  productId: productId,
  quantity: quantity,
  quantitySpec: quantitySpec,
);

TransferDraft _draft({
  String idempotencyKey = _key,
  String sourceBranchId = 'branch-north',
  String destinationBranchId = 'branch-south',
  List<TransferLine>? lines,
}) => TransferDraft(
  idempotencyKey: idempotencyKey,
  sourceBranchId: sourceBranchId,
  destinationBranchId: destinationBranchId,
  lines: lines ?? <TransferLine>[_line()],
);

/// A deep copy so every negative case differs from a valid payload once.
Map<String, Object?> _copy(Map<String, Object?> base) => <String, Object?>{
  ...base,
  'lines': (base['lines']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .map((Map<String, Object?> line) => <String, Object?>{...line})
      .toList(),
};

/// The exact six-field result the callable answers, derived from [request].
Map<String, Object?> _result(
  TransferDraft request, {
  bool replayed = false,
  int? occurredAt,
  List<Map<String, Object?>>? lines,
}) => <String, Object?>{
  'transferId': request.idempotencyKey,
  'sourceBranchId': request.sourceBranchId,
  'destinationBranchId': request.destinationBranchId,
  'occurredAt': occurredAt ?? 1767225600000,
  'lines':
      lines ??
      request.lines
          .map(
            (TransferLine line) => <String, Object?>{
              'productId': line.productId,
              'quantity': line.quantity,
              'quantityScaled': line.quantityScaled,
              'unit': line.quantitySpec.unit,
              'precision': line.quantitySpec.precision,
              'sourceQuantityScaled': 500,
              'destinationQuantityScaled': 250 + line.quantityScaled,
            },
          )
          .toList(),
  'replayed': replayed,
};

void main() {
  group('TransferLine', () {
    test('scales canonical decimals with exact integers only', () {
      expect(_line(quantity: '2', quantitySpec: _piece).quantityScaled, 2);
      expect(_line(quantity: '2.50').quantityScaled, 250);
      expect(_line(quantity: '0.07').quantityScaled, 7);
      expect(_line(quantity: '1234.56').quantityScaled, 123456);
      expect(
        _line(quantity: '8.999999', quantitySpec: _gram).quantityScaled,
        8999999,
      );
      expect(
        _line(
          quantity: '9007199254740.991',
          quantitySpec: _millilitre,
        ).quantityScaled,
        maxSafeTransferScaled,
      );
      expect(
        _line(
          quantity: '9007199254.740991',
          quantitySpec: _gram,
        ).quantityScaled,
        maxSafeTransferScaled,
      );
      expect(
        _line(quantity: '0.000001', quantitySpec: _gram).quantityScaled,
        1,
      );
    });

    test('rejects non-canonical, zero, and over-precision quantities', () {
      for (final String quantity in <String>[
        '',
        '0',
        '0.0',
        '0.00',
        '-1',
        '+1',
        '1.',
        '.5',
        '01',
        '1,5',
        '1e3',
        ' 1',
        '1 ',
        'Infinity',
        'NaN',
        '1.0e2',
      ]) {
        expect(
          () => _line(quantity: quantity).quantityScaled,
          throwsA(isA<TransferValidationException>()),
          reason: 'quantity "$quantity" must be rejected',
        );
      }

      expect(
        () => _line(quantity: '2.500').quantityScaled,
        throwsA(
          isA<TransferValidationException>().having(
            (TransferValidationException error) => error.reason,
            'reason',
            TransferValidationReason.quantity,
          ),
        ),
      );
      expect(
        () => _line(quantity: '1.5', quantitySpec: _piece).quantityScaled,
        throwsA(isA<TransferValidationException>()),
      );
      expect(
        () => _line(
          quantity: '9007199254740.992',
          quantitySpec: _millilitre,
        ).quantityScaled,
        throwsA(
          isA<TransferValidationException>().having(
            (TransferValidationException error) => error.reason,
            'reason',
            TransferValidationReason.quantityRange,
          ),
        ),
      );
      expect(
        () => _line(quantity: '9' * 19).quantityScaled,
        throwsA(isA<TransferValidationException>()),
      );
    });

    test('enforces the server identifier and specification patterns', () {
      expect(() => _line(productId: 'DEMO-RIBBON').validate(), returnsNormally);
      expect(() => _line(productId: 'ABCDEFGH').validate(), returnsNormally);
      for (final String productId in <String>[
        '',
        'abcdefgh',
        '1DEMO-RIBBON',
        '-DEMO-RIBBON',
        'DEMO_RIBBON',
        'DEMO RIBBON',
        'DEMO-RIBBON.',
        'A' * 65,
      ]) {
        expect(
          () => _line(productId: productId).validate(),
          throwsA(
            isA<TransferValidationException>().having(
              (TransferValidationException error) => error.reason,
              'reason',
              TransferValidationReason.product,
            ),
          ),
          reason: 'product id "$productId" must be rejected',
        );
      }

      expect(
        () =>
            _line(quantitySpec: QuantitySpec(unit: 'Meter', precision: 2))
                .validate(),
        throwsA(isA<TransferValidationException>()),
      );
      expect(
        () =>
            _line(quantitySpec: QuantitySpec(unit: 'm', precision: 7))
                .validate(),
        throwsA(isA<TransferValidationException>()),
      );
      expect(
        () =>
            _line(quantitySpec: QuantitySpec(unit: 'm', precision: 0))
                .validate(),
        throwsA(isA<TransferValidationException>()),
      );
    });

    test('exposes only the two server line fields and compares by value', () {
      expect(_line().toRequestLine(), <String, Object?>{
        'productId': 'DEMO-RIBBON',
        'quantity': '2.50',
      });
      expect(_line(), _line());
      expect(_line().hashCode, _line().hashCode);
      expect(_line(quantity: '2.5'), isNot(_line(quantity: '2.50')));
      expect(
        _line(quantitySpec: QuantitySpec(unit: 'meter', precision: 2)),
        _line(),
      );
    });
  });

  group('TransferDraft', () {
    test('emits the exact four-field server request without normalization', () {
      final TransferDraft draft = _draft(
        lines: <TransferLine>[
          _line(),
          _line(
            productId: 'PRD-COFFEE-01',
            quantity: '3',
            quantitySpec: _piece,
          ),
        ],
      );

      expect(draft.toRequest(), <String, Object?>{
        'idempotencyKey': _key,
        'sourceBranchId': 'branch-north',
        'destinationBranchId': 'branch-south',
        'lines': <Object?>[
          <String, Object?>{'productId': 'DEMO-RIBBON', 'quantity': '2.50'},
          <String, Object?>{'productId': 'PRD-COFFEE-01', 'quantity': '3'},
        ],
      });
    });

    test('snapshots caller lists and returns detached request maps', () {
      final List<TransferLine> lines = <TransferLine>[_line()];
      final TransferDraft draft = _draft(lines: lines);

      lines.add(_line(productId: 'PRD-COFFEE-01', quantity: '3'));
      expect(draft.lines, hasLength(1));
      expect(() => draft.lines.add(_line()), throwsUnsupportedError);

      final Map<String, Object?> request = draft.toRequest();
      (request['lines']! as List<Object?>).clear();
      request['sourceBranchId'] = 'branch-tampered';
      expect(draft.toRequest()['lines'], hasLength(1));
      expect(draft.toRequest()['sourceBranchId'], 'branch-north');
      expect(draft.sourceBranchId, 'branch-north');

      final Map<String, Object?> nested = draft.toRequest();
      (nested['lines']! as List<Object?>)
              .cast<Map<String, Object?>>()
              .first['quantity'] =
          '99';
      expect(draft.toRequest()['lines'], hasLength(1));
      expect(
        (draft.toRequest()['lines']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .first['quantity'],
        '2.50',
      );
    });

    test('accepts the server bounds for keys, branches, and line counts', () {
      expect(() => _draft().validate(), returnsNormally);
      // The server key pattern is broader than a UUID: no stricter client rule.
      expect(
        () => _draft(idempotencyKey: 'transfer-2026_01-a').validate(),
        returnsNormally,
      );
      expect(
        () =>
            _draft(idempotencyKey: 'a' * maxTransferIdempotencyKeyLength)
                .validate(),
        returnsNormally,
      );
      expect(
        () => _draft(
          sourceBranchId: 'branch-a1',
          destinationBranchId: 'branch-b2',
        ).validate(),
        returnsNormally,
      );
      expect(
        () => _draft(
          lines: List<TransferLine>.generate(
            transferLineLimit,
            (int index) =>
                _line(productId: 'P${index.toString().padLeft(7, "0")}X'),
          ),
        ).validate(),
        returnsNormally,
      );
    });

    test('rejects out-of-contract keys, branches, pairs, and lines', () {
      final Map<String, TransferValidationReason> invalidKeys =
          <String, TransferValidationReason>{
            '': TransferValidationReason.idempotencyKey,
            '_leading': TransferValidationReason.idempotencyKey,
            '-leading': TransferValidationReason.idempotencyKey,
            'has space': TransferValidationReason.idempotencyKey,
            'a' * 113: TransferValidationReason.idempotencyKey,
          };
      for (final String key in invalidKeys.keys) {
        expect(
          () => _draft(idempotencyKey: key).validate(),
          throwsA(
            isA<TransferValidationException>().having(
              (TransferValidationException error) => error.reason,
              'reason',
              invalidKeys[key],
            ),
          ),
          reason: 'key "$key" must be rejected',
        );
      }

      for (final String branch in <String>[
        '',
        'north',
        'Branch-north',
        'branch-',
        'branch-north_',
        'branch-north.south',
        'branch-north south',
        'branch-NORTH',
      ]) {
        expect(
          () => _draft(sourceBranchId: branch).validate(),
          throwsA(
            isA<TransferValidationException>().having(
              (TransferValidationException error) => error.reason,
              'reason',
              TransferValidationReason.branch,
            ),
          ),
          reason: 'source branch "$branch" must be rejected',
        );
        expect(
          () => _draft(destinationBranchId: branch).validate(),
          throwsA(
            isA<TransferValidationException>().having(
              (TransferValidationException error) => error.reason,
              'reason',
              TransferValidationReason.branch,
            ),
          ),
          reason: 'destination branch "$branch" must be rejected',
        );
      }

      expect(
        () => _draft(
          sourceBranchId: 'branch-north',
          destinationBranchId: 'branch-north',
        ).validate(),
        throwsA(
          isA<TransferValidationException>().having(
            (TransferValidationException error) => error.reason,
            'reason',
            TransferValidationReason.branchPair,
          ),
        ),
      );
      expect(
        () => _draft(lines: <TransferLine>[]).validate(),
        throwsA(
          isA<TransferValidationException>().having(
            (TransferValidationException error) => error.reason,
            'reason',
            TransferValidationReason.lines,
          ),
        ),
      );
      expect(
        () => _draft(
          lines: List<TransferLine>.generate(
            transferLineLimit + 1,
            (int index) =>
                _line(productId: 'P${index.toString().padLeft(7, "0")}X'),
          ),
        ).validate(),
        throwsA(isA<TransferValidationException>()),
      );
      expect(
        () => _draft(
          lines: <TransferLine>[
            _line(),
            _line(quantity: '3'),
          ],
        ).validate(),
        throwsA(
          isA<TransferValidationException>().having(
            (TransferValidationException error) => error.reason,
            'reason',
            TransferValidationReason.duplicateProduct,
          ),
        ),
      );
      expect(
        () => _draft(lines: <TransferLine>[_line(quantity: '0')]).validate(),
        throwsA(isA<TransferValidationException>()),
      );
    });

    test('compares by value including the frozen line specifications', () {
      expect(_draft(), _draft());
      expect(_draft().hashCode, _draft().hashCode);
      expect(_draft(sourceBranchId: 'branch-east'), isNot(_draft()));
      expect(
        _draft(lines: <TransferLine>[_line(quantity: '2.5')]),
        isNot(_draft()),
      );
      expect(_draft().lines, isA<List<TransferLine>>());
    });
  });

  group('TransferResult.fromCallable', () {
    test('parses the exact result and each per-line projection', () {
      final TransferDraft draft = _draft();
      final TransferResult result = TransferResult.fromCallable(
        _result(draft),
        request: draft,
      );

      expect(result.transferId, draft.idempotencyKey);
      expect(result.sourceBranchId, 'branch-north');
      expect(result.destinationBranchId, 'branch-south');
      expect(result.occurredAt, 1767225600000);
      expect(result.replayed, isFalse);
      expect(result.lines, hasLength(1));
      expect(result.lines.single.productId, 'DEMO-RIBBON');
      expect(result.lines.single.quantity, '2.50');
      expect(result.lines.single.quantityScaled, 250);
      expect(result.lines.single.unit, 'meter');
      expect(result.lines.single.precision, 2);
      expect(result.lines.single.sourceQuantityScaled, 500);
      expect(result.lines.single.destinationQuantityScaled, 500);
      expect(result.replayed, isFalse);

      final TransferResult replay = TransferResult.fromCallable(
        _result(draft, replayed: true),
        request: draft,
      );
      expect(replay.replayed, isTrue);
    });

    test('refuses any shape the server does not answer', () {
      final TransferDraft draft = _draft();
      final Map<String, Object?> valid = _result(draft);

      expect(
        () => TransferResult.fromCallable(null, request: draft),
        throwsA(isA<TransferProtocolException>()),
      );
      expect(
        () => TransferResult.fromCallable('ok', request: draft),
        throwsA(isA<TransferProtocolException>()),
      );
      expect(
        () => TransferResult.fromCallable(<String, Object?>{}, request: draft),
        throwsA(isA<TransferProtocolException>()),
      );
      expect(
        () => TransferResult.fromCallable(
          _result(_draft(idempotencyKey: 'other-valid-key-1')),
          request: draft,
        ),
        throwsA(isA<TransferProtocolException>()),
      );

      final Map<String, void Function(Map<String, Object?>)> mutations =
          <String, void Function(Map<String, Object?>)>{
            'extra root field': (Map<String, Object?> root) =>
                root['extra'] = 1,
            'missing transferId': (Map<String, Object?> root) =>
                root.remove('transferId'),
            'missing replayed': (Map<String, Object?> root) =>
                root.remove('replayed'),
            'wrong transferId': (Map<String, Object?> root) =>
                root['transferId'] = 'other-key',
            'wrong source': (Map<String, Object?> root) =>
                root['sourceBranchId'] = 'branch-east',
            'wrong destination': (Map<String, Object?> root) =>
                root['destinationBranchId'] = 'branch-east',
            'non-boolean replayed': (Map<String, Object?> root) =>
                root['replayed'] = 'false',
            'string occurredAt': (Map<String, Object?> root) =>
                root['occurredAt'] = '1767225600000',
            'fractional occurredAt': (Map<String, Object?> root) =>
                root['occurredAt'] = 1767225600000.5,
            'negative occurredAt': (Map<String, Object?> root) =>
                root['occurredAt'] = -1,
            'unsafe occurredAt': (Map<String, Object?> root) =>
                root['occurredAt'] = 9007199254740992,
            'empty lines': (Map<String, Object?> root) =>
                root['lines'] = <Object?>[],
            'extra line': (Map<String, Object?> root) =>
                root['lines'] = <Object?>[
                  ...(root['lines']! as List<Object?>),
                  <String, Object?>{
                    'productId': 'PRD-COFFEE-01',
                    'quantity': '3',
                    'quantityScaled': 3,
                    'unit': 'piece',
                    'precision': 0,
                    'sourceQuantityScaled': 0,
                    'destinationQuantityScaled': 3,
                  },
                ],
            'lines not a list': (Map<String, Object?> root) =>
                root['lines'] = 'DEMO-RIBBON',
          };

      final Map<String, void Function(Map<String, Object?>)> lineMutations =
          <String, void Function(Map<String, Object?>)>{
            'missing line field': (Map<String, Object?> l) => l.remove('unit'),
            'extra line field': (Map<String, Object?> l) =>
                l['unexpected'] = true,
            'wrong productId': (Map<String, Object?> l) =>
                l['productId'] = 'PRD-COFFEE-01',
            'wrong quantity': (Map<String, Object?> l) => l['quantity'] = '2.5',
            'wrong quantityScaled': (Map<String, Object?> l) =>
                l['quantityScaled'] = 251,
            'fractional quantityScaled': (Map<String, Object?> l) =>
                l['quantityScaled'] = 2.5,
            'zero quantityScaled': (Map<String, Object?> l) =>
                l['quantityScaled'] = 0,
            'wrong unit': (Map<String, Object?> l) => l['unit'] = 'kilogram',
            'wrong precision': (Map<String, Object?> l) => l['precision'] = 3,
            'negative source stock': (Map<String, Object?> l) =>
                l['sourceQuantityScaled'] = -1,
            'destination below transferred': (Map<String, Object?> l) =>
                l['destinationQuantityScaled'] = 249,
            'unsafe destination stock': (Map<String, Object?> l) =>
                l['destinationQuantityScaled'] = 9007199254740992,
            'stock not an integer': (Map<String, Object?> l) =>
                l['sourceQuantityScaled'] = '500',
          };

      mutations.forEach((
        String label,
        void Function(Map<String, Object?>) edit,
      ) {
        final Map<String, Object?> payload = _copy(valid);
        edit(payload);
        expect(
          () => TransferResult.fromCallable(payload, request: draft),
          throwsA(isA<TransferProtocolException>()),
          reason: 'root mutation "$label" must be refused',
        );
      });

      lineMutations.forEach((
        String label,
        void Function(Map<String, Object?>) edit,
      ) {
        final Map<String, Object?> payload = _copy(valid);
        final List<Map<String, Object?>> lines =
            (payload['lines']! as List<Object?>).cast<Map<String, Object?>>();
        edit(lines.first);
        expect(
          () => TransferResult.fromCallable(payload, request: draft),
          throwsA(isA<TransferProtocolException>()),
          reason: 'line mutation "$label" must be refused',
        );
      });
    });

    test('keeps a defensive copy of the parsed lines', () {
      final TransferDraft draft = _draft();
      final TransferResult result = TransferResult.fromCallable(
        _result(draft),
        request: draft,
      );
      expect(() => result.lines.clear(), throwsUnsupportedError);
      expect(result.lines, hasLength(1));
    });
  });

  group('TransferDraftStore', () {
    test('freezes the payload per exact owner and stable key', () async {
      final TransferDraftStore store = TransferDraftStore();
      final TransferDraft draft = _draft();
      final List<TransferLine> lines = <TransferLine>[...draft.lines];

      final TransferAttempt first = await store.begin(
        ownerUserId: 'administrator-1',
        draft: draft,
      );
      lines.add(_line(productId: 'PRD-COFFEE-01', quantity: '3'));

      expect(first.revision, 1);
      expect(first.ownerUserId, 'administrator-1');
      expect(first.idempotencyKey, _key);
      expect(store.unresolvedFor('administrator-1', _key), draft);
      expect(store.unresolvedFor('administrator-1', _key)!.lines, hasLength(1));
      expect(store.unresolvedByOwner('administrator-2'), isEmpty);
      expect(store.unresolvedFor('administrator-2', _key), isNull);

      final TransferAttempt second = await store.begin(
        ownerUserId: 'administrator-1',
        draft: _draft(),
      );
      expect(second.revision, 2);
      expect(store.isCurrent(first), isFalse);
      expect(store.isCurrent(second), isTrue);
    });

    test('refuses to overwrite a different unresolved payload', () async {
      final TransferDraftStore store = TransferDraftStore();
      final TransferDraft frozen = _draft();
      await store.begin(ownerUserId: 'administrator-1', draft: frozen);

      await expectLater(
        store.begin(
          ownerUserId: 'administrator-1',
          draft: _draft(
            lines: <TransferLine>[
              frozen.lines.single,
              _line(productId: 'PRD-COFFEE-01', quantity: '3'),
            ],
          ),
        ),
        throwsA(isA<TransferUnresolvedException>()),
      );
      expect(store.unresolvedFor('administrator-1', _key), frozen);
      expect(store.unresolvedFor('administrator-1', _key)!.lines, hasLength(1));
    });

    test('retains unresolved payloads and resolves settled ones', () async {
      final TransferDraftStore store = TransferDraftStore();
      final TransferAttempt attempt = await store.begin(
        ownerUserId: 'administrator-1',
        draft: _draft(),
      );

      store.retain(attempt);
      expect(store.unresolvedFor('administrator-1', _key), _draft());
      expect(store.unresolvedByOwner('administrator-1'), hasLength(1));

      final List<TransferDraft> snapshot = store.unresolvedByOwner(
        'administrator-1',
      );
      expect(
        () => snapshot.add(_draft(idempotencyKey: 'other-key')),
        throwsUnsupportedError,
      );

      expect(await store.resolve(attempt), isTrue);
      expect(store.unresolvedFor('administrator-1', _key), isNull);
      expect(store.unresolvedByOwner('administrator-1'), isEmpty);
      expect(await store.resolve(attempt), isFalse);
    });

    test(
      'stale attempts cannot discard the current unresolved payload',
      () async {
        final TransferDraftStore store = TransferDraftStore();
        final TransferAttempt old = await store.begin(
          ownerUserId: 'administrator-1',
          draft: _draft(),
        );
        final TransferAttempt current = await store.begin(
          ownerUserId: 'administrator-1',
          draft: _draft(),
        );

        expect(await store.resolve(old), isFalse);
        expect(store.unresolvedFor('administrator-1', _key), current.draft);

        final TransferDraftStore other = TransferDraftStore();
        await other.begin(ownerUserId: 'administrator-1', draft: _draft());
        final TransferAttempt foreign = await other.begin(
          ownerUserId: 'administrator-2',
          draft: _draft(sourceBranchId: 'branch-east'),
        );
        expect(store.isCurrent(foreign), isFalse);
        expect(await store.resolve(foreign), isFalse);
      },
    );

    test(
      'rejects empty owners and invalid drafts before storing anything',
      () async {
        final TransferDraftStore store = TransferDraftStore();
        await expectLater(
          store.begin(ownerUserId: '', draft: _draft()),
          throwsA(isA<TransferSessionException>()),
        );
        await expectLater(
          store.begin(
            ownerUserId: 'administrator-1',
            draft: _draft(destinationBranchId: 'branch-north'),
          ),
          throwsA(isA<TransferValidationException>()),
        );
        expect(store.unresolvedByOwner('administrator-1'), isEmpty);
      },
    );
  });

  group('createTransferUuidV4', () {
    test('produces canonical UUID v4 values for stable retry keys', () {
      final RegExp uuidV4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      final Set<String> seen = <String>{};
      for (int index = 0; index < 200; index += 1) {
        final String value = createTransferUuidV4();
        expect(uuidV4.hasMatch(value), isTrue, reason: value);
        seen.add(value);
      }
      expect(seen, hasLength(200));
    });
  });
}
