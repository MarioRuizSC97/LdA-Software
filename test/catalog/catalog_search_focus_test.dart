import 'dart:ui' show ImageFilter, PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';

import '../sales/sale_ui_fixtures.dart';

Finder _key(String key) => find.byKey(ValueKey<String>(key));
Finder get _field => _key('catalog-search');
Finder get _results => _key('catalog-search-results');
Finder _result(String key) =>
    find.descendant(of: _results, matching: _key(key));

Future<FakeSaleCheckout> _pump(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  VoidCallback? onLogout,
  bool reduceMotion = false,
}) async {
  final sales = FakeSaleCheckout();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations:
              reduceMotion || MediaQuery.disableAnimationsOf(context),
        ),
        child: child!,
      ),
      home: AuthenticatedCatalogPage(
        session: const EmulatorSession(
          userId: 'seller-north',
          email: 'seller@demo.invalid',
          role: InventoryRole.seller,
          branchId: 'branch-north',
        ),
        catalogLoader: (_) async => sellerSaleSnapshot(),
        onLogout: () async {
          onLogout?.call();
        },
        saleCheckout: sales.checkout,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return sales;
}

Future<void> _type(WidgetTester tester, [String query = 'Pin']) async {
  await tester.enterText(_field, query);
  await tester.pumpAndSettle();
}

String _query(WidgetTester tester) =>
    tester.widget<TextField>(_field).controller!.text;

void main() {
  testWidgets('focus blurs the whole scrim even before typing', (tester) async {
    await _pump(tester);
    final resting = tester.getRect(_key('catalog-search-lift'));
    await tester.tap(_field);
    await tester.pumpAndSettle();
    final blur = _key('catalog-search-blur');
    expect(blur, findsOneWidget);
    expect(tester.getRect(blur), tester.getRect(_key('catalog-search-scrim')));
    final clip = tester.widget<ClipPath>(
      find.ancestor(of: blur, matching: find.byType(ClipPath)).first,
    );
    final path = clip.clipper!.getClip(tester.getSize(blur));
    expect(path.contains(resting.center), isFalse);
    expect(path.contains(const Offset(4, 4)), isTrue);
    await _type(tester);
    expect(
      find.ancestor(of: _results, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets('$platform focus zoom is centered and returns to rest', (
      tester,
    ) async {
      await _pump(tester, platform: platform);
      final resting = tester.getRect(_key('catalog-search-lift'));
      await tester.tap(_field);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = tester.getRect(_key('catalog-search-lift'));
      expect(mid.width, greaterThan(resting.width));
      expect(mid.width, lessThan(resting.width * 1.041));
      expect(mid.center, resting.center);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.getRect(_key('catalog-search-lift')), resting);
    });
  }

  testWidgets('reduced motion never scales the field', (tester) async {
    await _pump(tester, reduceMotion: true);
    final resting = tester.getRect(_key('catalog-search-lift'));
    await tester.tap(_field);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(_key('catalog-search-lift')), resting);
    expect(
      tester
          .widget<AnimatedOpacity>(_key('catalog-search-scrim-fade'))
          .duration,
      Duration.zero,
    );
  });

  testWidgets('scrim covers chrome and app bar tap dismisses without action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var logouts = 0;
    await _pump(
      tester,
      platform: TargetPlatform.macOS,
      onLogout: () => logouts++,
    );
    expect(find.semantics.byLabel('Cerrar sesión'), findsOne);
    expect(find.semantics.byLabel('Abrir carrito. Carrito vacío'), findsOne);
    final cart = _key('sale-cart-button');
    final cartPoint = tester.getCenter(cart);
    final headerPoint = tester.getCenter(find.text('Cerrar sesión'));
    await _type(tester);
    final scrim = tester.getRect(_key('catalog-search-scrim'));
    expect(scrim.contains(headerPoint), isTrue);
    expect(scrim.contains(cartPoint), isTrue);
    expect(find.semantics.byLabel('Cerrar sesión'), findsNothing);
    expect(
      find.semantics.byLabel('Abrir carrito. Carrito vacío'),
      findsNothing,
    );
    for (final chrome in [find.byType(AppBar), cart]) {
      expect(
        find.ancestor(
          of: chrome,
          matching: find.byWidgetPredicate(
            (w) => w is ExcludeFocus && w.excluding,
          ),
        ),
        findsWidgets,
      );
    }
    await tester.tapAt(cartPoint);
    await tester.pumpAndSettle();
    expect(find.text('Carrito'), findsNothing);
    expect(_query(tester), 'Pin');
    await _type(tester);
    await tester.tapAt(headerPoint);
    await tester.pumpAndSettle();
    expect(_results, findsNothing);
    expect(_query(tester), 'Pin');
    expect(logouts, 0);
    semantics.dispose();
  });

  testWidgets('desktop results share both search field edges', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, platform: TargetPlatform.macOS);
    final field = tester.getRect(_key('catalog-search-lift'));
    await _type(tester);
    final results = tester.getRect(_results);
    expect(results.left, field.left);
    expect(results.right, field.right);
  });

  testWidgets('focus fades the scrim and lifts the search field', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_field);
    await tester.pump();
    final fade = tester.widget<AnimatedOpacity>(
      _key('catalog-search-scrim-fade'),
    );
    expect(fade.opacity, 1);
    expect(fade.duration, const Duration(milliseconds: 200));
    expect(fade.curve, Curves.easeOutCubic);
    expect(
      tester.widget<Material>(_key('catalog-search-lift')).elevation,
      greaterThan(0),
    );
    await tester.pumpAndSettle();
    expect(_results, findsNothing);
  });

  for (final exit in ['scrim', 'Escape', 'back']) {
    testWidgets('$exit leaves focus mode without clearing the filtered query', (
      tester,
    ) async {
      await _pump(tester);
      await _type(tester);
      if (exit == 'scrim') {
        await tester.tapAt(
          tester.getBottomLeft(_key('catalog-search-scrim')) +
              const Offset(4, -4),
        );
      } else if (exit == 'Escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(_results, findsNothing);
      expect(_query(tester), 'Pin');
      expect(_key('product-card-DEMO-PIN'), findsOneWidget);
      expect(find.text('Ribbon'), findsNothing);
      expect(tester.widget<TextField>(_field).focusNode!.hasFocus, isFalse);
    });
  }

  testWidgets('results blur the backdrop and reuse matching full cards', (
    tester,
  ) async {
    await _pump(tester);
    await _type(tester, '  PIN  ');
    expect(_result('product-card-DEMO-PIN'), findsOneWidget);
    expect(_result('product-card-DEMO-RIBBON'), findsNothing);
    expect(
      find.descendant(of: _results, matching: find.text('Precio: 2.50 MXN')),
      findsOneWidget,
    );
    final blur = tester.widget<BackdropFilter>(_key('catalog-search-blur'));
    expect(blur.filter, ImageFilter.blur(sigmaX: 5, sigmaY: 5));
    await tester.tap(_result('product-details-DEMO-PIN'));
    await tester.pumpAndSettle();
    expect(_key('product-sheet-DEMO-PIN'), findsOneWidget);
  });

  testWidgets(
    'Agregar sells once from results and shows the existing stepper',
    (tester) async {
      final sales = await _pump(tester);
      await _type(tester);
      await tester.tap(_result('sale-add-DEMO-PIN'));
      await tester.pumpAndSettle();
      expect(_result('sale-line-edit-DEMO-PIN'), findsOneWidget);
      expect(sales.quotedCarts.single.lines.single.quantity, '1');
    },
  );

  testWidgets('desktop mouse can sell directly from focused results', (
    tester,
  ) async {
    final sales = await _pump(tester, platform: TargetPlatform.macOS);
    await _type(tester);
    await tester.tap(
      _result('sale-add-DEMO-PIN'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(sales.quotedCarts.single.lines.single.quantity, '1');
    expect(_result('sale-line-edit-DEMO-PIN'), findsOneWidget);
  });

  testWidgets('long press on a result opens the unchanged detail peek', (
    tester,
  ) async {
    await _pump(tester);
    await _type(tester);
    await tester.longPress(_result('product-card-DEMO-PIN'));
    await tester.pumpAndSettle();
    expect(_key('product-sheet-DEMO-PIN'), findsOneWidget);
  });

  testWidgets(
    'whitespace has no results overlay and clear keeps the field usable',
    (tester) async {
      await _pump(tester);
      await _type(tester, '   ');
      expect(_results, findsNothing);
      await _type(tester);
      await tester.tap(_key('catalog-search-clear'));
      await tester.pumpAndSettle();
      expect(_results, findsNothing);
      expect(_query(tester), isEmpty);
      await _type(tester, 'Ribbon');
      expect(_result('product-card-DEMO-RIBBON'), findsOneWidget);
    },
  );

  testWidgets(
    'no match offers the existing message and clear action in results',
    (tester) async {
      await _pump(tester);
      await _type(tester, 'missing');
      expect(
        find.descendant(of: _results, matching: find.text('Sin resultados')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: _results, matching: find.text('Limpiar búsqueda')),
      );
      await tester.pumpAndSettle();
      expect(_query(tester), isEmpty);
      expect(_results, findsNothing);
    },
  );

  testWidgets('only the results cards receive pointers, semantics and focus', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);
    await _type(tester);
    expect(_key('sale-add-DEMO-PIN').hitTestable(), findsOneWidget);
    expect(find.semantics.byLabel('Agregar Pin al carrito'), findsOne);
    final grid = _key('catalog-search-grid');
    expect(
      find.ancestor(
        of: grid,
        matching: find.byWidgetPredicate(
          (w) => w is IgnorePointer && w.ignoring,
        ),
      ),
      findsWidgets,
    );
    expect(
      find.ancestor(
        of: grid,
        matching: find.byWidgetPredicate(
          (w) => w is ExcludeFocus && w.excluding,
        ),
      ),
      findsWidgets,
    );
    semantics.dispose();
  });

  testWidgets('reduced motion shows and hides focus mode instantly', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pump(tester);
    await tester.tap(_field);
    await tester.pump();
    expect(
      tester
          .widget<AnimatedOpacity>(_key('catalog-search-scrim-fade'))
          .duration,
      Duration.zero,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(_key('catalog-search-scrim-fade')).opacity,
      0,
    );
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform results fit 360px, text scale 2 and keyboard', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester, platform: platform);
      await _type(tester);
      expect(_results, findsOneWidget);
      expect(tester.getBottomRight(_results).dy, lessThanOrEqualTo(564));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(_result('product-details-DEMO-PIN'));
      await tester.pumpAndSettle();
      await tester.tap(_result('product-details-DEMO-PIN'));
      await tester.pumpAndSettle();
      expect(_key('product-sheet-DEMO-PIN'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
