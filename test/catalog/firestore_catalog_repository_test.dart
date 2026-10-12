import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_load_diagnostics.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';

class _FakeCatalogReadSource implements CatalogReadSource {
  _FakeCatalogReadSource({
    this.collections = const <String, List<CatalogDocument>>{},
    this.documents = const <String, CatalogDocument>{},
    this.collectionGroups = const <String, List<CatalogDocument>>{},
    this.onListCollection,
    this.onGetDocument,
  });

  final Map<String, List<CatalogDocument>> collections;
  final Map<String, CatalogDocument> documents;
  final Map<String, List<CatalogDocument>> collectionGroups;
  final void Function(String path)? onListCollection;
  final void Function(String path)? onGetDocument;
  final List<String> calls = <String>[];

  @override
  Future<CatalogDocument> getDocument(String path) async {
    calls.add('get:$path');
    onGetDocument?.call(path);
    final CatalogDocument? document = documents[path];
    if (document == null) throw StateError('missing test document');
    return document;
  }

  @override
  Future<List<CatalogDocument>> listCollection(String path) async {
    calls.add('list:$path');
    onListCollection?.call(path);
    return collections[path] ?? const <CatalogDocument>[];
  }

  @override
  Future<List<CatalogDocument>> listCollectionGroup(String collectionId) async {
    calls.add('group:$collectionId');
    return collectionGroups[collectionId] ?? const <CatalogDocument>[];
  }
}

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

const EmulatorSession _administrator = EmulatorSession(
  userId: 'admin-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);

Map<String, Object?> _product({
  String code = 'DEMO-RIBBON',
  String unit = 'meter',
  int precision = 2,
}) => <String, Object?>{
  'internalCode': code,
  'name': 'Demo Ribbon',
  'quantitySpec': <String, Object?>{'unit': unit, 'precision': precision},
  'pricing': <String, Object?>{
    'listedPriceCentavos': 4500,
    'currency': 'MXN',
    'priceMode': 'iva-additional-on-invoice',
    'ivaTreatment': 'taxable',
    'ivaRateBasisPoints': 1600,
  },
};

Map<String, Object?> _stock({
  int quantityScaled = 0,
  String unit = 'meter',
  int precision = 2,
}) => <String, Object?>{
  'quantityScaled': quantityScaled,
  'unit': unit,
  'precision': precision,
  'demoSeedVersion': 1,
};

// inventory.js transaction.set(stockReference) replaces the projection with
// these five fields. Firestore decodes the server Date as an SDK Timestamp.
Map<String, Object?> _intakeStock() => <String, Object?>{
  'quantityScaled': 425,
  'unit': 'meter',
  'precision': 2,
  'updatedAt': Timestamp(1790208000, 123000000),
  'lastMovementId': '550e8400-e29b-41d4-a716-446655440000',
};

_FakeCatalogReadSource _intakeSource(
  InventoryRole role,
  List<CatalogDocument> stock,
) => _FakeCatalogReadSource(
  collections: <String, List<CatalogDocument>>{
    if (role == InventoryRole.seller) 'branches/branch-north/stock': stock,
    if (role == InventoryRole.administrator) ...<String, List<CatalogDocument>>{
      'products': <CatalogDocument>[
        CatalogDocument(path: 'products/DEMO-RIBBON', data: _product()),
      ],
      'branches': const <CatalogDocument>[
        CatalogDocument(
          path: 'branches/branch-north',
          data: <String, Object?>{'name': 'North Demo Branch'},
        ),
      ],
    },
  },
  documents: <String, CatalogDocument>{
    'products/DEMO-RIBBON': CatalogDocument(
      path: 'products/DEMO-RIBBON',
      data: _product(),
    ),
  },
  collectionGroups: <String, List<CatalogDocument>>{
    if (role == InventoryRole.administrator) 'stock': stock,
  },
);

FirestoreCatalogRepository _intakeRepository(
  InventoryRole role,
  _FakeCatalogReadSource source,
) => role == InventoryRole.seller
    ? FirestoreCatalogRepository.seller(
        source: source,
        session: _seller,
        sessionChecker: () async => _seller,
      )
    : FirestoreCatalogRepository.administrator(
        source: source,
        session: _administrator,
        sessionChecker: () async => _administrator,
      );

Map<String, Object?> _cost() => <String, Object?>{
  'latestUnitCostCentavos': 0,
  'currency': 'MXN',
  'sourceEntryId': 'A_entry-1',
  'updatedAt': Timestamp(0, 0),
};

void main() {
  group('administrator latest unit cost metadata', () {
    _FakeCatalogReadSource sourceFor(
      List<CatalogDocument> costs, {
      void Function(String)? onRead,
    }) => _FakeCatalogReadSource(
      collections: <String, List<CatalogDocument>>{
        'products': <CatalogDocument>[
          CatalogDocument(path: 'products/DEMO-RIBBON', data: _product()),
        ],
        'costs': costs,
        'branches': const <CatalogDocument>[
          CatalogDocument(
            path: 'branches/branch-north',
            data: <String, Object?>{'name': 'North Demo Branch'},
          ),
        ],
      },
      collectionGroups: <String, List<CatalogDocument>>{
        'stock': <CatalogDocument>[
          CatalogDocument(
            path: 'branches/branch-north/stock/DEMO-RIBBON',
            data: _intakeStock(),
          ),
        ],
      },
      onListCollection: onRead,
    );
    CatalogDocument document(
      Map<String, Object?> data, [
      String path = 'costs/DEMO-RIBBON',
    ]) => CatalogDocument(path: path, data: data);

    test(
      'one global read maps exact zero and safe upper bound immutably',
      () async {
        for (final int cents in <int>[0, 9007199254740991]) {
          final source = sourceFor(<CatalogDocument>[
            document(<String, Object?>{
              ..._cost(),
              'latestUnitCostCentavos': cents,
            }),
          ]);
          final catalog = await _intakeRepository(
            InventoryRole.administrator,
            source,
          ).fetchCatalog();
          expect(source.calls, <String>[
            'list:products',
            'list:branches',
            'group:stock',
            'list:costs',
          ]);
          expect(catalog.costsAvailable, isTrue);
          final cost = catalog.costs['DEMO-RIBBON']!;
          expect(cost.productId, 'DEMO-RIBBON');
          expect(cost.latestUnitCostCentavos, cents);
          expect(cost.currency, 'MXN');
          expect(cost.sourceEntryId, 'A_entry-1');
          expect(cost.updatedAt, Timestamp(0, 0));
          expect(() => catalog.costs.clear(), throwsUnsupportedError);
        }
      },
    );
    test('successful absence differs from transient unavailable', () async {
      for (final String? code in <String?>[
        null,
        'unavailable',
        'deadline-exceeded',
      ]) {
        bool refreshed = false;
        final source = sourceFor(
          <CatalogDocument>[document(_cost())],
          onRead: (String path) {
            if (refreshed && path == 'costs' && code != null) {
              throw FirebaseException(plugin: 'cloud_firestore', code: code);
            }
          },
        );
        final repository = _intakeRepository(
          InventoryRole.administrator,
          source,
        );
        expect((await repository.fetchCatalog()).costs, hasLength(1));
        refreshed = true;
        source.collections['costs'] = <CatalogDocument>[];
        final catalog = await repository.fetchCatalog();
        expect(catalog.items, hasLength(1));
        expect(catalog.items.single.holdings.single.quantityScaled, 425);
        expect(catalog.branchChoices.single.branchId, 'branch-north');
        expect(catalog.items.single.product.toSafeFields(), _product());
        expect(catalog.costs, isEmpty);
        expect(catalog.costsAvailable, code == null);
      }
    });
    test('malformed private documents always fail closed', () async {
      final invalid = <CatalogDocument>[
        for (final String key in _cost().keys)
          document(Map<String, Object?>.of(_cost())..remove(key)),
        document(<String, Object?>{..._cost(), 'extra': null}),
        for (final Object? value in <Object?>[
          null,
          -1,
          9007199254740992,
          1.0,
          '0',
        ])
          document(<String, Object?>{
            ..._cost(),
            'latestUnitCostCentavos': value,
          }),
        for (final Object? value in <Object?>[null, 'USD', 'mxn'])
          document(<String, Object?>{..._cost(), 'currency': value}),
        for (final Object? value in <Object?>[
          null,
          1,
          '',
          '_entry',
          'entry/id',
          ' entry',
          'entry\n',
          List<String>.filled(129, 'A').join(),
        ])
          document(<String, Object?>{..._cost(), 'sourceEntryId': value}),
        for (final Object? value in <Object?>[
          null,
          0,
          'timestamp',
          DateTime.utc(2026),
        ])
          document(<String, Object?>{..._cost(), 'updatedAt': value}),
        for (final String path in <String>[
          'other/DEMO-RIBBON',
          'costs/DEMO-RIBBON/nested/id',
          'costs/',
          'costs/demo-ribbon',
          'costs/DEMO-ORPHAN',
        ])
          document(_cost(), path),
      ];
      for (final List<CatalogDocument> documents in <List<CatalogDocument>>[
        for (final CatalogDocument cost in invalid) <CatalogDocument>[cost],
        <CatalogDocument>[document(_cost()), document(_cost())],
      ]) {
        await expectLater(
          _intakeRepository(
            InventoryRole.administrator,
            sourceFor(documents),
          ).fetchCatalog(),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );
      }
    });
    test(
      'nontransport errors and session-checker errors never degrade',
      () async {
        for (final Object error in <Object>[
          StateError('unknown'),
          for (final String code in <String>[
            'unauthenticated',
            'permission-denied',
            'internal',
            'unknown',
          ])
            FirebaseException(plugin: 'cloud_firestore', code: code),
          FirebaseException(plugin: 'firebase_auth', code: 'unavailable'),
        ]) {
          await expectLater(
            _intakeRepository(
              InventoryRole.administrator,
              sourceFor(
                <CatalogDocument>[],
                onRead: (String path) {
                  if (path == 'costs') throw error;
                },
              ),
            ).fetchCatalog(),
            throwsA(isA<CatalogRepositoryUnavailable>()),
          );
        }
        final source = sourceFor(<CatalogDocument>[]);
        await expectLater(
          FirestoreCatalogRepository.administrator(
            source: source,
            session: _administrator,
            sessionChecker: () async {
              if (source.calls.contains('group:stock')) {
                throw FirebaseException(
                  plugin: 'cloud_firestore',
                  code: 'unavailable',
                );
              }
              return _administrator;
            },
          ).fetchCatalog(),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );
        expect(source.calls, isNot(contains('list:costs')));
      },
    );
    test(
      'late success and outage reject logout role and actor drift',
      () async {
        for (final EmulatorSession? replacement in <EmulatorSession?>[
          null,
          _seller,
          const EmulatorSession(
            userId: 'admin-1',
            email: 'admin@demo.invalid',
            role: InventoryRole.administrator,
            branchId: 'branch-north',
          ),
          const EmulatorSession(
            userId: 'other',
            email: 'other@demo.invalid',
            role: InventoryRole.administrator,
          ),
        ]) {
          for (final bool outage in <bool>[false, true]) {
            EmulatorSession? active = _administrator;
            final source = sourceFor(
              <CatalogDocument>[document(_cost())],
              onRead: (String path) {
                if (path != 'costs') return;
                active = replacement;
                if (outage) {
                  throw FirebaseException(
                    plugin: 'cloud_firestore',
                    code: 'unavailable',
                  );
                }
              },
            );
            await expectLater(
              FirestoreCatalogRepository.administrator(
                source: source,
                session: _administrator,
                sessionChecker: () async => active,
              ).fetchCatalog(),
              throwsA(isA<CatalogRepositoryUnavailable>()),
            );
          }
        }
      },
    );
    test('seller never reads costs or receives private metadata', () async {
      final source = _intakeSource(InventoryRole.seller, <CatalogDocument>[]);
      final catalog = await _intakeRepository(
        InventoryRole.seller,
        source,
      ).fetchCatalog();
      expect(source.calls, <String>['list:branches/branch-north/stock']);
      expect(catalog.costs, isEmpty);
      expect(catalog.costsAvailable, isFalse);
    });
  });
  group('server-written intake stock', () {
    for (final InventoryRole role in InventoryRole.values) {
      test(
        '${role.name} preserves optional metadata and identifier bounds',
        () async {
          final Map<String, Object?> legacy = <String, Object?>{
            'quantityScaled': 0,
            'unit': 'meter',
            'precision': 2,
          };
          for (final Map<String, Object?> data in <Map<String, Object?>>[
            legacy,
            _stock(),
            <String, Object?>{...legacy, 'updatedAt': Timestamp(0, 0)},
            <String, Object?>{...legacy, 'lastMovementId': 'A'},
            <String, Object?>{
              ..._intakeStock(),
              'quantityScaled': 9007199254740991,
              'lastMovementId': 'A${List<String>.filled(127, '_').join()}',
            },
          ]) {
            final CatalogSnapshot catalog = await _intakeRepository(
              role,
              _intakeSource(role, <CatalogDocument>[
                CatalogDocument(
                  path: 'branches/branch-north/stock/DEMO-RIBBON',
                  data: data,
                ),
              ]),
            ).fetchCatalog();
            expect(
              catalog.items.single.holdings.single.quantityScaled,
              data['quantityScaled'],
            );
          }
        },
      );

      test(
        '${role.name} rejects invalid metadata and protected fields',
        () async {
          final List<Map<String, Object?>> invalid = <Map<String, Object?>>[
            for (final Object? value in <Object?>[
              null,
              '2026-09-24T00:00:00Z',
              1790208000,
              DateTime.utc(2026),
              <String, Object?>{'seconds': 1790208000, 'nanoseconds': 0},
            ])
              <String, Object?>{..._intakeStock(), 'updatedAt': value},
            for (final Object? value in <Object?>[
              null,
              1,
              <String, Object?>{'id': 'movement-1'},
              '',
              '_movement',
              '-movement',
              'movement/id',
              ' movement',
              'movement ',
              'movement\n',
              List<String>.filled(129, 'A').join(),
            ])
              <String, Object?>{..._intakeStock(), 'lastMovementId': value},
            for (final String field in <String>[
              'actorId',
              'createdBy',
              'unitCostCentavos',
              'cost',
              'unknown',
            ])
              <String, Object?>{..._intakeStock(), field: 'protected'},
            <String, Object?>{..._intakeStock(), 'quantityScaled': -1},
            <String, Object?>{
              ..._intakeStock(),
              'quantityScaled': 9007199254740992,
            },
            <String, Object?>{..._intakeStock(), 'quantityScaled': 425.0},
            <String, Object?>{..._intakeStock(), 'unit': 'piece'},
            <String, Object?>{..._intakeStock(), 'precision': 3},
          ];
          for (final Map<String, Object?> data in invalid) {
            await expectLater(
              _intakeRepository(
                role,
                _intakeSource(role, <CatalogDocument>[
                  CatalogDocument(
                    path: 'branches/branch-north/stock/DEMO-RIBBON',
                    data: data,
                  ),
                ]),
              ).fetchCatalog(),
              throwsA(isA<CatalogRepositoryUnavailable>()),
              reason: 'Invalid server projection: $data',
            );
          }
        },
      );

      test(
        '${role.name} retains stock path and duplicate guards with metadata',
        () async {
          for (final List<String> paths in <List<String>>[
            <String>['branches/branch-south/stock/DEMO-RIBBON'],
            <String>['branches/branch-north/stock/DEMO-MISSING'],
            <String>['other/branch-north/stock/DEMO-RIBBON'],
            <String>[
              'branches/branch-north/stock/DEMO-RIBBON',
              'branches/branch-north/stock/DEMO-RIBBON',
            ],
          ]) {
            final _FakeCatalogReadSource source = _intakeSource(
              role,
              paths
                  .map(
                    (String path) =>
                        CatalogDocument(path: path, data: _intakeStock()),
                  )
                  .toList(),
            );
            await expectLater(
              _intakeRepository(role, source).fetchCatalog(),
              throwsA(isA<CatalogRepositoryUnavailable>()),
            );
            if (role == InventoryRole.seller &&
                !paths.any((String path) => path.endsWith('DEMO-MISSING'))) {
              expect(source.calls, <String>[
                'list:branches/branch-north/stock',
              ]);
            }
          }
        },
      );

      test('${role.name} loads server-written intake stock safely', () async {
        final _FakeCatalogReadSource source = _intakeSource(
          role,
          <CatalogDocument>[
            CatalogDocument(
              path: 'branches/branch-north/stock/DEMO-RIBBON',
              data: _intakeStock(),
            ),
          ],
        );
        final CatalogSnapshot catalog = await _intakeRepository(
          role,
          source,
        ).fetchCatalog();
        expect(catalog.items, hasLength(1));
        final CatalogHolding holding = catalog.items.single.holdings.single;
        expect(holding.branchId, 'branch-north');
        expect(holding.quantityScaled, 425);
        expect(
          holding.branchName,
          role == InventoryRole.seller ? null : 'North Demo Branch',
        );
        expect(catalog.items.single.product.toSafeFields(), _product());
        expect(
          catalog.branchChoices,
          role == InventoryRole.seller ? isEmpty : hasLength(1),
        );
        expect(
          source.calls,
          role == InventoryRole.seller
              ? <String>[
                  'list:branches/branch-north/stock',
                  'get:products/DEMO-RIBBON',
                ]
              : <String>[
                  'list:products',
                  'list:branches',
                  'group:stock',
                  'list:costs',
                ],
        );
      });
    }
  });

  group('seller catalog', () {
    test('lists only assigned stock then gets products individually', () async {
      final _FakeCatalogReadSource source = _FakeCatalogReadSource(
        collections: <String, List<CatalogDocument>>{
          'branches/branch-north/stock': <CatalogDocument>[
            CatalogDocument(
              path: 'branches/branch-north/stock/DEMO-RIBBON',
              data: _stock(),
            ),
          ],
        },
        documents: <String, CatalogDocument>{
          'products/DEMO-RIBBON': CatalogDocument(
            path: 'products/DEMO-RIBBON',
            data: _product(),
          ),
        },
      );

      final CatalogSnapshot catalog = await FirestoreCatalogRepository.seller(
        source: source,
        session: _seller,
        sessionChecker: () async => _seller,
      ).fetchCatalog();

      expect(source.calls, <String>[
        'list:branches/branch-north/stock',
        'get:products/DEMO-RIBBON',
      ]);
      expect(catalog.items, hasLength(1));
      expect(catalog.items.single.product.internalCode, 'DEMO-RIBBON');
      expect(catalog.items.single.holdings.single.quantityScaled, 0);
      expect(catalog.items.single.holdings.single.isOutOfStock, isTrue);
      expect(catalog.branchChoices, isEmpty);
    });

    test('rejects an unvalidated seller branch before reads', () async {
      final _FakeCatalogReadSource source = _FakeCatalogReadSource();
      const EmulatorSession invalid = EmulatorSession(
        userId: 'seller-1',
        email: 'seller@demo.invalid',
        role: InventoryRole.seller,
        branchId: '../branches/branch-south',
      );

      await expectLater(
        FirestoreCatalogRepository.seller(
          source: source,
          session: invalid,
          sessionChecker: () async => invalid,
        ).fetchCatalog(),
        throwsA(isA<CatalogRepositoryUnavailable>()),
      );
      expect(source.calls, isEmpty);
    });
  });

  group('session binding', () {
    test(
      'rejects a reused seller repository after logout without reading',
      () async {
        EmulatorSession? currentSession = _seller;
        final _FakeCatalogReadSource source = _FakeCatalogReadSource();
        final FirestoreCatalogRepository repository =
            FirestoreCatalogRepository.seller(
              source: source,
              session: _seller,
              sessionChecker: () async => currentSession,
            );

        await repository.fetchCatalog();
        expect(source.calls, <String>['list:branches/branch-north/stock']);

        currentSession = null;
        await expectLater(
          repository.fetchCatalog(),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );
        expect(source.calls, <String>['list:branches/branch-north/stock']);
      },
    );

    test(
      'invalidates a read when the same user claims change across an await',
      () async {
        EmulatorSession? currentSession = _seller;
        final _FakeCatalogReadSource source = _FakeCatalogReadSource(
          collections: <String, List<CatalogDocument>>{
            'branches/branch-north/stock': <CatalogDocument>[
              CatalogDocument(
                path: 'branches/branch-north/stock/DEMO-RIBBON',
                data: _stock(),
              ),
            ],
          },
          onListCollection: (_) {
            currentSession = const EmulatorSession(
              userId: 'seller-1',
              email: 'seller@demo.invalid',
              role: InventoryRole.seller,
              branchId: 'branch-south',
            );
          },
        );

        await expectLater(
          FirestoreCatalogRepository.seller(
            source: source,
            session: _seller,
            sessionChecker: () async => currentSession,
          ).fetchCatalog(),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );
        expect(source.calls, <String>['list:branches/branch-north/stock']);
      },
    );

    test('invalidates an in-flight product read after logout', () async {
      EmulatorSession? currentSession = _seller;
      final _FakeCatalogReadSource source = _FakeCatalogReadSource(
        collections: <String, List<CatalogDocument>>{
          'branches/branch-north/stock': <CatalogDocument>[
            CatalogDocument(
              path: 'branches/branch-north/stock/DEMO-RIBBON',
              data: _stock(),
            ),
          ],
        },
        documents: <String, CatalogDocument>{
          'products/DEMO-RIBBON': CatalogDocument(
            path: 'products/DEMO-RIBBON',
            data: _product(),
          ),
        },
        onGetDocument: (_) => currentSession = null,
      );

      await expectLater(
        FirestoreCatalogRepository.seller(
          source: source,
          session: _seller,
          sessionChecker: () async => currentSession,
        ).fetchCatalog(),
        throwsA(isA<CatalogRepositoryUnavailable>()),
      );
      expect(source.calls, <String>[
        'list:branches/branch-north/stock',
        'get:products/DEMO-RIBBON',
      ]);
    });

    test(
      'invalidates a seller read when claims switch to administrator',
      () async {
        EmulatorSession? currentSession = _seller;
        final _FakeCatalogReadSource source = _FakeCatalogReadSource(
          onListCollection: (_) => currentSession = const EmulatorSession(
            userId: 'seller-1',
            email: 'seller@demo.invalid',
            role: InventoryRole.administrator,
          ),
        );

        await expectLater(
          FirestoreCatalogRepository.seller(
            source: source,
            session: _seller,
            sessionChecker: () async => currentSession,
          ).fetchCatalog(),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );
        expect(source.calls, <String>['list:branches/branch-north/stock']);
      },
    );
  });

  group('administrator catalog', () {
    test('correlates global products, branches, and stock holdings', () async {
      final _FakeCatalogReadSource source = _FakeCatalogReadSource(
        collections: <String, List<CatalogDocument>>{
          'products': <CatalogDocument>[
            CatalogDocument(path: 'products/DEMO-RIBBON', data: _product()),
            CatalogDocument(
              path: 'products/DEMO-UNHELD',
              data: _product(code: 'DEMO-UNHELD', unit: 'piece', precision: 0),
            ),
          ],
          'branches': const <CatalogDocument>[
            CatalogDocument(
              path: 'branches/branch-north',
              data: <String, Object?>{
                'name': 'North Demo Branch',
                'demoSeedVersion': 1,
              },
            ),
          ],
        },
        collectionGroups: <String, List<CatalogDocument>>{
          'stock': <CatalogDocument>[
            CatalogDocument(
              path: 'branches/branch-north/stock/DEMO-RIBBON',
              data: _stock(quantityScaled: 425),
            ),
          ],
        },
      );

      final CatalogSnapshot catalog =
          await FirestoreCatalogRepository.administrator(
            source: source,
            session: _administrator,
            sessionChecker: () async => _administrator,
          ).fetchCatalog();

      expect(source.calls, <String>[
        'list:products',
        'list:branches',
        'group:stock',
        'list:costs',
      ]);
      expect(catalog.items, hasLength(2));
      expect(
        catalog.items
            .singleWhere((item) => item.product.internalCode == 'DEMO-RIBBON')
            .holdings
            .single
            .branchName,
        'North Demo Branch',
      );
      expect(
        catalog.items
            .singleWhere((item) => item.product.internalCode == 'DEMO-UNHELD')
            .holdings,
        isEmpty,
      );
    });

    test(
      'exposes every branch as a choice, including branches without stock',
      () async {
        final _FakeCatalogReadSource source = _FakeCatalogReadSource(
          collections: <String, List<CatalogDocument>>{
            'products': <CatalogDocument>[
              CatalogDocument(path: 'products/DEMO-RIBBON', data: _product()),
            ],
            'branches': const <CatalogDocument>[
              CatalogDocument(
                path: 'branches/branch-south',
                data: <String, Object?>{
                  'name': 'South Demo Branch',
                  'demoSeedVersion': 1,
                },
              ),
              CatalogDocument(
                path: 'branches/branch-north',
                data: <String, Object?>{
                  'name': 'North Demo Branch',
                  'demoSeedVersion': 1,
                },
              ),
              CatalogDocument(
                path: 'branches/branch-east',
                data: <String, Object?>{
                  'name': 'East Demo Branch',
                  'demoSeedVersion': 1,
                },
              ),
            ],
          },
          collectionGroups: <String, List<CatalogDocument>>{
            'stock': <CatalogDocument>[
              CatalogDocument(
                path: 'branches/branch-north/stock/DEMO-RIBBON',
                data: _stock(quantityScaled: 425),
              ),
            ],
          },
        );

        final CatalogSnapshot catalog =
            await FirestoreCatalogRepository.administrator(
              source: source,
              session: _administrator,
              sessionChecker: () async => _administrator,
            ).fetchCatalog();

        expect(source.calls, <String>[
          'list:products',
          'list:branches',
          'group:stock',
          'list:costs',
        ]);
        expect(
          catalog.branchChoices
              .map((choice) => choice.branchId)
              .toList(growable: false),
          <String>['branch-east', 'branch-north', 'branch-south'],
        );
        expect(
          catalog.branchChoices
              .map((choice) => choice.branchName)
              .toList(growable: false),
          <String>[
            'East Demo Branch',
            'North Demo Branch',
            'South Demo Branch',
          ],
        );
      },
    );

    test('rejects duplicate branch identifiers or names', () async {
      for (final List<CatalogDocument> branches in <List<CatalogDocument>>[
        const <CatalogDocument>[
          CatalogDocument(
            path: 'branches/branch-north',
            data: <String, Object?>{
              'name': 'North Demo Branch',
              'demoSeedVersion': 1,
            },
          ),
          CatalogDocument(
            path: 'branches/branch-north-2',
            data: <String, Object?>{
              'name': 'North Demo Branch',
              'demoSeedVersion': 1,
            },
          ),
        ],
        const <CatalogDocument>[
          CatalogDocument(
            path: 'branches/branch-north',
            data: <String, Object?>{
              'name': 'North Demo Branch',
              'demoSeedVersion': 1,
            },
          ),
          CatalogDocument(
            path: 'branches/branch-north',
            data: <String, Object?>{
              'name': 'North Branch Duplicate',
              'demoSeedVersion': 1,
            },
          ),
        ],
      ]) {
        final _FakeCatalogReadSource source = _FakeCatalogReadSource(
          collections: <String, List<CatalogDocument>>{
            'products': <CatalogDocument>[
              CatalogDocument(path: 'products/DEMO-RIBBON', data: _product()),
            ],
            'branches': branches,
          },
        );

        await expectLater(
          FirestoreCatalogRepository.administrator(
            source: source,
            session: _administrator,
            sessionChecker: () async => _administrator,
          ).fetchCatalog(),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );
      }
    });
  });

  group('fail-closed validation', () {
    test(
      'rejects malformed or legacy product fields without partial data',
      () async {
        for (final Map<String, Object?> product in <Map<String, Object?>>[
          <String, Object?>{..._product(), 'createdBy': 'legacy-admin'},
          <String, Object?>{..._product(), 'pricingUpdatedBy': 'legacy-admin'},
          <String, Object?>{..._product(), 'acquisitionCostCentavos': 100},
          <String, Object?>{..._product(), 'internalCode': 'OTHER-ID'},
        ]) {
          final _FakeCatalogReadSource source = _FakeCatalogReadSource(
            collections: <String, List<CatalogDocument>>{
              'products': <CatalogDocument>[
                CatalogDocument(path: 'products/DEMO-RIBBON', data: product),
              ],
              'branches': const <CatalogDocument>[],
            },
          );

          await expectLater(
            FirestoreCatalogRepository.administrator(
              source: source,
              session: _administrator,
              sessionChecker: () async => _administrator,
            ).fetchCatalog(),
            throwsA(
              isA<CatalogRepositoryUnavailable>().having(
                (error) => error.message,
                'message',
                'Catalog data is unavailable or invalid.',
              ),
            ),
          );
        }
      },
    );

    test('rejects orphan stock and unknown branches', () async {
      for (final String path in <String>[
        'branches/branch-missing/stock/DEMO-RIBBON',
        'branches/branch-north/stock/DEMO-MISSING',
      ]) {
        final _FakeCatalogReadSource source = _FakeCatalogReadSource(
          collections: <String, List<CatalogDocument>>{
            'products': <CatalogDocument>[
              CatalogDocument(path: 'products/DEMO-RIBBON', data: _product()),
            ],
            'branches': const <CatalogDocument>[
              CatalogDocument(
                path: 'branches/branch-north',
                data: <String, Object?>{'name': 'North Demo Branch'},
              ),
            ],
          },
          collectionGroups: <String, List<CatalogDocument>>{
            'stock': <CatalogDocument>[
              CatalogDocument(path: path, data: _stock()),
            ],
          },
        );

        await expectLater(
          FirestoreCatalogRepository.administrator(
            source: source,
            session: _administrator,
            sessionChecker: () async => _administrator,
          ).fetchCatalog(),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );
      }
    });

    test('rejects negative, unsafe, and mismatched stock quantities', () async {
      for (final Map<String, Object?> stock in <Map<String, Object?>>[
        _stock(quantityScaled: -1),
        _stock(quantityScaled: 9007199254740992),
        _stock(unit: 'piece'),
        _stock(precision: 3),
      ]) {
        final _FakeCatalogReadSource source = _FakeCatalogReadSource(
          collections: <String, List<CatalogDocument>>{
            'products': <CatalogDocument>[
              CatalogDocument(path: 'products/DEMO-RIBBON', data: _product()),
            ],
            'branches': const <CatalogDocument>[
              CatalogDocument(
                path: 'branches/branch-north',
                data: <String, Object?>{'name': 'North Demo Branch'},
              ),
            ],
          },
          collectionGroups: <String, List<CatalogDocument>>{
            'stock': <CatalogDocument>[
              CatalogDocument(
                path: 'branches/branch-north/stock/DEMO-RIBBON',
                data: stock,
              ),
            ],
          },
        );

        await expectLater(
          FirestoreCatalogRepository.administrator(
            source: source,
            session: _administrator,
            sessionChecker: () async => _administrator,
          ).fetchCatalog(),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );
      }
    });
  });

  group('branch code compatibility', () {
    // The read model has only branchId and branchName, so a parsed code can
    // never reach the UI; these tests keep that structural guarantee honest by
    // asserting the exact expected choices.
    Map<String, Object?> branchData(Object? code) => <String, Object?>{
      'name': 'North Demo Branch',
      'code': code,
      'demoSeedVersion': 1,
    };

    CatalogDocument branchDocument(String path, Map<String, Object?> data) =>
        CatalogDocument(path: path, data: data);

    Future<CatalogSnapshot> administratorCatalog(
      List<CatalogDocument> branches,
    ) async {
      final _FakeCatalogReadSource source = _FakeCatalogReadSource(
        collections: <String, List<CatalogDocument>>{
          'products': <CatalogDocument>[
            CatalogDocument(path: 'products/DEMO-RIBBON', data: _product()),
          ],
          'branches': branches,
        },
        collectionGroups: <String, List<CatalogDocument>>{
          'stock': <CatalogDocument>[
            CatalogDocument(
              path: 'branches/branch-north/stock/DEMO-RIBBON',
              data: _stock(quantityScaled: 425),
            ),
          ],
        },
      );
      return FirestoreCatalogRepository.administrator(
        source: source,
        session: _administrator,
        sessionChecker: () async => _administrator,
      ).fetchCatalog();
    }

    test('accepts the seeded demo branches that carry a folio code', () async {
      final CatalogSnapshot catalog = await administratorCatalog(
        <CatalogDocument>[
          branchDocument('branches/branch-north', <String, Object?>{
            'name': 'North Demo Branch',
            'code': 'NTE',
            'demoSeedVersion': 1,
          }),
          branchDocument('branches/branch-south', <String, Object?>{
            'name': 'South Demo Branch',
            'code': 'SUR',
            'demoSeedVersion': 1,
          }),
        ],
      );

      expect(catalog.branchChoices, <CatalogBranchChoice>[
        const CatalogBranchChoice(
          branchId: 'branch-north',
          branchName: 'North Demo Branch',
        ),
        const CatalogBranchChoice(
          branchId: 'branch-south',
          branchName: 'South Demo Branch',
        ),
      ]);
      expect(
        catalog.items.single.holdings.single.branchName,
        'North Demo Branch',
      );
      expect(catalog.items.single.holdings.single.quantityScaled, 425);
    });

    test('accepts a legacy branch document without any code', () async {
      final CatalogSnapshot catalog = await administratorCatalog(
        <CatalogDocument>[
          branchDocument('branches/branch-north', <String, Object?>{
            'name': 'North Demo Branch',
            'demoSeedVersion': 1,
          }),
        ],
      );

      expect(catalog.branchChoices.single.branchName, 'North Demo Branch');
    });

    test(
      'accepts every present code of two, three, or four uppercase letters',
      () async {
        for (final String code in <String>['NT', 'AB', 'ABC', 'ABCD', 'WXYZ']) {
          final CatalogSnapshot catalog = await administratorCatalog(
            <CatalogDocument>[
              branchDocument('branches/branch-north', branchData(code)),
            ],
          );
          expect(catalog.branchChoices.single.branchId, 'branch-north');
        }
      },
    );

    test(
      'rejects a present code that is not 2-4 uppercase ASCII letters',
      () async {
        for (final Object? code in <Object?>[
          null,
          1,
          1.5,
          true,
          <Object?>['NT'],
          <String, Object?>{'code': 'NT'},
          '',
          'N',
          'ABCDE',
          'nte',
          'Nte',
          'NTe',
          ' NT',
          'NT ',
          'N T',
          'N\tT',
          'NT\n',
          'N\u0000T',
          'NT\u007f',
          '1234',
          'N-T',
          'ÑTE',
          '\uff2e\uff34',
        ]) {
          await expectLater(
            administratorCatalog(<CatalogDocument>[
              branchDocument('branches/branch-north', branchData(code)),
            ]),
            throwsA(
              isA<CatalogRepositoryUnavailable>().having(
                (CatalogRepositoryUnavailable error) => error.message,
                'message',
                'Catalog data is unavailable or invalid.',
              ),
            ),
            reason: code is String
                ? 'should reject "$code"'
                : 'should reject ${code.runtimeType} $code',
          );
        }
      },
    );

    test('rejects unknown branch fields even next to a valid code', () async {
      for (final Map<String, Object?> data in <Map<String, Object?>>[
        <String, Object?>{...branchData('NTE'), 'Code': 'SUR'},
        <String, Object?>{...branchData('NTE'), 'cod': 'SUR'},
        <String, Object?>{...branchData('NTE'), 'note': 'renamed later'},
        <String, Object?>{...branchData('NTE'), 'createdBy': 'legacy-admin'},
        <String, Object?>{'code': 'NTE', 'demoSeedVersion': 1},
      ]) {
        await expectLater(
          administratorCatalog(<CatalogDocument>[
            branchDocument('branches/branch-north', data),
          ]),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );
      }
    });

    test(
      'keeps every branch name guard in force when a code is present',
      () async {
        for (final Object? name in <Object?>[
          null,
          42,
          '',
          'North Demo Branch ',
          ' North Demo Branch',
          'North\u0000Branch',
          'a' * 121,
        ]) {
          await expectLater(
            administratorCatalog(<CatalogDocument>[
              branchDocument('branches/branch-north', <String, Object?>{
                'name': name,
                'code': 'NTE',
                'demoSeedVersion': 1,
              }),
            ]),
            throwsA(isA<CatalogRepositoryUnavailable>()),
            reason: name is String
                ? 'should reject name "$name"'
                : 'should reject name ${name.runtimeType} $name',
          );
        }
      },
    );
  });

  group('safe load diagnostics', () {
    late List<CatalogLoadDiagnostic> reported;
    setUp(() {
      reported = <CatalogLoadDiagnostic>[];
      CatalogLoadDiagnostics.reporter = reported.add;
    });
    tearDown(CatalogLoadDiagnostics.restoreDefaultReporter);

    test('successful loads emit no diagnostic', () async {
      final _FakeCatalogReadSource source = _intakeSource(
        InventoryRole.seller,
        <CatalogDocument>[
          CatalogDocument(
            path: 'branches/branch-north/stock/DEMO-RIBBON',
            data: _intakeStock(),
          ),
        ],
      );

      await _intakeRepository(InventoryRole.seller, source).fetchCatalog();

      expect(source.calls, <String>[
        'list:branches/branch-north/stock',
        'get:products/DEMO-RIBBON',
      ]);
      expect(reported, isEmpty);
    });

    test('one sanitized line precedes the unchanged generic wrapper', () async {
      final _FakeCatalogReadSource source = _FakeCatalogReadSource(
        onListCollection: (String path) {
          if (path == 'branches/branch-north/stock') {
            throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'unavailable',
              message: 'Hostile text for products/DEMO-RIBBON token=abc123',
            );
          }
        },
      );

      await expectLater(
        _intakeRepository(InventoryRole.seller, source).fetchCatalog(),
        throwsA(
          isA<CatalogRepositoryUnavailable>().having(
            (CatalogRepositoryUnavailable error) => error.message,
            'message',
            'Catalog data is unavailable or invalid.',
          ),
        ),
      );

      expect(reported, hasLength(1));
      expect(
        reported.single.render(),
        '[catalog-load] stage=repository category=read code=unavailable',
      );
      expect(
        reported.single.toString(),
        isNot(allOf(contains('Hostile'), contains('abc123'), contains('DEMO'))),
      );
    });

    test(
      'session drift logs one session line, never a second parse line',
      () async {
        EmulatorSession? currentSession = _seller;
        final _FakeCatalogReadSource drifting = _FakeCatalogReadSource(
          collections: <String, List<CatalogDocument>>{
            'branches/branch-north/stock': <CatalogDocument>[
              CatalogDocument(
                path: 'branches/branch-north/stock/DEMO-RIBBON',
                data: _intakeStock(),
              ),
            ],
          },
          documents: <String, CatalogDocument>{
            'products/DEMO-RIBBON': CatalogDocument(
              path: 'products/DEMO-RIBBON',
              data: _product(),
            ),
          },
          onListCollection: (_) => currentSession = null,
        );

        await expectLater(
          FirestoreCatalogRepository.seller(
            source: drifting,
            session: _seller,
            sessionChecker: () async => currentSession,
          ).fetchCatalog(),
          throwsA(isA<CatalogRepositoryUnavailable>()),
        );

        expect(reported, hasLength(1));
        expect(
          reported.single.render(),
          '[catalog-load] stage=repository category=session code=none',
        );
      },
    );

    test('a throwing reporter cannot change the catalog failure', () async {
      CatalogLoadDiagnostics.reporter = (CatalogLoadDiagnostic diagnostic) =>
          throw StateError('sink failed');
      final _FakeCatalogReadSource source = _FakeCatalogReadSource(
        collections: <String, List<CatalogDocument>>{
          'branches/branch-north/stock': <CatalogDocument>[
            CatalogDocument(
              path: 'branches/branch-north/stock/DEMO-RIBBON',
              data: _intakeStock(),
            ),
          ],
        },
        documents: <String, CatalogDocument>{
          'products/DEMO-RIBBON': CatalogDocument(
            path: 'products/DEMO-RIBBON',
            data: _product(),
          ),
        },
        onGetDocument: (String path) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
            message: 'uid-42 cannot read products/DEMO-RIBBON',
          );
        },
      );

      await expectLater(
        _intakeRepository(InventoryRole.seller, source).fetchCatalog(),
        throwsA(
          isA<CatalogRepositoryUnavailable>().having(
            (CatalogRepositoryUnavailable error) => error.message,
            'message',
            'Catalog data is unavailable or invalid.',
          ),
        ),
      );
    });
  });
}
