import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';

import 'movement_fixtures.dart';

class _FakeSource implements MovementReadSource {
  final List<String> events = <String>[];
  List<CatalogDocument> movements = <CatalogDocument>[];
  Map<String, Object?> documents = <String, Object?>{};
  Object? queryError;

  @override
  Future<List<CatalogDocument>> queryMovements({
    String? branchId,
    required int limit,
  }) async {
    events.add('query:${branchId ?? '*'}:$limit');
    if (queryError case final Object error) throw error;
    return movements;
  }

  @override
  Future<CatalogDocument?> findDocument(String path) async {
    events.add('get:$path');
    final Object? value = documents[path];
    if (value is Exception) throw value;
    if (value == null) return null;
    return CatalogDocument(path: path, data: value as Map<String, Object?>);
  }
}

void main() {
  late _FakeSource source;
  late EmulatorSession? current;
  late FirestoreMovementRepository repository;

  setUp(() {
    source = _FakeSource();
    current = movementsAdministrator;
    repository = FirestoreMovementRepository(
      source: source,
      session: movementsAdministrator,
      sessionChecker: () async {
        source.events.add('session');
        return current;
      },
    );
  });

  test(
    'queries newest 50, optionally filtered, inside session checks',
    () async {
      source.movements = <CatalogDocument>[
        CatalogDocument(path: 'inventoryMovements/m-1', data: movementData()),
        CatalogDocument(
          path: 'inventoryMovements/m-2',
          data: movementData(type: 'bogus'),
        ),
      ];
      final List<MovementEntry> all = await repository.recentMovements();
      expect(all.map((MovementEntry e) => e.runtimeType), <Type>[
        InventoryMovement,
        UnreadableMovement,
      ]);
      expect(source.events, <String>['session', 'query:*:50', 'session']);

      source.events.clear();
      await repository.recentMovements(branchId: 'branch-south');
      expect(source.events, <String>[
        'session',
        'query:branch-south:50',
        'session',
      ]);
    },
  );

  test('a row from another branch under a filter is unreadable', () async {
    source.movements = <CatalogDocument>[
      CatalogDocument(path: 'inventoryMovements/m-1', data: movementData()),
    ];
    final List<MovementEntry> entries = await repository.recentMovements(
      branchId: 'branch-south',
    );
    expect(entries.single, isA<UnreadableMovement>());
  });

  test('rejects a non-administrator or lost session and bad filters', () async {
    current = movementsSeller;
    await expectLater(
      repository.recentMovements(),
      throwsA(isA<MovementsUnavailable>()),
    );
    current = movementsAdministrator;
    await expectLater(
      repository.recentMovements(branchId: 'north'),
      throwsA(isA<MovementsUnavailable>()),
    );
    expect(source.events.where((String e) => e.startsWith('query')), isEmpty);
  });

  test('profile lookups: named, missing, denied, failing, malformed', () async {
    source.documents = <String, Object?>{
      'sellerProfiles/a': <String, Object?>{
        'displayName': 'Ana',
        'branchId': 'branch-north',
      },
      'sellerProfiles/c': FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      ),
      'sellerProfiles/d': FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
      ),
      'sellerProfiles/e': <String, Object?>{
        'displayName': 'Ana',
        'branchId': 'branch-north',
        'phone': '555',
      },
      'sellerProfiles/f': <String, Object?>{'displayName': 'Ana'},
    };
    expect(await repository.sellerProfile('a'), const SellerNamed('Ana'));
    expect(await repository.sellerProfile('b'), const SellerUnnamed());
    expect(
      await repository.sellerProfile('c'),
      const SellerProfileUnavailable(denied: true),
    );
    expect(
      await repository.sellerProfile('d'),
      const SellerProfileUnavailable(),
    );
    expect(
      await repository.sellerProfile('e'),
      const SellerProfileUnavailable(),
    );
    expect(
      await repository.sellerProfile('f'),
      const SellerProfileUnavailable(),
    );
    expect(source.events.where((String e) => e.startsWith('get')), <String>[
      for (final String id in <String>['a', 'b', 'c', 'd', 'e', 'f'])
        'get:sellerProfiles/$id',
    ]);

    current = null;
    expect(
      await repository.sellerProfile('a'),
      const SellerProfileUnavailable(),
    );
  });

  test('a failed query keeps its cause and stack trace', () async {
    final FirebaseException missingIndex = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'failed-precondition',
    );
    source.queryError = missingIndex;
    final Object? error = await repository.recentMovements().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    expect(error, isA<MovementsUnavailable>());
    final MovementsUnavailable unavailable = error! as MovementsUnavailable;
    expect(unavailable.cause, same(missingIndex));
    expect(unavailable.stackTrace, isNotNull);
  });

  test('a branch-scoped expected session is never the administrator', () async {
    const EmulatorSession scoped = EmulatorSession(
      userId: 'administrator-1',
      email: 'admin@demo.invalid',
      role: InventoryRole.administrator,
      branchId: 'branch-north',
    );
    // The live session is the exact administrator; the expected one is not.
    repository = FirestoreMovementRepository(
      source: source,
      session: scoped,
      sessionChecker: () async => current,
    );
    source.documents = <String, Object?>{
      'sellerProfiles/a': <String, Object?>{
        'displayName': 'Ana',
        'branchId': 'branch-north',
      },
    };
    await expectLater(
      repository.recentMovements(),
      throwsA(isA<MovementsUnavailable>()),
    );
    expect(
      await repository.sellerProfile('a'),
      const SellerProfileUnavailable(),
    );
    expect(source.events, isEmpty);
  });
}
