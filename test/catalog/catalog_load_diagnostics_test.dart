import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_load_diagnostics.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

const String _wrapperMessage = 'Catalog data is unavailable or invalid.';

/// Fails every seller read with a prepared transport error.
class _ThrowingSource implements CatalogReadSource {
  _ThrowingSource(this.failure);

  final Object failure;
  final List<String> calls = <String>[];

  @override
  Future<CatalogDocument> getDocument(String path) async {
    calls.add('get:$path');
    throw failure;
  }

  @override
  Future<List<CatalogDocument>> listCollection(String path) async {
    calls.add('list:$path');
    throw failure;
  }

  @override
  Future<List<CatalogDocument>> listCollectionGroup(String id) async {
    calls.add('group:$id');
    throw failure;
  }
}

/// Serves an empty seller stock collection so only session checks can fail.
class _SilentSource implements CatalogReadSource {
  @override
  Future<CatalogDocument> getDocument(String path) async =>
      throw StateError('unexpected read');

  @override
  Future<List<CatalogDocument>> listCollection(String path) async {
    if (path == 'branches/branch-north/stock') return const <CatalogDocument>[];
    throw StateError('unexpected read');
  }

  @override
  Future<List<CatalogDocument>> listCollectionGroup(String id) async =>
      const <CatalogDocument>[];
}

FirestoreCatalogRepository _sellerRepository(
  CatalogReadSource source, {
  ActiveSessionChecker? sessionChecker,
}) => FirestoreCatalogRepository.seller(
  source: source,
  session: _seller,
  sessionChecker: sessionChecker ?? () async => _seller,
);

Future<Object> _failureFrom(Future<Object> Function() body) async {
  try {
    return await body();
  } catch (error) {
    return error;
  }
}

/// A value that is not an SDK error: its text and runtime type must never be
/// turned into console output.
class _Hostile {
  const _Hostile(this.secret);

  final String secret;

  @override
  String toString() => '_Hostile: $secret';
}

void main() {
  late List<CatalogLoadDiagnostic> reported;

  setUp(() {
    reported = <CatalogLoadDiagnostic>[];
    CatalogLoadDiagnostics.reporter = reported.add;
  });
  tearDown(CatalogLoadDiagnostics.restoreDefaultReporter);

  String singleDiagnostic() {
    expect(reported, hasLength(1), reason: '$reported');
    return reported.single.render();
  }

  void expectNoSecrets(String rendered, Iterable<String> secrets) {
    for (final String secret in secrets) {
      expect(rendered, isNot(contains(secret)), reason: 'leaked: $secret');
    }
  }

  group('repository boundary', () {
    test(
      'transport failure logs one fixed line, then the generic wrapper',
      () async {
        final Object failure = await _failureFrom(
          () => _sellerRepository(
            _ThrowingSource(
              FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
            ),
          ).fetchCatalog(),
        );

        expect(
          failure,
          isA<CatalogRepositoryUnavailable>().having(
            (CatalogRepositoryUnavailable error) => error.message,
            'message',
            _wrapperMessage,
          ),
        );
        expect(
          singleDiagnostic(),
          '[catalog-load] stage=repository category=read code=unavailable',
        );
      },
    );

    test('session fence logs category session exactly once', () async {
      final Object failure = await _failureFrom(
        () => _sellerRepository(
          _SilentSource(),
          sessionChecker: () async => null,
        ).fetchCatalog(),
      );

      expect(failure, isA<CatalogRepositoryUnavailable>());
      expect(
        singleDiagnostic(),
        '[catalog-load] stage=repository category=session code=none',
      );
    });

    test('document validation failure logs category parse', () async {
      await _failureFrom(
        () => _sellerRepository(
          _ThrowingSource(const FormatException('stock path is hostile')),
        ).fetchCatalog(),
      );

      final String rendered = singleDiagnostic();
      expect(
        rendered,
        '[catalog-load] stage=repository category=parse code=none',
      );
      expectNoSecrets(rendered, <String>['hostile', 'stock path']);
    });

    test('missing document logs category read', () async {
      await _failureFrom(
        () => _sellerRepository(
          _ThrowingSource(StateError('products/DEMO-RIBBON token=abc')),
        ).fetchCatalog(),
      );

      final String rendered = singleDiagnostic();
      expect(
        rendered,
        '[catalog-load] stage=repository category=read code=none',
      );
      expectNoSecrets(rendered, <String>['DEMO-RIBBON', 'token=abc', 'abc']);
    });
  });

  group('finite allowlist', () {
    test('unknown Firestore codes collapse to the fixed fallback', () async {
      const List<String> hostileCodes = <String>[
        'secret-token-abc123',
        'products/DEMO-RIBBON denied for uid-42',
        'deadline-exceeded-after-30s-host-10-0-0-8',
      ];
      for (final String code in hostileCodes) {
        reported.clear();
        await _failureFrom(
          () => _sellerRepository(
            _ThrowingSource(
              FirebaseException(plugin: 'cloud_firestore', code: code),
            ),
          ).fetchCatalog(),
        );

        final String rendered = singleDiagnostic();
        expect(
          rendered,
          '[catalog-load] stage=repository category=read code=other',
        );
        expectNoSecrets(rendered, <String>[code, 'abc123', 'uid-42', 'DEMO']);
      }
    });

    test('arbitrary plugin names are never emitted', () async {
      const String hostilePlugin = 'evil_plugin_with_credentials';
      await _failureFrom(
        () => _sellerRepository(
          _ThrowingSource(
            FirebaseException(plugin: hostilePlugin, code: 'unavailable'),
          ),
        ).fetchCatalog(),
      );

      final String rendered = singleDiagnostic();
      expect(
        rendered,
        '[catalog-load] stage=repository category=unknown code=unavailable',
      );
      expectNoSecrets(rendered, <String>[hostilePlugin, 'evil', 'credentials']);
    });

    test(
      'non-Firebase objects log category unknown without their own text',
      () async {
        await _failureFrom(
          () => _sellerRepository(
            _ThrowingSource(const _Hostile('token=SHOULD_NOT_APPEAR')),
          ).fetchCatalog(),
        );

        final String rendered = singleDiagnostic();
        expect(
          rendered,
          '[catalog-load] stage=repository category=unknown code=none',
        );
        expectNoSecrets(rendered, <String>[
          'SHOULD_NOT_APPEAR',
          '_Hostile',
          'token',
        ]);
      },
    );

    test('auth codes map to a fixed session category at bootstrap', () async {
      reportCatalogBootstrapFailure(
        FirebaseException(plugin: 'firebase_auth', code: 'invalid-credential'),
      );

      expect(
        singleDiagnostic(),
        '[catalog-load] stage=bootstrap category=session code=invalid-credential',
      );
    });
  });

  group('bootstrap loader boundary', () {
    test('loader failure before the repository is reached is logged', () async {
      final FirebaseException initialisation = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'deadline-exceeded',
      );

      expect(
        await _failureFrom(
          () => guardCatalogBootstrap(() async => throw initialisation),
        ),
        same(initialisation),
      );
      expect(
        singleDiagnostic(),
        '[catalog-load] stage=bootstrap category=read code=deadline-exceeded',
      );
    });

    test('wrapped repository failures are not logged twice', () async {
      expect(
        await _failureFrom(
          () => guardCatalogBootstrap(
            () => _sellerRepository(
              _ThrowingSource(
                FirebaseException(
                  plugin: 'cloud_firestore',
                  code: 'unavailable',
                ),
              ),
            ).fetchCatalog(),
          ),
        ),
        isA<CatalogRepositoryUnavailable>(),
      );

      expect(reported, hasLength(1));
      expect(reported.single.stage, CatalogDiagnosticStage.repository);
      expect(
        reported.single.render(),
        '[catalog-load] stage=repository category=read code=unavailable',
      );

      // A later, genuinely different bootstrap failure is still reported.
      expect(
        await _failureFrom(
          () => guardCatalogBootstrap(
            () async => throw StateError('bootstrap only'),
          ),
        ),
        isA<StateError>(),
      );
      expect(reported, hasLength(2));
      expect(reported.last.stage, CatalogDiagnosticStage.bootstrap);
      expect(
        reported.last.render(),
        '[catalog-load] stage=bootstrap category=read code=none',
      );
    });

    test('session fence inside the loader stays a single line', () async {
      await _failureFrom(
        () => guardCatalogBootstrap(
          () => _sellerRepository(
            _SilentSource(),
            sessionChecker: () async => null,
          ).fetchCatalog(),
        ),
      );

      expect(reported, hasLength(1));
      expect(reported.single.category, CatalogDiagnosticCategory.session);
      expect(reported.single.stage, CatalogDiagnosticStage.repository);
    });

    test('a successful load reports nothing', () async {
      expect(
        await guardCatalogBootstrap(
          () => _sellerRepository(_SilentSource()).fetchCatalog(),
        ),
        isA<CatalogSnapshot>(),
      );
      expect(reported, isEmpty);
    });
  });

  group('reporter failures stay isolated', () {
    test(
      'a throwing reporter changes neither catalog nor bootstrap failure',
      () async {
        CatalogLoadDiagnostics.reporter = (CatalogLoadDiagnostic diagnostic) =>
            throw StateError('logger down');

        final Object repositoryFailure = await _failureFrom(
          () => _sellerRepository(
            _ThrowingSource(
              FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
            ),
          ).fetchCatalog(),
        );
        expect(
          repositoryFailure,
          isA<CatalogRepositoryUnavailable>().having(
            (CatalogRepositoryUnavailable error) => error.message,
            'message',
            _wrapperMessage,
          ),
        );

        final FirebaseException bootstrapFailure = FirebaseException(
          plugin: 'firebase_auth',
          code: 'network-request-failed',
        );
        expect(
          await _failureFrom(
            () => guardCatalogBootstrap(() async => throw bootstrapFailure),
          ),
          same(bootstrapFailure),
        );
      },
    );
  });
}
