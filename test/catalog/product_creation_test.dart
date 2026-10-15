import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/product_creation.dart';

void main() {
  group('ProductCreationDraft', () {
    test(
      'serializes the exact callable request without normalizing the name',
      () {
        const ProductCreationDraft draft = ProductCreationDraft(
          idempotencyKey: '123e4567-e89b-42d3-a456-426614174000',
          name: 'Café molido',
          unit: 'kg_net',
          precision: 3,
        );

        expect(draft.toRequest(), <String, Object?>{
          'idempotencyKey': '123e4567-e89b-42d3-a456-426614174000',
          'name': 'Café molido',
          'quantitySpec': <String, Object?>{'unit': 'kg_net', 'precision': 3},
        });
      },
    );

    test('matches the server canonical name, unit, and precision rules', () {
      const List<ProductCreationDraft> invalid = <ProductCreationDraft>[
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: '',
          unit: 'piece',
          precision: 0,
        ),
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: ' Coffee',
          unit: 'piece',
          precision: 0,
        ),
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'Coffee ',
          unit: 'piece',
          precision: 0,
        ),
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'Coffee\u0000',
          unit: 'piece',
          precision: 0,
        ),
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'Coffee\u007f',
          unit: 'piece',
          precision: 0,
        ),
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'Coffee',
          unit: 'Piece',
          precision: 0,
        ),
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'Coffee',
          unit: '1piece',
          precision: 0,
        ),
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'Coffee',
          unit: 'a23456789012345678901234567890123',
          precision: 0,
        ),
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'Coffee',
          unit: 'piece',
          precision: -1,
        ),
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'Coffee',
          unit: 'piece',
          precision: 7,
        ),
      ];

      for (final ProductCreationDraft draft in invalid) {
        expect(
          draft.validate,
          throwsA(isA<ProductCreationValidationException>()),
        );
      }
      expect(
        const ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'x',
          unit: 'a',
          precision: 0,
        ).validate,
        returnsNormally,
      );
      expect(
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'x' * 120,
          unit: 'a-z_09',
          precision: 6,
        ).validate,
        returnsNormally,
      );
      expect(
        ProductCreationDraft(
          idempotencyKey: 'valid-key',
          name: 'x' * 121,
          unit: 'piece',
          precision: 0,
        ).validate,
        throwsA(isA<ProductCreationValidationException>()),
      );
    });
  });

  test('parses only the exact trusted callable result shape', () {
    expect(
      ProductCreationResult.fromCallable(<String, Object?>{
        'productId': 'PRD-COFFEE-001',
        'internalCode': 'PRD-COFFEE-001',
        'replayed': false,
      }),
      const ProductCreationResult(
        productId: 'PRD-COFFEE-001',
        internalCode: 'PRD-COFFEE-001',
        replayed: false,
      ),
    );

    for (final Object? invalid in <Object?>[
      null,
      <String, Object?>{},
      <String, Object?>{
        'productId': 'PRD-COFFEE-001',
        'internalCode': 'PRD-DIFFERENT-002',
        'replayed': false,
      },
      <String, Object?>{
        'productId': 'bad-code',
        'internalCode': 'bad-code',
        'replayed': false,
      },
      <String, Object?>{
        'productId': 'PRD-COFFEE-001',
        'internalCode': 'PRD-COFFEE-001',
        'replayed': false,
        'extra': true,
      },
    ]) {
      expect(
        () => ProductCreationResult.fromCallable(invalid),
        throwsA(isA<ProductCreationProtocolException>()),
      );
    }
  });

  group('ProductCreationDraftStore', () {
    const ProductCreationDraft coffee = ProductCreationDraft(
      idempotencyKey: 'draft-key-1',
      name: 'Coffee',
      unit: 'piece',
      precision: 0,
    );
    const ProductCreationDraft tea = ProductCreationDraft(
      idempotencyKey: 'draft-key-2',
      name: 'Tea',
      unit: 'piece',
      precision: 0,
    );

    test('freezes one immutable request per originating user', () {
      final ProductCreationDraftStore store = ProductCreationDraftStore();

      final ProductCreationAttempt first = store.begin(
        ownerUserId: 'admin-1',
        draft: coffee,
      );
      final ProductCreationAttempt retry = store.begin(
        ownerUserId: 'admin-1',
        draft: coffee,
      );

      expect(store.unresolvedFor('admin-1'), coffee);
      expect(store.unresolvedFor('admin-2'), isNull);
      expect(retry.revision, greaterThan(first.revision));
      expect(
        () => store.begin(ownerUserId: 'admin-1', draft: tea),
        throwsA(isA<ProductCreationUnresolvedException>()),
      );
    });

    test('stale completion cannot clear a newer attempt or request', () {
      final ProductCreationDraftStore store = ProductCreationDraftStore();
      final ProductCreationAttempt oldAttempt = store.begin(
        ownerUserId: 'admin-1',
        draft: coffee,
      );
      final ProductCreationAttempt retry = store.begin(
        ownerUserId: 'admin-1',
        draft: coffee,
      );

      expect(store.resolve(oldAttempt), isFalse);
      expect(store.unresolvedFor('admin-1'), coffee);
      expect(store.resolve(retry), isTrue);
      expect(store.unresolvedFor('admin-1'), isNull);

      final ProductCreationAttempt newRequest = store.begin(
        ownerUserId: 'admin-1',
        draft: tea,
      );
      store.retain(oldAttempt);
      expect(store.unresolvedFor('admin-1'), tea);
      expect(store.resolve(oldAttempt), isFalse);
      expect(store.resolve(newRequest), isTrue);
    });
  });

  group('ProductCreationCoordinator', () {
    test('uncertain retry retains the identical UUID and payload', () async {
      final List<ProductCreationDraft> attempts = <ProductCreationDraft>[];
      var calls = 0;
      final ProductCreationCoordinator coordinator = ProductCreationCoordinator(
        createIdempotencyKey: () => 'draft-key-1',
        submitRequest: (ProductCreationDraft draft) async {
          attempts.add(draft);
          calls += 1;
          if (calls == 1) throw const ProductCreationUncertainException();
          return const ProductCreationResult(
            productId: 'PRD-COFFEE-001',
            internalCode: 'PRD-COFFEE-001',
            replayed: true,
          );
        },
      );

      await expectLater(
        coordinator.submit(name: 'Coffee', unit: 'piece', precision: 0),
        throwsA(isA<ProductCreationUncertainException>()),
      );
      expect(coordinator.isLocked, isTrue);
      expect(coordinator.lockedDraft, same(attempts.single));

      final ProductCreationResult result = await coordinator.retry();

      expect(result.replayed, isTrue);
      expect(attempts, hasLength(2));
      expect(attempts[1], same(attempts[0]));
    });

    test(
      'cancelling presentation preserves an unresolved locked draft',
      () async {
        final ProductCreationCoordinator coordinator =
            ProductCreationCoordinator(
              createIdempotencyKey: () => 'draft-key-1',
              submitRequest: (_) =>
                  throw const ProductCreationUncertainException(),
            );

        await expectLater(
          coordinator.submit(name: 'Coffee', unit: 'piece', precision: 0),
          throwsA(isA<ProductCreationUncertainException>()),
        );
        coordinator.closePresentation();

        expect(coordinator.isLocked, isTrue);
        expect(coordinator.currentIdempotencyKey, 'draft-key-1');
        expect(coordinator.lockedDraft?.name, 'Coffee');
      },
    );

    test('restored uncertainty blocks a new key until resolved', () async {
      const ProductCreationDraft restored = ProductCreationDraft(
        idempotencyKey: 'draft-key-1',
        name: 'Coffee',
        unit: 'piece',
        precision: 0,
      );
      var keyCalls = 0;
      final List<ProductCreationDraft> attempts = <ProductCreationDraft>[];
      final ProductCreationCoordinator coordinator = ProductCreationCoordinator(
        createIdempotencyKey: () {
          keyCalls += 1;
          return 'draft-key-2';
        },
        restoredDraft: restored,
        submitRequest: (ProductCreationDraft draft) async {
          attempts.add(draft);
          return const ProductCreationResult(
            productId: 'PRD-COFFEE-001',
            internalCode: 'PRD-COFFEE-001',
            replayed: true,
          );
        },
      );

      expect(coordinator.isLocked, isTrue);
      expect(coordinator.currentIdempotencyKey, 'draft-key-1');
      expect(keyCalls, 0);
      await expectLater(
        coordinator.submit(name: 'Tea', unit: 'piece', precision: 0),
        throwsA(isA<StateError>()),
      );

      await coordinator.retry();

      expect(attempts, <ProductCreationDraft>[restored]);
      expect(coordinator.isLocked, isFalse);
      expect(coordinator.currentIdempotencyKey, 'draft-key-2');
      expect(keyCalls, 1);
    });

    test('success advances to one new v4 draft key', () async {
      final List<String> keys = <String>['draft-key-1', 'draft-key-2'];
      final ProductCreationCoordinator coordinator = ProductCreationCoordinator(
        createIdempotencyKey: () => keys.removeAt(0),
        submitRequest: (_) async => const ProductCreationResult(
          productId: 'PRD-COFFEE-001',
          internalCode: 'PRD-COFFEE-001',
          replayed: false,
        ),
      );

      await coordinator.submit(name: 'Coffee', unit: 'piece', precision: 0);

      expect(coordinator.currentIdempotencyKey, 'draft-key-2');
      expect(coordinator.isLocked, isFalse);
    });

    test('pending guard prevents duplicate mutation calls', () async {
      final Completer<ProductCreationResult> pending =
          Completer<ProductCreationResult>();
      var calls = 0;
      final ProductCreationCoordinator coordinator = ProductCreationCoordinator(
        createIdempotencyKey: () => 'draft-key-1',
        submitRequest: (_) {
          calls += 1;
          return pending.future;
        },
      );

      final Future<ProductCreationResult> first = coordinator.submit(
        name: 'Coffee',
        unit: 'piece',
        precision: 0,
      );
      await expectLater(
        coordinator.submit(name: 'Tea', unit: 'piece', precision: 0),
        throwsA(isA<StateError>()),
      );
      expect(calls, 1);
      pending.complete(
        const ProductCreationResult(
          productId: 'PRD-COFFEE-001',
          internalCode: 'PRD-COFFEE-001',
          replayed: false,
        ),
      );
      await first;
    });
  });

  test('secure draft keys are RFC 4122 version 4 UUIDs', () {
    final Set<String> keys = <String>{
      for (var index = 0; index < 20; index += 1) createProductDraftUuidV4(),
    };
    expect(keys, hasLength(20));
    for (final String key in keys) {
      expect(
        key,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    }
  });

  test('validation messages are shown to users in Spanish', () {
    expect(
      const ProductCreationDraft(
        idempotencyKey: 'valid-key',
        name: 'Coffee',
        unit: 'piece',
        precision: 7,
      ).validate,
      throwsA(
        isA<ProductCreationValidationException>().having(
          (ProductCreationValidationException error) => error.message,
          'message',
          'La precisión debe ser un entero del 0 al 6.',
        ),
      ),
    );
  });
}
