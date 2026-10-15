import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/stock_intake.dart';

const StockIntakeQuantitySpec _piece = StockIntakeQuantitySpec(
  unit: 'piece',
  precision: 0,
);
const StockIntakeQuantitySpec _kilo = StockIntakeQuantitySpec(
  unit: 'kg',
  precision: 2,
);
const StockIntakeQuantitySpec _gram = StockIntakeQuantitySpec(
  unit: 'g',
  precision: 6,
);

StockIntakeDraft _draft({
  String idempotencyKey = '123e4567-e89b-42d3-a456-426614174000',
  String branchId = 'branch-north',
  String productId = 'PRD-COFFEE-001',
  String quantity = '3',
  String unitCostMxn = '12.34',
  StockIntakeQuantitySpec quantitySpec = _piece,
}) => StockIntakeDraft(
  idempotencyKey: idempotencyKey,
  branchId: branchId,
  productId: productId,
  quantity: quantity,
  unitCostMxn: unitCostMxn,
  quantitySpec: quantitySpec,
);

Map<String, Object?> _callableResult(
  StockIntakeDraft request, {
  int? stockQuantityScaled,
  bool replayed = false,
}) => <String, Object?>{
  'entryId': request.idempotencyKey,
  'movementId': request.idempotencyKey,
  'quantityScaled': request.quantityScaled,
  'stockQuantityScaled': stockQuantityScaled ?? request.quantityScaled,
  'unitCostCentavos': request.unitCostCentavos,
  'lineTotalCentavos': request.lineTotalCentavos,
  'replayed': replayed,
};

void main() {
  group('StockIntakeQuantitySpec', () {
    test('accepts precisions 0 through 6 and lowercase units', () {
      for (final StockIntakeQuantitySpec spec in <StockIntakeQuantitySpec>[
        const StockIntakeQuantitySpec(unit: 'piece', precision: 0),
        const StockIntakeQuantitySpec(unit: 'kg', precision: 1),
        const StockIntakeQuantitySpec(unit: 'm-2', precision: 2),
        const StockIntakeQuantitySpec(unit: 'x_3', precision: 3),
        const StockIntakeQuantitySpec(unit: 'a', precision: 4),
        const StockIntakeQuantitySpec(unit: 'ml', precision: 5),
        const StockIntakeQuantitySpec(unit: 'g', precision: 6),
      ]) {
        expect(() => spec.validate(), returnsNormally, reason: spec.unit);
      }
    });

    test('rejects invalid units and out-of-range precisions', () {
      for (final StockIntakeQuantitySpec invalid in <StockIntakeQuantitySpec>[
        const StockIntakeQuantitySpec(unit: '', precision: 0),
        const StockIntakeQuantitySpec(unit: 'Kg', precision: 0),
        const StockIntakeQuantitySpec(unit: '1kg', precision: 0),
        const StockIntakeQuantitySpec(unit: 'kg kg', precision: 0),
        const StockIntakeQuantitySpec(unit: 'piece', precision: -1),
        const StockIntakeQuantitySpec(unit: 'piece', precision: 7),
        const StockIntakeQuantitySpec(unit: 'piece', precision: 1 << 31),
      ]) {
        expect(
          invalid.validate,
          throwsA(isA<StockIntakeValidationException>()),
          reason: '${invalid.unit}/${invalid.precision}',
        );
      }
    });
  });

  group('StockIntakeDraft request', () {
    test('serializes exactly the five server request fields', () {
      final StockIntakeDraft draft = _draft(
        quantity: '3.33',
        unitCostMxn: '12.5',
        quantitySpec: _kilo,
      );
      expect(draft.toRequest(), <String, Object?>{
        'idempotencyKey': '123e4567-e89b-42d3-a456-426614174000',
        'branchId': 'branch-north',
        'productId': 'PRD-COFFEE-001',
        'quantity': '3.33',
        'unitCostMxn': '12.5',
      });
    });

    test('exposes the historical truncation policy id', () {
      expect(
        StockIntakeDraft.calculationPolicyVersion,
        'mxn-unit-cost-truncate-v1',
      );
    });

    test('parses quantities with exact integer scaling per precision', () {
      expect(_draft(quantity: '12').quantityScaled, 12);
      expect(_draft(quantity: '3.14', quantitySpec: _kilo).quantityScaled, 314);
      expect(_draft(quantity: '0.5', quantitySpec: _kilo).quantityScaled, 50);
      expect(
        _draft(quantity: '0.000001', quantitySpec: _gram).quantityScaled,
        1,
      );
      expect(_draft(quantity: '1.5', quantitySpec: _kilo).quantityScaled, 150);
      expect(
        _draft(
          quantity: '9007199254740991',
          unitCostMxn: '0.01',
        ).quantityScaled,
        9007199254740991,
      );
      expect(
        _draft(
          quantity: '9007199254.740991',
          unitCostMxn: '0.01',
          quantitySpec: _gram,
        ).quantityScaled,
        9007199254740991,
      );
    });

    test('rejects malformed, signed, padded, and non-canonical quantities', () {
      for (final String invalid in <String>[
        '',
        ' 1',
        '1 ',
        '+1',
        '-1',
        '01',
        '1,5',
        '1e3',
        '1.',
        '.5',
        '1.2.3',
        '١٢',
      ]) {
        expect(
          _draft(quantity: invalid).validate,
          throwsA(isA<StockIntakeValidationException>()),
          reason: invalid,
        );
      }
    });

    test('rejects quantities over the 18-character input cap', () {
      expect(
        _draft(quantity: '1234567890123456.7890').validate,
        throwsA(isA<StockIntakeValidationException>()),
      );
    });

    test('rejects non-positive quantities at every precision', () {
      for (final MapEntry<String, StockIntakeQuantitySpec> entry
          in <String, StockIntakeQuantitySpec>{
            '0': _piece,
            '0.0': _kilo,
            '0.00': _kilo,
            '0.000000': _gram,
          }.entries) {
        expect(
          _draft(quantity: entry.key, quantitySpec: entry.value).validate,
          throwsA(isA<StockIntakeValidationException>()),
          reason: entry.key,
        );
      }
    });

    test('rejects excess fractional digits even when they are zeros', () {
      expect(
        _draft(quantity: '1.0', quantitySpec: _piece).validate,
        throwsA(isA<StockIntakeValidationException>()),
        reason: 'precision 0 rejects "1.0"',
      );
      expect(
        _draft(quantity: '1.500', quantitySpec: _kilo).validate,
        throwsA(isA<StockIntakeValidationException>()),
      );
      expect(
        _draft(quantity: '0.0000001', quantitySpec: _gram).validate,
        throwsA(isA<StockIntakeValidationException>()),
      );
    });

    test('rejects scaled quantities beyond the safe integer bound', () {
      expect(
        _draft(quantity: '9007199254740992').validate,
        throwsA(isA<StockIntakeValidationException>()),
      );
      expect(
        _draft(quantity: '9007199255', quantitySpec: _gram).validate,
        throwsA(isA<StockIntakeValidationException>()),
        reason: '9007199255000000 exceeds the safe bound',
      );
    });

    test('parses MXN costs with exact centavos arithmetic', () {
      expect(_draft(unitCostMxn: '0').unitCostCentavos, 0);
      expect(_draft(unitCostMxn: '0.0').unitCostCentavos, 0);
      expect(_draft(unitCostMxn: '0.00').unitCostCentavos, 0);
      expect(_draft(unitCostMxn: '12.34').unitCostCentavos, 1234);
      expect(_draft(unitCostMxn: '1.2').unitCostCentavos, 120);
      expect(
        _draft(
          quantity: '1',
          unitCostMxn: '90071992547409.91',
        ).unitCostCentavos,
        9007199254740991,
      );
    });

    test('rejects malformed or out-of-bound costs', () {
      for (final String invalid in <String>[
        '',
        ' 1',
        '1 ',
        '-1',
        '+1',
        '01',
        '1,50',
        '1.000',
        '1.',
        '.5',
        '90071992547409.92',
        '900719925474099.1',
        '9007199254740991',
      ]) {
        expect(
          _draft(unitCostMxn: invalid).validate,
          throwsA(isA<StockIntakeValidationException>()),
          reason: invalid,
        );
      }
    });

    test('rejects invalid identifiers', () {
      for (final String invalid in <String>[
        '',
        ' key',
        'key ',
        'key.name',
        '-key',
        '_key',
        'a' * 129,
      ]) {
        expect(
          _draft(idempotencyKey: invalid).validate,
          throwsA(isA<StockIntakeValidationException>()),
          reason: 'idempotencyKey "$invalid"',
        );
        expect(
          _draft(branchId: invalid).validate,
          throwsA(isA<StockIntakeValidationException>()),
          reason: 'branchId "$invalid"',
        );
        expect(
          _draft(productId: invalid).validate,
          throwsA(isA<StockIntakeValidationException>()),
          reason: 'productId "$invalid"',
        );
      }
    });

    test('rejects drafts carrying an invalid frozen quantity spec', () {
      expect(
        _draft(
          quantitySpec: const StockIntakeQuantitySpec(
            unit: 'piece',
            precision: 7,
          ),
        ).validate,
        throwsA(isA<StockIntakeValidationException>()),
      );
    });

    test('truncates fractional line totals toward zero exactly', () {
      // 3.33 kg * 0.01 MXN = 3.33 MXN -> 333 * 1 / 100 = 3.33 centavos.
      expect(
        _draft(
          quantity: '3.33',
          unitCostMxn: '0.01',
          quantitySpec: _kilo,
        ).lineTotalCentavos,
        3,
      );
      // 0.01 kg * 1 MXN = 0.01 MXN -> 1 * 100 / 100 = 1 centavo.
      expect(
        _draft(
          quantity: '0.01',
          unitCostMxn: '1',
          quantitySpec: _kilo,
        ).lineTotalCentavos,
        1,
      );
      // Whole pieces never truncate.
      expect(
        _draft(quantity: '3', unitCostMxn: '12.34').lineTotalCentavos,
        3702,
      );
      // Zero cost yields a zero total.
      expect(_draft(quantity: '5', unitCostMxn: '0').lineTotalCentavos, 0);
      // Exact truncation at the safe boundary: scaled quantity 1 at
      // precision 6 times the maximum centavos value truncates to 9007199254.
      expect(
        _draft(
          quantity: '0.000001',
          unitCostMxn: '90071992547409.91',
          quantitySpec: _gram,
        ).lineTotalCentavos,
        9007199254,
      );
      // Quantity 1 times the maximum centavos value stays exact.
      expect(
        _draft(
          quantity: '1',
          unitCostMxn: '90071992547409.91',
          quantitySpec: _piece,
        ).lineTotalCentavos,
        9007199254740991,
      );
    });

    test('rejects line totals beyond the safe integer bound', () {
      expect(
        _draft(
          quantity: '9007199254740991',
          unitCostMxn: '90071992547409.91',
          quantitySpec: _piece,
        ).validate,
        throwsA(isA<StockIntakeValidationException>()),
        reason: 'product of safe bounds overflows at precision 0',
      );
    });
  });

  group('StockIntakeResult', () {
    test('parses an exact seven-field success result', () {
      final StockIntakeDraft request = _draft(
        quantity: '2.5',
        unitCostMxn: '10',
        quantitySpec: _kilo,
      );
      final StockIntakeResult result = StockIntakeResult.fromCallable(
        _callableResult(request, stockQuantityScaled: 250 + 30),
        request: request,
      );
      expect(result.entryId, request.idempotencyKey);
      expect(result.movementId, request.idempotencyKey);
      expect(result.quantityScaled, 250);
      expect(result.stockQuantityScaled, 280);
      expect(result.unitCostCentavos, 1000);
      expect(result.lineTotalCentavos, 2500);
      expect(result.replayed, isFalse);
    });

    test('parses a replayed result with the stored stock projection', () {
      final StockIntakeDraft request = _draft(quantity: '1');
      final StockIntakeResult result = StockIntakeResult.fromCallable(
        _callableResult(request, stockQuantityScaled: 40, replayed: true),
        request: request,
      );
      expect(result.replayed, isTrue);
      expect(result.stockQuantityScaled, 40);
    });

    test('rejects missing, extra, and mistyped fields', () {
      final StockIntakeDraft request = _draft();
      final Map<String, Object?> valid = _callableResult(request);
      expect(
        () => StockIntakeResult.fromCallable(null, request: request),
        throwsA(isA<StockIntakeProtocolException>()),
      );
      expect(
        () => StockIntakeResult.fromCallable(
          <String, Object?>{},
          request: request,
        ),
        throwsA(isA<StockIntakeProtocolException>()),
      );
      for (final String key in valid.keys) {
        final Map<String, Object?> missing = <String, Object?>{...valid}
          ..remove(key);
        expect(
          () => StockIntakeResult.fromCallable(missing, request: request),
          throwsA(isA<StockIntakeProtocolException>()),
          reason: 'missing $key',
        );
        final Map<String, Object?> extra = <String, Object?>{...valid}
          ..['unexpected'] = 1;
        expect(
          () => StockIntakeResult.fromCallable(extra, request: request),
          throwsA(isA<StockIntakeProtocolException>()),
          reason: 'extra field with $key present',
        );
      }
      for (final String key in valid.keys) {
        final Object? wrong = switch (valid[key]) {
          String() => 1,
          int() => '${valid[key]}',
          bool() => 'true',
          _ => null,
        };
        final Map<String, Object?> mistyped = <String, Object?>{...valid}
          ..[key] = wrong;
        expect(
          () => StockIntakeResult.fromCallable(mistyped, request: request),
          throwsA(isA<StockIntakeProtocolException>()),
          reason: 'mistyped $key',
        );
      }
    });

    test('rejects correlation mismatches with the frozen request', () {
      final StockIntakeDraft request = _draft(quantity: '3');
      void expectRejected(
        Map<String, Object?> Function(Map<String, Object?>) mutate,
      ) {
        final Map<String, Object?> mutated = mutate(_callableResult(request));
        expect(
          () => StockIntakeResult.fromCallable(mutated, request: request),
          throwsA(isA<StockIntakeProtocolException>()),
        );
      }

      expectRejected(
        (Map<String, Object?> value) =>
            <String, Object?>{...value}..['entryId'] = 'other-key',
      );
      expectRejected(
        (Map<String, Object?> value) =>
            <String, Object?>{...value}..['movementId'] = 'other-key',
      );
      expectRejected(
        (Map<String, Object?> value) =>
            <String, Object?>{...value}..['quantityScaled'] = 4,
      );
      expectRejected(
        (Map<String, Object?> value) =>
            <String, Object?>{...value}..['unitCostCentavos'] = 1235,
      );
      expectRejected(
        (Map<String, Object?> value) =>
            <String, Object?>{...value}..['lineTotalCentavos'] = 3703,
      );
      expectRejected(
        (Map<String, Object?> value) =>
            <String, Object?>{...value}..['quantityScaled'] = 3.0,
      );
    });

    test('rejects unsafe or impossible stock projections', () {
      final StockIntakeDraft request = _draft(quantity: '3');
      void expectRejected(int stockQuantityScaled) {
        expect(
          () => StockIntakeResult.fromCallable(
            _callableResult(request, stockQuantityScaled: stockQuantityScaled),
            request: request,
          ),
          throwsA(isA<StockIntakeProtocolException>()),
        );
      }

      expectRejected(2);
      expectRejected(-3);
      expectRejected(9007199254740992);
    });
  });

  group('StockIntakeDraftStore', () {
    test('freezes the request and resolves only the current attempt', () {
      final StockIntakeDraftStore store = StockIntakeDraftStore();
      final StockIntakeDraft draft = _draft();
      final StockIntakeAttempt first = store.begin(
        ownerUserId: 'admin-1',
        draft: draft,
      );
      expect(first.revision, 1);
      expect(
        store.unresolvedFor('admin-1', draft.productId, draft.branchId),
        draft,
      );

      final StockIntakeAttempt retry = store.begin(
        ownerUserId: 'admin-1',
        draft: draft,
      );
      expect(retry.revision, 2);
      expect(store.isCurrent(first), isFalse);
      expect(store.isCurrent(retry), isTrue);
      expect(store.resolve(first), isFalse);
      expect(
        store.unresolvedFor('admin-1', draft.productId, draft.branchId),
        draft,
      );
      expect(store.resolve(retry), isTrue);
      expect(
        store.unresolvedFor('admin-1', draft.productId, draft.branchId),
        isNull,
      );
    });

    test('rejects a different request on an unresolved slot', () {
      final StockIntakeDraftStore store = StockIntakeDraftStore();
      store.begin(
        ownerUserId: 'admin-1',
        draft: _draft(quantity: '1'),
      );
      expect(
        () => store.begin(
          ownerUserId: 'admin-1',
          draft: _draft(quantity: '2'),
        ),
        throwsA(isA<StockIntakeUnresolvedException>()),
      );
    });

    test('requires an owning user', () {
      final StockIntakeDraftStore store = StockIntakeDraftStore();
      expect(
        () => store.begin(ownerUserId: '', draft: _draft()),
        throwsA(isA<StockIntakeSessionException>()),
      );
    });

    test('isolates actors for the same product and branch', () {
      final StockIntakeDraftStore store = StockIntakeDraftStore();
      final StockIntakeDraft draft = _draft();
      final StockIntakeAttempt adminAttempt = store.begin(
        ownerUserId: 'admin-1',
        draft: draft,
      );
      expect(
        store.unresolvedFor('admin-2', draft.productId, draft.branchId),
        isNull,
      );
      final StockIntakeAttempt otherAttempt = store.begin(
        ownerUserId: 'admin-2',
        draft: draft,
      );
      expect(otherAttempt.revision, 1);
      expect(store.isCurrent(adminAttempt), isTrue);
      expect(store.resolve(adminAttempt), isTrue);
      expect(
        store.unresolvedFor('admin-2', draft.productId, draft.branchId),
        draft,
      );
      expect(store.resolve(otherAttempt), isTrue);
    });

    test('isolates products for the same actor and branch', () {
      final StockIntakeDraftStore store = StockIntakeDraftStore();
      final StockIntakeDraft coffee = _draft(productId: 'PRD-COFFEE-001');
      final StockIntakeDraft sugar = _draft(productId: 'PRD-SUGAR-001');
      final StockIntakeAttempt coffeeAttempt = store.begin(
        ownerUserId: 'admin-1',
        draft: coffee,
      );
      final StockIntakeAttempt sugarAttempt = store.begin(
        ownerUserId: 'admin-1',
        draft: sugar,
      );
      expect(coffeeAttempt.revision, 1);
      expect(sugarAttempt.revision, 1);
      expect(
        store.unresolvedFor('admin-1', coffee.productId, coffee.branchId),
        coffee,
      );
      expect(
        store.unresolvedFor('admin-1', sugar.productId, sugar.branchId),
        sugar,
      );
      expect(store.resolve(coffeeAttempt), isTrue);
      expect(
        store.unresolvedFor('admin-1', sugar.productId, sugar.branchId),
        sugar,
      );
    });

    test('isolates branches for the same actor and product', () {
      final StockIntakeDraftStore store = StockIntakeDraftStore();
      final StockIntakeDraft north = _draft(branchId: 'branch-north');
      final StockIntakeDraft south = _draft(branchId: 'branch-south');
      final StockIntakeAttempt northAttempt = store.begin(
        ownerUserId: 'admin-1',
        draft: north,
      );
      final StockIntakeAttempt southAttempt = store.begin(
        ownerUserId: 'admin-1',
        draft: south,
      );
      expect(southAttempt.revision, 1);
      expect(
        store.unresolvedFor('admin-1', north.productId, north.branchId),
        north,
      );
      expect(
        store.unresolvedFor('admin-1', south.productId, south.branchId),
        south,
      );
      // A stale late completion for one branch never clears another branch.
      expect(store.resolve(southAttempt), isTrue);
      expect(
        store.unresolvedFor('admin-1', north.productId, north.branchId),
        north,
      );
      expect(store.isCurrent(northAttempt), isTrue);
    });

    test('a stale late completion cannot clear a newer retry', () {
      final StockIntakeDraftStore store = StockIntakeDraftStore();
      final StockIntakeDraft draft = _draft();
      final StockIntakeAttempt first = store.begin(
        ownerUserId: 'admin-1',
        draft: draft,
      );
      store.begin(ownerUserId: 'admin-1', draft: draft);
      expect(store.isCurrent(first), isFalse);
      expect(store.resolve(first), isFalse);
      expect(
        store.unresolvedFor('admin-1', draft.productId, draft.branchId),
        draft,
      );
    });
  });

  test('validation messages are shown to users in Spanish', () {
    expect(
      _draft(quantity: '1234567890123456.7890').validate,
      throwsA(
        isA<StockIntakeValidationException>().having(
          (StockIntakeValidationException error) => error.message,
          'message',
          'La cantidad debe ser un decimal positivo de máximo 18 caracteres, '
              'sin signo, espacios, comas ni exponentes.',
        ),
      ),
    );
  });
}
