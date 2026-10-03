import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
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

void main() {
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
}
