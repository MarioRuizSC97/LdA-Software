import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart'
    show FirebaseException, Timestamp;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/movements_view.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';

import '../support/viewport.dart';
import 'movement_fixtures.dart';

MovementEntry _entry(String id, Map<String, Object?> data) =>
    parseMovementEntry(
      CatalogDocument(path: 'inventoryMovements/$id', data: data),
    );

class _Backend {
  final List<String?> loads = <String?>[];
  final List<String> profileReads = <String>[];
  final List<(String, String)> writes = <(String, String)>[];
  Future<List<MovementEntry>> Function(String? branchId) onLoad = (_) async =>
      <MovementEntry>[];
  Map<String, SellerProfileLookup> profiles = <String, SellerProfileLookup>{};
  Future<SellerProfileLookup> Function(String uid)? onRead;
  Future<SellerProfileResult> Function(String uid, String name) onWrite = (
    String uid,
    String name,
  ) async => SellerProfileResult(uid: uid, replayed: false);

  AdministratorMovements get movements => AdministratorMovements(
    load: (String? branchId) {
      loads.add(branchId);
      return onLoad(branchId);
    },
    readProfile: (String uid) async {
      profileReads.add(uid);
      final Future<SellerProfileLookup> Function(String uid)? read = onRead;
      if (read != null) return read(uid);
      return profiles[uid] ?? const SellerUnnamed();
    },
    setSellerName: (String uid, String name) {
      writes.add((uid, name));
      return onWrite(uid, name);
    },
  );
}

Widget _view(_Backend backend, {VoidCallback? onClose}) => MaterialApp(
  home: Scaffold(
    body: MovementsView(
      movements: backend.movements,
      productNames: const <String, String>{'PRD-COFFEE-001': 'Café molido'},
      branchChoices: const <CatalogBranchChoice>[
        CatalogBranchChoice(branchId: 'branch-north', branchName: 'Norte'),
        CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sur'),
      ],
      onClose: onClose ?? () {},
    ),
  ),
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

List<MovementEntry> _standardEntries() => <MovementEntry>[
  _entry('m-1', movementData()),
  _entry(
    'm-2',
    movementData(
      type: 'stock-intake',
      quantityScaled: 1000,
      actorId: 'administrator-1',
      productId: 'PRD-UNKNOWN-01',
      branchId: 'branch-south',
      extra: const <String, Object?>{'entryId': 'e-1'},
    ),
  ),
  _entry('m-3', movementData(type: 'sale-return', actorId: unnamedSellerId)),
  _entry('m-4', movementData(type: 'teleport')),
];

void main() {
  late _Backend backend;

  setUp(() {
    backend = _Backend()
      ..onLoad = ((_) async => _standardEntries())
      ..profiles = <String, SellerProfileLookup>{
        namedSellerId: const SellerNamed('Ana López'),
      };
  });

  testWidgets('rows show type, product, quantity, branch, date and actor', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_view(backend));
    await tester.pumpAndSettle();

    final Finder first = _key('movement-m-1');
    expect(find.descendant(of: first, matching: find.text('Venta')), findsOne);
    expect(
      find.descendant(of: first, matching: find.textContaining('Café molido')),
      findsOne,
    );
    expect(
      find.descendant(of: first, matching: find.textContaining('-2.50 kg')),
      findsOne,
    );
    expect(
      find.descendant(of: first, matching: find.textContaining('Norte')),
      findsOne,
    );
    expect(
      find.descendant(
        of: first,
        matching: find.textContaining('8 de octubre de 2026, 19:42'),
      ),
      findsOne,
    );
    expect(tester.widget<Text>(_key('movement-actor-m-1')).data, 'Ana López');
    expect(find.text('Editar nombre'), findsOne);

    final Finder intake = _key('movement-m-2');
    expect(
      find.descendant(of: intake, matching: find.text('Entrada de stock')),
      findsOne,
    );
    expect(
      find.descendant(
        of: intake,
        matching: find.textContaining('PRD-UNKNOWN-01'),
      ),
      findsOne,
    );
    expect(
      find.descendant(of: intake, matching: find.textContaining('+10.00 kg')),
      findsOne,
    );
    expect(
      tester.widget<Text>(_key('movement-actor-m-2')).data,
      'Administrador',
    );
    expect(
      tester.widget<Text>(_key('movement-actor-m-3')).data,
      'Vendedor sin nombre (seller…)',
    );
    expect(find.text('Asignar nombre'), findsOne);
    expect(find.text('Movimiento ilegible'), findsOne);
    // Intake never reads a profile, and each seller is read once.
    expect(backend.profileReads, <String>[namedSellerId, unnamedSellerId]);
    // Only the name is shown, never the profile branch.
    expect(find.textContaining('branch-north'), findsNothing);
  });

  testWidgets('transfer legs show both directions with an admin actor', (
    WidgetTester tester,
  ) async {
    backend.onLoad = (_) async => <MovementEntry>[
      _entry(
        'tr-1-out',
        movementData(
          type: 'transfer-out',
          branchId: 'branch-north',
          quantityScaled: -250,
          actorId: 'administrator-1',
          extra: const <String, Object?>{'transferId': 'tr-key-1'},
        ),
      ),
      _entry(
        'tr-1-in',
        movementData(
          type: 'transfer-in',
          branchId: 'branch-south',
          quantityScaled: 250,
          actorId: 'administrator-1',
          extra: const <String, Object?>{'transferId': 'tr-key-1'},
        ),
      ),
      _entry('m-1', movementData()),
    ];
    await tester.pumpWidget(_view(backend));
    await tester.pumpAndSettle();

    final Finder out = _key('movement-tr-1-out');
    expect(
      find.descendant(of: out, matching: find.text('Traslado (salida)')),
      findsOne,
    );
    expect(
      find.descendant(of: out, matching: find.textContaining('Café molido')),
      findsOne,
    );
    expect(
      find.descendant(of: out, matching: find.textContaining('-2.50 kg')),
      findsOne,
    );
    expect(
      find.descendant(of: out, matching: find.textContaining('Norte')),
      findsOne,
    );
    expect(
      tester.widget<Text>(_key('movement-actor-tr-1-out')).data,
      'Administrador',
    );

    final Finder inLeg = _key('movement-tr-1-in');
    expect(
      find.descendant(of: inLeg, matching: find.text('Traslado (entrada)')),
      findsOne,
    );
    expect(
      find.descendant(of: inLeg, matching: find.textContaining('+2.50 kg')),
      findsOne,
    );
    expect(
      find.descendant(of: inLeg, matching: find.textContaining('Sur')),
      findsOne,
    );
    expect(
      tester.widget<Text>(_key('movement-actor-tr-1-in')).data,
      'Administrador',
    );

    // Administrator rows never offer a seller-name action and never read a
    // profile; the seller row on the same screen is unchanged.
    expect(
      find.descendant(of: out, matching: find.text('Editar nombre')),
      findsNothing,
    );
    expect(
      find.descendant(of: out, matching: find.text('Asignar nombre')),
      findsNothing,
    );
    expect(find.text('Editar nombre'), findsOne);
    expect(tester.widget<Text>(_key('movement-actor-m-1')).data, 'Ana López');
    expect(backend.profileReads, <String>[namedSellerId]);
    // The transfer reference itself is never rendered as data.
    expect(find.textContaining('tr-key-1'), findsNothing);
  });

  testWidgets('a transfer leg outside the contract stays unreadable', (
    WidgetTester tester,
  ) async {
    backend.onLoad = (_) async => <MovementEntry>[
      _entry(
        'tr-bad',
        movementData(
          type: 'transfer-out',
          quantityScaled: 250,
          actorId: 'administrator-1',
          extra: const <String, Object?>{'transferId': 'tr-key-1'},
        ),
      ),
    ];
    await tester.pumpWidget(_view(backend));
    await tester.pumpAndSettle();
    expect(find.text('Movimiento ilegible'), findsOne);
    expect(find.textContaining('tr-bad'), findsOne);
    expect(find.text('Administrador'), findsNothing);
    expect(backend.profileReads, isEmpty);
  });

  testWidgets('denied and failed lookups degrade without crashing', (
    WidgetTester tester,
  ) async {
    backend.profiles = <String, SellerProfileLookup>{
      namedSellerId: const SellerProfileUnavailable(denied: true),
      unnamedSellerId: const SellerProfileUnavailable(),
    };
    await tester.pumpWidget(_view(backend));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(_key('movement-actor-m-1')).data,
      'Nombre no disponible (seller…)',
    );
    expect(
      tester.widget<Text>(_key('movement-actor-m-3')).data,
      'Nombre no disponible (seller…)',
    );
    expect(find.text('Asignar nombre'), findsNothing);
    expect(find.text('Editar nombre'), findsNothing);
  });

  testWidgets('loading, empty, error and retry states', (
    WidgetTester tester,
  ) async {
    final Completer<List<MovementEntry>> pending =
        Completer<List<MovementEntry>>();
    backend.onLoad = (_) => pending.future;
    await tester.pumpWidget(_view(backend));
    await tester.pump();
    expect(_key('movements-loading'), findsOne);

    pending.completeError(const MovementsUnavailable());
    await tester.pumpAndSettle();
    expect(find.text('No se pudieron cargar los movimientos'), findsOne);

    backend.onLoad = (_) async => <MovementEntry>[];
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(find.text('No hay movimientos'), findsOne);
    expect(backend.loads, <String?>[null, null]);
  });

  testWidgets('branch filter and refresh reload; back closes', (
    WidgetTester tester,
  ) async {
    bool closed = false;
    await tester.pumpWidget(_view(backend, onClose: () => closed = true));
    await tester.pumpAndSettle();

    await tester.tap(_key('movements-branch-filter'));
    await tester.pumpAndSettle();
    expect(find.text('Todas'), findsWidgets);
    await tester.tap(find.text('Sur').last);
    await tester.pumpAndSettle();
    expect(backend.loads, <String?>[null, 'branch-south']);

    await tester.tap(find.text('Actualizar'));
    await tester.pumpAndSettle();
    expect(backend.loads, <String?>[null, 'branch-south', 'branch-south']);

    await tester.tap(find.text('Volver'));
    expect(closed, isTrue);
  });

  testWidgets('a stale load never overwrites a newer filter', (
    WidgetTester tester,
  ) async {
    final Completer<List<MovementEntry>> slow =
        Completer<List<MovementEntry>>();
    backend.onLoad = (String? branchId) => branchId == null
        ? slow.future
        : Future<List<MovementEntry>>.value(<MovementEntry>[]);
    await tester.pumpWidget(_view(backend));
    await tester.pump();
    await tester.tap(_key('movements-branch-filter'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Norte').last);
    await tester.pumpAndSettle();
    slow.complete(_standardEntries());
    await tester.pumpAndSettle();
    expect(find.text('No hay movimientos'), findsOne);
  });

  Future<void> openForm(WidgetTester tester, String label) async {
    await tester.pumpWidget(_view(backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
    expect(find.text('Nombre del vendedor'), findsOne);
  }

  testWidgets('assigning a name updates every row of that seller', (
    WidgetTester tester,
  ) async {
    backend.onLoad = (_) async => <MovementEntry>[
      ..._standardEntries(),
      _entry(
        'm-5',
        movementData(type: 'exchange-out', actorId: unnamedSellerId),
      ),
    ];
    await openForm(tester, 'Asignar nombre');
    await tester.enterText(_key('seller-name-field'), '  Bea Ruiz  ');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    expect(backend.writes, <(String, String)>[(unnamedSellerId, 'Bea Ruiz')]);
    expect(find.text('Nombre del vendedor'), findsNothing);
    expect(tester.widget<Text>(_key('movement-actor-m-3')).data, 'Bea Ruiz');
    expect(tester.widget<Text>(_key('movement-actor-m-5')).data, 'Bea Ruiz');
    expect(find.text('Asignar nombre'), findsNothing);
    // The cache answered; no profile was read again.
    expect(backend.profileReads, <String>[namedSellerId, unnamedSellerId]);
  });

  testWidgets('editing starts from the current name; blank is refused', (
    WidgetTester tester,
  ) async {
    await openForm(tester, 'Editar nombre');
    expect(
      tester.widget<TextField>(_key('seller-name-field')).controller!.text,
      'Ana López',
    );
    await tester.enterText(_key('seller-name-field'), '   ');
    await tester.tap(find.text('Guardar'));
    await tester.pump();
    expect(find.text('Escribe un nombre de 1 a 120 caracteres.'), findsOne);
    expect(backend.writes, isEmpty);
  });

  for (final (String? reason, String message) in <(String?, String)>[
    ('not-a-seller', 'Este usuario no es vendedor'),
    (
      'invalid-branch-claim',
      'La cuenta del vendedor no tiene una sucursal válida',
    ),
    (
      'invalid-stored-profile',
      'El perfil guardado está dañado; contacta a soporte',
    ),
    (null, 'No se pudo guardar el nombre.'),
  ]) {
    testWidgets('rejection ${reason ?? 'generic'} shows its message', (
      WidgetTester tester,
    ) async {
      backend.onWrite = (_, _) async => throw SellerProfileRejectedException(
        code: reason == null ? 'permission-denied' : 'failed-precondition',
        reason: reason,
      );
      await openForm(tester, 'Asignar nombre');
      await tester.enterText(_key('seller-name-field'), 'Bea');
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOne);
      expect(find.text('Nombre del vendedor'), findsOne);
      expect(find.text('Reintentar'), findsNothing);
    });
  }

  testWidgets('uncertain offers a retry with the same name', (
    WidgetTester tester,
  ) async {
    int attempts = 0;
    backend.onWrite = (String uid, String name) async {
      attempts += 1;
      if (attempts == 1) throw const SellerProfileUncertainException();
      return SellerProfileResult(uid: uid, replayed: true);
    };
    await openForm(tester, 'Asignar nombre');
    await tester.enterText(_key('seller-name-field'), 'Bea');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'No se pudo confirmar el cambio. Reintenta con el mismo nombre.',
      ),
      findsOne,
    );
    expect(
      tester.widget<TextField>(_key('seller-name-field')).enabled,
      isFalse,
    );
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(backend.writes, <(String, String)>[
      (unnamedSellerId, 'Bea'),
      (unnamedSellerId, 'Bea'),
    ]);
    expect(tester.widget<Text>(_key('movement-actor-m-3')).data, 'Bea');
  });

  testWidgets('a late cancel re-read never overwrites a newer save', (
    WidgetTester tester,
  ) async {
    await openForm(tester, 'Asignar nombre');
    final Completer<SellerProfileLookup> lateRead =
        Completer<SellerProfileLookup>();
    backend.onRead = (_) => lateRead.future;
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Asignar nombre'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('seller-name-field'), 'Bea');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_key('movement-actor-m-3')).data, 'Bea');

    lateRead.complete(const SellerUnnamed());
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_key('movement-actor-m-3')).data, 'Bea');
    expect(find.text('Editar nombre'), findsNWidgets(2));
  });

  testWidgets('a failed cancel re-read keeps the confirmed name', (
    WidgetTester tester,
  ) async {
    await openForm(tester, 'Editar nombre');
    backend.onRead = (_) async => const SellerProfileUnavailable();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(backend.profileReads.last, namedSellerId);
    expect(tester.widget<Text>(_key('movement-actor-m-1')).data, 'Ana López');
    expect(find.text('Editar nombre'), findsOne);
  });

  for (final (String? code, String message) in <(String?, String)>[
    (
      'failed-precondition',
      'Falta un índice en la base de datos; contacta a soporte.',
    ),
    ('permission-denied', 'No tienes permiso para ver los movimientos.'),
    ('unavailable', 'No se pudieron cargar los movimientos'),
    (null, 'No se pudieron cargar los movimientos'),
  ]) {
    testWidgets('a load failure ${code ?? 'without cause'} shows its message', (
      WidgetTester tester,
    ) async {
      backend.onLoad = (_) async => throw MovementsUnavailable(
        cause: code == null
            ? null
            : FirebaseException(plugin: 'cloud_firestore', code: code),
      );
      await tester.pumpWidget(_view(backend));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOne);
      expect(find.text('Reintentar'), findsOne);
    });
  }

  testWidgets('unknown types render unreadable, not a crash', (
    WidgetTester tester,
  ) async {
    backend.onLoad = (_) async => <MovementEntry>[
      _entry('bad', <String, Object?>{'occurredAt': Timestamp.now()}),
    ];
    await tester.pumpWidget(_view(backend));
    await tester.pumpAndSettle();
    expect(find.text('Movimiento ilegible'), findsOne);
    expect(find.textContaining('bad'), findsOne);
  });

  group('responsive and accessible layout', () {
    for (final double scale in <double>[1, 2]) {
      testWidgets('fits 320px at text scale $scale', (
        WidgetTester tester,
      ) async {
        useViewport(tester, const Size(320, 900), scale);
        await tester.pumpWidget(_view(backend));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(_key('movement-m-1'), findsOne);
        expect(find.text('Editar nombre'), findsOne);
      });
    }

    testWidgets('rows stay readable width on wide screens', (
      WidgetTester tester,
    ) async {
      useViewport(tester, const Size(1600, 900));
      await tester.pumpWidget(_view(backend));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(_key('movement-m-1')).width,
        lessThanOrEqualTo(920),
      );
    });

    testWidgets('the branch filter announces its purpose', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pumpWidget(_view(backend));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel(RegExp('Filtrar por sucursal')), findsOne);
      semantics.dispose();
    });

    testWidgets('a movement row reads as one announcement', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pumpWidget(_view(backend));
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(
          RegExp('Venta.*Café molido.*Norte.*Ana López', dotAll: true),
        ),
        findsOne,
      );
      // The name action stays its own focusable button.
      expect(find.bySemanticsLabel('Editar nombre'), findsOne);
      semantics.dispose();
    });
  });

  testWidgets('the movements view meets tap target guidelines', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(_view(backend));
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
